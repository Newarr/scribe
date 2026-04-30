import CryptoKit
import Foundation

/// Spec line 364: surfaces live levels, key validity, local model
/// status, output writability, and recent session statuses for support
/// triage. Phase θ ships both the in-app DiagnosticsView and this
/// exportable JSON blob.
///
/// SECURITY CONTRACT: this struct is the COMPLETE list of fields that
/// can ever appear in an exported diagnostics blob. Adding a new
/// PII-bearing field requires explicit review against the redaction
/// guards in `DiagnosticsExporterTests`. Notably, every field below
/// is either:
///   - a fixed enum / Bool / Int (no user data)
///   - a derived hash / count (input is opaque after derivation)
///   - a permission state name (granted/denied/notDetermined)
///
/// The exporter NEVER reads transcript bodies, attendee names, API
/// key values, audio file contents, or anything other than what's
/// modeled below.
public struct DiagnosticsSnapshot: Codable, Sendable, Equatable {
    public let appVersion: String
    public let exportedAt: String  // ISO8601
    public let settings: SettingsView
    public let permissions: PermissionsView
    public let engine: EngineView
    public let sessions: SessionSummary
    public let liveLevels: LiveLevels?

    public struct SettingsView: Codable, Sendable, Equatable {
        public let engineMode: String           // "cloud" | "local"
        public let keepRawStreams: Bool
        public let aecEnabled: Bool
        public let privacyAcknowledged: Bool
        /// SHA-256 hex of the absolute path. Lets the user correlate
        /// across exports without leaking their folder hierarchy.
        public let outputRootHash: String
        public let outputRootIsWritable: Bool

        public init(engineMode: String, keepRawStreams: Bool, aecEnabled: Bool, privacyAcknowledged: Bool, outputRootHash: String, outputRootIsWritable: Bool) {
            self.engineMode = engineMode
            self.keepRawStreams = keepRawStreams
            self.aecEnabled = aecEnabled
            self.privacyAcknowledged = privacyAcknowledged
            self.outputRootHash = outputRootHash
            self.outputRootIsWritable = outputRootIsWritable
        }
    }

    public struct PermissionsView: Codable, Sendable, Equatable {
        public let microphone: String        // "granted" | "denied" | "notDetermined" | "restricted"
        public let screenRecording: String
        public let calendar: String

        public init(microphone: String, screenRecording: String, calendar: String) {
            self.microphone = microphone
            self.screenRecording = screenRecording
            self.calendar = calendar
        }
    }

    public struct EngineView: Codable, Sendable, Equatable {
        /// True if the Keychain has any value stored. Never the value.
        public let cloudKeyConfigured: Bool
        /// Nil when not in local mode. Never a path.
        public let localBinaryPresent: Bool?
        public let localLanguageModelPresent: Bool?

        public init(cloudKeyConfigured: Bool, localBinaryPresent: Bool? = nil, localLanguageModelPresent: Bool? = nil) {
            self.cloudKeyConfigured = cloudKeyConfigured
            self.localBinaryPresent = localBinaryPresent
            self.localLanguageModelPresent = localLanguageModelPresent
        }
    }

    /// Aggregate counts ONLY. Per-session content (transcript bodies,
    /// attendee names, audio paths, calendar event titles) is NEVER
    /// included.
    public struct SessionSummary: Codable, Sendable, Equatable {
        public let total: Int
        public let pending: Int
        public let retrying: Int
        public let complete: Int
        public let failed: Int
        public let unknown: Int
        public let totalRetries: Int

        public init(total: Int, pending: Int, retrying: Int, complete: Int, failed: Int, unknown: Int, totalRetries: Int) {
            self.total = total
            self.pending = pending
            self.retrying = retrying
            self.complete = complete
            self.failed = failed
            self.unknown = unknown
            self.totalRetries = totalRetries
        }

        public static let zero = SessionSummary(total: 0, pending: 0, retrying: 0, complete: 0, failed: 0, unknown: 0, totalRetries: 0)
    }

    public struct LiveLevels: Codable, Sendable, Equatable {
        public let micRMS: Double?
        public let systemRMS: Double?

        public init(micRMS: Double? = nil, systemRMS: Double? = nil) {
            self.micRMS = micRMS
            self.systemRMS = systemRMS
        }
    }

    public init(
        appVersion: String,
        exportedAt: String,
        settings: SettingsView,
        permissions: PermissionsView,
        engine: EngineView,
        sessions: SessionSummary,
        liveLevels: LiveLevels?
    ) {
        self.appVersion = appVersion
        self.exportedAt = exportedAt
        self.settings = settings
        self.permissions = permissions
        self.engine = engine
        self.sessions = sessions
        self.liveLevels = liveLevels
    }
}

/// Pure encoder. Caller hands in a pre-redacted DiagnosticsSnapshot;
/// we JSON-encode it. The encoder NEVER touches disk on its own.
public enum DiagnosticsExporter {
    public enum ExportError: Error {
        case encodeFailed(Error)
    }

    public static func encode(_ snapshot: DiagnosticsSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(snapshot)
        } catch {
            throw ExportError.encodeFailed(error)
        }
    }
}

/// Reads ONLY the frontmatter status + attempts from each session
/// directory under `root`. Never reads transcript bodies, never
/// includes context (title / attendees / audio paths). Output is the
/// aggregate counts struct that maps directly into the diagnostics
/// snapshot.
public enum DiagnosticsCollector {
    public static func collectSessions(under root: URL) -> DiagnosticsSnapshot.SessionSummary {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return .zero
        }

        var pending = 0
        var retrying = 0
        var complete = 0
        var failed = 0
        var unknown = 0
        var totalRetries = 0
        var totalSessions = 0

        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let dir = SessionDirectory(url: entry)
            // The frontmatter reader returns just status + context +
            // attempts. We pluck `status` and `attempts` ONLY — the
            // context (which has attendees) is intentionally not
            // surfaced into the diagnostics output.
            guard let frontmatter = TranscriptFrontmatterReader.read(at: dir.transcript) else {
                // Either no transcript yet (in-progress orphan) or a
                // malformed file. Either way: count as unknown and move
                // on without reading anything else from the folder.
                if fm.fileExists(atPath: dir.transcript.path) {
                    unknown += 1
                    totalSessions += 1
                }
                continue
            }
            totalSessions += 1
            switch frontmatter.status {
            case .pending: pending += 1
            case .retrying: retrying += 1
            case .complete: complete += 1
            case .failed: failed += 1
            }
            totalRetries += frontmatter.attempts
        }

        return DiagnosticsSnapshot.SessionSummary(
            total: totalSessions,
            pending: pending,
            retrying: retrying,
            complete: complete,
            failed: failed,
            unknown: unknown,
            totalRetries: totalRetries
        )
    }

    /// SHA-256 hex of a path string. Lets the diagnostics output
    /// uniquely identify "this user's config" across exports without
    /// leaking the actual filesystem location.
    public static func hashPath(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
