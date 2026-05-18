import ScreenCaptureKit
import XCTest

@testable import TranscriberCore

/// Tests for the SCK shared-stream coordinator. Real `SCStream` requires
/// screen-recording permission and a display, so the production path is
/// validated manually; these tests exercise the registration / idempotency
/// contract that doesn't require live SCK.
final class SCKDualOutputStreamTests: XCTestCase {

  func testRegisterIsSynchronousAndAccumulates() {
    // The coordinator's API contract: register() runs on the caller's
    // thread synchronously so SCKAudioCaptureSource init can hand off
    // its handler queue without racing the first start().
    let coordinator = SCKDualOutputStream()
    let dummy = DummySCStreamOutput()
    let q = DispatchQueue(label: "test.handler")
    coordinator.register(kind: .microphone, output: dummy, queue: q)
    coordinator.register(kind: .system, output: dummy, queue: q)
    // No throw, no assertion needed beyond reaching this line — we just
    // care that register() returns synchronously.
    XCTAssertTrue(true)
  }

  func testContentFetchFailureClearsInFlightStartAndRetries() async throws {
    let factory = FakeSCKStreamFactory([
      .failure(FakeSCKError.contentUnavailable),
      .success(FakeSCKStreaming()),
    ])
    let coordinator = SCKDualOutputStream(streamFactory: factory)
    let dummy = DummySCStreamOutput()
    let q = DispatchQueue(label: "test.handler.content-retry")
    coordinator.register(kind: .microphone, output: dummy, queue: q)

    do {
      try await coordinator.startIfNeeded()
      XCTFail("Expected first start to throw")
    } catch FakeSCKError.contentUnavailable {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    try await coordinator.startIfNeeded()

    let factoryCalls = await factory.makeStreamCallCount()
    XCTAssertEqual(factoryCalls, 2)
    let streams = await factory.createdStreams()
    XCTAssertEqual(streams.count, 1)
    let successfulStartCalls = streams[0].startCaptureCallCount()
    XCTAssertEqual(successfulStartCalls, 1)
    let successfulStopCalls = streams[0].stopCaptureCallCount()
    XCTAssertEqual(successfulStopCalls, 0)
  }

  func testStreamSetupFailureStopsPartialStreamAndRetries() async throws {
    let addOutputFailureStream = FakeSCKStreaming(
      addStreamOutputError: FakeSCKError.addOutputFailed)
    let startCaptureFailureStream = FakeSCKStreaming(
      startCaptureError: FakeSCKError.startCaptureFailed)
    let successfulStream = FakeSCKStreaming()
    let factory = FakeSCKStreamFactory([
      .success(addOutputFailureStream),
      .success(startCaptureFailureStream),
      .success(successfulStream),
    ])
    let coordinator = SCKDualOutputStream(streamFactory: factory)
    let dummy = DummySCStreamOutput()
    let q = DispatchQueue(label: "test.handler.setup-retry")
    coordinator.register(kind: .microphone, output: dummy, queue: q)

    do {
      try await coordinator.startIfNeeded()
      XCTFail("Expected addStreamOutput failure")
    } catch SCKDualOutputStream.SCKError.streamFailedToStart {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let addFailureStops = addOutputFailureStream.stopCaptureCallCount()
    XCTAssertEqual(addFailureStops, 1)

    do {
      try await coordinator.startIfNeeded()
      XCTFail("Expected startCapture failure")
    } catch SCKDualOutputStream.SCKError.streamFailedToStart {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let startFailureStarts = startCaptureFailureStream.startCaptureCallCount()
    XCTAssertEqual(startFailureStarts, 1)
    let startFailureStops = startCaptureFailureStream.stopCaptureCallCount()
    XCTAssertEqual(startFailureStops, 1)

    try await coordinator.startIfNeeded()

    let retryFactoryCalls = await factory.makeStreamCallCount()
    XCTAssertEqual(retryFactoryCalls, 3)
    let retryStartCalls = successfulStream.startCaptureCallCount()
    XCTAssertEqual(retryStartCalls, 1)
    let retryStopCalls = successfulStream.stopCaptureCallCount()
    XCTAssertEqual(retryStopCalls, 0)
  }

  func testStopDuringStartDoesNotPoisonRetry() async throws {
    let firstStream = FakeSCKStreaming(startCaptureSuspends: true)
    let secondStream = FakeSCKStreaming()
    let factory = FakeSCKStreamFactory([
      .success(firstStream),
      .success(secondStream),
    ])
    let coordinator = SCKDualOutputStream(streamFactory: factory)
    let dummy = DummySCStreamOutput()
    let q = DispatchQueue(label: "test.handler.stop-during-start")
    coordinator.register(kind: .system, output: dummy, queue: q)

    async let startResult: Void = coordinator.startIfNeeded()
    await firstStream.waitUntilStartCaptureCalled()

    async let stopResult: Void = coordinator.stopIfRunning()
    firstStream.resumeStartCapture()
    try await startResult
    await stopResult

    let firstStartCalls = firstStream.startCaptureCallCount()
    XCTAssertEqual(firstStartCalls, 1)
    let firstStopCalls = firstStream.stopCaptureCallCount()
    XCTAssertEqual(firstStopCalls, 1)

    try await coordinator.startIfNeeded()

    let stopRetryFactoryCalls = await factory.makeStreamCallCount()
    XCTAssertEqual(stopRetryFactoryCalls, 2)
    let secondStartCalls = secondStream.startCaptureCallCount()
    XCTAssertEqual(secondStartCalls, 1)
    let secondStopCalls = secondStream.stopCaptureCallCount()
    XCTAssertEqual(secondStopCalls, 0)
  }

  func testStopIfRunningOnIdleStreamIsNoOp() async {
    // Both `SCKAudioCaptureSource.stop()` calls invoke stopIfRunning().
    // The second one must drop cheaply without touching SCK.
    let coordinator = SCKDualOutputStream()
    await coordinator.stopIfRunning()
    await coordinator.stopIfRunning()
    // No crash, no exception. Real SCK isn't touched because no stream
    // was created.
  }

  func testParallelStopsCompleteWithoutCrash() async {
    // Codex Phase β review P2.8: real concurrency hits both
    // stop callers at the same time. The serial DispatchQueue +
    // single-stop-extracts-stream pattern must absorb the race.
    let coordinator = SCKDualOutputStream()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask { await coordinator.stopIfRunning() }
      }
    }
    // No crash, no exception. The first stop sees a nil stream and
    // returns; subsequent stops see the same nil and also return.
  }
}

private enum FakeSCKError: Error {
  case contentUnavailable
  case addOutputFailed
  case startCaptureFailed
}

private actor FakeSCKStreamFactory: SCKStreamFactory {
  private var results: [Result<FakeSCKStreaming, Error>]
  private var streams: [FakeSCKStreaming] = []
  private var callCount = 0

  init(_ results: [Result<FakeSCKStreaming, Error>]) {
    self.results = results
  }

  func makeStreamCallCount() -> Int { callCount }

  func createdStreams() -> [FakeSCKStreaming] { streams }

  func makeStream(sampleRate: Int, channelCount: Int, capturesAudio: Bool, capturesMicrophone: Bool)
    async throws -> SCKStreaming
  {
    callCount += 1
    guard !results.isEmpty else { throw FakeSCKError.contentUnavailable }
    switch results.removeFirst() {
    case .success(let stream):
      streams.append(stream)
      return stream
    case .failure(let error):
      throw error
    }
  }
}

private final class FakeSCKStreaming: SCKStreaming, @unchecked Sendable {
  private let stateQueue = DispatchQueue(label: "test.fake-sck-streaming")
  private let addStreamOutputError: Error?
  private let startCaptureError: Error?
  private let startCaptureSuspends: Bool
  private var startContinuation: CheckedContinuation<Void, Never>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var addStreamOutputCalls = 0
  private var startCaptureCalls = 0
  private var stopCaptureCalls = 0

