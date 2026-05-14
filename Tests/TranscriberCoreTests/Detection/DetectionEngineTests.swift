import XCTest
@testable import TranscriberCore

final class DetectionEngineTests: XCTestCase {
    func testLaunchTriggersCallbackAfterDwellWithoutWallClockSleep() async throws {
        let captured = AppCapture()
        let engine = DetectionEngine(dwellTime: 30, sleep: immediateSleep) { app in
            await captured.set(app)
        }
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        await engine.handleLaunch(of: zoom)
        await Task.yield()
        let result = await captured.waitForBundleID("us.zoom.xos")
        XCTAssertEqual(result?.bundleID, "us.zoom.xos")
    }

    func testQuitBeforeDwellElapsesCancelsCallbackWithoutWallClockSleep() async throws {
        let captured = AppCapture()
        let engine = DetectionEngine(dwellTime: 30, sleep: cancellableNeverSleep) { app in
            await captured.set(app)
        }
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        await engine.handleLaunch(of: zoom)
        await Task.yield()
        await engine.handleQuit(of: zoom)
        await Task.yield()
        let result = await captured.value
        XCTAssertNil(result, "callback must not fire if app quit during dwell")
    }

    func testLaunchWhileSuppressedDoesNotFire() async throws {
        let captured = AppCapture()
        let skip = SkipState()
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        await skip.suppress(zoom.bundleID, for: 60)
        let engine = DetectionEngine(dwellTime: 30, skipState: skip, sleep: immediateSleep) { app in
            await captured.set(app)
        }
        await engine.handleLaunch(of: zoom)
        await Task.yield()
        let result = await captured.value
        XCTAssertNil(result, "suppressed apps must skip the dwell entirely")
    }

    func testSuppressDuringDwellCancelsCallbackWithoutWallClockSleep() async throws {
        let captured = AppCapture()
        let engine = DetectionEngine(dwellTime: 30, sleep: cancellableNeverSleep) { app in
            await captured.set(app)
        }
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        await engine.handleLaunch(of: zoom)
        await Task.yield()
        await engine.suppress(zoom)
        await Task.yield()
        let result = await captured.value
        XCTAssertNil(result, "suppress() during dwell must cancel the in-flight callback")
    }

    func testInactiveProbeSuppressesCandidate() async throws {
        let captured = AppCapture()
        let engine = DetectionEngine(
            dwellTime: 30,
            observationWindow: 0,
            probe: ConstantProbe(value: false),
            sleep: immediateSleep
        ) { app in
            await captured.set(app)
        }
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        await engine.handleLaunch(of: zoom)
        await Task.yield()
        let result = await captured.value
        XCTAssertNil(result, "probe returning false must suppress candidate fire (this is the Signal-without-call fix)")
    }

    func testActiveProbeFiresCandidate() async throws {
        let captured = AppCapture()
        let engine = DetectionEngine(
            dwellTime: 30,
            probe: ConstantProbe(value: true),
            sleep: immediateSleep
        ) { app in
            await captured.set(app)
        }
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        await engine.handleLaunch(of: zoom)
        await Task.yield()
        let result = await captured.waitForBundleID("us.zoom.xos")
        XCTAssertEqual(result?.bundleID, "us.zoom.xos", "probe returning true must allow candidate fire")
    }

    func testUnknownProbePassesThrough() async throws {
        let captured = AppCapture()
        let engine = DetectionEngine(
            dwellTime: 30,
            probe: ConstantProbe(value: nil),
            sleep: immediateSleep
        ) { app in
            await captured.set(app)
        }
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        await engine.handleLaunch(of: zoom)
        await Task.yield()
        let result = await captured.waitForBundleID("us.zoom.xos")
        XCTAssertEqual(result?.bundleID, "us.zoom.xos", "probe returning nil must pass through")
    }

    func testIdleBrowserDoesNotEmitCandidate() async throws {
        let captured = FireCounter()
        let chrome = MeetingApp(bundleID: "com.google.Chrome", displayName: "Chrome", kind: .browser)
        let engine = DetectionEngine(dwellTime: 30, retryInterval: 5, observationWindow: 0, probe: ConstantProbe(value: false), sleep: immediateSleep) { _ in
            await captured.increment()
        }

        await engine.reevaluate(chrome)
        await Task.yield()

        let count = await captured.value
        XCTAssertEqual(count, 0, "idle supported browsers must not produce candidates")
    }

    func testIdleNativeAppDoesNotEmitCandidate() async throws {
        let captured = FireCounter()
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        let engine = DetectionEngine(dwellTime: 30, retryInterval: 5, observationWindow: 0, probe: ConstantProbe(value: false), sleep: immediateSleep) { _ in
            await captured.increment()
        }

        await engine.reevaluate(zoom)
        await Task.yield()

        let count = await captured.value
        XCTAssertEqual(count, 0, "idle native apps must not produce candidates")
    }

    func testTransientFalseProbeRetriesAndLaterFiresWithoutWallClockSleep() async throws {
        let captured = AppCapture()
        let probe = SequenceProbe(values: [false, true])
        let clock = DateBox(Date(timeIntervalSince1970: 1_700_000_000))
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        let engine = DetectionEngine(dwellTime: 30, retryInterval: 5, observationWindow: 120, probe: probe, now: clock.now, sleep: { seconds in
            clock.advance(by: seconds)
            await Task.yield()
        }) { app in
            await captured.set(app)
        }

        await engine.reevaluate(zoom)
        await Task.yield()
        await Task.yield()

        let result = await captured.waitForBundleID(zoom.bundleID)
        XCTAssertEqual(result?.bundleID, zoom.bundleID, "early false observations must not permanently suppress later active calls")
    }

