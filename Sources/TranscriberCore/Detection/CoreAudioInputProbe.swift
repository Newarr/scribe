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
/// Multiple `AudioObjectID`s can share a bundle ID (Chrome helpers,
/// Teams renderer + main, etc.). Returns true if ANY matching process
/// is reading input.
public struct CoreAudioInputProbe: AudioActivityProbe {
    public init() {}

    public func isActive(bundleID: String) async -> Bool? {
        let processIDs = readProcessObjectList()
        guard let processIDs else { return nil }
        for processID in processIDs {
            guard let processBundleID = readBundleID(processID: processID),
                  processBundleID == bundleID else { continue }
            if readIsRunningInput(processID: processID) {
                return true
            }
        }
        return false
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

        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
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

    private func readIsRunningInput(processID: AudioObjectID) -> Bool {
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
        return status == noErr && value != 0
    }
}
