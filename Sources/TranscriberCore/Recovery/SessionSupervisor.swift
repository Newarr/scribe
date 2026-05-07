import Foundation

/// Scans the user's output folder (default `~/Scribe/`) on app launch and dispatches a
/// `TranscriptionWorker` for any session whose transcript is `pending` or
/// `retrying` (or any session whose audio was rescued from `.partial` files).
/// Sessions with no audio at all are stamped `failed` so they don't loop forever.
public actor SessionSupervisor {
    public typealias WorkerFactory = @Sendable (SessionDirectory, TranscriptContext) -> TranscriptionWorker
    public typealias ContextFactory = @Sendable (SessionDirectory) -> TranscriptContext

    public struct ScanResult: Equatable, Sendable {
        public var resumed: Int = 0
        public var skipped: Int = 0
        public var rescued: Int = 0
        public var markedFailed: Int = 0
        /// Sessions whose audio was one-sided (only mic OR only system).
        /// Spec line 339 (no mic-only fallback) means we can't transcribe
        /// these — supervisor writes a `failed` transcript referencing the
        /// surviving stream so the user can still recover the audio.
        public var partialAudioMarkedFailed: Int = 0
        /// Sessions whose `.partial` files couldn't be renamed this scan
        /// (immutable flag, permission, transient I/O). Left pending so
        /// the next scan can retry. Surfaced for telemetry; does NOT
        /// count against `markedFailed` because the session isn't
        /// terminal.
        public var recoveryDeferred: Int = 0

        /// Convenience: every transcript this scan terminally marked
        /// failed. Codex Phase ζ P1.2 — keeps callers from off-by-one
        /// summing `markedFailed` and `partialAudioMarkedFailed`.
        public var totalFailed: Int { markedFailed + partialAudioMarkedFailed }
    }

    /// Codex rc1-final P1.2: needed for the launch-time raw-stream
    /// sweep. nil here means "preserve everything" (treats every
    /// terminal-complete session as if keepRawStreams=true was in
    /// effect when it ran).
    private var keepRawStreams: Bool = false

    public init() {}

    /// Walks `root`, recovers orphaned audio, and dispatches workers for any
    /// non-terminal session. Returns once all dispatched workers have finished.
    public func scanAndResume(
        under root: URL,
        keepRawStreams: Bool = false,
        contextFactory: ContextFactory,
        workerFactory: WorkerFactory
    ) async -> ScanResult {
        self.keepRawStreams = keepRawStreams
        var result = ScanResult()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return result
        }

        var workers: [TranscriptionWorker] = []
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let dir = SessionDirectory(url: entry)

            // Read existing frontmatter once. Reused for: terminal-status
            // skip, original-context preservation, attempts count.
            let existing = TranscriptFrontmatterReader.read(at: dir.transcript)

            // P2.3 fix: never overwrite a terminal transcript, even if the
            // user has manually moved/deleted the audio. Spec lets users keep
            // audio "until manually deleted" which implies they may also
            // delete it; deleting audio shouldn't clobber the completed
            // transcript body.
            if let existing, existing.status == .complete || existing.status == .failed {
                result.skipped += 1
                // Codex rc1-final P1.2: sweep raw streams that survived
                // a prior cleanup attempt (immutable flag, transient I/O,
                // half-written metadata gate). Only fires when the
                // canonical audio.m4a is on disk AND the user opted-in
                // to default-OFF retention. The session itself is
                // terminal; we're just catching up on cleanup.
                if existing.status == .complete && !keepRawStreams {
                    sweepStrandedRawStreams(in: dir)
                }
                continue
            }

            let recovery = OrphanRecoverer.recover(dir)
            switch recovery {
            case .activeCapture:
                // Codex rc2-audit CAP-5: another process / window of
                // this app holds an active capture claim on this
                // directory. Skip — moving the .partial files would
                // corrupt the live capture's AVAssetWriter output.
                Log.engine.info("supervisor: skipping \(dir.url.lastPathComponent, privacy: .public): active capture claim held")
                result.skipped += 1
                continue
            case .alreadyFinalized:
                break  // both tracks present pre-scan; no rescue counter
            case .rescued:
                result.rescued += 1
            case .partialAudio(let stream):
                // Spec line 339 (`decision_no_mic_only_fallback`): one-sided
                // audio is NOT transcribable. Write a failed transcript
                // pointing the user at the surviving file so they can
                // recover the audio manually.
                //
                // Codex Phase ζ P0.2: rebuild the context with the
                // correct audioRelativePaths so frontmatter + body
                // match reality (don't promise files that aren't there).
                let baseContext = existing?.context ?? contextFactory(dir)
                let survivingFile = stream == .mic ? dir.micFinal : dir.systemFinal
                let context = Self.contextOverridingAudio(
                    base: baseContext,
                    paths: [survivingFile.lastPathComponent]
                )
                let message = "Session audio is one-sided (only \(stream.rawValue) survived). Per V1 spec the engine requires both microphone and system audio to produce diarized output; the surviving file at \(survivingFile.lastPathComponent) is preserved for manual recovery."
                do {
                    try TranscriptWriter.writeFailed(at: dir.transcript, context: context, errorMessage: message)
                    result.partialAudioMarkedFailed += 1
                } catch {
                    Log.engine.error("supervisor: writeFailed (partial audio) failed: \(String(describing: error), privacy: .public)")
                }
                continue
            case .recoveryDeferred(let stream):
                // At least one `.partial` is still on disk after a failed
                // rename (immutable flag, permission, transient I/O).
                // Codex Phase ζ P0.1: don't terminally fail — the bytes
                // are recoverable on the next scan. Log + continue.
                Log.engine.warning("supervisor: recovery deferred for session \(dir.url.lastPathComponent, privacy: .public): \(stream.rawValue) rename failed; .partial bytes preserved for next scan")
                result.recoveryDeferred += 1
                continue
            case .noAudio:
                // Codex Phase ζ P0.2: same fix — rebuild context with
                // empty audioRelativePaths so the failed transcript
                // doesn't promise files that don't exist.
                let baseContext = existing?.context ?? contextFactory(dir)
                let context = Self.contextOverridingAudio(base: baseContext, paths: [])
                do {
                    try TranscriptWriter.writeFailed(at: dir.transcript, context: context, errorMessage: "Session audio is missing. The capture session may have been interrupted before any audio was written.")
                    result.markedFailed += 1
                } catch {
                    Log.engine.error("supervisor: writeFailed (no audio) failed: \(String(describing: error), privacy: .public)")
                }
                continue
            }

            // Pending or retrying (or no transcript yet for fresh-rescued
            // orphans) — prefer the on-disk context (carries title +
            // attendees + language from the original session) over the
            // placeholder factory.
            let context = existing?.context ?? contextFactory(dir)
            let worker = workerFactory(dir, context)
            workers.append(worker)
            result.resumed += 1
        }

        // Dispatch all workers concurrently. Each is its own actor; running them
        // in a TaskGroup so the supervisor's caller can await full completion if
        // it wants to. Workers that fail still write status to disk; they don't
        // surface errors here.
        await withTaskGroup(of: Void.self) { group in
            for worker in workers {
                group.addTask { _ = await worker.run() }
            }
        }
        return result
    }

    /// Codex rc1-final P1.2: sweep raw streams (mic.m4a / system.m4a)
    /// from a terminal-complete session that previously failed
    /// cleanup (immutable flag, transient I/O, half-written metadata
    /// gate). Same guards as the worker's per-session cleanup:
    ///   - audio.m4a must exist (don't orphan the user's only copy)
    ///   - keepRawStreams must be false (handled at the call site)
    /// NEVER sweeps for failed-status sessions — those raws are the
    /// user's only path to manual recovery.
    private func sweepStrandedRawStreams(in dir: SessionDirectory) {
        let canonicalAudio = dir.url.appendingPathComponent("audio.m4a")
        guard FileManager.default.fileExists(atPath: canonicalAudio.path) else { return }
        for url in [dir.micFinal, dir.systemFinal] {
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                    Log.engine.info("Supervisor swept stranded raw stream: \(url.lastPathComponent, privacy: .public)")
                } catch {
                    Log.engine.warning("Supervisor sweep failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Codex Phase ζ P0.2: when writing a failed transcript for a
    /// session whose audio is one-sided or missing, the existing
    /// `TranscriptContext.audioRelativePaths` (e.g. `["mic.m4a",
    /// "system.m4a"]`) lies about what's on disk. Rebuild the context
    /// with the actually-present paths.
    private static func contextOverridingAudio(
        base: TranscriptContext,
        paths: [String]
    ) -> TranscriptContext {
        TranscriptContext(
            title: base.title,
            date: base.date,
            engine: base.engine,
            audioRelativePaths: paths,
            scheduledStart: base.scheduledStart,
            scheduledEnd: base.scheduledEnd,
            actualStart: base.actualStart,
            actualEnd: base.actualEnd,
            organizer: base.organizer,
            location: base.location,
            calendarEventID: base.calendarEventID,
            joinedLate: base.joinedLate,
            elapsedAtStartSeconds: base.elapsedAtStartSeconds,
            attendees: base.attendees,
            language: base.language
        )
    }
}
