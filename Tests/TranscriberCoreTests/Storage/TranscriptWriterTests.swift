import XCTest
@testable import TranscriberCore

final class TranscriptWriterTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    func testStubWrittenWithStatusPending() throws {
        let url = tmp.appendingPathComponent("transcript.md")
        let context = TranscriptContext(
            title: "Test",
            date: "2026-04-29",
            engine: "elevenlabs",
            audioRelativePaths: ["audio.m4a"],
            startedAt: "2026-04-29T14:30:00Z",
            endedAt: "2026-04-29T15:00:00Z",
            attendees: ["[[Szymon]]", "[[Faris]]"],
            language: nil
        )

        try TranscriptWriter.writePending(at: url, context: context)
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("status: pending"))
        XCTAssertTrue(content.contains("title: \"Test\""))
        XCTAssertTrue(content.contains("audio: audio.m4a"))
        XCTAssertTrue(content.contains("# Test"))
    }

    func testCompleteOverwritesWithBody() throws {
        let url = tmp.appendingPathComponent("transcript.md")
        let context = TranscriptContext(
            title: "Faris Sync", date: "2026-04-29",
            engine: "elevenlabs", audioRelativePaths: ["audio.m4a"],
            startedAt: "2026-04-29T14:30:00Z", endedAt: "2026-04-29T15:00:00Z",
            attendees: ["[[Szymon Sypniewicz]]", "[[Faris Riaz]]"],
            language: "en"
        )
        try TranscriptWriter.writePending(at: url, context: context)

        let utterances = [
            EngineResponse.Utterance(speaker: "speaker_0", startSeconds: 0, endSeconds: 1, text: "Hi"),
            EngineResponse.Utterance(speaker: "speaker_1", startSeconds: 1, endSeconds: 2, text: "Hello")
        ]
        let mapping = ["speaker_0": "Szymon Sypniewicz", "speaker_1": "Faris Riaz"]
        try TranscriptWriter.writeComplete(at: url, context: context, utterances: utterances, speakerMapping: mapping)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("status: complete"))
        XCTAssertTrue(content.contains("language: en"))
        XCTAssertTrue(content.contains("**Szymon Sypniewicz** [00:00]: Hi"))
        XCTAssertTrue(content.contains("**Faris Riaz** [00:01]: Hello"))
    }

    func testFailedTranscriptStillValid() throws {
        let url = tmp.appendingPathComponent("transcript.md")
        let context = TranscriptContext(
            title: "T", date: "2026-04-29", engine: "elevenlabs",
            audioRelativePaths: ["audio.m4a"],
            startedAt: "2026-04-29T14:30:00Z", endedAt: "2026-04-29T15:00:00Z",
            attendees: [], language: nil
        )
        try TranscriptWriter.writePending(at: url, context: context)
        try TranscriptWriter.writeFailed(at: url, context: context, errorMessage: "Rate limited after 3 retries")

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("status: failed"))
        XCTAssertTrue(content.contains("Rate limited after 3 retries"))
        XCTAssertTrue(content.contains("Audio was captured and saved as `audio.m4a`."))
    }

    /// CDX-S2.1: when capture produces multiple source tracks (mic + system),
    /// the transcript must reference all of them so users can find every audio
    /// asset, not just the primary one.
    func testMultipleAudioPathsRenderAsYAMLList() throws {
        let url = tmp.appendingPathComponent("transcript.md")
        let context = TranscriptContext(
            title: "Two-Track Sync", date: "2026-04-29",
            engine: "elevenlabs",
            audioRelativePaths: ["mic.m4a", "system.m4a"],
            startedAt: "2026-04-29T14:30:00Z", endedAt: "2026-04-29T15:00:00Z",
            attendees: [], language: nil
        )

        try TranscriptWriter.writePending(at: url, context: context)
        let pending = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(pending.contains("audio:\n  - mic.m4a\n  - system.m4a"))
        XCTAssertTrue(pending.contains("`mic.m4a` and `system.m4a`"))

        try TranscriptWriter.writeFailed(at: url, context: context, errorMessage: "boom")
        let failed = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(failed.contains("Audio was captured and saved as `mic.m4a` and `system.m4a`."))
    }
}
