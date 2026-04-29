import AppKit
import Foundation

/// Bridges NSWorkspace launch / terminate notifications into the detection
/// pipeline. Filters to allowlisted bundle IDs only — non-meeting apps don't
/// consume any further work.
///
/// macOS doesn't provide a privacy-respecting public API to ask "is this
/// other process using the microphone?", so slice 5 light treats process
/// running as the trigger signal. Slice 5b would augment with an SCK-driven
/// audio-activity probe.
public final class ProcessWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (MeetingApp) -> Void

    private let workspace: NSWorkspace
    private let onLaunch: Handler
    private let onQuit: Handler
    private var observers: [NSObjectProtocol] = []

    public init(
        workspace: NSWorkspace = .shared,
        onLaunch: @escaping Handler,
        onQuit: @escaping Handler
    ) {
        self.workspace = workspace
        self.onLaunch = onLaunch
        self.onQuit = onQuit
    }

    public func start() {
        let nc = workspace.notificationCenter
        let launch = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { [weak self] note in
            self?.handleLaunch(note)
        }
        let terminate = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            self?.handleTerminate(note)
        }
        observers.append(contentsOf: [launch, terminate])

        // Cold-start: emit launches for already-running allowlisted apps so we
        // don't miss ongoing sessions on relaunch.
        for runningApp in workspace.runningApplications {
            if let id = runningApp.bundleIdentifier, let meetingApp = MeetingApps.appFor(bundleID: id) {
                onLaunch(meetingApp)
            }
        }
    }

    public func stop() {
        for obs in observers { workspace.notificationCenter.removeObserver(obs) }
        observers.removeAll()
    }

    private func handleLaunch(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier,
              let meetingApp = MeetingApps.appFor(bundleID: id) else { return }
        onLaunch(meetingApp)
    }

    private func handleTerminate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier,
              let meetingApp = MeetingApps.appFor(bundleID: id) else { return }
        onQuit(meetingApp)
    }
}
