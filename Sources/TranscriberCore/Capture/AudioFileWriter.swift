import AVFoundation

public final class AudioFileWriter: @unchecked Sendable {
    public enum WriterError: Error {
        case notStarted
        case alreadyStarted
        case inputNotAcceptedByWriter
        case writerFailed(Error?)
    }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    private var sessionStarted = false

    public init(url: URL, sampleRate: Int, channelCount: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: channelCount,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: 64_000
        ]
        let createdInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        createdInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(createdInput) else {
            throw WriterError.inputNotAcceptedByWriter
        }
        writer.add(createdInput)
        self.input = createdInput
    }

    public func start() throws {
        guard !started else { throw WriterError.alreadyStarted }
        guard writer.startWriting() else { throw WriterError.writerFailed(writer.error) }
        started = true
    }

    public func append(_ buffer: CMSampleBuffer) throws {
        guard started else { throw WriterError.notStarted }
        if !sessionStarted {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }
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
