import AVFoundation

public final class AudioFileWriter: @unchecked Sendable {
    public enum WriterError: Error {
        case notStarted
        case alreadyStarted
        case writerFailed(Error?)
    }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "audio.writer", qos: .userInitiated)
    private var started = false

    public init(url: URL, sampleRate: Int, channelCount: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: channelCount,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: 64_000
        ]
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }

    public func start() throws {
        guard !started else { throw WriterError.alreadyStarted }
        guard writer.startWriting() else { throw WriterError.writerFailed(writer.error) }
        writer.startSession(atSourceTime: .zero)
        started = true
    }

    public func append(_ buffer: CMSampleBuffer) throws {
        guard started else { throw WriterError.notStarted }
        guard input.isReadyForMoreMediaData else { return }
        if !input.append(buffer) {
            throw WriterError.writerFailed(writer.error)
        }
    }

    public func finalize() async throws {
        guard started else { throw WriterError.notStarted }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed { throw WriterError.writerFailed(writer.error) }
    }
}
