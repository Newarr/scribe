import AVFoundation
import Foundation

/// Produces the V1 spec's user-facing `audio.m4a` (mono AAC, 48kHz) from the
/// per-channel mic.m4a + system.m4a files. Mix recipe matches AudioMixer:
/// equal-gain sum with peak clipping. The spec calls for LUFS normalization
/// to -16 LUFS true-peak ≤ -1 dBTP (line 208) — that's a nice-to-have for
/// playback comfort and is deferred to a polish pass.
public enum AudioFinalizer {
    public enum FinalizeError: Error {
        case readFailed(URL)
        case writerSetupFailed
        case writerFailed(Error?)
    }

    /// Reads mic + system, mixes to mono float, then encodes to AAC m4a at
    /// `output`. Synchronous-feeling async wrapper.
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
        let micBuf = try resampleFully(file: micFile, to: monoFormat)
        let sysBuf = try resampleFully(file: sysFile, to: monoFormat)

        let frames = max(micBuf.frameLength, sysBuf.frameLength)
        guard frames > 0 else { return }

        let mixed = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames)!
        mixed.frameLength = frames
        let micPtr = micBuf.floatChannelData![0]
        let sysPtr = sysBuf.floatChannelData![0]
        let mixPtr = mixed.floatChannelData![0]
        for i in 0..<Int(frames) {
            let m = i < Int(micBuf.frameLength) ? micPtr[i] : 0
            let s = i < Int(sysBuf.frameLength) ? sysPtr[i] : 0
            let sum = (m + s) * 0.5
            mixPtr[i] = max(-1.0, min(1.0, sum))
        }

        // Encode to AAC m4a. Same recipe as AudioFileWriter.start (slice 1) but
        // for a mixed stem. AVAssetWriter consumes float CMSampleBuffers and
        // emits AAC into the .m4a file format.
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

        // Wrap mixed PCMBuffer into a CMSampleBuffer for append.
        guard let sample = try? Self.makeSampleBuffer(from: mixed) else {
            throw FinalizeError.writerSetupFailed
        }

        if !input.append(sample) {
            throw FinalizeError.writerFailed(writer.error)
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw FinalizeError.writerFailed(writer.error)
        }
    }

    private static func makeSampleBuffer(from buffer: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        // CMSampleBuffer of the entire mixed buffer in one shot. AVAssetWriter
        // accepts arbitrarily-sized samples for non-realtime input.
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

        // Copy interleaved-or-noninterleaved float32 mono into the block buffer.
        // Mono with float32 means just `frameCount * 4` bytes from channelData[0].
        if let floatPtr = buffer.floatChannelData?[0] {
            CMBlockBufferReplaceDataBytes(with: floatPtr, blockBuffer: block, offsetIntoDestination: 0, dataLength: totalBytes)
        }

        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(asbd.mSampleRate)),
            presentationTimeStamp: .zero,
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

    private static func resampleFully(file: AVAudioFile, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let totalFrames = AVAudioFrameCount(
            Double(file.length) * format.sampleRate / file.fileFormat.sampleRate
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames + 1024)!
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        let readBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!

        var endOfFile = false
        var status: AVAudioConverterOutputStatus = .haveData
        while status == .haveData && !endOfFile {
            var error: NSError?
            status = converter.convert(to: buffer, error: &error) { _, outStatus in
                do {
                    try file.read(into: readBuffer)
                } catch {
                    outStatus.pointee = .endOfStream
                    endOfFile = true
                    return nil
                }
                if readBuffer.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    endOfFile = true
                    return nil
                }
                outStatus.pointee = .haveData
                return readBuffer
            }
            if let err = error { throw err }
        }
        return buffer
    }
}
