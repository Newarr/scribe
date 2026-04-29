import AVFoundation
import Foundation

public enum AudioMixer {
    public enum MixerError: Error { case readFailed(URL), writeFailed(URL) }

    /// Mix two mono input files into a single mono PCM WAV at the target sample rate.
    /// Uses simple equal-gain sum with safe peak clipping at +/- 1.0. Output is 16-bit
    /// signed integer little-endian PCM (Whisper/Scribe-friendly default).
    public static func mix(
        mic: URL,
        system: URL,
        output: URL,
        sampleRate: Double = 16000
    ) async throws {
        let micFile = try AVAudioFile(forReading: mic)
        let sysFile = try AVAudioFile(forReading: system)

        // Output WAV settings (16-bit signed PCM, mono). AVAudioFile internally converts
        // the float processingFormat we write to the int16 disk format.
        let outFile = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ])

        let resampleFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )!
        let micBuf = try resampleFully(file: micFile, to: resampleFormat)
        let sysBuf = try resampleFully(file: sysFile, to: resampleFormat)

        let frames = max(micBuf.frameLength, sysBuf.frameLength)
        guard frames > 0 else { return }

        let mixed = AVAudioPCMBuffer(pcmFormat: resampleFormat, frameCapacity: frames)!
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

        try outFile.write(from: mixed)
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
