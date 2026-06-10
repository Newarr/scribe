import AppKit
import Foundation

struct ProcessWatcherRunningApplication: Sendable, Equatable {
  let bundleIdentifier: String?
  let launchDate: Date?
}

protocol ProcessWatcherObserverToken: AnyObject {}

protocol ProcessWatcherWorkspaceObserving: AnyObject {
  var runningApplications: [ProcessWatcherRunningApplication] { get }

  func addLaunchObserver(_ handler: @escaping @Sendable (String?) -> Void)
    -> ProcessWatcherObserverToken
  func addTerminateObserver(_ handler: @escaping @Sendable (String?) -> Void)
    -> ProcessWatcherObserverToken
  func removeObserver(_ observer: ProcessWatcherObserverToken)
}

protocol ProcessWatcherTimerToken: AnyObject {
  func invalidate()
}

protocol ProcessWatcherTimerScheduling: AnyObject {
  func scheduleRepeating(interval: TimeInterval, _ handler: @escaping @Sendable () -> Void)
    -> ProcessWatcherTimerToken
}

private final class NotificationObserverToken: ProcessWatcherObserverToken {
  let rawValue: NSObjectProtocol

  init(_ rawValue: NSObjectProtocol) {
    self.rawValue = rawValue
  }
}

private final class NSWorkspaceProcessObserver: ProcessWatcherWorkspaceObserving {
  private let workspace: NSWorkspace

  init(workspace: NSWorkspace) {
    self.workspace = workspace
  }

  var runningApplications: [ProcessWatcherRunningApplication] {
    workspace.runningApplications.map {
      ProcessWatcherRunningApplication(
        bundleIdentifier: $0.bundleIdentifier, launchDate: $0.launchDate)
    }
  }

  func addLaunchObserver(_ handler: @escaping @Sendable (String?) -> Void)
    -> ProcessWatcherObserverToken
  {
    addObserver(forName: NSWorkspace.didLaunchApplicationNotification, handler)
  }

  func addTerminateObserver(_ handler: @escaping @Sendable (String?) -> Void)
    -> ProcessWatcherObserverToken
  {
    addObserver(forName: NSWorkspace.didTerminateApplicationNotification, handler)
  }

  func removeObserver(_ observer: ProcessWatcherObserverToken) {
    guard let observer = observer as? NotificationObserverToken else { return }
    workspace.notificationCenter.removeObserver(observer.rawValue)
  }

  private func addObserver(
    forName name: NSNotification.Name,
    _ handler: @escaping @Sendable (String?) -> Void
  ) -> ProcessWatcherObserverToken {
    let observer = workspace.notificationCenter.addObserver(forName: name, object: nil, queue: nil)
    { note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      handler(app?.bundleIdentifier)
    }
    return NotificationObserverToken(observer)
  }
}

private final class TimerToken: ProcessWatcherTimerToken {
  private let timer: Timer

  init(_ timer: Timer) {
    self.timer = timer
  }

  func invalidate() {
    timer.invalidate()
  }
}

