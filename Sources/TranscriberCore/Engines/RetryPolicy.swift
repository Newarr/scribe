import Foundation

public struct RetryPolicy: Sendable, Equatable {
    /// Spec policy for the cloud engine: 1m / 5m / 30m, 3 attempts after the
    /// initial failure (4 total attempts before terminal failure).
    public static let cloud = RetryPolicy(delays: [60, 300, 1800])

    public let delays: [TimeInterval]
    public var maxAttempts: Int { delays.count + 1 }

    public init(delays: [TimeInterval]) {
        self.delays = delays
    }

    /// Returns the delay to wait before the next attempt, where `failedAttempts`
    /// is the number of failures observed so far. Returns nil after the policy
    /// is exhausted; the caller treats nil as terminal failure.
    public func nextDelay(afterFailedAttempts failedAttempts: Int) -> TimeInterval? {
        guard failedAttempts >= 0, failedAttempts < delays.count else { return nil }
        return delays[failedAttempts]
    }
}
