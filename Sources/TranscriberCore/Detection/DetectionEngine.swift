import Foundation

/// Wires `ProcessWatcher` events through a per-bundle dwell timer and
/// `SkipState` check. Fires `onCandidate` once per dwell completion.
///
/// Per-bundle state machine:
///   Idle ─launch→ Dwelling(task) ─dwellTime elapsed→ Candidate(callback) → Idle
///   Dwelling ─quit→ Idle (cancel)
///   Idle | Dwelling ─suppress→ Suppressed (cancel)
///   Suppressed ─launch→ no-op (until SkipState TTL expires)
public actor DetectionEngine {
    public typealias OnCandidate = @Sendable (MeetingApp) async -> Void

    private let dwellTime: TimeInterval
    private let skipState: SkipState
    private let onCandidate: OnCandidate
    private var pendingTasks: [String: Task<Void, Never>] = [:]

    public init(
        dwellTime: TimeInterval = 30,
        skipState: SkipState = SkipState(),
        onCandidate: @escaping OnCandidate
    ) {
        self.dwellTime = dwellTime
        self.skipState = skipState
        self.onCandidate = onCandidate
    }

    /// Should be called by `ProcessWatcher.Delegate.didDetectMeetingAppLaunch`.
    /// Cancels any outstanding dwell for this bundle (de-bounces redundant
    /// launch events) and starts a fresh dwell timer.
    public func handleLaunch(of app: MeetingApp) async {
        if await skipState.isSuppressed(app.bundleID) { return }
        pendingTasks[app.bundleID]?.cancel()
        let bundleID = app.bundleID
        let dwell = dwellTime
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
            } catch {
                return // cancelled
            }
            if Task.isCancelled { return }
            // Re-check suppression at fire-time so a concurrent suppress() wins
            // even if it landed during the sleep.
            if let self, await self.skipState.isSuppressed(bundleID) { return }
            await self?.fireCandidate(for: app)
        }
        pendingTasks[app.bundleID] = task
    }

    public func handleQuit(of app: MeetingApp) {
        pendingTasks[app.bundleID]?.cancel()
        pendingTasks.removeValue(forKey: app.bundleID)
    }

    /// Suppresses `app` for `duration` seconds and cancels any in-flight dwell.
    /// Defaults to 30 minutes per spec line 162.
    public func suppress(_ app: MeetingApp, for duration: TimeInterval = 30 * 60) async {
        await skipState.suppress(app.bundleID, for: duration)
        pendingTasks[app.bundleID]?.cancel()
        pendingTasks.removeValue(forKey: app.bundleID)
    }

    private func fireCandidate(for app: MeetingApp) async {
        pendingTasks.removeValue(forKey: app.bundleID)
        await onCandidate(app)
    }
}