private final class RunLoopProcessWatcherTimerScheduler: ProcessWatcherTimerScheduling {
  func scheduleRepeating(interval: TimeInterval, _ handler: @escaping @Sendable () -> Void)
    -> ProcessWatcherTimerToken
  {
    let timer = Timer(timeInterval: interval, repeats: true) { _ in
      handler()
    }
    RunLoop.main.add(timer, forMode: .common)
    return TimerToken(timer)
  }
}

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

  private let workspaceObserver: ProcessWatcherWorkspaceObserving
  private let timerScheduler: ProcessWatcherTimerScheduling
  private let onLaunch: Handler
  private let onQuit: Handler
  private let onReevaluate: Handler
  private let reevaluationInterval: TimeInterval
  private var launchObserver: ProcessWatcherObserverToken?
  private var terminateObserver: ProcessWatcherObserverToken?
  private var reevaluationTimer: ProcessWatcherTimerToken?

  public convenience init(
    workspace: NSWorkspace = .shared,
    reevaluationInterval: TimeInterval = 5,
    onLaunch: @escaping Handler,
    onQuit: @escaping Handler,
    onReevaluate: Handler? = nil
  ) {
    self.init(
      workspaceObserver: NSWorkspaceProcessObserver(workspace: workspace),
      timerScheduler: RunLoopProcessWatcherTimerScheduler(),
      reevaluationInterval: reevaluationInterval,
      onLaunch: onLaunch,
      onQuit: onQuit,
      onReevaluate: onReevaluate
    )
  }

  init(
    workspaceObserver: ProcessWatcherWorkspaceObserving,
    timerScheduler: ProcessWatcherTimerScheduling,
    reevaluationInterval: TimeInterval = 5,
    onLaunch: @escaping Handler,
    onQuit: @escaping Handler,
    onReevaluate: Handler? = nil
  ) {
    self.workspaceObserver = workspaceObserver
    self.timerScheduler = timerScheduler
    self.reevaluationInterval = reevaluationInterval
    self.onLaunch = onLaunch
    self.onQuit = onQuit
    self.onReevaluate = onReevaluate ?? onLaunch
  }

  /// Only consider a cold-start app as "just launched" if its
  /// `launchDate` is within this many seconds of now. Catches the
  /// "Scribe restarted mid-call" case while ignoring apps the user
  /// has had open all day.
  static let coldStartLaunchWindow: TimeInterval = 60

  public func start() {
    guard launchObserver == nil, terminateObserver == nil, reevaluationTimer == nil else { return }

    launchObserver = workspaceObserver.addLaunchObserver { [weak self] bundleIdentifier in
      self?.handleLaunch(bundleIdentifier: bundleIdentifier)
    }
    terminateObserver = workspaceObserver.addTerminateObserver { [weak self] bundleIdentifier in
      self?.handleTerminate(bundleIdentifier: bundleIdentifier)
    }

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
    if let launchObserver {
      workspaceObserver.removeObserver(launchObserver)
      self.launchObserver = nil
    }
    if let terminateObserver {
      workspaceObserver.removeObserver(terminateObserver)
      self.terminateObserver = nil
    }
  }

  /// Re-scan currently running supported apps/browsers. Safe to call on
  /// launch, wake, calendar refresh, or a polling tick; DetectionEngine
  /// coalesces duplicates and uses CoreAudioInputProbe to reject idle apps.
  public func reevaluateRunningMeetingApps() {
    for app in Self.meetingApps(
      from: workspaceObserver.runningApplications.compactMap(\.bundleIdentifier))
    {
      onReevaluate(app)
    }
  }

  static func meetingApps(from bundleIDs: [String]) -> [MeetingApp] {
    var seen = Set<String>()
    var apps: [MeetingApp] = []
    for bundleID in bundleIDs {
      guard let app = MeetingApps.appFor(bundleID: bundleID), seen.insert(app.bundleID).inserted
      else { continue }
      apps.append(app)
    }
    return apps
  }

  private func startReevaluationTimer() {
    guard reevaluationInterval > 0, reevaluationTimer == nil else { return }
    reevaluationTimer = timerScheduler.scheduleRepeating(interval: reevaluationInterval) {
      [weak self] in
      self?.reevaluateRunningMeetingApps()
    }
  }

  private func emitRecentNativeLaunches() {
    let now = Date()
    let window = Self.coldStartLaunchWindow
    for runningApp in workspaceObserver.runningApplications {
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

  private func handleLaunch(bundleIdentifier: String?) {
    guard let id = bundleIdentifier, let meetingApp = MeetingApps.appFor(bundleID: id) else {
      return
    }
    onLaunch(meetingApp)
  }

  private func handleTerminate(bundleIdentifier: String?) {
    guard let id = bundleIdentifier, let meetingApp = MeetingApps.appFor(bundleID: id) else {
      return
    }
    onQuit(meetingApp)
  }
}
