import XCTest
import CoreMedia
@testable import TranscriberCore

final class PTSCollectorTests: XCTestCase {
    func testAccumulatesFirstPTSAndFrameCount() {
        let collector = PTSCollector()

        let buf1 = SyntheticSampleBuffer.make(
            ptsSeconds: 100.0, sampleRate: 48000, channelCount: 1, frameCount: 480
        )
        let buf2 = SyntheticSampleBuffer.make(
            ptsSeconds: 100.01, sampleRate: 48000, channelCount: 1, frameCount: 480
        )

        collector.observe(.mic, buffer: buf1)
        collector.observe(.mic, buffer: buf2)

        let snapshot = collector.snapshot()
        XCTAssertEqual(snapshot.mic.firstPTSSeconds, 100.0, accuracy: 1e-6)
        XCTAssertEqual(snapshot.mic.sampleRate, 48000)
        XCTAssertEqual(snapshot.mic.channelCount, 1)
        XCTAssertEqual(snapshot.mic.frameCount, 960)
    }

    func testAcceptsBothStreamsIndependently() {
        let collector = PTSCollector()
        let micBuf = SyntheticSampleBuffer.make(ptsSeconds: 50.0, sampleRate: 48000, channelCount: 1, frameCount: 1000)
        let sysBuf = SyntheticSampleBuffer.make(ptsSeconds: 50.005, sampleRate: 48000, channelCount: 1, frameCount: 2000)
        collector.observe(.mic, buffer: micBuf)
        collector.observe(.system, buffer: sysBuf)

        let snap = collector.snapshot()
        XCTAssertEqual(snap.mic.frameCount, 1000)
        XCTAssertEqual(snap.system.frameCount, 2000)
        XCTAssertEqual(snap.systemLeadInMicSamples, 240) // 5ms at 48kHz
    }

    func testWritesSidecarJSON() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let collector = PTSCollector()
        collector.observe(.mic, buffer: SyntheticSampleBuffer.make(
            ptsSeconds: 0, sampleRate: 48000, channelCount: 1, frameCount: 100
        ))
        collector.observe(.system, buffer: SyntheticSampleBuffer.make(
            ptsSeconds: 0.001, sampleRate: 48000, channelCount: 1, frameCount: 200
        ))

