import XCTest
@testable import TranscriberCore

final class DetectionEngineTests: XCTestCase {
    func testLaunchTriggersCallbackAfterDwell() async throws {
        let captured = AppCapture()
        let engine = DetectionEngine(dwellTime: 0.05) { app in
            await captured.set(app)
        }
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        await engine.handleLaunch(of: zoom)
        try await Task.sleep(nanoseconds: 200_000_000)
        let result = await captured.value
        XCTAssertEqual(result?.bundleID, "us.zoom.xos")
    }

    func testQuitBeforeDwellElapsesCancelsCallback() async throws {
        let captured = AppCapture()
        let engine = DetectionEngine(dwellTime: 0.5) { app in
            await captured.set(app)
        }
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        await engine.handleLaunch(of: zoom)
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.handleQuit(of: zoom)
        try await Task.sleep(nanoseconds: 600_000_000)
        let result = await captured.value
        XCTAssertNil(result, "callback must not fire if app quit during dwell")
    }

    func testLaunchWhileSuppressedDoesNotFire() async throws {
        let captured = AppCapture()
        let skip = SkipState()
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        await skip.suppress(zoom.bundleID, for: 60)
        let engine = DetectionEngine(dwellTime: 0.05, skipState: skip) { app in
            await captured.set(app)
        }
        await engine.handleLaunch(of: zoom)
        try await Task.sleep(nanoseconds: 200_000_000)
        let result = await captured.value
        XCTAssertNil(result, "suppressed apps must skip the dwell entirely")
    }

    func testSuppressDuringDwellCancelsCallback() async throws {
        let captured = AppCapture()
        let engine = DetectionEngine(dwellTime: 0.5) { app in
            await captured.set(app)
        }
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        await engine.handleLaunch(of: zoom)
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.suppress(zoom)
        try await Task.sleep(nanoseconds: 600_000_000)
        let result = await captured.value
        XCTAssertNil(result, "suppress() during dwell must cancel the in-flight callback")
    }

    func testRedundantLaunchEventsDebounce() async throws {
        let captured = FireCounter()
        // Bump dwellTime + final wait to absorb CI's scheduling jitter — local
        // runs at 0.1s/250ms passed locally but raced GitHub Actions' actor
        // dispatch where the third dwell timer hadn't fired by the assertion.
        // Final wait is now ~10x the dwell which has plenty of headroom.
        let engine = DetectionEngine(dwellTime: 0.2) { _ in
            await captured.increment()
        }
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        await engine.handleLaunch(of: zoom)
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.handleLaunch(of: zoom)
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.handleLaunch(of: zoom)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let count = await captured.value
        XCTAssertEqual(count, 1, "redundant launches must debounce; got \(count) callbacks")
    }
}

actor AppCapture {
    private(set) var value: MeetingApp?
    func set(_ app: MeetingApp) { value = app }
}

actor FireCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
