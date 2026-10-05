import AppKit
import CoreMedia
@testable import ScribeAppLogic
@testable import TranscriberCore
import XCTest

@MainActor
final class AppLifecycleTests: XCTestCase {
  func testOldTranscriptionCannotChangeActiveCaptureOrAllowAnotherStart() {
    for outcome: TranscriptionWorker.FinalState in [.complete, .failed(reason: "offline"), .cancelled] {
      let app = AppDelegate()
      let oldDirectory = URL(fileURLWithPath: "/old-recording")
      app.beginTranscription(at: oldDirectory, engineMode: .local, sourceLabel: "Old call")
      app.capturePhase = .recording

      app.finishTranscription(outcome, at: oldDirectory)

      XCTAssertEqual(app.status, .recording)
      XCTAssertFalse(app.canStartRecording)
      XCTAssertNil(app.lastFailureAt)
      XCTAssertNil(app.lastSavedAt)
    }
  }

  func testOldTranscriptionCannotReplaceNewerJobOutcome() {
    let app = AppDelegate()
    let oldDirectory = URL(fileURLWithPath: "/old-recording")
    let newDirectory = URL(fileURLWithPath: "/new-recording")
    app.beginTranscription(at: oldDirectory, engineMode: .cloud, sourceLabel: "Old call")
    app.beginTranscription(at: newDirectory, engineMode: .local, sourceLabel: "New call")

    app.finishTranscription(.failed(reason: "offline"), at: oldDirectory)

    XCTAssertEqual(app.status, .finalized)
    XCTAssertEqual(app.foregroundTranscription?.directory, newDirectory)
    XCTAssertEqual(app.foregroundTranscription?.engineMode, .local)
    XCTAssertNil(app.lastFailureAt)
  }

  func testCaptureReservesStartDuringPreflightAndStop() {
    let app = AppDelegate()
    for phase: AppDelegate.CapturePhase in [.starting, .recording, .stopping] {
      app.capturePhase = phase
      XCTAssertFalse(app.canStartRecording)
    }
    app.capturePhase = .idle
    XCTAssertTrue(app.canStartRecording)
  }

  func testStopCompletionReservesCaptureUntilItsTaskClears() async {
    let app = AppDelegate()
    app.capturePhase = .idle
    let task = Task<Void, Never> {}
    app.captureStopTask = task
    await task.value
    XCTAssertFalse(app.canStartRecording)
    app.captureStopTask = nil
    XCTAssertTrue(app.canStartRecording)
  }

  func testStaleStartupFailureCannotReleaseReplacementCapture() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let oldDirectory = try SessionDirectory.create(under: root, id: SessionID(from: Date()))
    let newDirectory = try SessionDirectory.create(under: root, id: SessionID(from: Date()))
    let source = FailingStopSource()
    let oldCapture = try CaptureSession(
      directory: oldDirectory, mic: source, system: source, sampleRate: 48_000, channelCount: 1)
    let newCapture = try CaptureSession(
      directory: newDirectory, mic: source, system: source, sampleRate: 48_000, channelCount: 1)
    let app = AppDelegate()
    app.session = newCapture
    app.currentSessionDirectory = newDirectory
    app.capturePhase = .recording

    await app.handleStartFailure(FailingStopSource.StopFailure(), session: oldCapture)

