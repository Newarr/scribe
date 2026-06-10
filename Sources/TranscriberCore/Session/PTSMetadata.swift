import Foundation

public struct PTSMetadata: Codable, Equatable, Sendable {
    public struct Stream: Codable, Equatable, Sendable {
        let firstPTSSeconds: Double
        public let sampleRate: Int
        public let channelCount: Int
        let frameCount: Int64

        public init(firstPTSSeconds: Double, sampleRate: Int, channelCount: Int, frameCount: Int64) {
            self.firstPTSSeconds = firstPTSSeconds
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.frameCount = frameCount
        }
    }

    public let mic: Stream
    public let system: Stream

    public init(mic: Stream, system: Stream) {
        self.mic = mic
        self.system = system
    }

    var systemLeadInMicSamples: Int64 {
        let deltaSec = system.firstPTSSeconds - mic.firstPTSSeconds
        return Int64((deltaSec * Double(mic.sampleRate)).rounded())
    }
}
