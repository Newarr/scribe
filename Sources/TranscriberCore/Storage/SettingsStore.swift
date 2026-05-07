import Foundation

/// Sendable wrapper around `UserDefaults`. Apple documents UserDefaults
/// as thread-safe but doesn't (yet) carry a formal Sendable conformance
/// in the macOS 14 SDK.
///
/// Codex Phase ζ P1.3: a global retroactive `extension UserDefaults:
/// Sendable` collides with any future Apple-provided conformance OR any
/// other module declaring the same. Wrap once in our own Sendable
/// struct and the conformance lives on a type WE own.
public struct UserDefaultsBox: @unchecked Sendable {
    public let defaults: UserDefaults
    public init(_ defaults: UserDefaults) { self.defaults = defaults }
    public static let standard = UserDefaultsBox(.standard)
}

public enum AppearanceTheme: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case system
    case light
    case dark
}

public enum ShortcutModifier: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case command
    case shift
    case option
    case control
}

public struct KeyboardShortcutSetting: Sendable, Equatable, Hashable, Codable {
    public var key: String
    public var keyCode: UInt16
    public var modifiers: [ShortcutModifier]

    public init(key: String, keyCode: UInt16, modifiers: [ShortcutModifier]) {
        self.key = key.uppercased()
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let defaultStartStop = KeyboardShortcutSetting(key: "S", keyCode: 1, modifiers: [.command, .shift])
}

/// Snapshot of all settings that drive a session's runtime behavior.
/// The supervisor / capture session / worker take this snapshot at start
/// and don't poll back into the store mid-session — settings changes
/// take effect on the next session, never to the running one.
public struct SessionSettings: Sendable, Equatable, Codable {
    public var outputRoot: URL
    public var engineMode: EngineMode
    public var appearanceTheme: AppearanceTheme
    /// Spec line 102: default OFF means raw mic.m4a + system.m4a are
    /// DELETED after audio.m4a is mixed. Set true only for users who
    /// want to inspect the per-channel originals.
    public var keepRawStreams: Bool
    /// D2: spec line 119 says single-channel diarized is the fallback
    /// when AEC fails — implies AEC is attempted by default. Setting
    /// this false bypasses the AEC pre-pass and forces single-channel
    /// mode unconditionally (debugging knob).
    public var aecEnabled: Bool
    /// Spec line 348: the user must explicitly acknowledge what data
    /// leaves the device (cloud engine only) before the first recording.
    /// One-way flag — once true, never written back to false by the app.
    public var privacyAcknowledged: Bool
    public var launchAtLogin: Bool
    public var showInMenuBar: Bool
    public var startStopShortcut: KeyboardShortcutSetting

    public init(
        outputRoot: URL,
        engineMode: EngineMode,
        keepRawStreams: Bool,
        aecEnabled: Bool,
        privacyAcknowledged: Bool,
        appearanceTheme: AppearanceTheme = .system,
        launchAtLogin: Bool = false,
        showInMenuBar: Bool = true,
        startStopShortcut: KeyboardShortcutSetting = .defaultStartStop
    ) {
        self.outputRoot = outputRoot
        self.engineMode = engineMode
        self.appearanceTheme = appearanceTheme
        self.keepRawStreams = keepRawStreams
        self.aecEnabled = aecEnabled
        self.privacyAcknowledged = privacyAcknowledged
        self.appearanceTheme = appearanceTheme
        self.launchAtLogin = launchAtLogin
        self.showInMenuBar = showInMenuBar
        self.startStopShortcut = startStopShortcut
    }

    private enum CodingKeys: String, CodingKey {
        case outputRoot, engineMode, keepRawStreams, aecEnabled, privacyAcknowledged, appearanceTheme, launchAtLogin, showInMenuBar, startStopShortcut
    }

