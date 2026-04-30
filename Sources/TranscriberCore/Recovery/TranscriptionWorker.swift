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
    /// The original engine request as constructed by the caller. May
    /// have `languageCode == nil`, in which case the language detector
    /// (Phase ν) gets a chance to fill it in before the engine call.
    private let request: EngineRequest
    private let speakerMapping: [String: String]
    private let policy: RetryPolicy
    private let sleep: Sleep
    private let prepareAudio: PrepareAudio
    /// Phase ι: spec line 102. Default OFF means raw mic.m4a +
    /// system.m4a get DELETED after transcription succeeds AND
    /// audio.m4a is on disk. NEVER deleted on pending / retrying /
    /// failed states (they may be needed for retry or recovery).
    private let keepRawStreams: Bool
    /// Phase ν: spec line 129. Whisper-tiny pre-pass for language ID.
    /// `nil` means skip detection (engine auto-detects). Detection runs
    /// once per session, before the retry loop, against the mic file.
    private let languageDetector: LanguageDetector?
    /// The canonical audio file path used in transcript + metadata. Either
    /// "audio.m4a" (after AudioFinalizer succeeded) or "" (use raw streams).
    /// Set once per run() invocation by `prepareCanonicalAudio`.
    private var canonicalAudioPath: String = ""

    public init(
        directory: SessionDirectory,
        context: TranscriptContext,
        engine: TranscriptionEngine,
        request: EngineRequest,
        speakerMapping: [String: String] = [:],
        policy: RetryPolicy = .cloud,
        sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        prepareAudio: @escaping PrepareAudio = { /* no-op: caller handled prep */ },
        keepRawStreams: Bool = false,
        languageDetector: LanguageDetector? = nil
    ) {
        self.directory = directory
        self.context = context
        self.engine = engine
        self.request = request
        self.speakerMapping = speakerMapping
        self.policy = policy
        self.sleep = sleep
        self.prepareAudio = prepareAudio
        self.keepRawStreams = keepRawStreams
        self.languageDetector = languageDetector
    }

    public func run() async -> FinalState {
        // Read the on-disk transcript once. Used both to skip already-terminal
        // sessions AND to recover the retry attempt count after an app relaunch
        // mid-backoff (codex slice-7 P2.2).
        let existing = TranscriptFrontmatterReader.read(at: directory.transcript)

        if let existing, existing.status == .complete || existing.status == .failed {
            return existing.status == .complete ? .complete : .failed(reason: "already terminal on disk")
        }

        // Phase γ: atomic per-session claim. Two workers running against the
        // same directory (running app + relaunched supervisor scan racing on
        // the same pending session) would clobber each other's writes.
        // acquire returns nil if a live worker holds the claim — return
        // cancelled so the caller knows we declined cleanly.
        guard let claimToken = SessionClaim.acquire(at: directory.claim) else {
            Log.engine.info("Worker declined: claim held by another process")
            return .cancelled
        }
        // Heartbeat task keeps the claim alive while we work. Cancellation
        // flows through to the heartbeat loop on every exit path.
        let heartbeatTask = Task { [claimToken] in
            while Task.isCancelled == false {
                SessionClaim.heartbeat(claimToken)
                try? await Task.sleep(nanoseconds: UInt64(SessionClaim.defaultHeartbeatInterval * 1_000_000_000))
            }
        }
        defer {
            heartbeatTask.cancel()
            SessionClaim.release(claimToken)
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

        // Slice 9a output contract: produce audio.m4a (mixed playback file)
        // up front, BEFORE the retry loop, so it exists for every terminal
        // state — including failed transcripts (codex slice-9a review P2.1).
        // Spec line 280's failed-transcript template ("Audio was captured
        // and saved as audio.m4a") requires this.
        let canonicalAudioPath = await prepareCanonicalAudio()

        // Phase ν: spec line 129. Run language detection (Whisper-tiny
        // pre-pass) before the engine call, but only if the caller
        // didn't already specify a language. The detector reads the mic
        // file (the user's voice carries the strongest language signal;
        // system audio can be music / silence / a different language).
        // Failure here is non-fatal — fall through to engine auto-detect.
        let resolvedRequest = await resolveLanguage(for: request)

        // Resume from the persisted attempt count, not from zero, so a relaunch
        // during the 5m/30m backoff doesn't grant a fresh retry budget.
        var failedAttempts = existing?.attempts ?? 0
        while true {
            if Task.isCancelled { return .cancelled }
            do {
                let response = try await engine.transcribe(resolvedRequest)
                if response.utterances.isEmpty {
                    let msg = "No speech detected. The audio tracks may be silent, corrupt, or below the engine's detection threshold."
                    writeFailed(reason: msg)
                    return .failed(reason: msg)
                }
                // Build the completed transcript context using whatever audio
                // path the up-front finalizer produced. canonicalAudioPath is
                // either "audio.m4a" (success) or empty (fall back to raw
                // streams). The metadata.json + transcript.md must agree so
                // JSON consumers and humans see the same canonical asset
                // (codex slice-9a review P2.2).
                let completedContext = TranscriptContext(
                    title: context.title,
                    date: context.date,
                    engine: context.engine,
                    audioRelativePaths: canonicalAudioPath.isEmpty
                        ? context.audioRelativePaths
                        : [canonicalAudioPath],
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
                writeMetadata(status: .complete, context: completedContext, audioPath: canonicalAudioPath)
                // Phase ι: spec line 102. Default-OFF keepRawStreams
                // means raw streams are deleted ONLY after the terminal
                // success state has been written to disk. We require
                // BOTH (a) keepRawStreams == false AND (b) the canonical
                // audio.m4a actually exists on disk — otherwise deleting
                // the raws would orphan the user's only copy of the
                // audio. NEVER deletes on pending / retrying / failed.
                cleanupRawStreamsIfPolicyAllows()
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
        // Failure transcripts reference whatever audio actually exists on
        // disk: audio.m4a if the finalizer ran successfully (slice 9a),
        // otherwise the raw mic + system streams from capture finalization.
        // Metadata.json mirrors the same audio reference for consistency
        // (codex slice-9a P2.2).
        let audioPaths: [String] = canonicalAudioPath.isEmpty
            ? context.audioRelativePaths
            : [canonicalAudioPath]
        let failedContext = TranscriptContext(
            title: context.title,
            date: context.date,
            engine: context.engine,
            audioRelativePaths: audioPaths,
            startedAt: context.startedAt,
            endedAt: context.endedAt,
            attendees: context.attendees,
            language: context.language
        )
        do {
            try TranscriptWriter.writeFailed(at: directory.transcript, context: failedContext, errorMessage: reason)
        } catch {
            Log.engine.error("writeFailed failed: \(String(describing: error), privacy: .public)")
        }
        writeMetadata(status: .failed, context: failedContext, audioPath: canonicalAudioPath)
    }

    /// Runs AudioFinalizer to produce audio.m4a from the raw streams.
    /// Returns "audio.m4a" on success, "" on failure (caller falls back to
    /// the raw stream list). Result is also stored on the actor so failure
    /// paths can stamp the same canonical path into metadata.
    private func prepareCanonicalAudio() async -> String {
        let audioFinalURL = directory.url.appendingPathComponent("audio.m4a")
        do {
            try await AudioFinalizer.finalize(
                mic: directory.micFinal,
                system: directory.systemFinal,
                output: audioFinalURL,
                sampleRate: 48000
            )
            canonicalAudioPath = "audio.m4a"
            return canonicalAudioPath
        } catch {
            Log.engine.error("AudioFinalizer failed; output will reference raw streams: \(String(describing: error), privacy: .public)")
            canonicalAudioPath = ""
            return ""
        }
    }

    /// Writes metadata.json mirroring the transcript frontmatter. Called from
    /// every terminal state (complete, failed) so JSON consumers always have
    /// a current snapshot. Best-effort — failure logs but doesn't escalate.
    /// Phase ν: spec line 129. Runs the language detector on mic.m4a
    /// once per session and returns a request copy with the detected
    /// `languageCode` filled in. If the caller already specified a
    /// language, or the detector returns nil (failure / no detector),
    /// the request is returned unchanged.
    private func resolveLanguage(for request: EngineRequest) async -> EngineRequest {
        guard request.languageCode == nil, let detector = languageDetector else {
            return request
        }
        guard FileManager.default.fileExists(atPath: directory.micFinal.path) else {
            // No mic to detect from — recovery-deferred or one-sided
            // session that somehow made it past the supervisor's gate.
            // Fall through to engine auto-detect.
            return request
        }
        let detected = await detector.detect(from: directory.micFinal)
        guard let detected else {
            Log.engine.info("Language detector returned nil; falling back to engine auto-detect")
            return request
        }
        Log.engine.info("Language detector resolved \(detected, privacy: .public); seeding engine request")
        return EngineRequest(
            audioURL: request.audioURL,
            mode: request.mode,
            languageCode: detected,
            keyterms: request.keyterms,
            modelID: request.modelID
        )
    }

    /// Phase ι: spec line 102. Default-OFF deletes raw mic.m4a +
    /// system.m4a after audio.m4a is on disk and the terminal status
    /// has been written. The deletion is gated on:
    ///   1. `keepRawStreams == false` (the spec default)
    ///   2. `audio.m4a` actually exists at `directory.url/audio.m4a`
    ///      (otherwise we'd orphan the user's only copy)
    ///
    /// NEVER fires on pending / retrying / failed — those states may
    /// need the raws for retry or recovery. Only invoked from the
    /// `.complete` happy path.
    private func cleanupRawStreamsIfPolicyAllows() {
        guard !keepRawStreams else {
            Log.engine.info("keepRawStreams=true: preserving mic.m4a + system.m4a")
            return
        }
        let canonicalAudio = directory.url.appendingPathComponent("audio.m4a")
        guard FileManager.default.fileExists(atPath: canonicalAudio.path) else {
            Log.engine.warning("Skipping raw-stream cleanup: audio.m4a missing — preserving mic.m4a + system.m4a as fallback")
            return
        }

        for url in [directory.micFinal, directory.systemFinal] {
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                // Best-effort: log but don't fail the worker. The user
                // has audio.m4a; the raws being slow to delete just
                // means they'll persist until the next sweep.
                Log.engine.warning("Failed to delete raw stream \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func writeMetadata(status: TranscriptStatus, context: TranscriptContext, audioPath: String) {
        // Metadata.audio is a single string per spec line 251-255; pick the
        // first audio reference. With audio.m4a present, that's "audio.m4a".
        // With raw-streams fallback, that's mic.m4a (or whatever's first in
        // the array). The transcript's `audio:` key still lists every track,
        // so JSON consumers preferring single-asset semantics get the
        // primary while transcript readers see the full set.
        let primaryAudio = audioPath.isEmpty
            ? (context.audioRelativePaths.first ?? "mic.m4a")
            : audioPath
        let metadata = MetadataJSONWriter.Metadata(
            status: status,
            context: context,
            audio: primaryAudio
        )
        let metadataURL = directory.url.appendingPathComponent("metadata.json")
        do {
            try MetadataJSONWriter.write(at: metadataURL, metadata: metadata)
        } catch {
            Log.engine.error("metadata.json write failed: \(String(describing: error), privacy: .public)")
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
