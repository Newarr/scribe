import Foundation

/// Owns one session's transcription retry loop. The worker reads the current
/// status from disk on construction (so it can resume mid-retry across launches),
/// runs the engine, and persists `pending` -> `retrying` -> `complete | failed`
/// transitions to `transcript.md`.
///
/// Cancellation: `Task.cancel()` on the run() task interrupts `Task.sleep` and
/// breaks the loop. The on-disk status stays at `retrying` so a future
/// SessionSupervisor scan can resume.
public actor TranscriptionWorker {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    public enum FinalState: Equatable, Sendable {
        case complete
        case failed(reason: String)
        case cancelled
    }

    public typealias PrepareAudio = @Sendable () async throws -> Void

    private let directory: SessionDirectory
    private let context: TranscriptContext
    private let engine: TranscriptionEngine
    private let request: EngineRequest
    private let speakerMapping: [String: String]
    private let policy: RetryPolicy
    private let sleep: Sleep
    private let prepareAudio: PrepareAudio

    public init(
        directory: SessionDirectory,
        context: TranscriptContext,
        engine: TranscriptionEngine,
        request: EngineRequest,
        speakerMapping: [String: String] = [:],
        policy: RetryPolicy = .cloud,
        sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        prepareAudio: @escaping PrepareAudio = { /* no-op: caller handled prep */ }
    ) {
        self.directory = directory
        self.context = context
        self.engine = engine
        self.request = request
        self.speakerMapping = speakerMapping
        self.policy = policy
        self.sleep = sleep
        self.prepareAudio = prepareAudio
    }

    public func run() async -> FinalState {
        // Skip work if the on-disk transcript is already terminal. This makes
        // the worker idempotent: SessionSupervisor can re-dispatch without
        // re-running completed work.
        if let existing = TranscriptStatusReader.read(at: directory.transcript),
           existing == .complete || existing == .failed {
            return existing == .complete ? .complete : .failed(reason: "already terminal on disk")
        }

        // One-shot audio preparation before the retry loop. Failure here is
        // terminal — if we can't even build the upload audio, retry won't fix it.
        do {
            try await prepareAudio()
        } catch is CancellationError {
            return .cancelled
        } catch {
            let reason = "Audio preparation failed: \(error)"
            writeFailed(reason: reason)
            return .failed(reason: reason)
        }

        var failedAttempts = 0
        while true {
            if Task.isCancelled { return .cancelled }
            do {
                let response = try await engine.transcribe(request)
                if response.utterances.isEmpty {
                    let msg = "No speech detected. The audio tracks may be silent, corrupt, or below the engine's detection threshold."
                    writeFailed(reason: msg)
                    return .failed(reason: msg)
                }
                let completedContext = TranscriptContext(
                    title: context.title,
                    date: context.date,
                    engine: context.engine,
                    audioRelativePaths: context.audioRelativePaths,
                    startedAt: context.startedAt,
                    endedAt: context.endedAt,
                    attendees: context.attendees,
                    language: response.detectedLanguage
                )
                do {
                    try TranscriptWriter.writeComplete(
                        at: directory.transcript,
                        context: completedContext,
                        utterances: response.utterances,
                        speakerMapping: speakerMapping
                    )
                } catch {
                    Log.engine.error("writeComplete failed: \(String(describing: error), privacy: .public)")
                    return .failed(reason: "transcript write failed: \(error)")
                }
                return .complete
            } catch is CancellationError {
                return .cancelled
            } catch {
                if !Self.isTransient(error) {
                    let reason = String(describing: error)
                    writeFailed(reason: reason)
                    return .failed(reason: reason)
                }
                failedAttempts += 1
                guard let delay = policy.nextDelay(afterFailedAttempts: failedAttempts - 1) else {
                    let reason = "retry budget exhausted: \(error)"
                    writeFailed(reason: reason)
                    return .failed(reason: reason)
                }
                writeRetrying(failedAttempts: failedAttempts, lastError: error)
                Log.engine.info("Transcription transient failure, attempt=\(failedAttempts, privacy: .public), nextDelay=\(delay, privacy: .public)s")
                do {
                    try await sleep(delay)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .cancelled
                }
            }
        }
    }

    private func writeRetrying(failedAttempts: Int, lastError: Error) {
        // We intentionally re-use writeFailed's body shape but stamp `status: retrying`.
        // TranscriptWriter doesn't currently expose a writeRetrying call; produce the
        // equivalent file inline so we don't drift from the writer's shape.
        let body = """
        ---
        schema: transcriber/v1
        status: retrying
        title: "\(context.title.replacingOccurrences(of: "\"", with: "\\\""))"
        date: \(context.date)
        engine: \(context.engine)
        audio:
        \(context.audioRelativePaths.map { "  - \($0)" }.joined(separator: "\n"))
        started_at: \(context.startedAt)
        ended_at: \(context.endedAt)
        attempts: \(failedAttempts)
        ---

        # \(context.title)

        > Transcription failed (attempt \(failedAttempts)/\(policy.maxAttempts)). Retrying.
        >
        > Last error: \(String(describing: lastError))
        """
        do {
            try body.write(to: directory.transcript, atomically: true, encoding: .utf8)
        } catch {
            Log.engine.error("writeRetrying failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func writeFailed(reason: String) {
        do {
            try TranscriptWriter.writeFailed(at: directory.transcript, context: context, errorMessage: reason)
        } catch {
            Log.engine.error("writeFailed failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Classifies whether an error from the engine should retry. Transient:
    /// rate-limited, HTTP 5xx, network/timeout. Terminal: auth failures,
    /// missing API key, malformed responses, unknown errors.
    public static func isTransient(_ error: Error) -> Bool {
        if let backendErr = error as? ElevenLabsScribeBackend.BackendError {
            switch backendErr {
            case .rateLimited: return true
            case .httpError(let code): return (500...599).contains(code)
            case .unauthorized, .missingAPIKey, .malformedResponse: return false
            }
        }
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                 .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        return false
    }
}
