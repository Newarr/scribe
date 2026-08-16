import XCTest

@testable import TranscriberCore

final class AutoRecordPolicyTests: XCTestCase {
    private func evidence(
        kind: MeetingApp.Kind,
        probe: Bool? = nil,
        tabMatch: Bool? = nil,
        calendar: Bool = false,
        micSeconds: TimeInterval = 0
    ) -> AutoRecordPolicy.Evidence {
        AutoRecordPolicy.Evidence(
            kind: kind,
            probeIsActive: probe,
            browserTabMatchesMeeting: tabMatch,
            calendarOverlapsNow: calendar,
            sustainedMicSeconds: micSeconds
        )
    }

    // MARK: - shouldRecord, native apps

    func testNativeAppPassesOnActiveProbe() {
        XCTAssertTrue(AutoRecordPolicy.shouldRecord(evidence(kind: .nativeMeetingApp, probe: true)))
    }

    func testNativeAppPassesOnIndeterminateProbe() {
        // Matches the engine's existing fire-on-nil behavior for native apps.
        XCTAssertTrue(AutoRecordPolicy.shouldRecord(evidence(kind: .nativeMeetingApp, probe: nil)))
    }

    func testNativeAppFailsOnInactiveProbe() {
        XCTAssertFalse(AutoRecordPolicy.shouldRecord(evidence(kind: .nativeMeetingApp, probe: false)))
    }

    // MARK: - shouldRecord, browsers

    func testBrowserPassesOnTabMatchAlone() {
        // A meeting-domain tab is the strongest signal and records alone.
        XCTAssertTrue(
            AutoRecordPolicy.shouldRecord(evidence(kind: .browser, probe: nil, tabMatch: true)))
    }

    func testBrowserFailsOnInspectedNonMeetingTab() {
        // YouTube tab, probe indeterminate: nil probe must not record a browser.
        XCTAssertFalse(
            AutoRecordPolicy.shouldRecord(evidence(kind: .browser, probe: nil, tabMatch: false)))
    }

    func testBrowserFallbackPassesOnCalendarPlusSustainedMic() {
        XCTAssertTrue(
            AutoRecordPolicy.shouldRecord(
                evidence(kind: .browser, probe: true, tabMatch: nil, calendar: true, micSeconds: 30)))
    }

    func testBrowserFallbackFailsWithoutCalendarOverlap() {
        XCTAssertFalse(
            AutoRecordPolicy.shouldRecord(
                evidence(kind: .browser, probe: true, tabMatch: nil, calendar: false, micSeconds: 300)))
    }

    func testBrowserFallbackFailsUnderMicRequirement() {
        // Short mic bursts are dictation, not calls.
        XCTAssertFalse(
            AutoRecordPolicy.shouldRecord(
                evidence(kind: .browser, probe: true, tabMatch: nil, calendar: true, micSeconds: 25)))
    }

    func testBrowserFallbackHonorsCustomMicRequirement() {
        let e = evidence(kind: .browser, tabMatch: nil, calendar: true, micSeconds: 10)
        XCTAssertTrue(AutoRecordPolicy.shouldRecord(e, sustainedMicRequirementSeconds: 10))
        XCTAssertFalse(AutoRecordPolicy.shouldRecord(e, sustainedMicRequirementSeconds: 11))
    }

    func testBrowserUninspectableWithNoCalendarNeverRecords() {
        // Firefox with no calendar overlap: both gates closed.
        XCTAssertFalse(
            AutoRecordPolicy.shouldRecord(
                evidence(kind: .browser, probe: true, tabMatch: nil, calendar: false, micSeconds: 60)))
    }

    // MARK: - shouldAutoDiscard

    func testDetectedEndGuardStopUnderThresholdDiscards() {
        XCTAssertTrue(
            AutoRecordPolicy.shouldAutoDiscard(
                durationSeconds: 60, origin: .detected, initiator: .endGuard, thresholdSeconds: 120))
    }

    func testDetectedEndGuardStopOverThresholdKeeps() {
        XCTAssertFalse(
            AutoRecordPolicy.shouldAutoDiscard(
                durationSeconds: 120, origin: .detected, initiator: .endGuard, thresholdSeconds: 120))
    }

    func testUserStopNeverDiscards() {
        // An explicit stop is a decision, by the same argument that
        // exempts manual recordings.
        XCTAssertFalse(
            AutoRecordPolicy.shouldAutoDiscard(
                durationSeconds: 5, origin: .detected, initiator: .user, thresholdSeconds: 120))
    }

    func testManualOriginNeverDiscards() {
        XCTAssertFalse(
            AutoRecordPolicy.shouldAutoDiscard(
                durationSeconds: 5, origin: .manual, initiator: .endGuard, thresholdSeconds: 120))
    }
}
