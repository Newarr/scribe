import XCTest

@testable import TranscriberCore

final class ProcessWatcherTests: XCTestCase {

  func testStartIsIdempotentAndStopCleansObserversAndTimers() {
    let workspace = FakeProcessWatcherWorkspaceObserver(runningApplications: [
      .init(bundleIdentifier: "us.zoom.xos", launchDate: Date())
    ])
    let timerScheduler = FakeProcessWatcherTimerScheduler()
    let recorder = ProcessWatcherEventRecorder()
    let watcher = ProcessWatcher(
      workspaceObserver: workspace,
      timerScheduler: timerScheduler,
      reevaluationInterval: 5,
      onLaunch: { recorder.recordLaunch($0) },
      onQuit: { recorder.recordQuit($0) },
      onReevaluate: { recorder.recordReevaluation($0) }
    )

    watcher.start()
    watcher.start()

    XCTAssertEqual(workspace.activeLaunchObserverCount, 1)
    XCTAssertEqual(workspace.activeTerminateObserverCount, 1)
    XCTAssertEqual(timerScheduler.activeTimerCount, 1)
    XCTAssertEqual(recorder.launchBundleIDs, ["us.zoom.xos"])
    XCTAssertEqual(recorder.reevaluationBundleIDs, ["us.zoom.xos"])

    workspace.postLaunch(bundleIdentifier: "us.zoom.xos")
    workspace.postTerminate(bundleIdentifier: "us.zoom.xos")
    timerScheduler.fireAll()

    XCTAssertEqual(recorder.launchBundleIDs, ["us.zoom.xos", "us.zoom.xos"])
    XCTAssertEqual(recorder.quitBundleIDs, ["us.zoom.xos"])
    XCTAssertEqual(recorder.reevaluationBundleIDs, ["us.zoom.xos", "us.zoom.xos"])

    watcher.stop()

    XCTAssertEqual(workspace.activeLaunchObserverCount, 0)
    XCTAssertEqual(workspace.activeTerminateObserverCount, 0)
    XCTAssertEqual(timerScheduler.activeTimerCount, 0)

    workspace.postLaunch(bundleIdentifier: "us.zoom.xos")
    workspace.postTerminate(bundleIdentifier: "us.zoom.xos")
    timerScheduler.fireAll()

    XCTAssertEqual(recorder.launchBundleIDs, ["us.zoom.xos", "us.zoom.xos"])
    XCTAssertEqual(recorder.quitBundleIDs, ["us.zoom.xos"])
    XCTAssertEqual(recorder.reevaluationBundleIDs, ["us.zoom.xos", "us.zoom.xos"])
  }

  func testMeetingAppsFromRunningBundleIDsIncludesNativeAppsAndBrowsers() {
    let apps = ProcessWatcher.meetingApps(from: [
      "com.apple.finder",
      "com.google.Chrome",
      "us.zoom.xos",
      "com.google.Chrome",
      "org.mozilla.firefox",
    ])

    XCTAssertEqual(
      apps.map(\.bundleID),
      [
        "com.google.Chrome",
        "us.zoom.xos",
        "org.mozilla.firefox",
      ], "running-app scans must re-evaluate supported browsers and native apps once each")
  }

  func testMeetingAppsFromRunningBundleIDsDoesNotIncludeHelpersOrUnsupportedApps() {
    let apps = ProcessWatcher.meetingApps(from: [
      "com.google.Chrome.helper.renderer",
      "com.apple.WebKit.Networking",
      "com.apple.FaceTime",
    ])

    XCTAssertEqual(
      apps.map(\.bundleID), ["com.apple.FaceTime"],
      "ProcessWatcher should scan top-level running apps while CoreAudioInputProbe handles helper process bundle matching"
    )
  }
}

private final class ProcessWatcherEventRecorder: @unchecked Sendable {
  private var launches: [MeetingApp] = []
  private var quits: [MeetingApp] = []
  private var reevaluations: [MeetingApp] = []

  var launchBundleIDs: [String] { launches.map(\.bundleID) }
  var quitBundleIDs: [String] { quits.map(\.bundleID) }
  var reevaluationBundleIDs: [String] { reevaluations.map(\.bundleID) }

  func recordLaunch(_ app: MeetingApp) {
    launches.append(app)
  }

  func recordQuit(_ app: MeetingApp) {
    quits.append(app)
  }

  func recordReevaluation(_ app: MeetingApp) {
    reevaluations.append(app)
  }
}

private final class FakeProcessWatcherObserverToken: ProcessWatcherObserverToken {
  enum Kind {
    case launch
    case terminate
  }

  let kind: Kind
  let id = UUID()
  let handler: @Sendable (String?) -> Void

  init(kind: Kind, handler: @escaping @Sendable (String?) -> Void) {
    self.kind = kind
    self.handler = handler
  }
}

private final class FakeProcessWatcherWorkspaceObserver: ProcessWatcherWorkspaceObserving {
  var runningApplications: [ProcessWatcherRunningApplication]
  private var launchObservers: [FakeProcessWatcherObserverToken] = []
  private var terminateObservers: [FakeProcessWatcherObserverToken] = []

  init(runningApplications: [ProcessWatcherRunningApplication]) {
    self.runningApplications = runningApplications
  }

  var activeLaunchObserverCount: Int { launchObservers.count }
  var activeTerminateObserverCount: Int { terminateObservers.count }

  func addLaunchObserver(_ handler: @escaping @Sendable (String?) -> Void)
    -> ProcessWatcherObserverToken
  {
    let token = FakeProcessWatcherObserverToken(kind: .launch, handler: handler)
    launchObservers.append(token)
    return token
  }

  func addTerminateObserver(_ handler: @escaping @Sendable (String?) -> Void)
    -> ProcessWatcherObserverToken
  {
    let token = FakeProcessWatcherObserverToken(kind: .terminate, handler: handler)
    terminateObservers.append(token)
    return token
  }

  func removeObserver(_ observer: ProcessWatcherObserverToken) {
    guard let token = observer as? FakeProcessWatcherObserverToken else { return }
    switch token.kind {
    case .launch:
      launchObservers.removeAll { $0.id == token.id }
    case .terminate:
      terminateObservers.removeAll { $0.id == token.id }
    }
  }

  func postLaunch(bundleIdentifier: String?) {
    for observer in launchObservers {
      observer.handler(bundleIdentifier)
    }
  }

  func postTerminate(bundleIdentifier: String?) {
    for observer in terminateObservers {
      observer.handler(bundleIdentifier)
    }
  }
}

private final class FakeProcessWatcherTimer: ProcessWatcherTimerToken {
  private(set) var isValid = true
  private let handler: @Sendable () -> Void

  init(handler: @escaping @Sendable () -> Void) {
    self.handler = handler
  }

  func invalidate() {
    isValid = false
  }

  func fire() {
    guard isValid else { return }
    handler()
  }
}

private final class FakeProcessWatcherTimerScheduler: ProcessWatcherTimerScheduling {
  private var timers: [FakeProcessWatcherTimer] = []

  var activeTimerCount: Int {
    timers.filter(\.isValid).count
  }

  func scheduleRepeating(interval: TimeInterval, _ handler: @escaping @Sendable () -> Void)
    -> ProcessWatcherTimerToken
  {
    let timer = FakeProcessWatcherTimer(handler: handler)
    timers.append(timer)
    return timer
  }

  func fireAll() {
    for timer in timers {
      timer.fire()
    }
  }
}
