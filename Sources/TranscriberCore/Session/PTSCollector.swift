import Foundation
import CoreMedia

public final class PTSCollector: @unchecked Sendable {
    public enum StreamID: String, Sendable { case mic, system }

    private let lock = NSLock()
    private var micFirstPTS: Double?
    private var sysFirstPTS: Double?
    private var micRate: Int = 0
    private var sysRate: Int = 0
    private var micChannels: Int = 0
    private var sysChannels: Int = 0
    private var micFrames: Int64 = 0
    private var sysFrames: Int64 = 0

    public init() {}

    public func observe(_ stream: StreamID, buffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(buffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }
        let asbd = asbdPointer.pointee
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
        let frames = Int64(CMSampleBufferGetNumSamples(buffer))
        let rate = Int(asbd.mSampleRate)
        let channels = Int(asbd.mChannelsPerFrame)

        lock.lock(); defer { lock.unlock() }
        switch stream {
        case .mic:
            if micFirstPTS == nil { micFirstPTS = pts; micRate = rate; micChannels = channels }
            micFrames += frames
        case .system:
            if sysFirstPTS == nil { sysFirstPTS = pts; sysRate = rate; sysChannels = channels }
            sysFrames += frames
        }
    }

    public func snapshot() -> PTSMetadata {
        lock.lock(); defer { lock.unlock() }
        return PTSMetadata(
            mic: .init(
                firstPTSSeconds: micFirstPTS ?? 0,
                sampleRate: micRate,
                channelCount: micChannels,
                frameCount: micFrames
            ),
            system: .init(
                firstPTSSeconds: sysFirstPTS ?? 0,
                sampleRate: sysRate,
                channelCount: sysChannels,
                frameCount: sysFrames
            )
        )
    }

    public func writeSidecar(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot())
        try data.write(to: url, options: .atomic)
    }
}
