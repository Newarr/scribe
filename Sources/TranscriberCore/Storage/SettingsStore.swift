import Foundation

// `UserDefaults` is documented as thread-safe by Apple but does not yet
// carry a formal `Sendable` conformance in the macOS 14 SDK. Mark it
// `@unchecked Sendable` retroactively so the SettingsStore actor can
// accept one across isolation boundaries without a sending-data-race
// false positive. If Apple ships the conformance natively, this extension
// becomes a no-op (and the compiler will warn / drop the override).
extension UserDefaults: @unchecked @retroactive Sendable {}

/// Snapshot of all settings that drive a session's runtime behavior.
/// The supervisor / capture session / worker take this snapshot at start
/// and don't poll back into the store mid-session — settings changes
/// take effect on the next session, never to the running one.
public struct SessionSettings: Sendable, Equatable {
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
/// inject an in-memory `UserDefaults(suiteName:)` instance.
///
/// All reads go through `snapshot()` so the worker holds an immutable
/// `SessionSettings` value rather than a live reference. Writes happen
/// on whichever queue the call lands on; the actor isolation keeps
/// concurrent writers from racing on multi-key updates (e.g. setting
/// engineMode and outputRoot from the same Settings UI commit).
public actor SettingsStore {
    public enum Key: String, Sendable {
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

    private let defaults: UserDefaults
    private let fallback: Defaults

    public init(defaults: UserDefaults = .standard, fallback: Defaults) {
        self.defaults = defaults
        self.fallback = fallback
    }

    /// Returns an immutable view of all settings. Use this at session
    /// start; do not re-read mid-session.
    public func snapshot() -> SessionSettings {
        SessionSettings(
            outputRoot: readOutputRoot(),
            engineMode: readEngineMode(),
            keepRawStreams: readKeepRawStreams(),
            aecEnabled: readAECEnabled()
        )
    }

    // MARK: - typed setters

    public func setOutputRoot(_ url: URL) {
        defaults.set(url.path, forKey: Key.outputRoot.rawValue)
    }

    public func setEngineMode(_ mode: EngineMode) {
        defaults.set(mode.rawValue, forKey: Key.engineMode.rawValue)
    }

    public func setKeepRawStreams(_ on: Bool) {
        defaults.set(on, forKey: Key.keepRawStreams.rawValue)
    }

    public func setAECEnabled(_ on: Bool) {
        defaults.set(on, forKey: Key.aecEnabled.rawValue)
    }

    // MARK: - typed getters (private — public surface is `snapshot()`)

    private func readOutputRoot() -> URL {
        if let path = defaults.string(forKey: Key.outputRoot.rawValue), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return fallback.outputRoot
    }

    private func readEngineMode() -> EngineMode {
        guard let raw = defaults.string(forKey: Key.engineMode.rawValue),
              let mode = EngineMode(rawValue: raw) else {
            return fallback.engineMode
        }
        return mode
    }

    private func readKeepRawStreams() -> Bool {
        // UserDefaults.bool returns false for missing keys, which is what
        // we want for the spec-default (off). But to honor an explicit
        // user-set true, we still need to check object presence — bool
        // alone can't distinguish "unset" from "set to false."
        if defaults.object(forKey: Key.keepRawStreams.rawValue) != nil {
            return defaults.bool(forKey: Key.keepRawStreams.rawValue)
        }
        return fallback.keepRawStreams
    }

    private func readAECEnabled() -> Bool {
        // D2: default ON means an unset key reads as the fallback (true).
        // Distinguish unset from explicit-false the same way as above.
        if defaults.object(forKey: Key.aecEnabled.rawValue) != nil {
            return defaults.bool(forKey: Key.aecEnabled.rawValue)
        }
        return fallback.aecEnabled
    }
}
