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

    // CGPreflightScreenCaptureAccess reads TCC directly, returns instantly,
    // and doesn't have the "first call after grant throws until restart"
    // failure mode that SCShareableContent.current does. The async signature
    // is preserved so PermissionStatusProbing can keep its shape.
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
