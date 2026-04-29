import Foundation

/// Per-bundle "Not a meeting" suppression with TTL. Slice 5 light keeps this
/// in memory only — restarting the app forgets all suppressions. Slice 7's
/// filesystem-as-queue model could persist this if needed, but in practice
/// users opening Zoom days later don't expect a stale Skip to apply.
public actor SkipState {
    private var until: [String: Date] = [:]

    public init() {}

    /// Suppresses prompts for `bundleID` until `now + duration`.
    public func suppress(_ bundleID: String, for duration: TimeInterval, now: Date = Date()) {
        until[bundleID] = now.addingTimeInterval(duration)
    }

    /// True if the bundle is currently suppressed. Side-effect: if the entry
    /// has expired, it's removed from the map so the next check is fast.
    public func isSuppressed(_ bundleID: String, now: Date = Date()) -> Bool {
        guard let expiry = until[bundleID] else { return false }
        if expiry > now { return true }
        until.removeValue(forKey: bundleID)
        return false
    }

    /// Removes any suppression for `bundleID`. Used by tests; production
    /// callers shouldn't need this.
    public func clear(_ bundleID: String) {
        until.removeValue(forKey: bundleID)
    }
}