    func testRepeatedObservationsCoalesceIntoOneCandidate() async throws {
        let captured = FireCounter()
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        let engine = DetectionEngine(dwellTime: 30, retryInterval: 5, observationWindow: 120, probe: ConstantProbe(value: true), sleep: immediateSleep) { _ in
            await captured.increment()
        }

        await engine.reevaluate(zoom)
        await engine.reevaluate(zoom)
        await engine.handleLaunch(of: zoom)
        await Task.yield()
        await engine.reevaluate(zoom)
        await Task.yield()

        let count = await captured.waitForValue(1)
        XCTAssertEqual(count, 1, "repeated observations for one active call must coalesce")
    }

    func testStaleCandidateClearsAfterCallEnds() async throws {
        let captured = FireCounter()
        let probe = SequenceProbe(values: [true, false, true])
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        let engine = DetectionEngine(dwellTime: 30, retryInterval: 5, observationWindow: 120, probe: probe, sleep: immediateSleep) { _ in
            await captured.increment()
        }

        await engine.reevaluate(zoom)
        _ = await captured.waitForValue(1)
        await engine.reevaluate(zoom)
        await Task.yield()
        await engine.reevaluate(zoom)
        await Task.yield()

        let count = await captured.waitForValue(2)
        XCTAssertEqual(count, 2, "ended calls must clear stale candidate state")
    }

    func testEndedActiveCandidateNotifiesShellForStalePromptInvalidation() async throws {
        let fired = FireCounter()
        let ended = AppCapture()
        let probe = SequenceProbe(values: [true, false])
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        let engine = DetectionEngine(
            dwellTime: 30,
            retryInterval: 5,
            observationWindow: 120,
            probe: probe,
            sleep: immediateSleep,
            onCandidateEnded: { app in
                await ended.set(app)
            }
        ) { _ in
            await fired.increment()
        }

        await engine.reevaluate(zoom)
        let fireCount = await fired.waitForValue(1)
        await engine.reevaluate(zoom)

        let endedApp = await ended.waitForBundleID(zoom.bundleID)
        XCTAssertEqual(fireCount, 1, "the first active observation should fire one prompt candidate")
        XCTAssertEqual(endedApp?.bundleID, zoom.bundleID, "a later inactive observation for the same coalesced candidate should notify the app shell to invalidate stale prompt state")
    }

    func testRedundantLaunchEventsDebounceWithoutWallClockSleep() async throws {
        let captured = FireCounter()
        let engine = DetectionEngine(dwellTime: 30, sleep: immediateSleep) { _ in
            await captured.increment()
        }
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        await engine.handleLaunch(of: zoom)
        await engine.handleLaunch(of: zoom)
        await engine.handleLaunch(of: zoom)
        await Task.yield()
        let count = await captured.waitForValue(1)
        XCTAssertEqual(count, 1, "redundant launches must debounce; got \(count) callbacks")
    }

    func testCompetingIdleSupportedSurfacesDoNotBlockActiveSurface() async throws {
        let captured = AppCapture()
        let probe = BundleScriptProbe(valuesByBundleID: [
            "com.google.Chrome": [false],
            "com.apple.Safari": [false],
            "us.zoom.xos": [true],
        ])
        let chrome = MeetingApp(bundleID: "com.google.Chrome", displayName: "Chrome", kind: .browser)
        let safari = MeetingApp(bundleID: "com.apple.Safari", displayName: "Safari", kind: .browser)
        let zoom = MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .nativeMeetingApp)
        let engine = DetectionEngine(dwellTime: 30, retryInterval: 5, observationWindow: 0, probe: probe, sleep: immediateSleep) { app in
            await captured.set(app)
        }

        await engine.reevaluate(chrome)
        await engine.reevaluate(safari)
        await engine.reevaluate(zoom)
        await Task.yield()

        let result = await captured.waitForBundleID(zoom.bundleID)
        XCTAssertEqual(result?.bundleID, zoom.bundleID, "idle supported surfaces must neither create extra candidates nor block the active meeting surface")
    }
}

actor AppCapture {
    private(set) var value: MeetingApp?
    func set(_ app: MeetingApp) { value = app }

    func waitForBundleID(_ bundleID: String, maxYields: Int = 1_000) async -> MeetingApp? {
        for _ in 0..<maxYields {
            if value?.bundleID == bundleID { return value }
            await Task.yield()
        }
        return value
    }
}

actor FireCounter {
    private(set) var value = 0
    func increment() { value += 1 }

    func waitForValue(_ expected: Int, maxYields: Int = 1_000) async -> Int {
        for _ in 0..<maxYields {
            if value == expected { return value }
            await Task.yield()
        }
        return value
    }
}

struct ConstantProbe: AudioActivityProbe {
    let value: Bool?
    func isActive(bundleID: String) async -> Bool? { value }
}


actor SequenceProbe: AudioActivityProbe {
    private var values: [Bool?]

    init(values: [Bool?]) {
        self.values = values
    }

    func isActive(bundleID: String) async -> Bool? {
        if values.isEmpty { return false }
        return values.removeFirst()
    }
}

private func immediateSleep(_ seconds: TimeInterval) async {
    await Task.yield()
}

private func cancellableNeverSleep(_ seconds: TimeInterval) async {
    while !Task.isCancelled {
        await Task.yield()
    }
}

final class DateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

actor BundleScriptProbe: AudioActivityProbe {
    private var valuesByBundleID: [String: [Bool?]]

    init(valuesByBundleID: [String: [Bool?]]) {
        self.valuesByBundleID = valuesByBundleID
    }

    func isActive(bundleID: String) async -> Bool? {
        var values = valuesByBundleID[bundleID] ?? [false]
        let next = values.isEmpty ? false : values.removeFirst()
        valuesByBundleID[bundleID] = values
        return next
    }
}
