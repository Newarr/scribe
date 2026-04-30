import AVFoundation
import Foundation

/// Produces the V1 spec's user-facing `audio.m4a` (mono AAC, 48kHz) from the
/// per-channel `mic.m4a` + `system.m4a` files.
///
/// Phase ε: streaming pipeline. v0 read both files entirely into memory
/// (~700MB per stream at 60 minutes); the streaming version reads + mixes +
/// writes one ~100ms chunk at a time with `expectsMediaDataInRealTime =
/// false` and `isReadyForMoreMediaData` backpressure polling, keeping
/// peak resident memory proportional to chunk size, not file size.
///
/// Mix recipe: power-preserving — single-active side passes through at its
/// original amplitude, dual-active sides are scaled by 1/√2 each (so two
/// uncorrelated full-scale signals don't clip the sum). Per-sample peak
/// limit at 0.891 ≈ -1 dBFS gives true-peak headroom per spec line 208.
///
/// LUFS normalization (spec line 208, target -16 LUFS / true peak ≤ -1
/// dBTP) is approximated as RMS-style mixing per the D3 plan decision —
/// shipping rc1 with documented spec deviation; real BS.1770 is V1.1.
public enum AudioFinalizer {
    public enum FinalizeError: Error, Equatable {
        case readFailed(URL)
        case writerSetupFailed
        case writerFailed(String?)
        case converterCreationFailed
        case backpressureTimeout
        case writerStatusFailed
    }

    /// Knobs are surfaced so tests can drive partial-chunk EOF boundaries
    /// and short backpressure timeouts without 30-second wall-clock waits.
    public struct Options: Sendable {
        /// Target frames produced per pull. 4800 @ 48kHz = 100ms — small
        /// enough to bound memory, large enough to keep the AAC encoder fed.
        public var chunkFrames: AVAudioFrameCount

        /// Backpressure poll interval when the AVAssetWriter input is full.
        public var backpressureSleep: TimeInterval

        /// Maximum continuous time we'll wait for the writer to drain
        /// before giving up. Prevents an indefinite hang when the disk is
        /// full or the encoder has wedged.
        public var backpressureTimeout: TimeInterval

        public init(
            chunkFrames: AVAudioFrameCount = 4800,
            backpressureSleep: TimeInterval = 0.01,
            backpressureTimeout: TimeInterval = 30
        ) {
            self.chunkFrames = chunkFrames
            self.backpressureSleep = backpressureSleep
            self.backpressureTimeout = backpressureTimeout
        }

        public static let `default` = Options()
    }

