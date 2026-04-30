import EventKit
import Foundation

/// Engine selection at preflight time. Used to decide which engine readiness
/// probe runs (cloud needs the API key; local needs the bundled binary +
/// language-detect model).
public enum EngineMode: String, Sendable, Codable {
    case cloud
    case local
}

/// One reason `RecordRequestGate.audit` returns deny or warn. Each reason is
/// individually addressable so `PermissionRecoveryView` can deep-link to the
/// matching System Settings pane (Phase η).
public enum PreflightReason: Sendable, Equatable, Hashable {
    case microphoneDenied
    case microphoneNotDetermined
    case screenRecordingDenied
    case outputFolderUnwritable(URL)
    case outputFolderInSyncedStorage(URL, providerHint: String)
    case missingCloudAPIKey
    case missingLocalEngineBinary(URL)
    case missingLocalLanguageModel(URL)
    case calendarDeniedOptional
    case calendarNotDetermined
}

/// Result of running the preflight audit. The gate's job is to map this into
/// a single-action verdict for the start path.
public struct PreflightReport: Sendable, Equatable {
    public let blockers: [PreflightReason]
    public let warnings: [PreflightReason]

    public init(blockers: [PreflightReason], warnings: [PreflightReason]) {
        self.blockers = blockers
        self.warnings = warnings
    }
}

/// Outcome the start path consumes. `.allow` proceeds. `.allowWithWarnings`
/// proceeds and surfaces a non-blocking notice. `.deny` shows the Setup
/// Required popover and aborts the start request.
public enum PreflightVerdict: Sendable, Equatable {
    case allow
    case allowWithWarnings([PreflightReason])
    case deny([PreflightReason])
}

// MARK: - Probes

/// Permission status probing — extracted so tests can stub each branch
/// without poking AVFoundation / ScreenCaptureKit / EventKit globals.
public protocol PermissionStatusProbing: Sendable {
    func microphone() async -> PermissionStatus
    func screenRecording() async -> PermissionStatus
    /// Returns granted only when the EventKit authorization is full-access.
    /// Anything else (including legacy `.authorized`) counts as
    /// `notDetermined` for the doctor; spec calls calendar optional and we
    /// don't second-guess EventKit's privacy split.
    func calendar() async -> PermissionStatus
}

/// Default probe wired to the existing PermissionsService + EventKit.
public struct DefaultPermissionStatusProbe: PermissionStatusProbing {
    private let permissions: PermissionsService

    public init(permissions: PermissionsService = PermissionsService()) {
        self.permissions = permissions
    }

    public func microphone() async -> PermissionStatus { permissions.microphoneStatus() }
    public func screenRecording() async -> PermissionStatus { await permissions.screenRecordingStatus() }
    public func calendar() async -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined, .authorized, .writeOnly:
            // Treat partial / legacy authorizations as "not yet usable" so the
            // first-run flow re-prompts. Recording still proceeds because
            // calendar is optional; this just keeps the warning surface honest.
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }
}

/// Engine readiness probing. Cloud mode checks the Keychain entry; local mode
/// checks for the bundled binary + Whisper-tiny model on disk.
public protocol EngineReadinessProbing: Sendable {
    func cloudKeyAvailable() async -> Bool
    func localEngineBinaryURL() -> URL?
    func localLanguageModelURL() -> URL?
    func localBinaryReady(_ url: URL) async -> Bool
    func localModelReady(_ url: URL) async -> Bool
}

/// Default readiness probe. Cohere binary + Whisper-tiny model paths default
/// to nil for V1 cloud-only builds; Phase ο wires the real bundle paths.
public struct DefaultEngineReadinessProbe: EngineReadinessProbing {
    private let keychain: KeychainStore
    private let cohereBinary: URL?
    private let whisperModel: URL?

    public init(
        keychain: KeychainStore,
        cohereBinary: URL? = nil,
        whisperModel: URL? = nil
    ) {
        self.keychain = keychain
        self.cohereBinary = cohereBinary
        self.whisperModel = whisperModel
    }

