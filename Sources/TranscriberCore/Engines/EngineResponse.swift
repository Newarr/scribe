import Foundation

public struct EngineResponse: Sendable, Equatable {
    public struct Utterance: Sendable, Equatable {
        public let speaker: String
        public let startSeconds: Double
        public let endSeconds: Double
        public let text: String

        public init(speaker: String, startSeconds: Double, endSeconds: Double, text: String) {
            self.speaker = speaker
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.text = text
        }
    }

    public let utterances: [Utterance]
    public let detectedLanguage: String?
    public let modelID: String

    public init(utterances: [Utterance], detectedLanguage: String?, modelID: String) {
        self.utterances = utterances
        self.detectedLanguage = detectedLanguage
        self.modelID = modelID
    }
}
