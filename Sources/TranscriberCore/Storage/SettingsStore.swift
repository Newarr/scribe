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

/// Snapshot of all settings that drive a session's runtime behavior.
/// The supervisor / capture session / worker take this snapshot at start
/// and don't poll back into the store mid-session — settings changes
/// take effect on the next session, never to the running one.
public struct SessionSettings: Sendable, Equatable, Codable {
    public var outputRoot: URL
    public var engineMode: EngineMode
    /// Spec line 102: default OFF means raw mic.m4a + system.m4a are
    /// DELETED after audio.m4a is mixed. Set true only for users who
    /// want to inspect the per-channel originals.
    public var keepRawStreams: Bool
    /// D2: spec line 119 says single-channel diarized is the fallback
    /// when AEC fails — implies AEC is attempted by default. Setting
    /// this false bypasses the AEC pre-pass and forces single-channel
    /// mode unconditionally (debugging knob).
    public var aecEnabled: Bool

    public init(
        outputRoot: URL,
        engineMode: EngineMode,
        keepRawStreams: Bool,
        aecEnabled: Bool
    ) {
        self.outputRoot = outputRoot
        self.engineMode = engineMode
        self.keepRawStreams = keepRawStreams
        self.aecEnabled = aecEnabled
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
    }

    public struct Defaults: Sendable {
        public var outputRoot: URL
        public var engineMode: EngineMode
        public var keepRawStreams: Bool
        public var aecEnabled: Bool

        public init(
            outputRoot: URL,
            engineMode: EngineMode = .cloud,
            keepRawStreams: Bool = false,  // spec line 102
            aecEnabled: Bool = true         // D2
        ) {
            self.outputRoot = outputRoot
            self.engineMode = engineMode
            self.keepRawStreams = keepRawStreams
            self.aecEnabled = aecEnabled
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
        commit(current)
    }

    public func setEngineMode(_ mode: EngineMode) {
        var current = snapshot()
        current.engineMode = mode
        commit(current)
    }

    public func setKeepRawStreams(_ on: Bool) {
        var current = snapshot()
        current.keepRawStreams = on
        commit(current)
    }

    public func setAECEnabled(_ on: Bool) {
        var current = snapshot()
        current.aecEnabled = on
        commit(current)
    }

    /// Atomic multi-key commit. Phase η Settings UI calls this after
    /// the user clicks Save so the resulting on-disk state never
    /// contains a partial mix of old + new fields.
    public func commit(_ settings: SessionSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            box.defaults.set(data, forKey: Key.storage.rawValue)
        } else {
            Log.engine.error("SettingsStore: failed to encode SessionSettings")
        }
    }
}

private extension SettingsStore.Defaults {
    func toSnapshot() -> SessionSettings {
        SessionSettings(
            outputRoot: outputRoot,
            engineMode: engineMode,
            keepRawStreams: keepRawStreams,
            aecEnabled: aecEnabled
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
            aecEnabled: fallback.aecEnabled
        )
    }
}
