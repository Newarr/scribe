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
        /// Exactly one track survived. NOT transcribable per spec line 339;
        /// caller must write a failed transcript referencing this stream.
        case partialAudio(stream: Stream)
        /// No audio whatsoever. Caller must write a failed transcript with
        /// "session audio is missing" body.
        case noAudio
    }

    public static func recover(_ dir: SessionDirectory) -> Result {
        let fm = FileManager.default

        let micFinal = fm.fileExists(atPath: dir.micFinal.path)
        let sysFinal = fm.fileExists(atPath: dir.systemFinal.path)
        if micFinal && sysFinal { return .alreadyFinalized }

        if !micFinal && fm.fileExists(atPath: dir.micPartial.path) {
            try? fm.moveItem(at: dir.micPartial, to: dir.micFinal)
        }
        if !sysFinal && fm.fileExists(atPath: dir.systemPartial.path) {
            try? fm.moveItem(at: dir.systemPartial, to: dir.systemFinal)
        }

        let nowMic = fm.fileExists(atPath: dir.micFinal.path)
        let nowSys = fm.fileExists(atPath: dir.systemFinal.path)
        switch (nowMic, nowSys) {
        case (true, true): return .rescued
        case (true, false): return .partialAudio(stream: .mic)
        case (false, true): return .partialAudio(stream: .system)
        case (false, false): return .noAudio
        }
    }
}