    public func cloudKeyAvailable() async -> Bool {
        guard let value = (try? keychain.read()) ?? nil else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func localEngineBinaryURL() -> URL? { cohereBinary }
    public func localLanguageModelURL() -> URL? { whisperModel }

    public func localBinaryReady(_ url: URL) async -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    public func localModelReady(_ url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

/// Output folder probing — writability check + cloud-sync heuristic. Pulled
/// behind a protocol so tests can drive every branch without touching disk.
public protocol OutputFolderProbing: Sendable {
    func isWritable(_ url: URL) async -> Bool
    func syncedStorageHint(_ url: URL) -> String?
}

public struct DefaultOutputFolderProbe: OutputFolderProbing {
    public init() {}

    public func isWritable(_ url: URL) async -> Bool {
        let fm = FileManager.default
        // Ensure directory exists; silently create if missing (matches the
        // pre-existing behaviour in AppDelegate).
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let probe = url.appendingPathComponent(".transcriber-write-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try fm.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    public func syncedStorageHint(_ url: URL) -> String? {
        // Path-component heuristic. A real check would pull
        // NSURLUbiquitousItemDownloadingStatusKey / Mobile Documents container,
        // but path matching catches the user-visible disasters (saving into
        // a Drive/Dropbox/iCloud folder) without needing entitlements.
        let path = url.path.lowercased()
        if path.contains("/library/mobile documents/") || path.contains("/icloud") {
            return "iCloud Drive"
        }
        if path.contains("/dropbox/") || path.hasSuffix("/dropbox") {
            return "Dropbox"
        }
        if path.contains("/google drive/") || path.contains("/googledrive/") {
            return "Google Drive"
        }
        if path.contains("/onedrive/") {
            return "OneDrive"
        }
        return nil
    }
}

// MARK: - Doctor

/// Runs every preflight probe and emits a `PreflightReport`. Order of probes
/// is fixed so the popover always shows blockers in the same order: mic →
/// screen → output → engine → calendar. That lets the user fix them top-down.
public actor PermissionDoctor {
    private let permissions: PermissionStatusProbing
    private let engine: EngineReadinessProbing
    private let folder: OutputFolderProbing

    public init(
        permissions: PermissionStatusProbing = DefaultPermissionStatusProbe(),
        engine: EngineReadinessProbing,
        folder: OutputFolderProbing = DefaultOutputFolderProbe()
    ) {
        self.permissions = permissions
        self.engine = engine
        self.folder = folder
    }

    public func audit(outputRoot: URL, engineMode: EngineMode) async -> PreflightReport {
        var blockers: [PreflightReason] = []
        var warnings: [PreflightReason] = []

        // Mic — required.
        switch await permissions.microphone() {
        case .granted: break
        case .notDetermined: blockers.append(.microphoneNotDetermined)
        case .denied: blockers.append(.microphoneDenied)
        }

        // Screen recording — required (spec line 339: no mic-only fallback).
        if await permissions.screenRecording() != .granted {
            blockers.append(.screenRecordingDenied)
        }

        // Output folder writability — required.
        if await folder.isWritable(outputRoot) == false {
            blockers.append(.outputFolderUnwritable(outputRoot))
        } else if let hint = folder.syncedStorageHint(outputRoot) {
            // Synced-storage parents are a blocker, not a warning: silent
            // file conflicts during a 60-min recording would be far more
            // destructive than aborting the start request.
            blockers.append(.outputFolderInSyncedStorage(outputRoot, providerHint: hint))
        }

        // Engine readiness — required, mode-dependent.
        switch engineMode {
        case .cloud:
            if await engine.cloudKeyAvailable() == false {
                blockers.append(.missingCloudAPIKey)
            }
        case .local:
            if let bin = engine.localEngineBinaryURL() {
                if await engine.localBinaryReady(bin) == false {
                    blockers.append(.missingLocalEngineBinary(bin))
                }
            } else {
                // Local mode selected but no binary path configured at all —
                // V1 cloud-only builds hit this if the user flips engine to
                // local before Phase ο ships.
                blockers.append(.missingLocalEngineBinary(URL(fileURLWithPath: "Resources/cohere_transcribe_rs")))
            }
            if let model = engine.localLanguageModelURL() {
                if await engine.localModelReady(model) == false {
                    blockers.append(.missingLocalLanguageModel(model))
                }
            } else {
                blockers.append(.missingLocalLanguageModel(URL(fileURLWithPath: "Resources/whisper-tiny")))
            }
        }

        // Calendar — optional. Spec lines 88 and 333: never blocks recording.
        switch await permissions.calendar() {
        case .granted: break
        case .denied: warnings.append(.calendarDeniedOptional)
        case .notDetermined: warnings.append(.calendarNotDetermined)
        }

        return PreflightReport(blockers: blockers, warnings: warnings)
    }
}

// MARK: - Gate

/// Maps a `PreflightReport` to a single start-path verdict. Kept tiny so the
/// rule (any blocker → deny; warnings → allowWithWarnings; clean → allow) is
/// obvious and unit-testable in isolation from the doctor.
public struct RecordRequestGate: Sendable {
    public init() {}

    public func verdict(from report: PreflightReport) -> PreflightVerdict {
        if report.blockers.isEmpty == false {
            return .deny(report.blockers)
        }
        if report.warnings.isEmpty == false {
            return .allowWithWarnings(report.warnings)
        }
        return .allow
    }
}
