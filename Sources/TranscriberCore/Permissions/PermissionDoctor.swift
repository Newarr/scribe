import Foundation
import UserNotifications

/// Engine selection at preflight time. Used to decide which engine readiness
/// probe runs (cloud needs the API key; local needs verified native Cohere/MLX readiness).
public enum EngineMode: String, Sendable, Codable {
    case cloud
    case local
}

public extension EngineMode {
    /// Canonical identifier persisted in transcript frontmatter,
    /// session.json, and metadata ("elevenlabs" | "cohere"). Every
    /// reader and writer must round-trip through this pair so the
    /// recovery, repair, and diagnostics layers can't drift apart.
    var persistedIdentifier: String {
        switch self {
        case .cloud: return "elevenlabs"
        case .local: return "cohere"
        }
    }

    /// Parses a persisted engine identifier. Tolerates surrounding
    /// whitespace and any casing, matching the recovery readers.
    init?(persistedIdentifier: String) {
        switch persistedIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case EngineMode.cloud.persistedIdentifier: self = .cloud
        case EngineMode.local.persistedIdentifier: self = .local
        default: return nil
        }
    }

    /// User-facing engine name for notifications and transcripts.
    var displayName: String {
        switch self {
        case .cloud: return "ElevenLabs"
        case .local: return "Cohere"
        }
    }
}

/// One reason `RecordRequestGate.audit` returns deny or warn. Each reason is
/// individually addressable so `PermissionRecoveryView` can deep-link to the
/// matching System Settings pane (Phase η).
public enum PreflightReason: Sendable, Equatable, Hashable {
    public static let systemAudioRequiredMessage = "System Audio is required to capture other people in calls."

    case microphoneDenied
    case microphoneNotDetermined
    case screenRecordingDenied
    case outputFolderUnwritable(URL)
    case outputFolderInSyncedStorage(URL, providerHint: String)
    case missingCloudAPIKey
    case localModelNotVerified(modelID: String)
    case localRuntimeUnavailable
    case calendarDeniedOptional
    case calendarNotDetermined
    case notificationsDeniedOptional
    case notificationsNotDetermined

    /// Codex rc2-audit P0 (privacy): public-safe label for log sites
    /// that need to record WHICH reason fired without exposing the
    /// associated `URL` (which would carry `/Users/<name>/...`).
    /// Use this in `Log.*` calls with `.public` privacy; pair with
    /// the full reason at `.private` if path detail is needed.
    public var publicLabel: String {
        switch self {
        case .microphoneDenied: return "microphoneDenied"
        case .microphoneNotDetermined: return "microphoneNotDetermined"
        case .screenRecordingDenied: return "screenRecordingDenied"
        case .outputFolderUnwritable: return "outputFolderUnwritable"
        case .outputFolderInSyncedStorage(_, let provider): return "outputFolderInSyncedStorage(\(provider))"
        case .missingCloudAPIKey: return "missingCloudAPIKey"
        case .localModelNotVerified: return "localModelNotVerified"
        case .localRuntimeUnavailable: return "localRuntimeUnavailable"
        case .calendarDeniedOptional: return "calendarDeniedOptional"
        case .calendarNotDetermined: return "calendarNotDetermined"
        case .notificationsDeniedOptional: return "notificationsDeniedOptional"
        case .notificationsNotDetermined: return "notificationsNotDetermined"
        }
    }
}

extension Sequence where Element == PreflightReason {
    /// Public-log-safe rendering: comma-separated case names, never
    /// the associated paths.
    public var publicLabels: String {
        map(\.publicLabel).joined(separator: ", ")
    }
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
    /// Returns granted only when EventKit allows Scribe to read events.
    /// Full access and the legacy `.authorized` value are granted;
    /// denied, restricted, and write-only are actionable denied states.
    func calendar() async -> PermissionStatus
    func notifications() async -> PermissionStatus
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
        permissions.calendarStatus()
    }

    public func notifications() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}

/// Engine readiness probing. Cloud mode checks the Keychain entry; local mode
/// checks native Cohere/MLX runtime support and verified model readiness.
public protocol EngineReadinessProbing: Sendable {
    func cloudKeyAvailable() async -> Bool
    func localModelStatus() async -> LocalModelCacheStatus
    func localModelID() -> String
}

public extension EngineReadinessProbing {
    func localRuntimeAvailable() async -> Bool {
        if case .unsupported = await localModelStatus() { return false }
        return true
    }

    func localModelVerified() async -> Bool {
        (await localModelStatus()).isReady
    }
}

public protocol LocalModelStatusProviding: Sendable {
    func status() async -> LocalModelCacheStatus
}

extension LocalModelManager: LocalModelStatusProviding {}

