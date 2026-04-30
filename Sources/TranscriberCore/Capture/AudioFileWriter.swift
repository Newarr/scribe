import AVFoundation
import Foundation

public final class AudioFileWriter: @unchecked Sendable {
    public enum WriterError: Error {
        case notStarted
        case alreadyStarted
        case inputNotAcceptedByWriter
        case writerFailed(Error?)
    }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput

    /// Serial queue around all writer mutation. SCK output callbacks land
    /// on the SCK sample-handler queue; without this, the AVAssetWriter
    /// state (`started`, `sessionStarted`, `input.append`) would race with
    /// `finalize()` running on the actor's thread. Codex pass 1 + pass 2
    /// flagged this as the actual fix for "stop swallowed by in-flight
    /// buffers" — clearing the handler closure was a partial mitigation
    /// at best.
    private let queue = DispatchQueue(label: "audiofilewriter.serial")
    private var started = false
    private var sessionStarted = false
    private var finalized = false

    /// Counts of post-finalize append() calls. Tests assert this counter is
    /// non-zero to prove that "no errors after finalize" came from the
    /// drain barrier and not from silent buffer loss.
    private var postFinalizeAppendCount: Int = 0

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
        var thrown: WriterError?
        queue.sync {
            guard !started else { thrown = .alreadyStarted; return }
            guard writer.startWriting() else { thrown = .writerFailed(writer.error); return }
            started = true
        }
        if let error = thrown { throw error }
    }

    public func append(_ buffer: CMSampleBuffer) throws {
        var thrown: WriterError?
        queue.sync {
            // Post-finalize append must not throw — the SCK output queue may
            // hold a sample buffer in flight when stop() runs, and a thrown
            // error there would propagate up into the SCStreamOutput
            // callback. Count it instead so the test can assert the no-op
            // path actually fired.
            if finalized {
                postFinalizeAppendCount &+= 1
                return
            }
            guard started else { thrown = .notStarted; return }
            if !sessionStarted {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                writer.startSession(atSourceTime: pts)
                sessionStarted = true
            }
            guard input.isReadyForMoreMediaData else { return }
            if !input.append(buffer) {
                thrown = .writerFailed(writer.error)
            }
        }
        if let error = thrown { throw error }
    }

    public func finalize() async throws {
        // Capture the in-flight state on the serial queue, mark finalized,
        // then run finishWriting outside the queue (it's an async API and
        // would deadlock if held on the same serial queue as `append`).
        var notStarted = false
        var alreadyFinalized = false
        queue.sync {
            if !started { notStarted = true; return }
            if finalized { alreadyFinalized = true; return }
            input.markAsFinished()
            finalized = true
        }
        if notStarted { throw WriterError.notStarted }
        if alreadyFinalized { return }  // Idempotent — second finalize is a no-op.

        await writer.finishWriting()
        if writer.status == .failed { throw WriterError.writerFailed(writer.error) }
    }

    /// Test-only: how many append() calls the writer absorbed AFTER finalize.
    /// Internal access; package tests reach in via @testable import.
    var postFinalizeAppendCounter: Int {
        queue.sync { postFinalizeAppendCount }
    }
}
