import CoreAudio
import Foundation

/// Per-PID input-device probe. Asks the macOS HAL: "is the audio process
/// associated with this bundle currently consuming the input device?"
///
/// Why this exists: dwell-on-launch + bundle allowlist alone fires the
/// start prompt every time the user opens Signal to read messages or
/// opens Chrome for any reason. The market-standard fix (Granola,
/// Recall.ai Desktop SDK) is to narrow the trigger to "this PID is
/// holding the input device right now," which uniquely distinguishes
/// "the user is in a call" from "the user opened the app for messaging
/// / browsing / dictating into something else."
///
/// API surface used (all macOS 14.0+, deployment target is 15):
///   - `kAudioHardwarePropertyProcessObjectList` — list of
///     `AudioObjectID`s, one per audio-active process.
///   - `kAudioProcessPropertyBundleID` — bundle ID for a process object.
///   - `kAudioProcessPropertyIsRunningInput` — true if that process is
///     actively reading from input. Output is intentionally NOT checked
///     (background YouTube tabs, system sounds, music) to keep the
///     signal narrow.
///
/// Bundle matching is **prefix-aware**: Chrome's renderer that
/// actually holds the mic for a Meet tab has bundle ID
/// `com.google.Chrome.helper.renderer`, not `com.google.Chrome`. Same
/// for Signal (`org.whispersystems.signal-desktop.helper.Renderer`),
/// Teams, Slack, etc. Matching only the parent bundle would silently
/// miss every real browser/Electron call. The probe therefore matches
/// when a process bundle equals the allowlist bundle OR is in its
/// dotted descendant namespace.
///
/// Returns true if ANY matching process is reading input. Returns nil
/// (engine pass-through) if the HAL refused to enumerate processes OR
/// if a matching process had a transient read error on its input
/// property — the caller treats nil as "couldn't determine, run the
/// dwell-only legacy path" rather than "no call."
public struct CoreAudioInputProbe: AudioActivityProbe {
    public init() {}

    public func isActive(bundleID: String) async -> Bool? {
        let processIDs = readProcessObjectList()
        guard let processIDs else { return nil }
        var sawReadError = false
        for processID in processIDs {
            guard let processBundleID = readBundleID(processID: processID),
                  Self.matches(allowlistBundle: bundleID, processBundle: processBundleID) else { continue }
            switch readIsRunningInput(processID: processID) {
            case .some(true):  return true
            case .some(false): continue
            case .none:        sawReadError = true
            }
        }
        return sawReadError ? nil : false
    }

    /// Internal so tests can lock the prefix semantics without spinning
    /// up the full HAL plumbing. Public probe surface stays `isActive`.
    static func matches(allowlistBundle: String, processBundle: String) -> Bool {
        if processBundle == allowlistBundle { return true }
        return processBundle.hasPrefix(allowlistBundle + ".")
    }

    private func readProcessObjectList() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )
        guard sizeStatus == noErr else { return nil }
        if size == 0 { return [] }

        // Defend against a non-multiple HAL response (rare, but cheap
        // to guard). If the byte count isn't a clean multiple of the
        // AudioObjectID stride, drop the trailing partial element.
        let stride = MemoryLayout<AudioObjectID>.stride
        let count = Int(size) / stride
        size = UInt32(count * stride)
        var ids = [AudioObjectID](repeating: 0, count: count)
        let dataStatus = ids.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                UnsafeMutableRawPointer(base)
            )
        }
        return dataStatus == noErr ? ids : nil
    }

    private func readBundleID(processID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var bundleRef: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &bundleRef) { ptr -> OSStatus in
            AudioObjectGetPropertyData(processID, &address, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
        guard status == noErr, let ref = bundleRef else { return nil }
        // CoreAudio CFString property reads return a +1 reference per
        // header docs ("the caller is responsible for releasing the
        // returned CFString"). takeRetainedValue handles the release.
        return ref.takeRetainedValue() as String
    }

    /// Returns:
    ///   - `.some(true)`  — process is actively reading input.
    ///   - `.some(false)` — process is not reading input.
    ///   - `nil`          — HAL refused the read (process tearing down,
    ///                      transient error). Caller distinguishes this
    ///                      from a definitive "no" and surfaces nil up
    ///                      to `isActive` so the engine pass-through
    ///                      doesn't suppress a real call.
    private func readIsRunningInput(processID: AudioObjectID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(processID, &address, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
        guard status == noErr else { return nil }
        return value != 0
    }
}
