import XCTest
import AVFoundation
@testable import TranscriberCore

final class AudioMixerTests: XCTestCase {
    var tmp: URL!
    let sampleRate: Double = 16000

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testMixesTwoSilentFilesIntoSilentOutput() async throws {
        let micURL = tmp.appendingPathComponent("mic.m4a")
        let sysURL = tmp.appendingPathComponent("system.m4a")
        let outURL = tmp.appendingPathComponent("mixed.wav")

        try writeSilent(to: micURL, durationSec: 1.0)
        try writeSilent(to: sysURL, durationSec: 1.0)

        try await AudioMixer.mix(mic: micURL, system: sysURL, output: outURL, sampleRate: 16000)

        let file = try AVAudioFile(forReading: outURL)
        XCTAssertEqual(file.fileFormat.sampleRate, 16000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(file.length, 0)
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
        let frameCount = AVAudioFrameCount(durationSec * 48000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try file.write(from: buffer)
    }
}
