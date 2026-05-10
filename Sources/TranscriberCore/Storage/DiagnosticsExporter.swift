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
    public let osVersion: OSVersion
    /// Normalized, non-content-bearing calendar source. This never carries
    /// event titles, calendar names, attendee data, or account identifiers.
    public let activeCalendarSource: String
    public let exportedAt: String  // ISO8601
    public let settings: SettingsView
    public let permissions: PermissionsView
    public let engine: EngineView
    public let sessions: SessionSummary
    public let liveLevels: LiveLevels?

    public struct OSVersion: Codable, Sendable, Equatable {
        public let major: Int
        public let minor: Int
        public let patch: Int

        public init(major: Int, minor: Int, patch: Int) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        public init(_ version: OperatingSystemVersion) {
            self.init(major: version.majorVersion, minor: version.minorVersion, patch: version.patchVersion)
        }
    }

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
        /// Explicit current setting, separate from session provenance.
        public let selectedEngine: String  // "cloud" | "local"
        /// Readiness for the selected engine only. Cloud requires a readable
        /// key; Local requires verified cache plus MLX/runtime availability.
        public let selectedEngineReady: Bool
        /// Tri-state per codex P1.4. "configured" = key present and
        /// readable. "missing" = key not in keychain. "unreadable" =
        /// keychain returned an error other than item-not-found
        /// (locked, denied, transient I/O). Never carries the value.
        public let cloudKey: String  // "configured" | "missing" | "unreadable"
        /// Normalized Local Cohere model status. Never a path.
        public let localModelStatus: String
        /// Pinned reviewed model identity only.
        public let localModelID: String
        /// Cache path is represented only as existence, never as URL/path.
        public let localCachePathExists: Bool
        public let mlxAvailable: Bool
        public let localReady: Bool
        /// Bounded reviewed failure code/message; empty when no failure.
        public let lastDownloadError: String

        public init(
            selectedEngine: String,
            selectedEngineReady: Bool,
            cloudKey: String,
            localModelStatus: String,
            localModelID: String,
            localCachePathExists: Bool,
            mlxAvailable: Bool,
            localReady: Bool,
            lastDownloadError: String
        ) {
            self.selectedEngine = selectedEngine
            self.selectedEngineReady = selectedEngineReady
            self.cloudKey = cloudKey
            self.localModelStatus = localModelStatus
            self.localModelID = localModelID
            self.localCachePathExists = localCachePathExists
            self.mlxAvailable = mlxAvailable
            self.localReady = localReady
            self.lastDownloadError = lastDownloadError
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
        /// Codex P1.5: session folders with audio (mic.m4a /
        /// mic.m4a.partial or system equivalents) but NO transcript.md
        /// — recovery-deferred or pre-supervisor-scan crash windows.
        /// Counted distinctly from "unknown" (which is malformed
        /// transcript) so support sees both diagnostically.
        public let orphanedWithAudio: Int
        public let totalRetries: Int
        /// Session engine provenance counts from transcript frontmatter only.
        /// These are aggregate counts and never include titles, paths, or text.
        public let cloudEngineSessions: Int
        public let localEngineSessions: Int
        public let unknownEngineSessions: Int

        public init(
            total: Int,
            pending: Int,
            retrying: Int,
            complete: Int,
            failed: Int,
            unknown: Int,
            orphanedWithAudio: Int,
            totalRetries: Int,
            cloudEngineSessions: Int,
            localEngineSessions: Int,
            unknownEngineSessions: Int
        ) {
            self.total = total
            self.pending = pending
            self.retrying = retrying
            self.complete = complete
            self.failed = failed
            self.unknown = unknown
            self.orphanedWithAudio = orphanedWithAudio
            self.totalRetries = totalRetries
            self.cloudEngineSessions = cloudEngineSessions
            self.localEngineSessions = localEngineSessions
            self.unknownEngineSessions = unknownEngineSessions
        }

        public static let zero = SessionSummary(total: 0, pending: 0, retrying: 0, complete: 0, failed: 0, unknown: 0, orphanedWithAudio: 0, totalRetries: 0, cloudEngineSessions: 0, localEngineSessions: 0, unknownEngineSessions: 0)
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
        osVersion: OSVersion,
        activeCalendarSource: String,
        exportedAt: String,
        settings: SettingsView,
        permissions: PermissionsView,
        engine: EngineView,
        sessions: SessionSummary,
        liveLevels: LiveLevels?
    ) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.activeCalendarSource = activeCalendarSource
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
        var orphanedWithAudio = 0
        var totalRetries = 0
        var totalSessions = 0
        var cloudEngineSessions = 0
        var localEngineSessions = 0
        var unknownEngineSessions = 0

        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let dir = SessionDirectory(url: entry)

            // Codex P1.5: a session folder with audio artifacts but no
            // transcript.md is a crash-window orphan. Surface it
            // distinctly so support knows the user has recoverable
            // bytes that haven't been processed yet.
            if !fm.fileExists(atPath: dir.transcript.path) {
                let hasAudio = fm.fileExists(atPath: dir.micFinal.path)
                    || fm.fileExists(atPath: dir.micPartial.path)
                    || fm.fileExists(atPath: dir.systemFinal.path)
                    || fm.fileExists(atPath: dir.systemPartial.path)
                if hasAudio {
                    orphanedWithAudio += 1
                    totalSessions += 1
                }
                continue
            }

            // Codex rc2-audit PRIVACY-1: use the streaming reader
            // that stops at the second `---` line so we never load
            // transcript bodies into memory. The diagnostics surface
            // needs status + attempts; everything else is body or
            // PII-bearing context.
            guard let result = TranscriptFrontmatterReader.readDiagnosticsFrontmatterStreaming(at: dir.transcript) else {
                unknown += 1
                totalSessions += 1
                unknownEngineSessions += 1
                continue
            }
            totalSessions += 1
            switch result.engine {
            case "elevenlabs": cloudEngineSessions += 1
            case "cohere": localEngineSessions += 1
            default: unknownEngineSessions += 1
            }
            switch result.status {
            case .pending: pending += 1
            case .retrying: retrying += 1
            case .complete: complete += 1
            case .failed: failed += 1
            }
            totalRetries += result.attempts
        }

        return DiagnosticsSnapshot.SessionSummary(
            total: totalSessions,
            pending: pending,
            retrying: retrying,
            complete: complete,
            failed: failed,
            unknown: unknown,
            orphanedWithAudio: orphanedWithAudio,
            totalRetries: totalRetries,
            cloudEngineSessions: cloudEngineSessions,
            localEngineSessions: localEngineSessions,
            unknownEngineSessions: unknownEngineSessions
        )
    }

    /// HMAC-SHA256 hex of a path string keyed with a per-install
    /// secret. Codex Phase θ P1.2: plain SHA-256 of a low-entropy path
    /// like `/Users/<name>/Documents/Scribe` is dictionary-
    /// attackable and stable across exports. HMAC with a per-install
    /// secret defeats the rainbow attack while preserving stable
    /// across-export correlation for the same user.
    public static func hashPath(_ url: URL, instanceID: String) -> String {
        let key = SymmetricKey(data: Data(instanceID.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(url.path.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Async snapshot helpers — wired to the same probe protocols
    /// PermissionDoctor uses, so diagnostics matches preflight reality.

    public static func permissions(probe: PermissionStatusProbing) async -> DiagnosticsSnapshot.PermissionsView {
        async let mic = probe.microphone()
        async let screen = probe.screenRecording()
        async let cal = probe.calendar()
        return await DiagnosticsSnapshot.PermissionsView(
            microphone: permissionStatusName(mic),
            screenRecording: permissionStatusName(screen),
            calendar: permissionStatusName(cal)
        )
    }

    /// Probes engine readiness and local model/runtime state using the
    /// same source of truth as preflight. Local fields are always present
    /// and fixed-shape, regardless of selected engine, so schema tests catch
    /// unreviewed additions and support can distinguish current selection
    /// from the engine that produced existing sessions.
    public static func engine(
        mode: EngineMode,
        cloudProbe: () async -> CloudKeyState,
        engineProbe: EngineReadinessProbing
    ) async -> DiagnosticsSnapshot.EngineView {
        let cloudState = await cloudProbe()
        let localStatus = await engineProbe.localModelStatus()
        let localStatusView = diagnosticsLocalModelStatus(localStatus)
        let mlxAvailable = diagnosticsMLXAvailable(localStatus)
        let localReady = localStatus.isReady && mlxAvailable
        let selectedReady: Bool
        switch mode {
        case .cloud:
            selectedReady = cloudState == .configured
        case .local:
            selectedReady = localReady
        }
        return DiagnosticsSnapshot.EngineView(
            selectedEngine: mode.rawValue,
            selectedEngineReady: selectedReady,
            cloudKey: cloudState.rawValue,
            localModelStatus: localStatusView.status,
            localModelID: engineProbe.localModelID(),
            localCachePathExists: localStatusView.cachePathExists,
            mlxAvailable: mlxAvailable,
            localReady: localReady,
            lastDownloadError: localStatusView.lastDownloadError
        )
    }

    private static func diagnosticsLocalModelStatus(_ status: LocalModelCacheStatus) -> (status: String, cachePathExists: Bool, lastDownloadError: String) {
        switch status {
        case .notDownloaded:
            return ("notDownloaded", false, "")
        case .downloading:
            return ("downloading", false, "")
        case .verifying:
            return ("verifying", false, "")
        case .verified:
            return ("verified", true, "")
        case .failed(_, let reason, _):
            return ("failed", false, diagnosticsFailureReason(reason))
        case .unsupported(_, let reason):
            return ("unsupported", false, diagnosticsFailureReason(reason))
        }
    }

    private static func diagnosticsMLXAvailable(_ status: LocalModelCacheStatus) -> Bool {
        if case .unsupported = status { return false }
        return true
    }

    private static func diagnosticsFailureReason(_ failure: LocalModelFailure) -> String {
        // Export a reviewed, bounded code only. This avoids leaking raw paths,
        // usernames, signed URLs, stack traces, calendar text, or token-like
        // substrings that may appear in lower-level error messages.
        String(failure.code.rawValue.prefix(80))
    }

    public static func activeCalendarSource(calendarPermission: String) -> String {
        switch calendarPermission {
        case "granted": return "appleCalendar"
        case "denied", "notDetermined", "restricted": return "none"
        default: return "unknown"
        }
    }

    public enum CloudKeyState: String, Sendable, Equatable {
        case configured
        case missing
        case unreadable
    }

    private static func permissionStatusName(_ s: PermissionStatus) -> String {
        switch s {
        case .granted: return "granted"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        }
    }
}

/// Per-install random secret stored in the macOS Keychain. Used as the
/// HMAC key for `hashPath`. Generated lazily on first read so a fresh
/// install starts with a unique correlation value but multiple exports
/// from the same install share the same hash.
///
/// Codex rc2-audit PRIVACY-2: the v0 path used `try?` around both the
/// keychain read and write, which collapsed "not yet generated" with
/// "keychain locked / unreadable" into the same code path AND silently
/// fell back to an ephemeral secret if write failed — defeating the
/// cross-export correlation invariant. New flow distinguishes the
/// three states (configured / missing / unreadable) and surfaces a
/// `.unreadable` value when the secret can't be persisted, so the
/// diagnostics blob can record `outputRootHash: "unreadable"` instead
/// of producing a non-correlatable hash.
public actor DiagnosticsInstanceID {
    public enum State: Sendable, Equatable {
        case configured(String)  // hex-encoded secret
        case unreadable          // keychain can't be read OR written
    }

    private let keychain: KeychainStore
    private var cached: State?

    public init(service: String, account: String) {
        self.keychain = KeychainStore(service: service, account: account)
    }

    /// Returns the per-install secret if Keychain access succeeded;
    /// `.unreadable` otherwise. Callers in the diagnostics flow MUST
    /// handle the `.unreadable` case rather than coercing to a
    /// throwaway secret — the whole point of HMAC-keying is stable
    /// across-export correlation.
    public func currentState() -> State {
        if let cached { return cached }
        // Try read first. KeychainStore.read returns nil for "not
        // present" (errSecItemNotFound) and throws for everything
        // else (locked, denied, transient I/O).
        let readResult: Result<String?, Error>
        do { readResult = .success(try keychain.read()) }
        catch { readResult = .failure(error) }

        switch readResult {
        case .success(let stored?) where !stored.isEmpty:
            cached = .configured(stored)
            return .configured(stored)
        case .success:
            // Not yet generated — try to create + persist. RNG status
            // is checked: errSecSuccess is the only non-failure case.
            var bytes = [UInt8](repeating: 0, count: 32)
            let rng = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard rng == errSecSuccess else {
                Log.engine.error("DiagnosticsInstanceID: SecRandomCopyBytes failed with status \(rng, privacy: .public)")
                cached = .unreadable
                return .unreadable
            }
            let secret = bytes.map { String(format: "%02x", $0) }.joined()
            do {
                try keychain.write(secret)
                cached = .configured(secret)
                return .configured(secret)
            } catch {
                // Persistence failed — caching the ephemeral secret
                // would let one export succeed but the next run would
                // generate a different one, breaking correlation. Mark
                // unreadable so callers know.
                Log.engine.error("DiagnosticsInstanceID: Keychain write failed: \(String(describing: error), privacy: .public)")
                cached = .unreadable
                return .unreadable
            }
        case .failure(let error):
            Log.engine.error("DiagnosticsInstanceID: Keychain read failed: \(String(describing: error), privacy: .public)")
            cached = .unreadable
            return .unreadable
        }
    }

    /// Backwards-compatible accessor for callers that only need the
    /// hex string. Returns `"unreadable"` when the state is unreadable
    /// — that string is then visible in the export's `outputRootHash`,
    /// surfacing the failure to support without crashing the export.
    public func current() -> String {
        switch currentState() {
        case .configured(let s): return s
        case .unreadable: return "unreadable"
        }
    }
}
