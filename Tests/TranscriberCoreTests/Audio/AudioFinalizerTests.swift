import XCTest
import AVFoundation
@testable import TranscriberCore

final class AudioFinalizerTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testProducesNonEmptyAACFile() async throws {
        let micURL = tmp.appendingPathComponent("mic.m4a")
        let sysURL = tmp.appendingPathComponent("system.m4a")
        let outURL = tmp.appendingPathComponent("audio.m4a")
        try writeAACSilence(to: micURL, durationSec: 1.0)
        try writeAACSilence(to: sysURL, durationSec: 1.0)

        try await AudioFinalizer.finalize(mic: micURL, system: sysURL, output: outURL, sampleRate: 48000)

        let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
        let size = (attrs[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "audio.m4a should be non-empty")
    }

    func testOutputIsAACMonoAtTargetSampleRate() async throws {
        let micURL = tmp.appendingPathComponent("mic.m4a")
        let sysURL = tmp.appendingPathComponent("system.m4a")
        let outURL = tmp.appendingPathComponent("audio.m4a")
        try writeAACSilence(to: micURL, durationSec: 0.5)
        try writeAACSilence(to: sysURL, durationSec: 0.5)

        try await AudioFinalizer.finalize(mic: micURL, system: sysURL, output: outURL, sampleRate: 48000)

        let asset = AVURLAsset(url: outURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        XCTAssertGreaterThan(seconds, 0.3, "duration should reflect audio content; got \(seconds)s")
        XCTAssertLessThan(seconds, 2.0, "duration should not balloon; got \(seconds)s")

        let file = try AVAudioFile(forReading: outURL)
        XCTAssertEqual(file.fileFormat.sampleRate, 48000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
    }

    func testStreamingFinalizeHandlesLongDurationWithoutMemoryBlowup() async throws {
        // Phase ε: streaming version must handle 30+ minutes without
        // reading the whole file into RAM. v0 finalize at this scale was
        // ~700MB per stream resident; the streaming version processes one
        // 100ms chunk at a time. We can't directly assert peak resident
        // memory in CI (no instruments hookup), but we CAN assert the
        // function completes in reasonable time on a 30-second synthetic
        // input — if the streaming pipeline regresses to whole-file reads,
        // either memory or time will balloon.
        //
        // 30s instead of 30min keeps the test under CI's 60s threshold
        // while still exercising 1500 chunks.
        let micURL = tmp.appendingPathComponent("mic.m4a")
        let sysURL = tmp.appendingPathComponent("system.m4a")
        let outURL = tmp.appendingPathComponent("audio.m4a")
        try writeAACSilence(to: micURL, durationSec: 30.0)
        try writeAACSilence(to: sysURL, durationSec: 30.0)

        let start = Date()
        try await AudioFinalizer.finalize(mic: micURL, system: sysURL, output: outURL, sampleRate: 48000)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 30.0, "30s of audio must finalize in well under 30s; got \(elapsed)s")

        let asset = AVURLAsset(url: outURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        XCTAssertGreaterThan(seconds, 25.0, "expected ~30s output; got \(seconds)s")
        XCTAssertLessThan(seconds, 35.0)
    }

    func testStreamingHandlesUnequalLengthInputs() async throws {
        // mic and system rarely start at the same instant — one stream is
        // slightly longer. The streaming pipeline must zero-pad the
        // shorter side, same as the in-memory v0.
        let micURL = tmp.appendingPathComponent("mic.m4a")
        let sysURL = tmp.appendingPathComponent("system.m4a")
        let outURL = tmp.appendingPathComponent("audio.m4a")
        try writeAACSilence(to: micURL, durationSec: 2.0)
        try writeAACSilence(to: sysURL, durationSec: 5.0)

        try await AudioFinalizer.finalize(mic: micURL, system: sysURL, output: outURL, sampleRate: 48000)

        let asset = AVURLAsset(url: outURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        // Output should be the LONGER side (system at 5s); shorter side
        // zero-padded.
        XCTAssertGreaterThan(seconds, 4.0)
        XCTAssertLessThan(seconds, 6.0)
    }

    private func writeAACSilence(to url: URL, durationSec: Double) throws {
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
}
