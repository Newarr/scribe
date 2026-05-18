import XCTest
import AVFoundation
import Darwin
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

    func testStreamingResamplesMismatchedInputSampleRate() async throws {
        // Codex P0: the v0 converter callback returned `.endOfStream` after
        // every single source-buffer pull, so an upsampling scenario
        // (16 kHz mic → 48 kHz output) produced 1x target frames per call
        // instead of 3x. This silently truncated 3-second 16 kHz inputs to
        // 1-second outputs. The new StreamReader drives the converter
        // until the underlying file is genuinely exhausted.
        let micURL = tmp.appendingPathComponent("mic.m4a")
        let sysURL = tmp.appendingPathComponent("system.m4a")
        let outURL = tmp.appendingPathComponent("audio.m4a")
        try writeAACSilence(to: micURL, durationSec: 3.0, sampleRate: 16000)
        try writeAACSilence(to: sysURL, durationSec: 3.0, sampleRate: 48000)

        try await AudioFinalizer.finalize(mic: micURL, system: sysURL, output: outURL, sampleRate: 48000)

        let asset = AVURLAsset(url: outURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        XCTAssertGreaterThan(seconds, 2.7, "16 kHz mic input must resample to full ~3s @ 48 kHz; got \(seconds)s — converter likely truncating")
        XCTAssertLessThan(seconds, 3.6)
    }

    func testStreamingHandlesUnequalLengthInputs() async throws {
        // mic and system rarely start at the same instant — one stream is
        // slightly longer. The streaming pipeline must zero-pad the
        // shorter side, same as the in-memory v0.
        //
        // Codex P2: also assert the longer side's CONTENT survives, not
        // just the duration. We use a 440 Hz tone in the system tail past
        // the mic's end and verify the output has audible energy in that
        // window — a regression that wrote only the shorter side or
        // dropped single-active samples would fail this.
        let micURL = tmp.appendingPathComponent("mic.m4a")
        let sysURL = tmp.appendingPathComponent("system.m4a")
        let outURL = tmp.appendingPathComponent("audio.m4a")

        // Mic: 2s of silence.
        try writeAACPCM(to: micURL, sampleRate: 48000, duration: 2.0) { ptr, frames, sr in
            for i in 0..<frames { ptr[i] = 0 }
        }
        // System: 2s silence + 3s of 0.5-amplitude 440Hz tone (total 5s).
        try writeAACPCM(to: sysURL, sampleRate: 48000, duration: 5.0) { ptr, frames, sr in
            for i in 0..<frames {
                let t = Double(i) / Double(sr)
                if t < 2.0 {
                    ptr[i] = 0
                } else {
                    ptr[i] = Float(0.5 * sin(2 * .pi * 440 * t))
                }
            }
        }

        try await AudioFinalizer.finalize(mic: micURL, system: sysURL, output: outURL, sampleRate: 48000)

        let asset = AVURLAsset(url: outURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        XCTAssertGreaterThan(seconds, 4.0, "longer side (5s) should survive; got \(seconds)s")
        XCTAssertLessThan(seconds, 6.0)

        // Read tail (last 1 second) — should have audible RMS, ≥ ~0.1
        // even after AAC compression.
        let outFile = try AVAudioFile(forReading: outURL)
        let format = outFile.processingFormat
        let total = AVAudioFrameCount(outFile.length)
        XCTAssertGreaterThan(total, AVAudioFrameCount(4 * 48000))
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total)!
        try outFile.read(into: buf)

        let tailFrames = 48000  // last 1 second
        let tailStart = Int(buf.frameLength) - tailFrames
        let ptr = buf.floatChannelData![0]
        var sumSq: Double = 0
        for i in tailStart..<Int(buf.frameLength) {
            let v = Double(ptr[i])
            sumSq += v * v
        }
        let rms = sqrt(sumSq / Double(tailFrames))
        XCTAssertGreaterThan(rms, 0.1, "tail (sys-only, single-active) should retain tone; RMS=\(rms) — finalizer may be attenuating single-active or writing wrong side")
    }

    func testStreamingMemoryStaysBoundedAt90s() async throws {
        // Codex P2: the v0 memory test only measured elapsed time. A
        // regression to whole-file reads on a 30s fixture would still
        // pass. Bump to a 90s fixture and sample resident size.
        //
        // 90s @ 48kHz mono float32 = ~17MB per stream raw, ~34MB both.
        // v0 in-memory finalizer would peak well above that during mix.
        // Streaming should add <30MB delta (chunk buffers + AAC encoder
        // state). Threshold tuned: tight enough to catch a regression to
        // whole-file reads, loose enough to absorb encoder/foundation
        // overhead and the test runner's own jitter.
        let micURL = tmp.appendingPathComponent("mic.m4a")
        let sysURL = tmp.appendingPathComponent("system.m4a")
        let outURL = tmp.appendingPathComponent("audio.m4a")
        try writeAACSilence(to: micURL, durationSec: 90.0)
        try writeAACSilence(to: sysURL, durationSec: 90.0)

        // Allow a settle moment before sampling baseline.
        try await Task.sleep(nanoseconds: 100_000_000)
        let baseline = readResidentBytes()
        let sampler = PeakSampler(baseline: baseline)

        let pollTask = Task<Void, Never> {
            while !Task.isCancelled {
                await sampler.sample(readResidentBytes())
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        try await AudioFinalizer.finalize(mic: micURL, system: sysURL, output: outURL, sampleRate: 48000)
        pollTask.cancel()

        let peak = await sampler.peak
        let delta = peak - baseline
        let mb = delta / (1024 * 1024)
        XCTAssertLessThan(delta, 80 * 1024 * 1024, "streaming finalize on 90s fixture peaked at \(mb) MB above baseline — likely regressed to whole-file reads")
    }

    func testStreamingRejectsShortBackpressureTimeout() async throws {
        // Codex P1: the polling loop must give up if the writer wedges.
        // We can't easily wedge a real AVAssetWriter from a test, but we
        // CAN configure an absurdly short backpressure timeout on a real
        // run and prove the finalizer either succeeds quickly or surfaces
        // the timeout — never hangs forever. The 1s budget is far smaller
        // than the 30s default, but real synthetic finalize is sub-second
        // so this should still pass cleanly.
        let micURL = tmp.appendingPathComponent("mic.m4a")
        let sysURL = tmp.appendingPathComponent("system.m4a")
        let outURL = tmp.appendingPathComponent("audio.m4a")
        try writeAACSilence(to: micURL, durationSec: 0.5)
        try writeAACSilence(to: sysURL, durationSec: 0.5)

        let opts = AudioFinalizer.Options(backpressureTimeout: 1.0)
        try await AudioFinalizer.finalize(mic: micURL, system: sysURL, output: outURL, sampleRate: 48000, options: opts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
    }

    func testStreamingHonorsCustomChunkFrames() async throws {
        // Codex P2: chunkFrames must be test-overridable so partial-EOF
        // boundary cases can be exercised without 30s+ fixtures. Force a
        // tiny 480-frame (10ms) chunk on a 0.5s input → 50 chunks. If the
        // converter callback regression resurfaces, this catches it
        // because every chunk would be a partial pull.
        let micURL = tmp.appendingPathComponent("mic.m4a")
        let sysURL = tmp.appendingPathComponent("system.m4a")
        let outURL = tmp.appendingPathComponent("audio.m4a")
        try writeAACSilence(to: micURL, durationSec: 0.5)
        try writeAACSilence(to: sysURL, durationSec: 0.5)

        let opts = AudioFinalizer.Options(chunkFrames: 480)
        try await AudioFinalizer.finalize(mic: micURL, system: sysURL, output: outURL, sampleRate: 48000, options: opts)

        let asset = AVURLAsset(url: outURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        XCTAssertGreaterThan(seconds, 0.4)
        XCTAssertLessThan(seconds, 0.7)
    }

    func testStreamingFailureLeavesExistingOutputIntact() async throws {
        // Codex P1: prior `try? removeItem(at: output)` at the top of
        // finalize would clobber a previously good audio.m4a even if the
        // current run failed. New code writes to a sibling .inflight temp
        // and only moves it into place after finishWriting succeeds.
        // Simulate a failure by passing a non-existent mic path — we
        // expect the existing output to survive untouched.
        let outURL = tmp.appendingPathComponent("audio.m4a")
        let goodBytes = "PRIOR_GOOD_RUN".data(using: .utf8)!
        try goodBytes.write(to: outURL)

        let badMic = tmp.appendingPathComponent("nonexistent-mic.m4a")
        let sysURL = tmp.appendingPathComponent("system.m4a")
        try writeAACSilence(to: sysURL, durationSec: 0.5)

        do {
            try await AudioFinalizer.finalize(mic: badMic, system: sysURL, output: outURL, sampleRate: 48000)
            XCTFail("expected finalize to throw on missing mic file")
        } catch {
            // expected
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path), "previous good output must survive a failed retry")
        let surviving = try Data(contentsOf: outURL)
        XCTAssertEqual(surviving, goodBytes, "previous good output must not be overwritten by a failed retry")
    }


    func testPTSTimelinePreservesInterBufferGap() async throws {
        let micURL = tmp.appendingPathComponent("mic-gap.m4a")
        let sysURL = tmp.appendingPathComponent("system-gap.m4a")
        let ptsURL = tmp.appendingPathComponent("pts-gap.jsonl")
        let outURL = tmp.appendingPathComponent("audio-gap.m4a")
        try writeAACPCM(to: micURL, sampleRate: 48000, duration: 0.2) { ptr, frames, _ in
            for i in 0..<frames { ptr[i] = Float(0.45 * sin(2 * .pi * 440 * Double(i) / 48000.0)) }
        }
        try writeAACSilence(to: sysURL, durationSec: 0.2)
        try writePTSLog(to: ptsURL, entries: [
            PTSLogEntry(stream: "mic", ptsSeconds: 0.0, sampleCount: 4800, sampleRate: 48000),
            PTSLogEntry(stream: "mic", ptsSeconds: 0.3, sampleCount: 4800, sampleRate: 48000),
            PTSLogEntry(stream: "system", ptsSeconds: 0.0, sampleCount: 4800, sampleRate: 48000),
            PTSLogEntry(stream: "system", ptsSeconds: 0.3, sampleCount: 4800, sampleRate: 48000)
        ])

        try await AudioFinalizer.finalize(mic: micURL, system: sysURL, output: outURL, sampleRate: 48000, ptsLogURL: ptsURL)

        let samples = try readSamples(from: outURL)
        XCTAssertGreaterThan(samples.count, 18_000)
        XCTAssertGreaterThan(rms(samples, start: 1_000, count: 2_000), 0.05)
        XCTAssertLessThan(rms(samples, start: 6_000, count: 6_000), 0.02, "200ms logged PTS gap should remain silent instead of compressed")
        XCTAssertGreaterThan(rms(samples, start: 15_000, count: 2_000), 0.05, "second chunk should begin after the logged gap")
    }

    func testPTSTimelineHonorsSubChunkOffset() async throws {
        let micURL = tmp.appendingPathComponent("mic-offset.m4a")
        let sysURL = tmp.appendingPathComponent("system-offset.m4a")
        let ptsURL = tmp.appendingPathComponent("pts-offset.jsonl")
        let outURL = tmp.appendingPathComponent("audio-offset.m4a")
        try writeAACSilence(to: micURL, durationSec: 0.1)
        try writeAACPCM(to: sysURL, sampleRate: 48000, duration: 0.1) { ptr, frames, _ in
            for i in 0..<frames { ptr[i] = Float(0.5 * sin(2 * .pi * 880 * Double(i) / 48000.0)) }
        }
        try writePTSLog(to: ptsURL, entries: [
            PTSLogEntry(stream: "mic", ptsSeconds: 0.0, sampleCount: 4800, sampleRate: 48000),
            PTSLogEntry(stream: "system", ptsSeconds: 0.05, sampleCount: 4800, sampleRate: 48000)
        ])

        try await AudioFinalizer.finalize(mic: micURL, system: sysURL, output: outURL, sampleRate: 48000, ptsLogURL: ptsURL, options: .init(chunkFrames: 4800))

        let samples = try readSamples(from: outURL)
        let firstEnergy = firstFrameAboveEnergy(samples, threshold: 0.03) ?? -1
        XCTAssertGreaterThanOrEqual(firstEnergy, 2_000)
        XCTAssertLessThan(firstEnergy, 3_200, "50ms offset should land near frame 2400, not rounded to one 4800-frame chunk; got \(firstEnergy)")
    }

    func testMalformedMiddlePTSLogThrowsAndPreservesExistingOutput() async throws {
        let micURL = tmp.appendingPathComponent("mic-corrupt.m4a")
        let sysURL = tmp.appendingPathComponent("system-corrupt.m4a")
        let ptsURL = tmp.appendingPathComponent("pts-corrupt.jsonl")
        let outURL = tmp.appendingPathComponent("audio-corrupt.m4a")
        let previous = Data("previous audio".utf8)
        try previous.write(to: outURL)
        try writeAACSilence(to: micURL, durationSec: 0.1)
        try writeAACSilence(to: sysURL, durationSec: 0.1)
        let valid = try JSONEncoder().encode(PTSLogEntry(stream: "mic", ptsSeconds: 0, sampleCount: 4800, sampleRate: 48000))
        var text = String(data: valid, encoding: .utf8)! + "\n"
        text += "{ malformed middle line\n"
        text += String(data: valid, encoding: .utf8)! + "\n"
        try text.write(to: ptsURL, atomically: true, encoding: .utf8)

        do {
            try await AudioFinalizer.finalize(mic: micURL, system: sysURL, output: outURL, sampleRate: 48000, ptsLogURL: ptsURL)
            XCTFail("expected malformed middle PTS log to fail")
        } catch AudioFinalizer.FinalizeError.invalidPTSLog {
            // expected
        } catch {
            XCTFail("expected invalidPTSLog, got \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: outURL), previous)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmp.path).filter { $0.contains(".inflight-") }
        XCTAssertTrue(leftovers.isEmpty, "failed PTS parse should not leave inflight temp files: \(leftovers)")
    }

    // MARK: - fixtures


    private func writePTSLog(to url: URL, entries: [PTSLogEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = try entries.map { entry -> String in
            let data = try encoder.encode(entry)
            return String(data: data, encoding: .utf8)!
        }.joined(separator: "\n") + "\n"
        try lines.write(to: url, atomically: true, encoding: .utf8)
    }

    private func readSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let ptr = buffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: ptr, count: Int(buffer.frameLength)))
    }

    private func rms(_ samples: [Float], start: Int, count: Int) -> Double {
        guard start < samples.count else { return 0 }
        let end = min(samples.count, start + count)
        guard end > start else { return 0 }
        let sum = samples[start..<end].reduce(0.0) { $0 + Double($1 * $1) }
        return sqrt(sum / Double(end - start))
    }

    private func firstFrameAboveEnergy(_ samples: [Float], threshold: Float) -> Int? {
        for (index, sample) in samples.enumerated() where abs(sample) > threshold {
            return index
        }
        return nil
    }

    private func writeAACSilence(to url: URL, durationSec: Double, sampleRate: Double = 48000) throws {
        try writeAACPCM(to: url, sampleRate: sampleRate, duration: durationSec) { ptr, frames, _ in
            for i in 0..<frames { ptr[i] = 0 }
        }
    }

    /// Writes a mono AAC m4a where each sample is set by `fill`.
    private func writeAACPCM(
        to url: URL,
        sampleRate: Double,
        duration: Double,
        fill: (UnsafeMutablePointer<Float>, Int, Double) -> Void
    ) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        // Bitrate intentionally omitted — AAC's valid range depends on
        // sample rate, and a fixed 64_000 errors at 16 kHz with
        // kAudioCodecBadPropertySizeError. Default lets the encoder pick.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let ptr = buffer.floatChannelData?[0] {
            fill(ptr, Int(frames), sampleRate)
        }
        try file.write(from: buffer)
    }

    private func currentResidentBytes() -> Int {
        readResidentBytes()
    }
}

/// File-private free function so a `Task` polling closure does not have to
/// capture `XCTestCase` self (which isn't Sendable).
fileprivate func readResidentBytes() -> Int {
    var info = mach_task_basic_info()
    let stride = MemoryLayout<integer_t>.stride
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / stride)
    let result = withUnsafeMutablePointer(to: &info) { infoPtr -> kern_return_t in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), ptr, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size) : 0
}

private actor PeakSampler {
    let baseline: Int
    private(set) var peak: Int

    init(baseline: Int) {
        self.baseline = baseline
        self.peak = baseline
    }

    func sample(_ now: Int) {
        if now > peak { peak = now }
    }
}
