import Foundation

public struct DetectionCandidate: Sendable, Equatable, Hashable {
    public let app: MeetingApp
    public let triggerIdentity: String

    public init(app: MeetingApp, triggerIdentity: String) {
        self.app = app
        self.triggerIdentity = triggerIdentity
    }

    public var bundleID: String { app.bundleID }
    public var displayName: String { app.displayName }
    public var kind: MeetingApp.Kind { app.kind }
}

/// Wires `ProcessWatcher` and running-app observations through a per-trigger
/// dwell window, app-level suppression, audio activity probing, duplicate
/// coalescing, and stale-candidate cleanup.
///
/// Policy invariants:
///   - Running app/browser presence alone is not a meeting. Native apps
///     need the input-device probe positive or indeterminate. Browsers
///     need a meeting-domain tab match, or (when the tab cannot be read)
///     a calendar overlap plus sustained microphone activity.
///   - A transient inactive probe result does not permanently black-hole a
///     plausible app; observation retries until the observation window expires.
///   - Repeated observations for the same ongoing app/call/calendar occurrence
///     coalesce into one user-facing candidate until the app quits or a later
///     inactive probe clears the stale active candidate.
///   - Calendar-enriched candidates key by event ID plus occurrence start when
///     available; app/browser-only candidates fall back to an app signature.
///   - App-level suppression is delegated to in-memory `SkipState` and cancels
///     in-flight/active recognition for that app only.
///   - Every gate decision flows through `AutoRecordPolicy.shouldRecord`:
///     the engine owns evidence collection, the policy owns the rule.
public actor DetectionEngine {
    public typealias TriggerIdentityProvider = @Sendable (MeetingApp) async -> String
    public typealias OnCandidate = @Sendable (DetectionCandidate) async -> Void
    public typealias OnCandidateEnded = @Sendable (DetectionCandidate) async -> Void
    public typealias CalendarOverlapProvider = @Sendable (Date) async -> Bool

    private struct ObservationState: Sendable {
        let candidate: DetectionCandidate
        let startedAt: Date
        /// Consecutive positive probe samples scaled by the sample
        /// interval. A `nil` (indeterminate) sample never counts as mic
        /// time and resets the streak, so HAL indeterminacy can never
        /// satisfy the sustained-mic fallback on its own.
        var sustainedMicSeconds: TimeInterval = 0
    }

    private let dwellTime: TimeInterval
    private let retryInterval: TimeInterval
    private let observationWindow: TimeInterval
    private let skipState: SkipState
    private let probe: AudioActivityProbe
    private let tabInspector: BrowserTabInspecting?
    private let calendarOverlapsNow: CalendarOverlapProvider
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let triggerIdentity: TriggerIdentityProvider
    private let onCandidate: OnCandidate
    private let onCandidateEnded: OnCandidateEnded?
    private var pendingTasks: [String: Task<Void, Never>] = [:]
    private var pendingObservations: [String: ObservationState] = [:]
    private var activeCandidates: [String: DetectionCandidate] = [:]

    public init(
        dwellTime: TimeInterval = 30,
        retryInterval: TimeInterval = 5,
        observationWindow: TimeInterval = 2 * 60,
        skipState: SkipState = SkipState(),
        probe: AudioActivityProbe = UnknownAudioActivityProbe(),
        tabInspector: BrowserTabInspecting? = nil,
        calendarOverlapsNow: @escaping CalendarOverlapProvider = { _ in false },
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = DetectionEngine.sleep(seconds:),
        triggerIdentity: @escaping TriggerIdentityProvider = DetectionEngine.defaultTriggerIdentity(for:),
        onCandidateEnded: OnCandidateEnded? = nil,
        onCandidate: @escaping OnCandidate
    ) {
        self.dwellTime = dwellTime
        self.retryInterval = retryInterval
        self.observationWindow = observationWindow
        self.skipState = skipState
        self.probe = probe
        self.tabInspector = tabInspector
        self.calendarOverlapsNow = calendarOverlapsNow
        self.now = now
        self.sleep = sleep
        self.triggerIdentity = triggerIdentity
        self.onCandidateEnded = onCandidateEnded
        self.onCandidate = onCandidate
    }

    /// Should be called by `ProcessWatcher.Delegate.didDetectMeetingAppLaunch`.
    /// Launches are one observation source; already-running app scans should call
    /// `reevaluate(_:)` for the same policy path.
    public func handleLaunch(of app: MeetingApp) async {
        await reevaluate(app)
    }

    /// Re-evaluates a supported app/browser that is currently running. This is
    /// safe to call from polling, launch, calendar refresh, wake, or audio-change
    /// signals: duplicate observations coalesce by trigger identity.
    public func reevaluate(_ app: MeetingApp) async {
        if await skipState.isSuppressed(app.bundleID, now: now()) { return }

        let identity = await triggerIdentity(app)
        let candidate = DetectionCandidate(app: app, triggerIdentity: identity)
        if activeCandidates[identity] != nil {
            let cleared = await clearStaleActiveCandidateIfNeeded(candidate)
            if !cleared { return }
        } else {
            await clearEndedCandidatesForSameBundle(as: candidate)
        }

        guard pendingTasks[identity] == nil else { return }
        startObservation(for: candidate)
    }

    public func handleQuit(of app: MeetingApp) async {
        for (identity, observation) in pendingObservations where observation.candidate.app.bundleID == app.bundleID {
            pendingTasks[identity]?.cancel()
            pendingTasks.removeValue(forKey: identity)
            pendingObservations.removeValue(forKey: identity)
        }
        let ended = activeCandidates.values.filter { $0.app.bundleID == app.bundleID }
        for candidate in ended {
            activeCandidates.removeValue(forKey: candidate.triggerIdentity)
            await onCandidateEnded?(candidate)
        }
    }

    /// Allows the app shell to re-present a still-active candidate after an
    /// intervening recording has stopped. This keeps active-recording queueing
    /// non-interruptive without permanently coalescing the queued trigger.
    public func releaseActiveCandidate(_ candidate: DetectionCandidate) {
        activeCandidates.removeValue(forKey: candidate.triggerIdentity)
    }

    /// Backward-compatible app-scoped release for callers without trigger
    /// context. Removes all active identities for the app.
    public func releaseActiveCandidate(for app: MeetingApp) {
        for identity in activeCandidates.keys where activeCandidates[identity]?.app.bundleID == app.bundleID {
            activeCandidates.removeValue(forKey: identity)
        }
    }

    /// Suppresses `app` for `duration` seconds and cancels any in-flight or
    /// coalesced active candidate for that app. Defaults to 30 minutes per spec.
    public func suppress(_ app: MeetingApp, for duration: TimeInterval = 30 * 60) async {
        await skipState.suppress(app.bundleID, for: duration, now: now())
        for (identity, observation) in pendingObservations where observation.candidate.app.bundleID == app.bundleID {
            pendingTasks[identity]?.cancel()
            pendingTasks.removeValue(forKey: identity)
            pendingObservations.removeValue(forKey: identity)
        }
        for identity in activeCandidates.keys where activeCandidates[identity]?.app.bundleID == app.bundleID {
            activeCandidates.removeValue(forKey: identity)
        }
    }

    private func startObservation(for candidate: DetectionCandidate) {
        let identity = candidate.triggerIdentity
        let bundleID = candidate.app.bundleID
        pendingObservations[identity] = ObservationState(candidate: candidate, startedAt: now())
        let dwell = dwellTime
        let retry = retryInterval
        let window = observationWindow
        let sleep = sleep
        let task = Task { [weak self] in
            await sleep(dwell)
            while !Task.isCancelled {
                guard let self else { return }
                if await self.skipState.isSuppressed(bundleID, now: self.now()) {
                    await self.finishObservation(identity: identity)
                    return
                }

                let shouldContinue = await self.evaluatePendingObservation(identity: identity, observationWindow: window)
                guard shouldContinue else { return }
                await sleep(retry)
            }
        }
        pendingTasks[identity] = task
    }

    /// Returns true when the observation should retry after `retryInterval`.
    /// Builds `AutoRecordPolicy.Evidence` per sample and fires only when
    /// `shouldRecord` passes.
    private func evaluatePendingObservation(identity: String, observationWindow: TimeInterval) async -> Bool {
        guard let observation = pendingObservations[identity] else { return false }
        let probeIsActive = await probe.isActive(bundleID: observation.candidate.app.bundleID)
        if Task.isCancelled {
            finishObservation(identity: identity)
            return false
        }

        var updated = observation
        if probeIsActive == .some(true) {
            updated.sustainedMicSeconds += retryInterval
        } else {
            updated.sustainedMicSeconds = 0
        }
        pendingObservations[identity] = updated

        let tabMatches: Bool?
        switch observation.candidate.kind {
        case .nativeMeetingApp:
            tabMatches = nil
        case .browser:
            tabMatches = await tabInspector?.activeTabMatchesMeeting(bundleID: observation.candidate.bundleID)
        }

        if Task.isCancelled {
            finishObservation(identity: identity)
            return false
        }

        let evidence = AutoRecordPolicy.Evidence(
            kind: observation.candidate.kind,
            probeIsActive: probeIsActive,
            browserTabMatchesMeeting: tabMatches,
            calendarOverlapsNow: await calendarOverlapsNow(now()),
            sustainedMicSeconds: updated.sustainedMicSeconds
        )
        if AutoRecordPolicy.shouldRecord(evidence) {
            await fireCandidate(observation.candidate)
            return false
        }
        if now().timeIntervalSince(updated.startedAt) >= observationWindow {
            finishObservation(identity: identity)
            return false
        }
        return true
    }

    /// Definitive "this app is not in a meeting" verdict used to clear
    /// stale active candidates. For browsers, an unreadable tab is not
    /// proof of absence: require both a definitive inactive probe AND an
    /// inspected non-meeting tab.
    private func definitelyNotInAMeeting(_ candidate: DetectionCandidate) async -> Bool {
        let isActive = await probe.isActive(bundleID: candidate.bundleID)
        switch candidate.kind {
        case .nativeMeetingApp:
            return isActive == false
        case .browser:
            guard isActive == false else { return false }
            let tabMatches = await tabInspector?.activeTabMatchesMeeting(bundleID: candidate.bundleID)
            return tabMatches == false
        }
    }

    /// Returns true when stale active state was cleared and the current
    /// observation may start a fresh dwell/probe cycle for the same trigger.
    private func clearStaleActiveCandidateIfNeeded(_ candidate: DetectionCandidate) async -> Bool {
        if await definitelyNotInAMeeting(candidate) {
            let ended = activeCandidates.removeValue(forKey: candidate.triggerIdentity) ?? candidate
            await onCandidateEnded?(ended)
            return true
        }
        return false
    }

    /// A calendar-scoped candidate can become app-scoped after the calendar
    /// event ends. If the app is now inactive, clear the old active candidates
    /// so the shell can show the stop prompt for the recording.
    private func clearEndedCandidatesForSameBundle(as candidate: DetectionCandidate) async {
        let stale = activeCandidates.values.filter {
            $0.app.bundleID == candidate.app.bundleID && $0.triggerIdentity != candidate.triggerIdentity
        }
        guard !stale.isEmpty else { return }
        guard await definitelyNotInAMeeting(candidate) else { return }
        for ended in stale {
            activeCandidates.removeValue(forKey: ended.triggerIdentity)
            await onCandidateEnded?(ended)
        }
    }

    private func fireCandidate(_ candidate: DetectionCandidate) async {
        finishObservation(identity: candidate.triggerIdentity)
        guard activeCandidates[candidate.triggerIdentity] == nil else { return }
        activeCandidates[candidate.triggerIdentity] = candidate
        await onCandidate(candidate)
    }

    private func finishObservation(identity: String) {
        pendingTasks[identity]?.cancel()
        pendingTasks.removeValue(forKey: identity)
        pendingObservations.removeValue(forKey: identity)
    }

    public static func defaultTriggerIdentity(for app: MeetingApp) -> String {
        "app:\(app.bundleID)"
    }

    public static func sleep(seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } catch {
            return
        }
    }
}

public enum DetectionTriggerIdentity {
    static let calendarPrefix = "calendar:"

    public static func matchesEndedCandidate(
        pendingTriggerIdentity: String,
        pendingBundleID: String,
        endedCandidate: DetectionCandidate
    ) -> Bool {
        guard pendingBundleID == endedCandidate.bundleID else { return false }

        let exactPrompt = pendingTriggerIdentity == endedCandidate.triggerIdentity
        let calendarPromptMovedToAppIdentity =
            pendingTriggerIdentity.hasPrefix(calendarPrefix) &&
            endedCandidate.triggerIdentity == DetectionEngine.defaultTriggerIdentity(for: endedCandidate.app)

        return exactPrompt || calendarPromptMovedToAppIdentity
    }
}