    /// Decoder permits older blob formats that omit `privacyAcknowledged`
    /// — those rolled forward as `false` (re-prompt). Avoids a hard
    /// fallback to ALL defaults just because one new field is missing.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.outputRoot = try c.decode(URL.self, forKey: .outputRoot)
        self.engineMode = try c.decode(EngineMode.self, forKey: .engineMode)
        self.appearanceTheme = try c.decodeIfPresent(AppearanceTheme.self, forKey: .appearanceTheme) ?? .system
        self.keepRawStreams = try c.decode(Bool.self, forKey: .keepRawStreams)
        self.aecEnabled = try c.decode(Bool.self, forKey: .aecEnabled)
        self.privacyAcknowledged = try c.decodeIfPresent(Bool.self, forKey: .privacyAcknowledged) ?? false
        self.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        self.showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? true
        self.startStopShortcut = try c.decodeIfPresent(KeyboardShortcutSetting.self, forKey: .startStopShortcut) ?? .defaultStartStop
    }
}

/// Settings backing store. UserDefaults under the hood; tests can
/// inject an in-memory `UserDefaults(suiteName:)` instance via
/// `UserDefaultsBox`.
///
/// Codex Phase ζ P1.4: settings are persisted as a single JSON blob
/// (key `transcriber.settings.v1`) so multi-key writes are atomic by
/// construction. Per-key setters do read-modify-write inside the actor;
/// the actor's serialization makes that safe against concurrent writers.
///
/// Reads are also single-blob, so a partial write (e.g. crash mid-
/// commit) leaves the previous good blob intact rather than mixing
/// fields from two epochs.
public actor SettingsStore {
    public enum Key: String, Sendable {
        /// Single JSON blob holding the whole settings struct.
        case storage = "transcriber.settings.v1"

        // Legacy per-key keys are no longer used for writes but are
        // surfaced here so AppDelegate's synchronous accessor can match
        // the same identifiers if we ever ship a migration path.
        case outputRoot = "transcriber.outputRoot"
        case engineMode = "transcriber.engineMode"
        case keepRawStreams = "transcriber.keepRawStreams"
        case aecEnabled = "transcriber.aecEnabled"
        case appearanceTheme = "transcriber.appearanceTheme"
        case launchAtLogin = "transcriber.launchAtLogin"
        case showInMenuBar = "transcriber.showInMenuBar"
        case startStopShortcut = "transcriber.startStopShortcut"
    }

    public struct Defaults: Sendable {
        public var outputRoot: URL
        public var engineMode: EngineMode
        public var appearanceTheme: AppearanceTheme
        public var keepRawStreams: Bool
        public var aecEnabled: Bool
        public var privacyAcknowledged: Bool
        public var launchAtLogin: Bool
        public var showInMenuBar: Bool
        public var startStopShortcut: KeyboardShortcutSetting

        public init(
            outputRoot: URL,
            engineMode: EngineMode = .cloud,
            keepRawStreams: Bool = false,  // spec line 102
            aecEnabled: Bool = true,        // D2
            privacyAcknowledged: Bool = false,  // spec line 348
            appearanceTheme: AppearanceTheme = .system,
            launchAtLogin: Bool = false,
            showInMenuBar: Bool = true,
            startStopShortcut: KeyboardShortcutSetting = .defaultStartStop
        ) {
            self.outputRoot = outputRoot
            self.engineMode = engineMode
            self.appearanceTheme = appearanceTheme
            self.keepRawStreams = keepRawStreams
            self.aecEnabled = aecEnabled
            self.privacyAcknowledged = privacyAcknowledged
            self.appearanceTheme = appearanceTheme
            self.launchAtLogin = launchAtLogin
            self.showInMenuBar = showInMenuBar
            self.startStopShortcut = startStopShortcut
        }
    }

    private let box: UserDefaultsBox
    private let fallback: Defaults

    public init(defaults: UserDefaultsBox = .standard, fallback: Defaults) {
        self.box = defaults
        self.fallback = fallback
    }

    /// Returns an immutable view of all settings. Use this at session
    /// start; do not re-read mid-session.
    public func snapshot() -> SessionSettings {
        if let data = box.defaults.data(forKey: Key.storage.rawValue),
           let decoded = try? JSONDecoder().decode(SessionSettings.self, from: data) {
            return decoded
        }
        return fallback.toSnapshot()
    }

    // MARK: - typed setters (read-modify-write — actor serializes)

    public func setOutputRoot(_ url: URL) {
        var current = snapshot()
        current.outputRoot = url
        try? commit(current)
    }

    public func setEngineMode(_ mode: EngineMode) {
        var current = snapshot()
        current.engineMode = mode
        try? commit(current)
    }

    public func setKeepRawStreams(_ on: Bool) {
        var current = snapshot()
        current.keepRawStreams = on
        try? commit(current)
    }

    public func setAECEnabled(_ on: Bool) {
        var current = snapshot()
        current.aecEnabled = on
        try? commit(current)
    }

    public func setPrivacyAcknowledged(_ acked: Bool) {
        var current = snapshot()
        current.privacyAcknowledged = acked
        try? commit(current)
    }

    public func setAppearanceTheme(_ theme: AppearanceTheme) {
        var current = snapshot()
        current.appearanceTheme = theme
        try? commit(current)
    }

    public func setLaunchAtLogin(_ on: Bool) {
        var current = snapshot()
        current.launchAtLogin = on
        try? commit(current)
    }

    public func setShowInMenuBar(_ on: Bool) {
        var current = snapshot()
        current.showInMenuBar = on
        try? commit(current)
    }

    public func setStartStopShortcut(_ shortcut: KeyboardShortcutSetting) {
        var current = snapshot()
        current.startStopShortcut = shortcut
        try? commit(current)
    }

    /// Atomic multi-key commit. Phase η Settings UI calls this after
    /// the user clicks Save so the resulting on-disk state never
    /// contains a partial mix of old + new fields.
    ///
    /// Codex Phase η P0.3: privacyAcknowledged is a one-way flag (spec
    /// line 348). If the on-disk snapshot already has it true, refuse
    /// to write false back over it — protects against a stale Settings
    /// form snapshot demoting the flag after the user acked elsewhere.
    /// Throws CommitError if encoding fails so the caller can surface it.
    public func commit(_ settings: SessionSettings) throws {
        var sanitized = settings
        let current = snapshot()
        if current.privacyAcknowledged && !sanitized.privacyAcknowledged {
            Log.engine.warning("SettingsStore: refusing to demote privacyAcknowledged true -> false; preserving acknowledgement")
            sanitized.privacyAcknowledged = true
        }
        do {
            let data = try JSONEncoder().encode(sanitized)
            box.defaults.set(data, forKey: Key.storage.rawValue)
        } catch {
            Log.engine.error("SettingsStore: failed to encode SessionSettings: \(String(describing: error), privacy: .public)")
            throw CommitError.encodeFailed(error)
        }
    }

    public enum CommitError: Error {
        case encodeFailed(Error)
    }
}

