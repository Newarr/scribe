import AVFoundation
import CoreGraphics
import EventKit

public enum PermissionStatus: Sendable, Equatable {
    case notDetermined, denied, granted
}

public final class PermissionsService: Sendable {
    public init() {}

    public func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        case .authorized: return .granted
        @unknown default: return .denied
        }
    }

    public func requestMicrophone() async -> PermissionStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }

    // CGPreflightScreenCaptureAccess reads TCC directly and returns
    // instantly. Unlike SCShareableContent.current it doesn't throw on
    // first call after grant, but it shares the underlying macOS quirk:
    // a grant made while the process is running may not become visible
    // to the running process until relaunch. AppDelegate handles that
    // by detecting `requestScreenRecording() == true` paired with
    // `screenRecordingStatus() == .denied` and surfacing a restart
    // alert. The async signature is preserved so PermissionStatusProbing
    // can keep its shape.
    public func screenRecordingStatus() async -> PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    @discardableResult
    public func requestScreenRecording() async -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func requestCalendar() async -> PermissionStatus {
        let store = EKEventStore()
        return await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted ? .granted : .denied)
            }
        }
    }
}