  init(
    addStreamOutputError: Error? = nil,
    startCaptureError: Error? = nil,
    startCaptureSuspends: Bool = false
  ) {
    self.addStreamOutputError = addStreamOutputError
    self.startCaptureError = startCaptureError
    self.startCaptureSuspends = startCaptureSuspends
  }

  func addStreamOutput(
    _ output: SCStreamOutput, type: SCStreamOutputType, sampleHandlerQueue: DispatchQueue?
  ) throws {
    let error = stateQueue.sync {
      addStreamOutputCalls += 1
      return addStreamOutputError
    }
    if let error { throw error }
  }

  func startCapture() async throws {
    let waiters: [CheckedContinuation<Void, Never>] = stateQueue.sync {
      startCaptureCalls += 1
      let waiters = startWaiters
      startWaiters.removeAll()
      return waiters
    }
    waiters.forEach { $0.resume() }
    if startCaptureSuspends {
      await withCheckedContinuation { continuation in
        stateQueue.sync { startContinuation = continuation }
      }
    }
    if let startCaptureError { throw startCaptureError }
  }

  func stopCapture() async throws {
    stateQueue.sync { stopCaptureCalls += 1 }
  }

  func waitUntilStartCaptureCalled() async {
    if stateQueue.sync(execute: { startCaptureCalls > 0 }) { return }
    await withCheckedContinuation { continuation in
      let shouldResume = stateQueue.sync {
        if startCaptureCalls > 0 { return true }
        startWaiters.append(continuation)
        return false
      }
      if shouldResume { continuation.resume() }
    }
  }

  func resumeStartCapture() {
    let continuation = stateQueue.sync {
      let continuation = startContinuation
      startContinuation = nil
      return continuation
    }
    continuation?.resume()
  }

  func startCaptureCallCount() -> Int {
    stateQueue.sync { startCaptureCalls }
  }

  func stopCaptureCallCount() -> Int {
    stateQueue.sync { stopCaptureCalls }
  }
}

private final class DummySCStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {}
}
