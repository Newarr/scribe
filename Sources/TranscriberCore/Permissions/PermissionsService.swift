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

    public func calendarStatus() -> PermissionStatus {
        Self.currentCalendarStatus()
    }

    public func requestCalendar() async -> PermissionStatus {
        let before = Self.currentCalendarStatus()
        let store = EKEventStore()
        do {
            let granted = try await store.requestFullAccessToEvents()
            Log.permissions.info("Calendar full-access request returned granted=\(granted, privacy: .public)")
        } catch {
            Log.permissions.error("Calendar full-access request failed: \(String(describing: error), privacy: .public)")
        }

        let after = Self.currentCalendarStatus()
        if before == .notDetermined, after == .notDetermined {
            Log.permissions.error("Calendar full-access request finished without an authorization status transition")
        }
        return after
    }

    static func currentCalendarStatus() -> PermissionStatus {
        mapCalendarAuthorizationStatus(EKEventStore.authorizationStatus(for: .event))
    }

    static func mapCalendarAuthorizationStatus(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .fullAccess, .authorized:
            return .granted
        case .denied, .restricted, .writeOnly:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }
}
