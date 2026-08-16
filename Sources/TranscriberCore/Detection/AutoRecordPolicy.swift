import Foundation

/// Pure decision layer for auto-record. `DetectionEngine` builds an
/// `Evidence` value per probe sample and fires a candidate only when
/// `shouldRecord` passes. `shouldAutoDiscard` decides whether a finished
/// recording is short enough to trash unseen. No state, no clocks;
/// callers own both.
///
/// Plan: `plans/auto-record.md`. The gate lives here, not in the app
/// layer, because the engine's observation loop is the one place all
/// the evidence exists (probe samples, tab inspection, mic accumulation).
public enum AutoRecordPolicy {
    /// Everything the detection layer knows about a candidate at
    /// evaluation time. Built by `DetectionEngine`, nowhere else.
    public struct Evidence: Sendable, Equatable {
        public var kind: MeetingApp.Kind
        /// Result of the input-device probe for this sample. `nil` means
        /// the HAL could not answer.
        public var probeIsActive: Bool?
        /// Result of the tab inspection. `nil` means the browser could
        /// not be inspected (Firefox, timeout, error, missing grant).
        public var browserTabMatchesMeeting: Bool?
        public var calendarOverlapsNow: Bool
        /// Consecutive positive probe samples multiplied by the sample
        /// interval. The engine resets this on a `false` OR `nil` sample
        /// for browsers, so HAL indeterminacy never counts as mic time.
        public var sustainedMicSeconds: TimeInterval

        public init(
            kind: MeetingApp.Kind,
            probeIsActive: Bool?,
            browserTabMatchesMeeting: Bool?,
            calendarOverlapsNow: Bool,
            sustainedMicSeconds: TimeInterval
        ) {
            self.kind = kind
            self.probeIsActive = probeIsActive
            self.browserTabMatchesMeeting = browserTabMatchesMeeting
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
            if evidence.browserTabMatchesMeeting == true { return true }
            return evidence.calendarOverlapsNow
                && evidence.sustainedMicSeconds >= sustainedMicRequirementSeconds
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
