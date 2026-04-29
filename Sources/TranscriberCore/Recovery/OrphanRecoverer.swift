import Foundation

/// Rescues sessions where `CaptureSession.stop()` threw and left `mic.m4a.partial`
/// or `system.m4a.partial` on disk. Best-effort renames `.partial` -> `.m4a`.
public enum OrphanRecoverer {
    public enum Result: Equatable {
        case alreadyFinalized
        case rescued
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
        if nowMic || nowSys { return .rescued }
        return .noAudio
    }
}
