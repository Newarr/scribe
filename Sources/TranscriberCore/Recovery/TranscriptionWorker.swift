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
        // Read the on-disk transcript once. Used both to skip already-terminal
        // sessions AND to recover the retry attempt count after an app relaunch
        // mid-backoff (codex slice-7 P2.2).
        let existing = TranscriptFrontmatterReader.read(at: directory.transcript)

        if let existing, existing.status == .complete || existing.status == .failed {
            return existing.status == .complete ? .complete : .failed(reason: "already terminal on disk")
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

        // Resume from the persisted attempt count, not from zero, so a relaunch
        // during the 5m/30m backoff doesn't grant a fresh retry budget.
        var failedAttempts = existing?.attempts ?? 0
        while true {
            if Task.isCancelled { return .cancelled }
            do {
                let response = try await engine.transcribe(request)
                if response.utterances.isEmpty {
                    let msg = "No speech detected. The audio tracks may be silent, corrupt, or below the engine's detection threshold."
                    writeFailed(reason: msg)
                    return .failed(reason: msg)
                }
                // Slice 9a output contract: produce audio.m4a (mixed playback
                // file) before writing the completed transcript so the
                // transcript can reference audio.m4a as the canonical
                // audio path. AudioFinalizer mixes mic.m4a + system.m4a;
                // failure here is terminal but the engine's response is
                // already in hand — we still write the complete transcript
                // pointing at raw streams as fallback.
                let audioFinalURL = directory.url.appendingPathComponent("audio.m4a")
                var completedAudioPath = "audio.m4a"
                do {
                    try await AudioFinalizer.finalize(
                        mic: directory.micFinal,
                        system: directory.systemFinal,
                        output: audioFinalURL,
                        sampleRate: 48000
                    )
                } catch {
                    Log.engine.error("AudioFinalizer failed; transcript will reference raw streams: \(String(describing: error), privacy: .public)")
                    // Fall back to raw streams in the completed transcript;
                    // user can still play mic.m4a + system.m4a.
                    completedAudioPath = ""
                }

                let completedContext = TranscriptContext(
                    title: context.title,
                    date: context.date,
                    engine: context.engine,
                    audioRelativePaths: completedAudioPath.isEmpty
                        ? context.audioRelativePaths
                        : [completedAudioPath],
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
                // metadata.json — JSON mirror of the frontmatter so agents
                // and downstream pipelines have a machine-readable surface
                // (spec lines 285-288).
                let metadataURL = directory.url.appendingPathComponent("metadata.json")
                let metadata = MetadataJSONWriter.Metadata(
                    status: .complete,
                    context: completedContext,
                    audio: completedAudioPath.isEmpty ? "mic.m4a" : completedAudioPath
                )
                do {
                    try MetadataJSONWriter.write(at: metadataURL, metadata: metadata)
                } catch {
                    Log.engine.error("metadata.json write failed: \(String(describing: error), privacy: .public)")
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
        // Build the retrying-status frontmatter inline. Must mirror every field
        // the supervisor's TranscriptFrontmatterReader knows how to restore,
        // including language + attendees, so a relaunch during the backoff
        // doesn't lose the calendar-enriched metadata that was on the original
        // pending transcript (codex slice-7 final-review P2.2).
        var lines: [String] = ["---", "schema: transcriber/v1", "status: retrying"]
        lines.append("title: \"\(Self.yamlEscape(context.title))\"")
        lines.append("date: \(context.date)")
        lines.append("engine: \(context.engine)")
        if let lang = context.language { lines.append("language: \(lang)") }
        if context.audioRelativePaths.count == 1 {
            lines.append("audio: \"\(Self.yamlEscape(context.audioRelativePaths[0]))\"")
        } else {
            lines.append("audio:")
            for p in context.audioRelativePaths { lines.append("  - \"\(Self.yamlEscape(p))\"") }
        }
        lines.append("started_at: \(context.startedAt)")
        lines.append("ended_at: \(context.endedAt)")
        if !context.attendees.isEmpty {
            lines.append("attendees:")
            for a in context.attendees { lines.append("  - \"\(Self.yamlEscape(a))\"") }
        }
        lines.append("attempts: \(failedAttempts)")
        lines.append("---")
        lines.append("")
        lines.append("# \(context.title)")
        lines.append("")
        lines.append("> Transcription failed (attempt \(failedAttempts)/\(policy.maxAttempts)). Retrying.")
        lines.append(">")
        lines.append("> Last error: \(String(describing: lastError))")

        let body = lines.joined(separator: "\n")
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

    /// Same escape rules as TranscriptWriter.yamlEscape — duplicated here
    /// because writeRetrying is built inline rather than via the writer.
    private static func yamlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
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