public struct LocalModelEngineReadinessProbe: EngineReadinessProbing {
    private let cloudKeyProbe: @Sendable () async -> Bool
    private let localModel: any LocalModelStatusProviding
    private let modelID: String

    public init(
        cloudKeyProbe: @escaping @Sendable () async -> Bool,
        localModel: any LocalModelStatusProviding,
        modelID: String = CohereMLXBackend.modelID
    ) {
        self.cloudKeyProbe = cloudKeyProbe
        self.localModel = localModel
        self.modelID = modelID
    }

    public func cloudKeyAvailable() async -> Bool { await cloudKeyProbe() }
    public func localModelStatus() async -> LocalModelCacheStatus { await localModel.status() }
    public func localModelID() -> String { modelID }
}

/// Default readiness probe. Until the app wires an owned model manager into
/// this probe, Local fails closed as not downloaded rather than falling back.
public struct DefaultEngineReadinessProbe: EngineReadinessProbing {
    private let keychain: KeychainStore

    public init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    public func cloudKeyAvailable() async -> Bool {
        guard let value = (try? keychain.read(allowingUserInteraction: false)) ?? nil else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func localModelStatus() async -> LocalModelCacheStatus {
#if arch(arm64)
        return .notDownloaded(modelID: CohereMLXBackend.modelID)
#else
        return .unsupported(
            modelID: CohereMLXBackend.modelID,
            reason: LocalModelFailure(code: .unsupportedRuntime, message: "Local Cohere runtime is unavailable on this Mac.")
        )
#endif
    }

    public func localModelID() -> String { CohereMLXBackend.modelID }
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
        //
        // Covers both legacy paths and the modern `~/Library/CloudStorage/`
        // tree macOS uses since 12.0 for File Provider mirrored folders
        // (codex Phase α review P1.2): GoogleDrive-, OneDrive-, Dropbox,
        // Box, etc. all live under that directory.
        let path = url.path.lowercased()
        if path.contains("/library/mobile documents/") || path.contains("/icloud") {
            return "iCloud Drive"
        }
        if path.contains("/library/cloudstorage/googledrive") || path.contains("/google drive/") || path.contains("/googledrive/") {
            return "Google Drive"
        }
        if path.contains("/library/cloudstorage/onedrive") || path.contains("/onedrive/") || path.contains("/onedrive-") {
            return "OneDrive"
        }
        if path.contains("/library/cloudstorage/dropbox") || path.contains("/dropbox/") || path.contains("/dropbox (") || path.hasSuffix("/dropbox") {
            return "Dropbox"
        }
        if path.contains("/library/cloudstorage/box") || path.contains("/box sync/") {
            return "Box"
        }
        // Generic CloudStorage subfolder (e.g. third-party File Providers).
        if path.contains("/library/cloudstorage/") {
            return "synced storage"
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

        // Screen/system audio — required (spec line 339: no mic-only fallback).
        if await permissions.screenRecording() != .granted {
            blockers.append(.screenRecordingDenied)
        }

        // Output folder writability — required.
        if await folder.isWritable(outputRoot) == false {
            blockers.append(.outputFolderUnwritable(outputRoot))
        } else if let hint = folder.syncedStorageHint(outputRoot) {
            // Spec line 231: "Warn if output folder is in iCloud Drive,
            // Dropbox, Google Drive, or another synced location." Codex
            // Phase α review P1.1 caught that v0 of this code blocked, not
            // warned — fixed here. Synced-storage hint surfaces as a
            // warning so the user can proceed but knows file conflicts are
            // possible. Phase η renders the prompt UI.
            warnings.append(.outputFolderInSyncedStorage(outputRoot, providerHint: hint))
        }

        // Engine readiness — required, mode-dependent.
        switch engineMode {
        case .cloud:
            if await engine.cloudKeyAvailable() == false {
                blockers.append(.missingCloudAPIKey)
            }
        case .local:
            switch await engine.localModelStatus() {
            case .verified:
                break
            case .unsupported:
                blockers.append(.localRuntimeUnavailable)
            case .notDownloaded, .downloading, .verifying, .failed:
                blockers.append(.localModelNotVerified(modelID: engine.localModelID()))
            }
        }

        // Calendar — optional. Spec lines 88 and 333: never blocks recording.
        switch await permissions.calendar() {
        case .granted: break
        case .denied: warnings.append(.calendarDeniedOptional)
        case .notDetermined: warnings.append(.calendarNotDetermined)
        }

        // Notifications — optional. Missing notification permission reduces the
        // redundant-channel prompt pattern, but must not block manual recording.
        switch await permissions.notifications() {
        case .granted: break
        case .denied: warnings.append(.notificationsDeniedOptional)
        case .notDetermined: warnings.append(.notificationsNotDetermined)
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
