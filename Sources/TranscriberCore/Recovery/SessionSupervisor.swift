import Foundation

/// Scans `~/Documents/Transcriber/` on app launch and dispatches a
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
    }

    public init() {}

    /// Walks `root`, recovers orphaned audio, and dispatches workers for any
    /// non-terminal session. Returns once all dispatched workers have finished.
    public func scanAndResume(
        under root: URL,
        contextFactory: ContextFactory,
        workerFactory: WorkerFactory
    ) async -> ScanResult {
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

            let recovery = OrphanRecoverer.recover(dir)
            if recovery == .rescued { result.rescued += 1 }

            if recovery == .noAudio {
                let context = contextFactory(dir)
                do {
                    try TranscriptWriter.writeFailed(at: dir.transcript, context: context, errorMessage: "Session audio is missing. The capture session may have been interrupted before any audio was written.")
                    result.markedFailed += 1
                } catch {
                    Log.engine.error("supervisor: writeFailed (no audio) failed: \(String(describing: error), privacy: .public)")
                }
                continue
            }

            let status = TranscriptStatusReader.read(at: dir.transcript)
            switch status {
            case .complete, .failed:
                result.skipped += 1
                continue
            case .pending, .retrying, .none:
                let context = contextFactory(dir)
                let worker = workerFactory(dir, context)
                workers.append(worker)
                result.resumed += 1
            }
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
}