    XCTAssertTrue(app.session === newCapture)
    XCTAssertEqual(app.currentSessionDirectory, newDirectory)
    XCTAssertEqual(app.status, .recording)
    XCTAssertNil(SessionClaim.acquire(at: newDirectory.claim))
  }

  func testQuittingRejectsLateSupervisorRecovery() async {
    let app = AppDelegate()
    let blocked = TestSignal()
    let completed = expectation(description: "quit completed")
    let task = Task { await blocked.wait() }
    app.inflightTasks[UUID()] = task
    let reply = app.requestTermination(confirm: { true }) { completed.fulfill() }
    XCTAssertEqual(reply, .terminateLater)
    let count = app.inflightTasks.count

    app.scheduleSupervisorRecovery()

    XCTAssertEqual(app.inflightTasks.count, count)
    XCTAssertFalse(app.canStartRecording)
    await blocked.signal()
    await fulfillment(of: [completed], timeout: 2)
  }

  func testCancelledQuitLeavesCaptureAvailableToStop() {
    let app = AppDelegate()
    app.capturePhase = .recording

    let reply = app.requestTermination(confirm: { false }) {
      XCTFail("Cancelled quit must not reply with termination")
    }

    XCTAssertEqual(reply, .terminateCancel)
    XCTAssertEqual(app.status, .recording)
    XCTAssertFalse(app.termination.hasStarted)
  }

  func testRetrySuccessRestoresIdleMenuAndKeepsItsEngineUntilCompletion() {
    let app = AppDelegate()
    app.menu = RecordingMenu(onAction: { _ in })
    let directory = URL(fileURLWithPath: "/failed-call")
    app.beginTranscription(at: directory, engineMode: .local, sourceLabel: "Call")
    app.menu?.elapsedSeconds = 80
    XCTAssertEqual(app.menu?.sessionEngineMode, .local)
    XCTAssertEqual(app.menu?.outcomeFolderURL, directory)
    XCTAssertEqual(app.status, .finalized)

    app.finishTranscription(.complete, at: directory)

    XCTAssertEqual(app.status, .idle)
    XCTAssertNil(app.menu?.outcomeFolderURL)
    XCTAssertNil(app.menu?.outcomeFolderName)
    XCTAssertEqual(app.menu?.elapsedSeconds, 0)
    app.savedFlashTimer?.invalidate()
  }

  func testDetectionQueuesThroughoutCaptureLifecycle() async {
    let app = AppDelegate()
    app.menu = RecordingMenu(onAction: { _ in })
    let candidate = DetectionCandidate(app: MeetingApps.allowlist[0], triggerIdentity: "next-call")
    for phase: AppDelegate.CapturePhase in [.starting, .recording, .stopping] {
      app.capturePhase = phase
      await app.handleDetectionCandidate(candidate)
      XCTAssertEqual(app.menu?.queuedNextMeeting?.title, candidate.app.displayName)
      app.clearQueuedDetectionCandidate()
    }
  }

  func testPromptCalendarContextSurvivesSetupDenial() {
    let app = AppDelegate()
    let date = Date(timeIntervalSince1970: 1_000)
    let event = CalendarEvent(title: "Meeting", startDate: date, endDate: date.addingTimeInterval(1_800),
      attendees: [], eventIdentifier: "calendar-event", occurrenceStartDate: date)
    let candidate = DetectionCandidate(app: MeetingApps.allowlist[0], triggerIdentity: "calendar-call")
    app.retainPromptForSetup(candidate: candidate, event: event)
    _ = app.handleStartPreflightResult(.init(blockers: [.missingCloudAPIKey], warnings: []))

    XCTAssertEqual(app.pendingPromptCalendarEventForStart?.calendarEventID, event.calendarEventID)
    let context = AppDelegate.makeContext(dir: .init(url: URL(fileURLWithPath: "/recording")),
      startedAt: date, endedAt: date.addingTimeInterval(600), event: app.pendingPromptCalendarEventForStart,
      engineMode: .local)
    XCTAssertEqual(context.calendarEventID, event.calendarEventID)
    XCTAssertEqual(context.title, "Meeting")
    XCTAssertEqual(context.engine, "cohere")
  }

  func testSetupDenialPreservesCandidateForRecoveryAndEndedCallClearsIt() async {
    let app = AppDelegate()
    app.startPromptCoordinator = StartPromptCoordinator(
      notifications: SuspendedNotifications(), runModal: { _, _, _ in .dismissed })
    let candidate = DetectionCandidate(app: MeetingApps.allowlist[0], triggerIdentity: "call-1")
    app.retainPromptForSetup(candidate: candidate, event: nil)
    app.capturePhase = .starting

    let allowed = app.handleStartPreflightResult(.init(blockers: [.missingCloudAPIKey], warnings: []))

    XCTAssertFalse(allowed)
    XCTAssertTrue(app.setupNeedsAttention)
    XCTAssertTrue(app.detectionPromptActive)
    XCTAssertEqual(app.pendingPromptCandidateForStart?.triggerIdentity, "call-1")
    XCTAssertEqual(app.pendingPromptTriggerIdentity, "call-1")

    await app.handleEndedDetectionCandidate(candidate)

    XCTAssertFalse(app.detectionPromptActive)
    XCTAssertNil(app.pendingPromptCandidateForStart)
    XCTAssertNil(app.pendingPromptTriggerIdentity)
  }

  func testFailedStreamStopKeepsCaptureOwnedAndRetryable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try SessionDirectory.create(under: root, id: SessionID(from: Date()))
    let source = FailingStopSource()
    let capture = try CaptureSession(
      directory: directory, mic: source, system: source, sampleRate: 48_000, channelCount: 1)
    try await capture.start()
    let app = AppDelegate()
    app.session = capture
    app.currentSessionDirectory = directory
    app.capturePhase = .recording

    await app.stopRecording()

    XCTAssertTrue(app.session === capture)
    XCTAssertEqual(app.status, .recording)
    XCTAssertFalse(app.canStartRecording)
    XCTAssertNil(SessionClaim.acquire(at: directory.claim))

    await source.allowStop()
    await app.stopRecording()
    XCTAssertNil(app.session)
  }
}