    public static func finalize(
        mic: URL,
        system: URL,
        output: URL,
        sampleRate: Double = 48000,
        options: Options = .default
    ) async throws {
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        // Write to a sibling temp path so a mid-stream failure (or an
        // attempted retry after a previous run) cannot wipe an existing
        // finalized audio.m4a. Atomic move at the very end.
        let tempName = ".\(output.lastPathComponent).inflight-\(UUID().uuidString.prefix(8))"
        let tempOutput = output.deletingLastPathComponent().appendingPathComponent(tempName)
        try? FileManager.default.removeItem(at: tempOutput)

        let micFile = try AVAudioFile(forReading: mic)
        let sysFile = try AVAudioFile(forReading: system)

        let micReader = try StreamReader(file: micFile, target: monoFormat, chunkFrames: options.chunkFrames)
        let sysReader = try StreamReader(file: sysFile, target: monoFormat, chunkFrames: options.chunkFrames)

        let writer = try AVAssetWriter(outputURL: tempOutput, fileType: .m4a)
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

        guard writer.startWriting() else {
            throw FinalizeError.writerFailed(writer.error.map { String(describing: $0) })
        }
        writer.startSession(atSourceTime: .zero)

        let micChunk = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: options.chunkFrames)!
        let sysChunk = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: options.chunkFrames)!
        var cumulativeFrames: Int64 = 0

        // Power-preserving mix coefficients. Single active side stays at
        // unity, dual-active is scaled by 1/√2 so two uncorrelated
        // full-scale sources sum to ~ -3 dB (instead of clipping at 6 dB
        // above, or attenuating at 6 dB below as v0's *0.5 averaging did).
        let invSqrt2 = Float(1.0 / 2.0.squareRoot())
        let peakLimit: Float = 0.891  // ~ -1 dBFS true-peak headroom

        do {
            while !(micReader.isExhausted && sysReader.isExhausted) {
                let micFrames = try micReader.produce(into: micChunk, target: options.chunkFrames)
                let sysFrames = try sysReader.produce(into: sysChunk, target: options.chunkFrames)

                let frames = max(micFrames, sysFrames)
                if frames == 0 { break }

                let mixed = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames)!
                mixed.frameLength = frames
                let mixPtr = mixed.floatChannelData![0]
                let micPtr = micChunk.floatChannelData![0]
                let sysPtr = sysChunk.floatChannelData![0]

                let micCount = Int(micFrames)
                let sysCount = Int(sysFrames)
                for i in 0..<Int(frames) {
                    let micActive = i < micCount
                    let sysActive = i < sysCount
                    let m = micActive ? micPtr[i] : 0
                    let s = sysActive ? sysPtr[i] : 0
                    let sum: Float
                    if micActive && sysActive {
                        sum = (m + s) * invSqrt2
                    } else {
                        sum = m + s  // single-active side preserved at unity
                    }
                    mixPtr[i] = max(-peakLimit, min(peakLimit, sum))
                }

                let pts = CMTime(value: cumulativeFrames, timescale: Int32(sampleRate))
                cumulativeFrames += Int64(frames)
                let sample = try Self.makeSampleBuffer(from: mixed, presentationTimeStamp: pts)

                // Bounded backpressure. Without the timeout + writer-status
                // check, a wedged writer (disk full, sandbox revoked,
                // encoder stalled) would loop forever.
                let waitStart = Date()
                while !input.isReadyForMoreMediaData {
                    if Task.isCancelled { throw CancellationError() }
                    if writer.status == .failed || writer.status == .cancelled {
                        throw FinalizeError.writerStatusFailed
                    }
                    if Date().timeIntervalSince(waitStart) > options.backpressureTimeout {
                        throw FinalizeError.backpressureTimeout
                    }
                    try await Task.sleep(nanoseconds: UInt64(options.backpressureSleep * 1_000_000_000))
                }

                if !input.append(sample) {
                    throw FinalizeError.writerFailed(writer.error.map { String(describing: $0) })
                }
            }

            input.markAsFinished()
            await writer.finishWriting()
            if writer.status == .failed {
                throw FinalizeError.writerFailed(writer.error.map { String(describing: $0) })
            }

            // Atomic-ish replace: move the finished temp into place. Only
            // remove the existing output AFTER the temp is confirmed
            // written, so an aborted retry leaves the previous good
            // audio.m4a intact.
            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            try FileManager.default.moveItem(at: tempOutput, to: output)
        } catch {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: tempOutput)
            throw error
        }
    }

    // MARK: - private

    /// Per-source streaming reader that owns its file, optional resampling
    /// converter, scratch read buffer, and EOF state. Each `produce` call
    /// drains the converter (or copies passthrough frames) until either
    /// `target` frames are produced or the source is fully exhausted.
    ///
    /// Replaces the v0 `readMonoChunk` static helper which had a critical
    /// bug: the converter input callback signaled `.endOfStream` after
    /// every single source-buffer pull, so an upsampled input (e.g.
    /// 16kHz → 48kHz) could only ever yield 1x target frames per call,
    /// silently truncating the input to a third of its real length.
    ///
    /// `@unchecked Sendable`: the AVAudioConverter input callback is typed
    /// `@Sendable`, but in practice the converter invokes it synchronously
    /// on the calling thread of `convert(to:error:withInputFrom:)`. Each
    /// StreamReader instance is owned by a single async call to
    /// `finalize(...)` and never escapes — there is no concurrent access
    /// to its mutable state in practice.
    private final class StreamReader: @unchecked Sendable {
        let file: AVAudioFile
        let converter: AVAudioConverter?
        let readBuffer: AVAudioPCMBuffer
        private var fileEOF = false
        private var converterEOF = false

        var isExhausted: Bool {
            // Passthrough: no internal converter buffer, so file EOF == done.
            // Converter: must drain the converter's tail too — signalled by
            // `.endOfStream` from the most recent convert call.
            converter == nil ? fileEOF : converterEOF
        }

        init(file: AVAudioFile, target: AVAudioFormat, chunkFrames: AVAudioFrameCount) throws {
            self.file = file
            let processingFormat = file.processingFormat
            self.readBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: chunkFrames)!
            if processingFormat.isEqual(target) {
                self.converter = nil
            } else {
                guard let conv = AVAudioConverter(from: processingFormat, to: target) else {
                    // Don't silently fall through to passthrough — that
                    // would memcpy non-Float-mono bytes into a Float-mono
                    // buffer and produce garbage with no error.
                    throw FinalizeError.converterCreationFailed
                }
                self.converter = conv
            }
        }

        /// Reads one source-format chunk into `readBuffer`. Returns the
        /// frames written, or 0 on real EOF. Throws only on REAL read
        /// errors (corrupt file, truncation), never on EOF.
        ///
        /// AVAudioFile.read(into:) is documented to return frameLength=0
        /// at EOF, but on AAC-decoded m4a inputs it can throw `nilError`
        /// instead. Distinguish via `framePosition` vs `length`: once
        /// we've read every frame the file declares, any further throw is
        /// EOF; before that, a throw is a real failure.
        private func readNextSourceChunk() throws -> AVAudioFrameCount {
            let total = file.length
            if file.framePosition >= total {
                fileEOF = true
                return 0
            }
            readBuffer.frameLength = 0
            do {
                try file.read(into: readBuffer)
            } catch {
                if file.framePosition >= total {
                    // Read drained the file; the throw is the AAC decoder's
                    // way of signalling EOF. Not a real failure.
                    fileEOF = true
                    return 0
                }
                throw FinalizeError.readFailed(file.url)
            }
            let frames = readBuffer.frameLength
            if frames == 0 {
                fileEOF = true
            }
            return frames
        }

        func produce(into out: AVAudioPCMBuffer, target: AVAudioFrameCount) throws -> AVAudioFrameCount {
            out.frameLength = 0
            if let converter {
                return try produceConverted(out: out, target: target, converter: converter)
            } else {
                return try producePassthrough(out: out, target: target)
            }
        }

        private func producePassthrough(out: AVAudioPCMBuffer, target: AVAudioFrameCount) throws -> AVAudioFrameCount {
            if fileEOF { return 0 }
            let frames = try readNextSourceChunk()
            if frames == 0 { return 0 }
            out.frameLength = frames
            if let src = readBuffer.floatChannelData?[0],
               let dst = out.floatChannelData?[0] {
                memcpy(dst, src, Int(frames) * MemoryLayout<Float>.size)
            }
            return frames
        }

        private func produceConverted(
            out: AVAudioPCMBuffer,
            target: AVAudioFrameCount,
            converter: AVAudioConverter
        ) throws -> AVAudioFrameCount {
            if converterEOF { return 0 }
            // out.frameCapacity caps the produced target frames.
            // The converter pulls source data via the input callback below
            // as it needs more — we only signal endOfStream when the
            // underlying file is genuinely empty.
            var convertError: NSError?
            let errorBox = ConverterErrorBox()
            let status = converter.convert(to: out, error: &convertError) { _, outStatus in
                if self.fileEOF {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                let frames: AVAudioFrameCount
                do {
                    frames = try self.readNextSourceChunk()
                } catch {
                    errorBox.error = error
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if frames == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return self.readBuffer
            }

            if let hardError = errorBox.error { throw hardError }
            if let err = convertError { throw err }
            switch status {
            case .haveData:
                break  // produced up to target frames; more may follow
            case .endOfStream:
                converterEOF = true
            case .inputRanDry:
                // Shouldn't happen with a synchronous file-pull callback;
                // emit what was produced and let the caller decide.
                break
            case .error:
                throw FinalizeError.readFailed(file.url)
            @unknown default:
                throw FinalizeError.readFailed(file.url)
            }
            return out.frameLength
        }
    }

    /// Reference-typed error sink so the converter input callback can
    /// stash a hard read failure without tripping Swift 6's mutation-
    /// of-captured-var-in-Sendable-closure warning. The callback itself
    /// runs synchronously on the same thread as `convert(...)`, so this
    /// is read-write-safe in practice.
    private final class ConverterErrorBox: @unchecked Sendable {
        var error: Error?
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
