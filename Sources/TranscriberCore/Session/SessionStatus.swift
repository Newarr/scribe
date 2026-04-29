public enum SessionStatus: String, Codable, Sendable, Equatable {
    case idle
    case starting
    case recording
    case stopping
    case finalized
    case failed
}
