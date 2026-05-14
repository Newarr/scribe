import Foundation

/// F-2: the menu bar icon is the design's primary trust surface. The
/// shape is computed from a tuple of (`SessionStatus`, setup blocker
/// flag, detection-prompt active flag, last-saved timestamp,
/// last-failure timestamp). This file owns the pure mapping so the
/// logic is testable without any AppKit dependency — the AppDelegate
/// just feeds the inputs in and turns the result into an asset name +
/// CALayer animation.
public enum TrustState: String, Sendable, Equatable, CaseIterable {
    /// App ready, no recording, preflight green. Bare 4-bar mark.
    case idle
    /// Preflight failed (any blocker). Bars + amber dot.
    case setupRequired
    /// Detection candidate fired; prompt is on screen awaiting a
    /// response. Bars + concentric ring (Swift drives the pulse).
    case detected
    /// Capture active.
    case recording
    /// End-guard countdown active.
    case stopping
    /// Stop requested; audio + transcript writing.
    case finalizing
    /// Last session completed; transient (~3s).
    case saved
    /// Terminal failure on last session; persists until next attempt.
    case failed
}

extension TrustState {
    /// Inputs the AppDelegate hands to the resolver. `now` is injected
    /// so unit tests can assert window edges deterministically.
    public struct Inputs: Sendable, Equatable {
        public var status: SessionStatus
        public var setupNeedsAttention: Bool
        public var detectionPromptActive: Bool
        public var lastSavedAt: Date?
        public var lastFailureAt: Date?
        public var now: Date
        /// Window during which `.saved` shows on the menu bar before
        /// reverting to `.idle`. Spec F-2 calls for ~3s.
        public var savedFlashDuration: TimeInterval

        public init(
            status: SessionStatus,
            setupNeedsAttention: Bool,
            detectionPromptActive: Bool,
            lastSavedAt: Date? = nil,
            lastFailureAt: Date? = nil,
            now: Date = Date(),
            savedFlashDuration: TimeInterval = 3.0
        ) {
            self.status = status
            self.setupNeedsAttention = setupNeedsAttention
            self.detectionPromptActive = detectionPromptActive
            self.lastSavedAt = lastSavedAt
            self.lastFailureAt = lastFailureAt
            self.now = now
            self.savedFlashDuration = savedFlashDuration
        }
    }

    /// Pure derivation. Order is deliberate: a blocker on the
    /// permission stack outranks any session state, because the
    /// session can't usefully proceed until it's resolved. Within
    /// session activity, capture + countdown beat the transient
    /// outcomes; only when the session is idle do we surface a recent
    /// `saved` flash or a stuck `failed` state.
    public static func resolve(_ inputs: Inputs) -> TrustState {
        // 1. Active recording / countdown / finalize wins outright —
        //    a blocker that fires mid-recording is the wrong icon to
        //    show until the session finishes.
        switch inputs.status {
        case .recording: return .recording
        case .stopping:  return .stopping
        case .finalized: return .finalizing
        default:         break
        }

        // 2. A required setup blocker must remain visible even when a
        //    meeting prompt is pending. The popover can still expose the
        //    pending Start/Not now recovery actions, but the trust icon
        //    should communicate that recording cannot proceed yet.
        if inputs.setupNeedsAttention { return .setupRequired }

        // 3. Mid-flight detection prompt is the next-strongest
        //    signal: it's awaiting a user decision, so the icon
        //    should pulse to draw the eye when recording is otherwise
        //    allowed.
        if inputs.detectionPromptActive { return .detected }

        // 4. A terminal failure outranks the transient saved flash because
        //    the user just tried to record and it failed — that needs
        //    to stay visible until they take an action.
        if inputs.lastFailureAt != nil { return .failed }

        // 5. Transient saved confirmation, after a successful save.
        if let saved = inputs.lastSavedAt,
           inputs.now.timeIntervalSince(saved) < inputs.savedFlashDuration {
            return .saved
        }

        // 6. Default.
        return .idle
    }

    /// Asset catalog name backing each state. Kept in core so the
    /// trust-state mapping is one source of truth.
    public var assetName: String {
        switch self {
        case .idle:           return "MenuBarIcon"
        case .setupRequired:  return "MenuBarIconSetup"
        case .detected:       return "MenuBarIconDetected"
        case .recording:      return "MenuBarIconRecording"
        case .stopping:       return "MenuBarIconStopping"
        case .finalizing:     return "MenuBarIconFinalizing"
        case .saved:          return "MenuBarIconSaved"
        case .failed:         return "MenuBarIconFailed"
        }
    }

    /// Accessibility / VoiceOver description.
    public var accessibilityLabel: String {
        switch self {
        case .idle:           return "Scribe"
        case .setupRequired:  return "Scribe, setup required"
        case .detected:       return "Scribe, meeting detected"
        case .recording:      return "Scribe, recording"
        case .stopping:       return "Scribe, stopping recording"
        case .finalizing:     return "Scribe, saving recording"
        case .saved:          return "Scribe, recording saved"
        case .failed:         return "Scribe, last recording failed"
        }
    }
}
