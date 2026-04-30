import Foundation

public struct SessionDirectory: Equatable, Sendable {
    public let url: URL

    init(url: URL) {
        self.url = url
    }

    public static func create(
        under parent: URL,
        id: SessionID
    ) throws -> SessionDirectory {
        var targetUrl = parent.appendingPathComponent(id.slug)
        var suffix = 2

        // Check for collisions and resolve with suffix
        while FileManager.default.fileExists(atPath: targetUrl.path) {
            targetUrl = parent.appendingPathComponent(id.slugWithSuffix(suffix))
            suffix += 1
        }

        // Create directory with 0o700 permissions (owner read-write-execute only)
        try FileManager.default.createDirectory(
            at: targetUrl,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        return SessionDirectory(url: targetUrl)
    }

    public var micPartial: URL {
        url.appendingPathComponent("mic.m4a.partial")
    }

    public var systemPartial: URL {
        url.appendingPathComponent("system.m4a.partial")
    }

    public var micFinal: URL {
        url.appendingPathComponent("mic.m4a")
    }

    public var systemFinal: URL {
        url.appendingPathComponent("system.m4a")
    }

    public var ptsSidecar: URL {
        url.appendingPathComponent("pts.json")
    }

    /// Per-buffer PTS log written incrementally by `PTSCollector` during
    /// capture. Streaming finalize (Phase ε) and AEC (Phase ξ) consume this
    /// to align mic / system streams and insert silence for gaps. Distinct
    /// from `ptsSidecar`, which is a one-shot summary written at finalize
    /// time and used by metadata.json consumers.
    public var ptsStreamingLog: URL {
        url.appendingPathComponent("pts.jsonl")
    }

    /// Atomic per-session claim file used by SessionClaim to prevent two
    /// concurrent TranscriptionWorker runs (Phase γ). Stores
    /// {pid, boot_time, started_at, heartbeat_at} so a relaunched
    /// SessionSupervisor can detect a dead claimer and reclaim safely.
    public var claim: URL {
        url.appendingPathComponent("claim.json")
    }

    public var transcript: URL {
        url.appendingPathComponent("transcript.md")
    }

    public func finalize() throws {
        let fileManager = FileManager.default

        // Atomically rename partial files to final files
        if fileManager.fileExists(atPath: micPartial.path) {
            try fileManager.moveItem(at: micPartial, to: micFinal)
        }

        if fileManager.fileExists(atPath: systemPartial.path) {
            try fileManager.moveItem(at: systemPartial, to: systemFinal)
        }
    }
}
