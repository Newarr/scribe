import Foundation

/// Spec § Detection: real audio-activity detection (is there actually
/// audio coming out of this PID's audio device, not just is the app
/// running?). Phase π is research-gated: macOS 14.4+ exposes
/// `ProcessObjectList` + `kAudioDevicePropertyDeviceIsRunning` listeners
/// that COULD answer this, but no public API ties "PID X is producing
/// audio right now" together. The plan's honest position: ship the
/// protocol surface + a `bidirectional silence` fallback (already in
/// EndGuard from Phase δ), and the real probe lands in V1.1 if/when a
/// reliable signal exists.
public protocol AudioActivityProbe: Sendable {
    /// Returns true if `bundleID` (or any descendant process) is
    /// currently producing audio output OR holding the input device.
    /// `nil` means the probe could not determine the answer (no
    /// supporting public API on this macOS version, or the bundle is
    /// not registered with HAL).
    func isActive(bundleID: String) async -> Bool?
}

/// Always-nil probe. Used when the public API surface for
/// "PID X is producing audio" is unavailable. The detection layer
/// treats `nil` as indeterminate: it may continue through the dwell path,
/// but Calendar overlap alone is never promoted to active-call evidence.
public struct UnknownAudioActivityProbe: AudioActivityProbe {
    public init() {}
    public func isActive(bundleID: String) async -> Bool? { nil }
}
