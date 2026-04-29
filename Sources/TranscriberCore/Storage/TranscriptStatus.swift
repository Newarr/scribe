public enum TranscriptStatus: String, Sendable, Codable, Equatable {
    case pending
    case retrying
    case complete
    case failed
}
