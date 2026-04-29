import Foundation

public protocol TranscriptionEngine: Sendable {
    func transcribe(_ request: EngineRequest) async throws -> EngineResponse
}
