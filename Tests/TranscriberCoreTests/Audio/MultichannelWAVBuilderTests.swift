import XCTest
import AVFoundation
@testable import TranscriberCore

final class MultichannelWAVBuilderTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testProducesTwoChannelWAV() async throws {
        let micURL = tmp.appendingPathComponent("mic.m4a")
        let sysURL = tmp.appendingPathComponent("system.m4a")
        let outURL = tmp.appendingPathComponent("multichannel.wav")
        try writeSilent(to: micURL, durationSec: 1.0)
        try writeSilent(to: sysURL, durationSec: 1.0)

        try await MultichannelWAVBuilder.build(
            mic: micURL,
            system: sysURL,
            output: outURL,
            sampleRate: 16000
        )

        let file = try AVAudioFile(forReading: outURL)
        XCTAssertEqual(file.fileFormat.sampleRate, 16000)
        XCTAssertEqual(file.fileFormat.channelCount, 2, "must produce a 2-channel file")
        XCTAssertGreaterThan(file.length, 0)
    }

    func testChannelOrderingMicOnZeroSystemOnOne() async throws {
        let micURL = tmp.appendingPathComponent("mic.m4a")
        let sysURL = tmp.appendingPathComponent("system.m4a")
        let outURL = tmp.appendingPathComponent("multichannel.wav")
        try writeSine(to: micURL, frequency: 440, durationSec: 0.5)
        try writeSine(to: sysURL, frequency: 880, durationSec: 0.5)

        try await MultichannelWAVBuilder.build(mic: micURL, system: sysURL, output: outURL, sampleRate: 16000)

        let file = try AVAudioFile(forReading: outURL)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        XCTAssertEqual(Int(buf.frameLength), 8000, accuracy: 200)

        let ch0 = buf.floatChannelData![0]
        let ch1 = buf.floatChannelData![1]
        var rms0: Float = 0, rms1: Float = 0
        for i in 0..<Int(buf.frameLength) { rms0 += ch0[i] * ch0[i]; rms1 += ch1[i] * ch1[i] }
        rms0 = sqrt(rms0 / Float(buf.frameLength))
        rms1 = sqrt(rms1 / Float(buf.frameLength))
        XCTAssertGreaterThan(rms0, 0.05, "ch0 should carry the mic sine")
        XCTAssertGreaterThan(rms1, 0.05, "ch1 should carry the system sine")
    }

    private func writeSilent(to url: URL, durationSec: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(durationSec * 48000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
    }

    private func writeSine(to url: URL, frequency: Double, durationSec: Double) throws {
        let sr: Double = 48000
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(durationSec * sr)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ptr = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            ptr[i] = Float(sin(2.0 * .pi * frequency * Double(i) / sr) * 0.4)
        }
        try file.write(from: buffer)
    }
}
