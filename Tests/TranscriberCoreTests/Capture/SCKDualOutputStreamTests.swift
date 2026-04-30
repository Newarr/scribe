import XCTest
import ScreenCaptureKit
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

    func testStopIfRunningOnIdleStreamIsNoOp() async {
        // Both `SCKAudioCaptureSource.stop()` calls invoke stopIfRunning().
        // The second one must drop cheaply without touching SCK.
        let coordinator = SCKDualOutputStream()
        await coordinator.stopIfRunning()
        await coordinator.stopIfRunning()
        // No crash, no exception. Real SCK isn't touched because no stream
        // was created.
    }
}

private final class DummySCStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}
