import Foundation

/// Wires `ProcessWatcher` and running-app observations through a per-bundle
/// dwell window, app-level suppression, audio activity probing, duplicate
/// coalescing, and stale-candidate cleanup.
///
/// Policy invariants:
///   - Running app/browser presence alone is not a meeting when the probe can
///     determine inactivity.
///   - A transient inactive probe result does not permanently black-hole a
///     plausible app; observation retries until the observation window expires.
///   - Repeated observations for the same ongoing app/call coalesce into one
///     user-facing candidate until the app quits or a later inactive probe
///     clears the stale active candidate.
///   - App-level suppression is delegated to in-memory `SkipState` and cancels
///     in-flight/active recognition for that app only.
public actor DetectionEngine {
    public typealias OnCandidate = @Sendable (MeetingApp) async -> Void

    private struct ObservationState: Sendable {
        let app: MeetingApp
        let startedAt: Date
    }

    private let dwellTime: TimeInterval
    private let retryInterval: TimeInterval
    private let observationWindow: TimeInterval
    private let skipState: SkipState
    private let probe: AudioActivityProbe
    private let now: @Sendable () -> Date
    private let onCandidate: OnCandidate
    private var pendingTasks: [String: Task<Void, Never>] = [:]
    private var pendingObservations: [String: ObservationState] = [:]
    private var activeCandidateBundleIDs: Set<String> = []

    public init(
        dwellTime: TimeInterval = 30,
        retryInterval: TimeInterval = 5,
        observationWindow: TimeInterval = 2 * 60,
        skipState: SkipState = SkipState(),
        probe: AudioActivityProbe = UnknownAudioActivityProbe(),
        now: @escaping @Sendable () -> Date = Date.init,
        onCandidate: @escaping OnCandidate
    ) {
        self.dwellTime = dwellTime
        self.retryInterval = retryInterval
        self.observationWindow = observationWindow
        self.skipState = skipState
        self.probe = probe
        self.now = now
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
    /// signals: duplicate observations coalesce by bundle ID.
    public func reevaluate(_ app: MeetingApp) async {
        if await skipState.isSuppressed(app.bundleID, now: now()) { return }

        if activeCandidateBundleIDs.contains(app.bundleID) {
            await clearStaleActiveCandidateIfNeeded(app)
            return
        }

        guard pendingTasks[app.bundleID] == nil else { return }
        startObservation(for: app)
    }

    public func handleQuit(of app: MeetingApp) {
        pendingTasks[app.bundleID]?.cancel()
        pendingTasks.removeValue(forKey: app.bundleID)
        pendingObservations.removeValue(forKey: app.bundleID)
        activeCandidateBundleIDs.remove(app.bundleID)
    }

    /// Suppresses `app` for `duration` seconds and cancels any in-flight or
    /// coalesced active candidate for that app. Defaults to 30 minutes per spec.
    public func suppress(_ app: MeetingApp, for duration: TimeInterval = 30 * 60) async {
        await skipState.suppress(app.bundleID, for: duration, now: now())
        pendingTasks[app.bundleID]?.cancel()
        pendingTasks.removeValue(forKey: app.bundleID)
        pendingObservations.removeValue(forKey: app.bundleID)
        activeCandidateBundleIDs.remove(app.bundleID)
    }

    private func startObservation(for app: MeetingApp) {
        let bundleID = app.bundleID
        pendingObservations[bundleID] = ObservationState(app: app, startedAt: now())
        let dwell = dwellTime
        let retry = retryInterval
        let window = observationWindow
        let task = Task { [weak self] in
            await Self.sleep(seconds: dwell)
            while !Task.isCancelled {
                guard let self else { return }
                if await self.skipState.isSuppressed(bundleID, now: self.now()) {
                    await self.finishObservation(bundleID: bundleID)
                    return
                }

                let shouldContinue = await self.evaluatePendingObservation(bundleID: bundleID, observationWindow: window)
                guard shouldContinue else { return }
                await Self.sleep(seconds: retry)
            }
        }
        pendingTasks[bundleID] = task
    }

    /// Returns true when the observation should retry after `retryInterval`.
    private func evaluatePendingObservation(bundleID: String, observationWindow: TimeInterval) async -> Bool {
        guard let observation = pendingObservations[bundleID] else { return false }
        let isActive = await probe.isActive(bundleID: bundleID)
        if Task.isCancelled {
            finishObservation(bundleID: bundleID)
            return false
        }

        switch isActive {
        case true, nil:
            await fireCandidate(for: observation.app)
            return false
        case false:
            if now().timeIntervalSince(observation.startedAt) >= observationWindow {
                finishObservation(bundleID: bundleID)
                return false
            }
            return true
        }
    }

    private func clearStaleActiveCandidateIfNeeded(_ app: MeetingApp) async {
        let isActive = await probe.isActive(bundleID: app.bundleID)
        if isActive == false {
            activeCandidateBundleIDs.remove(app.bundleID)
        }
    }

    private func fireCandidate(for app: MeetingApp) async {
        finishObservation(bundleID: app.bundleID)
        guard !activeCandidateBundleIDs.contains(app.bundleID) else { return }
        activeCandidateBundleIDs.insert(app.bundleID)
        await onCandidate(app)
    }

    private func finishObservation(bundleID: String) {
        pendingTasks[bundleID]?.cancel()
        pendingTasks.removeValue(forKey: bundleID)
        pendingObservations.removeValue(forKey: bundleID)
    }

    private static func sleep(seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } catch {
            return
        }
    }
}