private actor FailingStopSource: AudioCaptureSource {
  private var stopAllowed = false
  nonisolated func setHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {}
  func start() async throws {}
  func stop() async throws {
    if !stopAllowed { throw StopFailure() }
  }
  func allowStop() { stopAllowed = true }
  struct StopFailure: Error {}
}

@MainActor
final class TerminationCoordinatorTests: XCTestCase {
  func testDeadlineCompletesQuitWithoutWaitingForUncooperativeDrain() async {
    let coordinator = TerminationCoordinator()
    let blockedDrain = TestSignal()
    let deadline = TestSignal()
    let drainStarted = expectation(description: "drain started")
    let drained = expectation(description: "drain returned")
    let completed = expectation(description: "quit completed")
    var completions = 0
    coordinator.start(
      drain: {
        drainStarted.fulfill()
        await blockedDrain.wait()
        drained.fulfill()
      },
      waitForDeadline: { await deadline.wait() },
      completion: {
        completions += 1
        completed.fulfill()
      })
    await fulfillment(of: [drainStarted], timeout: 2)
    await deadline.signal()
    await fulfillment(of: [completed], timeout: 2)
    XCTAssertEqual(completions, 1)
    await blockedDrain.signal()
    await fulfillment(of: [drained], timeout: 2)
    XCTAssertEqual(completions, 1)
  }

  func testSuccessfulDrainCompletesQuitBeforeDeadlineOnlyOnce() async {
    let coordinator = TerminationCoordinator()
    let deadline = TestSignal()
    let completed = expectation(description: "quit completed")
    var completions = 0
    coordinator.start(
      drain: {},
      waitForDeadline: { await deadline.wait() },
      completion: {
        completions += 1
        completed.fulfill()
      })
    await fulfillment(of: [completed], timeout: 2)
    await deadline.signal()
    coordinator.start(drain: {}, completion: { completions += 1 })
    await Task.yield()
    XCTAssertEqual(completions, 1)
  }
}

private actor TestSignal {
  private var signalled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if signalled { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func signal() {
    signalled = true
    let pending = waiters
    waiters.removeAll()
    pending.forEach { $0.resume() }
  }
}
