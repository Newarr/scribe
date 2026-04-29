import Foundation

public struct EngineRequest: Sendable {
    public enum Mode: Sendable, Equatable {
        case singleChannelDiarized(numSpeakers: Int?)
        case multichannel
    }

    public let audioURL: URL
    public let mode: Mode
    public let languageCode: String?
    public let keyterms: [String]
    public let modelID: String

    public init(audioURL: URL, mode: Mode, languageCode: String?, keyterms: [String], modelID: String = "scribe_v2") {
        self.audioURL = audioURL
        self.mode = mode
        self.languageCode = languageCode
        self.keyterms = keyterms
        self.modelID = modelID
    }
}
