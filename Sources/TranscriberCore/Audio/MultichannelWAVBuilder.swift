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
        try build(micReader: micFile, systemReader: sysFile, output: output, sampleRate: sampleRate)
    }

    static func build(
        micReader: AudioPCMReadable,
        systemReader: AudioPCMReadable,
        output: URL,
        sampleRate: Double = 16000
    ) throws {
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let micBuf: AVAudioPCMBuffer
        do {
            micBuf = try AudioReadSupport.resampleFully(reader: micReader, to: monoFormat)
        } catch {
            throw BuildError.readFailed(micReader.sourceURL)
        }
        let sysBuf: AVAudioPCMBuffer
        do {
            sysBuf = try AudioReadSupport.resampleFully(reader: systemReader, to: monoFormat)
        } catch {
            throw BuildError.readFailed(systemReader.sourceURL)
        }

        let frames = max(micBuf.frameLength, sysBuf.frameLength)
        guard micBuf.frameLength > 0, sysBuf.frameLength > 0, frames > 0 else {
            throw BuildError.readFailed(micBuf.frameLength == 0 ? micReader.sourceURL : systemReader.sourceURL)
        }

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

        do {
            try AudioReadSupport.writeAtomically(output: output, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ]) { outFile in
                try outFile.write(from: stereo)
            }
        } catch {
            throw BuildError.writeFailed(output)
        }
    }
}
