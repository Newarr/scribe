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
    private let onReevaluate: Handler
    private let reevaluationInterval: TimeInterval
    private var observers: [NSObjectProtocol] = []
    private var reevaluationTimer: Timer?

    public init(
        workspace: NSWorkspace = .shared,
        reevaluationInterval: TimeInterval = 5,
        onLaunch: @escaping Handler,
        onQuit: @escaping Handler,
        onReevaluate: Handler? = nil
    ) {
        self.workspace = workspace
        self.reevaluationInterval = reevaluationInterval
        self.onLaunch = onLaunch
        self.onQuit = onQuit
        self.onReevaluate = onReevaluate ?? onLaunch
    }

    /// Only consider a cold-start app as "just launched" if its
    /// `launchDate` is within this many seconds of now. Catches the
    /// "Scribe restarted mid-call" case while ignoring apps the user
    /// has had open all day.
    public static let coldStartLaunchWindow: TimeInterval = 60

    public func start() {
        let nc = workspace.notificationCenter
        let launch = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { [weak self] note in
            self?.handleLaunch(note)
        }
        let terminate = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            self?.handleTerminate(note)
        }
        observers.append(contentsOf: [launch, terminate])

        // Cold-start: launches remain a strong signal for native meeting apps
        // that just appeared, but app/browser presence alone is not enough to
        // prompt. Separately re-evaluate every currently running allowlisted
        // surface so Scribe launch into an already-active call and long-running
        // browsers can reach the audio-probed DetectionEngine path.
        emitRecentNativeLaunches()
        reevaluateRunningMeetingApps()
        startReevaluationTimer()
    }

    public func stop() {
        reevaluationTimer?.invalidate()
        reevaluationTimer = nil
        for obs in observers { workspace.notificationCenter.removeObserver(obs) }
        observers.removeAll()
    }

    /// Re-scan currently running supported apps/browsers. Safe to call on
    /// launch, wake, calendar refresh, or a polling tick; DetectionEngine
    /// coalesces duplicates and uses CoreAudioInputProbe to reject idle apps.
    public func reevaluateRunningMeetingApps() {
        for app in Self.meetingApps(from: workspace.runningApplications.compactMap(\.bundleIdentifier)) {
            onReevaluate(app)
        }
    }

    public static func meetingApps(from bundleIDs: [String]) -> [MeetingApp] {
        var seen = Set<String>()
        var apps: [MeetingApp] = []
        for bundleID in bundleIDs {
            guard let app = MeetingApps.appFor(bundleID: bundleID), seen.insert(app.bundleID).inserted else { continue }
            apps.append(app)
        }
        return apps
    }

    private func startReevaluationTimer() {
        guard reevaluationInterval > 0 else { return }
        let timer = Timer(timeInterval: reevaluationInterval, repeats: true) { [weak self] _ in
            self?.reevaluateRunningMeetingApps()
        }
        RunLoop.main.add(timer, forMode: .common)
        reevaluationTimer = timer
    }

    private func emitRecentNativeLaunches() {
        let now = Date()
        let window = Self.coldStartLaunchWindow
        for runningApp in workspace.runningApplications {
            guard
                let id = runningApp.bundleIdentifier,
                let meetingApp = MeetingApps.appFor(bundleID: id),
                meetingApp.kind == .nativeMeetingApp,
                let launchDate = runningApp.launchDate,
                now.timeIntervalSince(launchDate) <= window
            else { continue }
            onLaunch(meetingApp)
        }
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
