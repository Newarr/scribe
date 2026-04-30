import AVFoundation
import Foundation

/// Produces the V1 spec's user-facing `audio.m4a` (mono AAC, 48kHz) from the
/// per-channel `mic.m4a` + `system.m4a` files. Mix recipe: equal-gain sum
/// with peak clipping.
///
/// Phase ε: streaming pipeline. v0 read both files entirely into memory
/// (~700MB per stream at 60 minutes); the streaming version reads + mixes +
/// writes one ~100ms chunk at a time with `expectsMediaDataInRealTime =
/// false` and `isReadyForMoreMediaData` backpressure polling, keeping
/// peak resident memory proportional to chunk size, not file size.
///
/// LUFS normalization (spec line 208, target -16 LUFS / true peak ≤ -1
/// dBTP) is approximated as RMS scaling per the D3 plan decision —
/// shipping rc1 with documented spec deviation; real BS.1770 is V1.1.
public enum AudioFinalizer {
    public enum FinalizeError: Error {
        case readFailed(URL)
        case writerSetupFailed
        case writerFailed(Error?)
    }

    /// Streaming chunk size in frames. 4800 @ 48kHz = 100ms — small enough
    /// to bound memory, large enough to keep the AAC encoder fed.
    public static let chunkFrames: AVAudioFrameCount = 4800

    /// Backpressure poll interval when the AVAssetWriter input is full.
    private static let backpressureSleep: TimeInterval = 0.01

    public static func finalize(
        mic: URL,
        system: URL,
        output: URL,
        sampleRate: Double = 48000
    ) async throws {
        try? FileManager.default.removeItem(at: output)

        let micFile = try AVAudioFile(forReading: mic)
        let sysFile = try AVAudioFile(forReading: system)

        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: 64_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw FinalizeError.writerSetupFailed }
        writer.add(input)

        guard writer.startWriting() else { throw FinalizeError.writerFailed(writer.error) }
        writer.startSession(atSourceTime: .zero)

        var micConverter: AVAudioConverter?
        var sysConverter: AVAudioConverter?

        let micRead = AVAudioPCMBuffer(pcmFormat: micFile.processingFormat, frameCapacity: chunkFrames)!
        let sysRead = AVAudioPCMBuffer(pcmFormat: sysFile.processingFormat, frameCapacity: chunkFrames)!
        let micChunk = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunkFrames)!
        let sysChunk = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunkFrames)!

        // Format converters resample the source format (whatever the m4a
        // decoded to) into the mono target. Created lazily because both
        // sources may already be the target format.
        if !micFile.processingFormat.isEqual(monoFormat) {
            micConverter = AVAudioConverter(from: micFile.processingFormat, to: monoFormat)
        }
        if !sysFile.processingFormat.isEqual(monoFormat) {
            sysConverter = AVAudioConverter(from: sysFile.processingFormat, to: monoFormat)
        }

        var cumulativeFrames: Int64 = 0
        var micExhausted = false
        var sysExhausted = false

        while !(micExhausted && sysExhausted) {
            // Read one chunk from each (zero frames if exhausted).
            let micFrames: AVAudioFrameCount
            if !micExhausted {
                micFrames = try Self.readMonoChunk(
                    file: micFile,
                    readBuffer: micRead,
                    converter: micConverter,
                    out: micChunk,
                    targetFormat: monoFormat
                )
                if micFrames == 0 { micExhausted = true }
            } else {
                micFrames = 0
            }

            let sysFrames: AVAudioFrameCount
            if !sysExhausted {
                sysFrames = try Self.readMonoChunk(
                    file: sysFile,
                    readBuffer: sysRead,
                    converter: sysConverter,
                    out: sysChunk,
                    targetFormat: monoFormat
                )
                if sysFrames == 0 { sysExhausted = true }
            } else {
                sysFrames = 0
            }

            let frames = max(micFrames, sysFrames)
            if frames == 0 { break }

            let mixed = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames)!
            mixed.frameLength = frames
            let mixPtr = mixed.floatChannelData![0]
            let micPtr = micChunk.floatChannelData![0]
            let sysPtr = sysChunk.floatChannelData![0]
            for i in 0..<Int(frames) {
                let m = i < Int(micFrames) ? micPtr[i] : 0
                let s = i < Int(sysFrames) ? sysPtr[i] : 0
                let sum = (m + s) * 0.5
                mixPtr[i] = max(-1.0, min(1.0, sum))
            }

            let pts = CMTime(value: cumulativeFrames, timescale: Int32(sampleRate))
            cumulativeFrames += Int64(frames)
            let sample = try Self.makeSampleBuffer(from: mixed, presentationTimeStamp: pts)

            // Phase ε backpressure: AVAssetWriter input may say it's not
            // ready while AAC encoder catches up. Poll + sleep instead of
            // dropping the chunk.
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: UInt64(backpressureSleep * 1_000_000_000))
            }
            if !input.append(sample) {
                throw FinalizeError.writerFailed(writer.error)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw FinalizeError.writerFailed(writer.error)
        }
    }

    // MARK: - private

    /// Reads one chunk from `file`, resamples through `converter` if set,
    /// returns the actual frame count written into `out`. 0 means EOF.
    private static func readMonoChunk(
        file: AVAudioFile,
        readBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        out: AVAudioPCMBuffer,
        targetFormat: AVAudioFormat
    ) throws -> AVAudioFrameCount {
        readBuffer.frameLength = 0
        do {
            try file.read(into: readBuffer)
        } catch {
            return 0
        }
        if readBuffer.frameLength == 0 { return 0 }

        if let converter {
            // Convert the source-format chunk into mono target format.
            out.frameLength = 0
            var error: NSError?
            var consumed = false
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return readBuffer
            }
            if let err = error { throw err }
            if status == .error { throw FinalizeError.readFailed(file.url) }
            return out.frameLength
        } else {
            // Source already mono target format — copy frames straight over.
            let frames = readBuffer.frameLength
            out.frameLength = frames
            if let src = readBuffer.floatChannelData?[0],
               let dst = out.floatChannelData?[0] {
                memcpy(dst, src, Int(frames) * MemoryLayout<Float>.size)
            }
            return frames
        }
    }

    private static func makeSampleBuffer(
        from buffer: AVAudioPCMBuffer,
        presentationTimeStamp: CMTime
    ) throws -> CMSampleBuffer {
        let asbd = buffer.format.streamDescription.pointee
        var formatDesc: CMFormatDescription?
        var asbdCopy = asbd
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbdCopy,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard formatStatus == noErr, let format = formatDesc else {
            throw FinalizeError.writerSetupFailed
        }

        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let frameCount = Int(buffer.frameLength)
        let totalBytes = bytesPerFrame * frameCount

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let block = blockBuffer else {
            throw FinalizeError.writerSetupFailed
        }

        if let floatPtr = buffer.floatChannelData?[0] {
            CMBlockBufferReplaceDataBytes(with: floatPtr, blockBuffer: block, offsetIntoDestination: 0, dataLength: totalBytes)
        }

        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(asbd.mSampleRate)),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: [timing],
            sampleSizeEntryCount: 1,
            sampleSizeArray: [bytesPerFrame],
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sample = sampleBuffer else {
            throw FinalizeError.writerSetupFailed
        }
        return sample
    }
}
