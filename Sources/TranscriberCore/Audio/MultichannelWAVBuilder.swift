import AVFoundation
import Foundation

public enum MultichannelWAVBuilder {
    public enum BuildError: Error {
        case readFailed(URL)
        case writeFailed(URL)
    }

    /// Read mic.m4a + system.m4a, resample each to `sampleRate`, write an interleaved
    /// 16-bit stereo WAV with mic on ch0 and system on ch1. AVAudioFile handles the
    /// float -> int16 conversion on disk write.
    ///
    /// TODO(slice 4): same memory footprint concern as `AudioMixer` — buffers each
    /// full input plus the full output. Stream in chunks once the AEC subprocess
    /// pipeline lands.
    public static func build(
        mic: URL,
        system: URL,
        output: URL,
        sampleRate: Double = 16000
    ) async throws {
        let micFile = try AVAudioFile(forReading: mic)
        let sysFile = try AVAudioFile(forReading: system)

        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let micBuf = try resampleFully(file: micFile, to: monoFormat)
        let sysBuf = try resampleFully(file: sysFile, to: monoFormat)

        let frames = max(micBuf.frameLength, sysBuf.frameLength)
        guard frames > 0 else { return }

        let stereoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let stereo = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: frames)!
        stereo.frameLength = frames

        let micSrc = micBuf.floatChannelData![0]
        let sysSrc = sysBuf.floatChannelData![0]
        let ch0 = stereo.floatChannelData![0]
        let ch1 = stereo.floatChannelData![1]
        for i in 0..<Int(frames) {
            ch0[i] = i < Int(micBuf.frameLength) ? micSrc[i] : 0
            ch1[i] = i < Int(sysBuf.frameLength) ? sysSrc[i] : 0
        }

        let outFile = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ])
        try outFile.write(from: stereo)
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
