import Foundation

public struct SessionID: Equatable, Hashable, Sendable {
    public let slug: String

    public init(from date: Date, timeZone: TimeZone = TimeZone(identifier: "Europe/Warsaw")!) {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        self.slug = formatter.string(from: date)
    }

    public func slugWithSuffix(_ n: Int) -> String {
        precondition(n >= 2, "suffix only for collisions, n>=2")
        return "\(slug)-\(n)"
    }
}