        try collector.writeSidecar(to: tmp)
        let data = try Data(contentsOf: tmp)
        let decoded = try JSONDecoder().decode(PTSMetadata.self, from: data)
        XCTAssertEqual(decoded.mic.frameCount, 100)
        XCTAssertEqual(decoded.system.frameCount, 200)
    }

    // MARK: - per-buffer streaming log (Phase β)

    func testStreamingLogPersistsEveryBuffer() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pts.jsonl")
        defer { try? FileManager.default.removeItem(at: log) }

        let collector = PTSCollector(streamingLogURL: log)
        collector.observe(.mic, buffer: SyntheticSampleBuffer.make(
            ptsSeconds: 0.0, sampleRate: 48000, channelCount: 1, frameCount: 480
        ))
        collector.observe(.mic, buffer: SyntheticSampleBuffer.make(
            ptsSeconds: 0.01, sampleRate: 48000, channelCount: 1, frameCount: 480
        ))
        collector.observe(.system, buffer: SyntheticSampleBuffer.make(
            ptsSeconds: 0.005, sampleRate: 48000, channelCount: 1, frameCount: 480
        ))

        let entries = try collector.loggedEntries()
        XCTAssertEqual(entries.count, 3, "every observe() must persist exactly one log line")

        // Order is ingest-order; mic+mic+system above.
        XCTAssertEqual(entries[0].stream, "mic")
        XCTAssertEqual(entries[0].sampleCount, 480)
        XCTAssertEqual(entries[0].ptsSeconds, 0.0, accuracy: 1e-6)
        XCTAssertEqual(entries[1].ptsSeconds, 0.01, accuracy: 1e-6)
        XCTAssertEqual(entries[2].stream, "system")
        XCTAssertEqual(entries[2].ptsSeconds, 0.005, accuracy: 1e-6)
    }

    func testGapInPTSShowsUpInLog() throws {
        // The streaming finalize pipeline (Phase ε) detects gaps by walking
        // the JSONL — pause + resume capture must leave a discoverable gap.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pts.jsonl")
        defer { try? FileManager.default.removeItem(at: log) }

        let collector = PTSCollector(streamingLogURL: log)
        collector.observe(.mic, buffer: SyntheticSampleBuffer.make(
            ptsSeconds: 0.0, sampleRate: 48000, channelCount: 1, frameCount: 480
        ))
        // 200ms gap.
        collector.observe(.mic, buffer: SyntheticSampleBuffer.make(
            ptsSeconds: 0.21, sampleRate: 48000, channelCount: 1, frameCount: 480
        ))

        let entries = try collector.loggedEntries()
        XCTAssertEqual(entries.count, 2)
        let gapSeconds = entries[1].ptsSeconds - (entries[0].ptsSeconds + Double(entries[0].sampleCount) / Double(entries[0].sampleRate))
        XCTAssertEqual(gapSeconds, 0.2, accuracy: 0.001,
                       "200ms gap must be reconstructible from per-buffer entries; AEC + streaming mix both depend on this")
    }


    func testLoggedEntriesDuringCaptureDoesNotStopFutureLogging() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pts.jsonl")
        defer { try? FileManager.default.removeItem(at: log) }

        let collector = PTSCollector(streamingLogURL: log)
        collector.observe(.mic, buffer: SyntheticSampleBuffer.make(
            ptsSeconds: 0.0, sampleRate: 48000, channelCount: 1, frameCount: 480
        ))

        let firstRead = try collector.loggedEntries()
        XCTAssertEqual(firstRead.map(\.ptsSeconds), [0.0])

        collector.observe(.system, buffer: SyntheticSampleBuffer.make(
            ptsSeconds: 0.015, sampleRate: 48000, channelCount: 1, frameCount: 960
        ))

        let secondRead = try collector.loggedEntries()
        XCTAssertEqual(secondRead.count, 2)
        XCTAssertEqual(secondRead[0].stream, "mic")
        XCTAssertEqual(secondRead[0].ptsSeconds, 0.0, accuracy: 1e-6)
        XCTAssertEqual(secondRead[1].stream, "system")
        XCTAssertEqual(secondRead[1].ptsSeconds, 0.015, accuracy: 1e-6)
        XCTAssertEqual(secondRead[1].sampleCount, 960)
        XCTAssertEqual(secondRead[1].sampleRate, 48000)
    }

    func testFlushLogIsIdempotentAndPersistsQueuedEntries() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pts.jsonl")
        defer { try? FileManager.default.removeItem(at: log) }

        let collector = PTSCollector(streamingLogURL: log)
        for index in 0..<50 {
            let stream: PTSCollector.StreamID = index.isMultiple(of: 2) ? .mic : .system
            collector.observe(stream, buffer: SyntheticSampleBuffer.make(
                ptsSeconds: Double(index) * 0.01, sampleRate: 48000, channelCount: 1, frameCount: 480
            ))
        }

        collector.flushLog()
        collector.flushLog()

        let entries = try collector.loggedEntries()
        XCTAssertEqual(entries.count, 50)
        XCTAssertEqual(entries.first?.stream, "mic")
        XCTAssertEqual(entries.last?.stream, "system")
        XCTAssertEqual(entries.last?.ptsSeconds ?? -1, 0.49, accuracy: 1e-6)
        XCTAssertEqual(entries.allSatisfy { $0.sampleCount == 480 && $0.sampleRate == 48000 }, true)
    }

    func testNilLogURLDisablesStreamingLog() throws {
        let collector = PTSCollector(streamingLogURL: nil)
        collector.observe(.mic, buffer: SyntheticSampleBuffer.make(
            ptsSeconds: 0, sampleRate: 48000, channelCount: 1, frameCount: 100
        ))
        XCTAssertEqual(try collector.loggedEntries(), [],
                       "tests that don't care about the JSONL must opt out cleanly")
    }

    func testTruncatedTrailingLineToleratedOnRead() throws {
        // Codex Phase β review P1.6: a kill mid-write can leave a partial
        // trailing JSONL line. The recovery path must not throw on that
        // (otherwise SessionSupervisor can't read what little PTS data
        // survived).
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pts.jsonl")
        defer { try? FileManager.default.removeItem(at: log) }

        // Write two valid lines + one truncated trailing line.
        let validA = #"{"ptsSeconds":0.0,"sampleCount":480,"sampleRate":48000,"stream":"mic"}"# + "\n"
        let validB = #"{"ptsSeconds":0.01,"sampleCount":480,"sampleRate":48000,"stream":"mic"}"# + "\n"
        let truncated = #"{"ptsSeconds":0.02,"sampleCo"#  // No newline, no closing brace.
        try (validA + validB + truncated).write(to: log, atomically: true, encoding: .utf8)

        let collector = PTSCollector(streamingLogURL: log)
        let entries = try collector.loggedEntries()
        XCTAssertEqual(entries.count, 2,
                       "valid lines must be readable; trailing truncation tolerated")
        XCTAssertEqual(entries[0].ptsSeconds, 0.0, accuracy: 1e-6)
    }

    func testMidLineCorruptionStillThrows() throws {
        // Codex Phase β review P1.6: only the TRAILING line can be
        // truncated. Bad data in the middle of the log is real corruption
        // and recovery should refuse to silently skip it.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pts.jsonl")
        defer { try? FileManager.default.removeItem(at: log) }

        let validA = #"{"ptsSeconds":0.0,"sampleCount":480,"sampleRate":48000,"stream":"mic"}"# + "\n"
        let mid = "{not-json}\n"
        let validB = #"{"ptsSeconds":0.01,"sampleCount":480,"sampleRate":48000,"stream":"mic"}"# + "\n"
        try (validA + mid + validB).write(to: log, atomically: true, encoding: .utf8)

        let collector = PTSCollector(streamingLogURL: log)
        XCTAssertThrowsError(try collector.loggedEntries(),
                             "mid-line corruption is real, not a kill artifact; must surface")
    }
}
