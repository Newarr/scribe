import Foundation
import Darwin

public struct SessionDirectory: Equatable, Sendable {
    public let url: URL

    init(url: URL) {
        self.url = url
    }

    public static func create(
        under parent: URL,
        id: SessionID
    ) throws -> SessionDirectory {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var suffix = 1
        while true {
            let name = suffix == 1 ? id.slug : id.slugWithSuffix(suffix)
            let target = parent.appendingPathComponent(name)
            if mkdir(target.path, 0o700) == 0 {
                return SessionDirectory(url: target)
            }
            let failure = errno
            guard failure == EEXIST else {
                throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
            }
            suffix += 1
        }
    }

    var micPartial: URL {
        url.appendingPathComponent("mic.m4a.partial")
    }

    var systemPartial: URL {
        url.appendingPathComponent("system.m4a.partial")
    }

    public var micFinal: URL {
        url.appendingPathComponent("mic.m4a")
    }

    public var systemFinal: URL {
        url.appendingPathComponent("system.m4a")
    }

    var ptsSidecar: URL {
        url.appendingPathComponent("pts.json")
    }

    /// Per-buffer PTS log written incrementally by `PTSCollector` during
    /// capture. Streaming finalize (Phase ε) and AEC (Phase ξ) consume this
    /// to align mic / system streams and insert silence for gaps. Distinct
    /// from `ptsSidecar`, which is a one-shot summary written at finalize
    /// time and used by metadata.json consumers.
    var ptsStreamingLog: URL {
        url.appendingPathComponent("pts.jsonl")
    }

    public var claim: URL {
        url.appendingPathComponent("claim.json")
    }

    /// Start-time durable session provenance written before capture starts.
    /// Recovery reads this when transcript.md does not exist yet (for
    /// active-capture crash/orphan sessions).
    var startManifest: URL {
        url.appendingPathComponent("session.json")
    }

    public var transcript: URL {
        url.appendingPathComponent("transcript.md")
    }

    /// Canonical saved recording produced by finalization and consumed by
    /// transcription, retry, and repair flows. Single source for the
    /// "audio.m4a" name; eligibility checks live on `CanonicalAudio`.
    public var audioFinal: URL {
        CanonicalAudio.url(in: url)
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
