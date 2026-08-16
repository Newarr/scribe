import Foundation

/// Pure decision layer for auto-record. `DetectionEngine` builds an
/// `Evidence` value per probe sample and consults this policy for both
/// gates: `shouldRecord` decides whether a candidate fires, and
/// `isDefinitelyNotInAMeeting` decides whether a stale active candidate
/// may be cleared. One policy, so a start-gate change cannot drift from
/// the end-of-call gate. `shouldAutoDiscard` decides whether a finished
/// recording is short enough to trash unseen. No state, no clocks;
/// callers own both.
///
/// Plan: `plans/auto-record.md`.
public enum AutoRecordPolicy {
    /// Everything the detection layer knows about a candidate at
    /// evaluation time. Built by `DetectionEngine`, nowhere else.
    public struct Evidence: Sendable, Equatable {
        public var kind: MeetingApp.Kind
        /// Result of the input-device probe for this sample. `nil` means
        /// the HAL could not answer.
        public var probeIsActive: Bool?
        /// Result of the tab inspection. `nil` means the candidate is not
        /// a browser (native apps are never inspected).
        public var browserTab: TabInspectionResult?
        public var calendarOverlapsNow: Bool
        /// Consecutive positive probe samples multiplied by the sample
        /// interval. The engine resets this on a `false` OR `nil` sample
        /// for browsers, so HAL indeterminacy never counts as mic time.
        public var sustainedMicSeconds: TimeInterval

        public init(
            kind: MeetingApp.Kind,
            probeIsActive: Bool?,
            browserTab: TabInspectionResult? = nil,
            calendarOverlapsNow: Bool,
            sustainedMicSeconds: TimeInterval
        ) {
            self.kind = kind
            self.probeIsActive = probeIsActive
            self.browserTab = browserTab
            self.calendarOverlapsNow = calendarOverlapsNow
            self.sustainedMicSeconds = sustainedMicSeconds
        }
    }

    public enum SessionOrigin: Sendable, Equatable {
        case manual
        case detected
    }

    public enum StopInitiator: Sendable, Equatable {
        case endGuard
        case user
    }

    /// The calendar-plus-mic fallback needs this much sustained
    /// microphone activity. Shorter bursts are dictation, not calls.
    public static let defaultSustainedMicRequirementSeconds: TimeInterval = 30

    /// Called by `DetectionEngine` before it fires a candidate.
    /// A meeting-domain tab records alone. An inspected non-meeting tab
    /// never records, whatever the calendar or mic say: the fallback
    /// runs only when the tab was unreadable.
    public static func shouldRecord(
        _ evidence: Evidence,
        sustainedMicRequirementSeconds: TimeInterval = defaultSustainedMicRequirementSeconds
    ) -> Bool {
        switch evidence.kind {
        case .nativeMeetingApp:
            // Probe true or indeterminate passes, matching the engine's
            // existing fire-on-true-or-nil behavior for native apps.
            return evidence.probeIsActive != false
        case .browser:
            switch evidence.browserTab {
            case .meeting:
                return true
            case .notMeeting:
                return false
            case .unreadable, nil:
                return evidence.calendarOverlapsNow
                    && evidence.sustainedMicSeconds >= sustainedMicRequirementSeconds
            }
        }
    }

    /// Definitive "this app is not in a meeting" verdict used to clear
    /// stale active candidates. For browsers an unreadable tab is not
    /// proof of absence: it requires both a definitive inactive probe
    /// AND an inspected non-meeting tab.
    public static func isDefinitelyNotInAMeeting(_ evidence: Evidence) -> Bool {
        switch evidence.kind {
        case .nativeMeetingApp:
            return evidence.probeIsActive == false
        case .browser:
            return evidence.probeIsActive == false && evidence.browserTab == .notMeeting
        }
    }

    /// True when a finished recording is short enough to trash unseen.
    /// Scoped to EndGuard-initiated stops of detected sessions: an
    /// explicit user stop is a decision and always keeps.
    public static func shouldAutoDiscard(
        durationSeconds: TimeInterval,
        origin: SessionOrigin,
        initiator: StopInitiator,
        thresholdSeconds: TimeInterval
    ) -> Bool {
        origin == .detected
            && initiator == .endGuard
            && durationSeconds < thresholdSeconds
    }
}
