import XCTest

@testable import TranscriberCore

final class AutoRecordPolicyTests: XCTestCase {
    private func evidence(
        kind: MeetingApp.Kind,
        probe: Bool? = nil,
        tab: TabInspectionResult? = nil,
        calendar: Bool = false,
        micSeconds: TimeInterval = 0
    ) -> AutoRecordPolicy.Evidence {
        AutoRecordPolicy.Evidence(
            kind: kind,
            probeIsActive: probe,
            browserTab: tab,
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
            AutoRecordPolicy.shouldRecord(evidence(kind: .browser, probe: nil, tab: .meeting)))
    }

    func testBrowserFailsOnInspectedNonMeetingTab() {
        // YouTube tab, probe indeterminate: nil probe must not record a browser.
        XCTAssertFalse(
            AutoRecordPolicy.shouldRecord(evidence(kind: .browser, probe: nil, tab: .notMeeting)))
    }

    func testInspectedNonMeetingTabNeverTakesTheFallback() {
        // The hole this pins: an inspected YouTube tab must not record
        // even with calendar overlap AND a full sustained-mic streak.
        // The fallback exists only for tabs that could not be read.
        XCTAssertFalse(
            AutoRecordPolicy.shouldRecord(
                evidence(kind: .browser, probe: true, tab: .notMeeting, calendar: true, micSeconds: 300)))
    }

    func testBrowserFallbackPassesOnCalendarPlusSustainedMic() {
        XCTAssertTrue(
            AutoRecordPolicy.shouldRecord(
                evidence(kind: .browser, probe: true, tab: .unreadable, calendar: true, micSeconds: 30)))
    }

    func testBrowserFallbackFailsWithoutCalendarOverlap() {
        XCTAssertFalse(
            AutoRecordPolicy.shouldRecord(
                evidence(kind: .browser, probe: true, tab: .unreadable, calendar: false, micSeconds: 300)))
    }

    func testBrowserFallbackFailsUnderMicRequirement() {
        // Short mic bursts are dictation, not calls.
        XCTAssertFalse(
            AutoRecordPolicy.shouldRecord(
                evidence(kind: .browser, probe: true, tab: .unreadable, calendar: true, micSeconds: 25)))
    }

    func testBrowserFallbackHonorsCustomMicRequirement() {
        let e = evidence(kind: .browser, tab: .unreadable, calendar: true, micSeconds: 10)
        XCTAssertTrue(AutoRecordPolicy.shouldRecord(e, sustainedMicRequirementSeconds: 10))
        XCTAssertFalse(AutoRecordPolicy.shouldRecord(e, sustainedMicRequirementSeconds: 11))
    }

    func testBrowserUninspectableWithNoCalendarNeverRecords() {
        // Firefox with no calendar overlap: both gates closed.
        XCTAssertFalse(
            AutoRecordPolicy.shouldRecord(
                evidence(kind: .browser, probe: true, tab: .unreadable, calendar: false, micSeconds: 60)))
    }

    // MARK: - isDefinitelyNotInAMeeting

    func testNativeAppDefinitelyNotInAMeetingOnlyOnDefinitiveInactiveProbe() {
        XCTAssertTrue(
            AutoRecordPolicy.isDefinitelyNotInAMeeting(evidence(kind: .nativeMeetingApp, probe: false)))
        XCTAssertFalse(
            AutoRecordPolicy.isDefinitelyNotInAMeeting(evidence(kind: .nativeMeetingApp, probe: nil)))
        XCTAssertFalse(
            AutoRecordPolicy.isDefinitelyNotInAMeeting(evidence(kind: .nativeMeetingApp, probe: true)))
    }

    func testBrowserNotInAMeetingRequiresInactiveProbeAndInspectedNonMeetingTab() {
        XCTAssertTrue(
            AutoRecordPolicy.isDefinitelyNotInAMeeting(
                evidence(kind: .browser, probe: false, tab: .notMeeting)))
        // An unreadable tab is not proof of absence, whatever the probe says.
        XCTAssertFalse(
            AutoRecordPolicy.isDefinitelyNotInAMeeting(
                evidence(kind: .browser, probe: false, tab: .unreadable)))
        XCTAssertFalse(
            AutoRecordPolicy.isDefinitelyNotInAMeeting(
                evidence(kind: .browser, probe: false, tab: .meeting)))
        XCTAssertFalse(
            AutoRecordPolicy.isDefinitelyNotInAMeeting(
                evidence(kind: .browser, probe: true, tab: .notMeeting)))
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
