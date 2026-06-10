import AVFoundation
import Foundation

enum AudioMixer {
    enum MixerError: Error { case readFailed(URL), writeFailed(URL) }

    /// Mix two mono input files into a single mono PCM WAV at the target sample rate.
    /// Uses simple equal-gain sum with safe peak clipping at +/- 1.0. Output is 16-bit
    /// signed integer little-endian PCM (Whisper/Scribe-friendly default).
    ///
    /// TODO(slice 4): this implementation buffers each input fully into memory and
    /// allocates a third full-size mixed buffer before writing. A 2-hour mono 48kHz
    /// recording is ~1.4GB peak. Slice 4 (AEC pre-pass) needs streaming for the Rust
    /// AEC3 subprocess pipeline anyway; convert this to chunked stream-mix at that
    /// point. Tracked in codex review of slice 2 (P2).
    static func mix(
        mic: URL,
        system: URL,
        output: URL,
        sampleRate: Double = 16000
    ) async throws {
        let micFile = try AVAudioFile(forReading: mic)
        let sysFile = try AVAudioFile(forReading: system)
        try mix(micReader: micFile, systemReader: sysFile, output: output, sampleRate: sampleRate)
    }

    static func mix(
        micReader: AudioPCMReadable,
        systemReader: AudioPCMReadable,
        output: URL,
        sampleRate: Double = 16000
    ) throws {
        let resampleFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )!
        let micBuf: AVAudioPCMBuffer
        do {
            micBuf = try AudioReadSupport.resampleFully(reader: micReader, to: resampleFormat)
        } catch {
            throw MixerError.readFailed(micReader.sourceURL)
        }
        let sysBuf: AVAudioPCMBuffer
        do {
            sysBuf = try AudioReadSupport.resampleFully(reader: systemReader, to: resampleFormat)
        } catch {
            throw MixerError.readFailed(systemReader.sourceURL)
        }

        let frames = max(micBuf.frameLength, sysBuf.frameLength)
        guard micBuf.frameLength > 0, sysBuf.frameLength > 0, frames > 0 else {
            throw MixerError.readFailed(micBuf.frameLength == 0 ? micReader.sourceURL : systemReader.sourceURL)
        }

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

        do {
            try AudioReadSupport.writeAtomically(output: output, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ]) { outFile in
                try outFile.write(from: mixed)
            }
        } catch {
            throw MixerError.writeFailed(output)
        }
    }
}
