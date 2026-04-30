import Foundation

/// Rescues sessions where `CaptureSession.stop()` threw and left
/// `mic.m4a.partial` or `system.m4a.partial` on disk. Best-effort renames
/// `.partial` -> `.m4a`. Returns a typed result so the caller knows whether
/// the surviving audio is enough for transcription.
///
/// Phase ζ: spec line 339 (`decision_no_mic_only_fallback`) forbids
/// transcribing one-sided audio. Codex pass 2 P0 #5 caught that the v0
/// returned `.rescued` if either track survived, which would dispatch a
/// worker against an unusable single-channel session. The new
/// `.partialAudio(stream:)` case lets `SessionSupervisor` write a
/// `failed` transcript referencing whichever stream survived (so the user
/// can still recover the audio manually) without ever calling the engine.
///
/// Phase ζ codex fix (P0.1): the previous version classified rename
/// failures (immutable flag, permission denied, disk full) as
/// `.partialAudio` because it only inspected the post-state of `.m4a`
/// paths. That terminally failed sessions whose `.partial` bytes were
/// still recoverable on the next launch. New code captures pre/post
/// state and emits `.recoveryDeferred(stream:)` when a `.partial` we
/// tried to rename is still on disk — supervisor leaves the session
/// pending so the next scan can retry.
public enum OrphanRecoverer {
    public enum Stream: String, Sendable, Equatable {
        case mic
        case system
    }

    public enum Result: Equatable {
        /// Both `mic.m4a` and `system.m4a` already exist. No-op.
        case alreadyFinalized
        /// Both tracks present (potentially after renaming `.partial`).
        /// Worker may run.
        case rescued
        /// Exactly one track survived AND no `.partial` is left on disk
        /// awaiting rename. NOT transcribable per spec line 339; caller
        /// must write a failed transcript referencing this stream.
        case partialAudio(stream: Stream)
        /// At least one rename attempt failed but the `.partial` bytes are
        /// still on disk. Caller should NOT terminally fail the session —
        /// leave it pending so the next scan can retry.
        case recoveryDeferred(stream: Stream)
        /// No audio whatsoever. Caller must write a failed transcript with
        /// "session audio is missing" body.
        case noAudio
        /// Codex rc2-audit CAP-5: session has a live capture claim
        /// (the running app holds an exclusive flock on the claim file).
        /// Skipping recovery here is critical — moving `.partial` files
        /// out from under an active AVAssetWriter would corrupt the
        /// session. The caller (SessionSupervisor) treats this as a
        /// neutral "skip for now" outcome.
        case activeCapture
    }

    public static func recover(_ dir: SessionDirectory) -> Result {
        let fm = FileManager.default

        // Codex rc2-audit CAP-5: defer to live captures. The capture
        // session writes a claim file when it starts and releases it
        // on stop. Trying to acquire the same claim non-blocking
        // tells us whether anyone else holds it. We don't keep the
        // claim — we only check, then release if we got it.
        if let probeToken = SessionClaim.acquire(at: dir.claim) {
            // No live capture; safe to recover. Release our own probe
            // claim before proceeding so the worker can re-acquire it
            // in the normal flow.
            SessionClaim.release(probeToken)
        } else {
            return .activeCapture
        }

        // Capture pre-recovery state so we can detect rename failures
        // (rather than misclassifying them as "system never existed").
        let micFinalPre = fm.fileExists(atPath: dir.micFinal.path)
        let sysFinalPre = fm.fileExists(atPath: dir.systemFinal.path)
        let micPartialPre = fm.fileExists(atPath: dir.micPartial.path)
        let sysPartialPre = fm.fileExists(atPath: dir.systemPartial.path)

        if micFinalPre && sysFinalPre { return .alreadyFinalized }

        if !micFinalPre && micPartialPre {
            try? fm.moveItem(at: dir.micPartial, to: dir.micFinal)
        }
        if !sysFinalPre && sysPartialPre {
            try? fm.moveItem(at: dir.systemPartial, to: dir.systemFinal)
        }

        let micFinalPost = fm.fileExists(atPath: dir.micFinal.path)
        let sysFinalPost = fm.fileExists(atPath: dir.systemFinal.path)
        let micPartialPost = fm.fileExists(atPath: dir.micPartial.path)
        let sysPartialPost = fm.fileExists(atPath: dir.systemPartial.path)

        // Rename failed if we tried to recover a `.partial` that's still
        // sitting on disk afterward. Don't terminally fail — defer.
        let micRenameFailed = micPartialPre && !micFinalPost && micPartialPost
        let sysRenameFailed = sysPartialPre && !sysFinalPost && sysPartialPost
        if micRenameFailed || sysRenameFailed {
            // Pick whichever stream has the unrecovered partial bytes.
            // If both, prefer mic (arbitrary; the caller doesn't care
            // which side beyond logging).
            let stuck: Stream = micRenameFailed ? .mic : .system
            return .recoveryDeferred(stream: stuck)
        }

        switch (micFinalPost, sysFinalPost) {
        case (true, true): return .rescued
        case (true, false): return .partialAudio(stream: .mic)
        case (false, true): return .partialAudio(stream: .system)
        case (false, false): return .noAudio
        }
    }
}