private extension SettingsStore.Defaults {
    func toSnapshot() -> SessionSettings {
        SessionSettings(
            outputRoot: outputRoot,
            engineMode: engineMode,
            keepRawStreams: keepRawStreams,
            aecEnabled: aecEnabled,
            privacyAcknowledged: privacyAcknowledged,
            appearanceTheme: appearanceTheme,
            launchAtLogin: launchAtLogin,
            showInMenuBar: showInMenuBar,
            startStopShortcut: startStopShortcut
        )
    }
}

/// Synchronous read of the same settings blob the actor reads. Useful
/// from MainActor-bound code paths that can't await an actor hop.
///
/// Codex Phase ζ note: this is observably consistent with the actor's
/// snapshot because both read the same JSON-blob key. There's still a
/// theoretical race if a write lands between the user's click and the
/// session-start path, but multi-key inconsistency is impossible
/// because the blob is the unit of commit.
public enum SettingsSnapshotReader {
    public static func read(
        from box: UserDefaultsBox = .standard,
        fallback: SettingsStore.Defaults
    ) -> SessionSettings {
        if let data = box.defaults.data(forKey: SettingsStore.Key.storage.rawValue),
           let decoded = try? JSONDecoder().decode(SessionSettings.self, from: data) {
            return decoded
        }
        return SessionSettings(
            outputRoot: fallback.outputRoot,
            engineMode: fallback.engineMode,
            keepRawStreams: fallback.keepRawStreams,
            aecEnabled: fallback.aecEnabled,
            privacyAcknowledged: fallback.privacyAcknowledged,
            appearanceTheme: fallback.appearanceTheme,
            launchAtLogin: fallback.launchAtLogin,
            showInMenuBar: fallback.showInMenuBar,
            startStopShortcut: fallback.startStopShortcut
        )
    }
}
