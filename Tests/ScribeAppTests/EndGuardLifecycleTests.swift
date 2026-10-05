import CoreMedia
@testable import ScribeAppLogic
import TranscriberCore
import XCTest

@MainActor
final class EndGuardLifecycleTests: XCTestCase {
  func testPreviousRecordingGuardCannotStopReplacementCapture() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = AppDelegate()
    let oldCapture = try makeCapture(under: root, app: app)
    app.session = oldCapture
    app.capturePhase = .recording
    let startedAt = Date(timeIntervalSince1970: 1_000)
    await app.startEndGuard(startedAt: startedAt)
    app.endGuardTickTimer?.invalidate()
    let previousGuard = try XCTUnwrap(app.endGuard)
    let replacement = try makeCapture(under: root, app: app)
    app.session = replacement
    await app.startEndGuard(startedAt: startedAt)
    app.endGuardTickTimer?.invalidate()
    let replacementGuard = app.endGuard

    await previousGuard.tick(now: startedAt.addingTimeInterval(4 * 60 * 60))

    XCTAssertTrue(app.session === replacement)
    XCTAssertTrue(app.endGuard === replacementGuard)
    XCTAssertEqual(app.capturePhase, .recording)
    XCTAssertNil(app.captureStopTask)
    await app.tearDownEndGuard()
  }

  func testPreviousGuardCannotPresentUpdateOrCancelReplacementPrompt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = AppDelegate()
    app.menu = RecordingMenu(onAction: { _ in })
    app.startPromptCoordinator = StartPromptCoordinator(
      notifications: SuspendedNotifications(), runModal: { _, _, _ in .dismissed })
    let oldCapture = try makeCapture(under: root, app: app)
    app.session = oldCapture
    app.capturePhase = .recording
    let startedAt = Date(timeIntervalSince1970: 1_000)
    await app.startEndGuard(startedAt: startedAt)
    app.endGuardTickTimer?.invalidate()
    let previousGuard = try XCTUnwrap(app.endGuard)
    app.session = try makeCapture(under: root, app: app)
    await app.startEndGuard(startedAt: startedAt)
    app.endGuardTickTimer?.invalidate()
    app.activeEndPromptID = "replacement-prompt"
    app.activeEndPromptGeneration = 8
    app.menu?.endPrompt = .init(generation: 8, reason: "call ended", secondsRemaining: 7)

    await previousGuard.observeAudioLevel(stream: .mic, rms: 0, at: startedAt)
    await previousGuard.observeAudioLevel(stream: .system, rms: 0, at: startedAt)
    await previousGuard.tick(now: startedAt.addingTimeInterval(31))
    XCTAssertEqual(app.activeEndPromptID, "replacement-prompt")
    XCTAssertEqual(app.activeEndPromptGeneration, 8)
    await previousGuard.tick(now: startedAt.addingTimeInterval(32))
    XCTAssertEqual(app.menu?.endPrompt?.secondsRemaining, 7)
    await previousGuard.observeAudioLevel(stream: .mic, rms: 1, at: startedAt.addingTimeInterval(33))
    XCTAssertEqual(app.activeEndPromptID, "replacement-prompt")
    XCTAssertEqual(app.activeEndPromptGeneration, 8)
    XCTAssertEqual(app.menu?.endPrompt?.secondsRemaining, 7)
    await app.tearDownEndGuard()
  }

  private func makeCapture(under root: URL, app: AppDelegate) throws -> CaptureSession {
    let directory = try SessionDirectory.create(under: root, id: SessionID(from: Date()))
    app.currentSessionDirectory = directory
    return try CaptureSession(
      directory: directory, mic: InactiveCaptureSource(), system: InactiveCaptureSource(),
      sampleRate: 48_000, channelCount: 1)
  }
}

private final class InactiveCaptureSource: AudioCaptureSource {
  func setHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {}
  func start() async throws {}
  func stop() async throws {}
}
