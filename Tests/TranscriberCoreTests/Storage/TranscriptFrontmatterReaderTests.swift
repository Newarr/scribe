import XCTest
@testable import TranscriberCore

final class TranscriptFrontmatterReaderTests: XCTestCase {
    func testRoundTripPending() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let context = TranscriptContext(
            title: "1:1 with Faris",
            date: "2026-04-29",
            engine: "elevenlabs",
            audioRelativePaths: ["mic.m4a", "system.m4a"],
            startedAt: "2026-04-29T14:30:00Z",
            endedAt: "2026-04-29T15:00:00Z",
            attendees: ["[[Szymon]]", "[[Faris]]"],
            language: "en"
        )
        try TranscriptWriter.writePending(at: tmp, context: context)

        let parsed = TranscriptFrontmatterReader.read(at: tmp)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.status, .pending)
        XCTAssertEqual(parsed?.context.title, "1:1 with Faris")
        XCTAssertEqual(parsed?.context.audioRelativePaths, ["mic.m4a", "system.m4a"])
        XCTAssertEqual(parsed?.context.attendees, ["[[Szymon]]", "[[Faris]]"])
        XCTAssertEqual(parsed?.context.language, "en")
        XCTAssertEqual(parsed?.attempts, 0)
    }

    func testParsesAttemptsFromRetryingTranscript() {
        // Synthesized retrying transcript matching what TranscriptionWorker.writeRetrying writes.
        let md = """
        ---
        schema: transcriber/v1
        status: retrying
        title: "Faris Sync"
        date: 2026-04-29
        engine: elevenlabs
        audio:
          - mic.m4a
          - system.m4a
        started_at: 2026-04-29T14:30:00Z
        ended_at: 2026-04-29T15:00:00Z
        attempts: 2
        ---

        body
        """
        let parsed = TranscriptFrontmatterReader.readFromString(md)
        XCTAssertEqual(parsed?.status, .retrying)
        XCTAssertEqual(parsed?.attempts, 2)
        XCTAssertEqual(parsed?.context.title, "Faris Sync")
    }

    func testParsesSingleStringAudio() {
        let md = """
        ---
        schema: transcriber/v1
        status: pending
        title: "Single Track"
        date: 2026-04-29
        engine: elevenlabs
        audio: mic.m4a
        started_at: 2026-04-29T14:30:00Z
        ended_at: 2026-04-29T15:00:00Z
        ---

        body
        """
        let parsed = TranscriptFrontmatterReader.readFromString(md)
        XCTAssertEqual(parsed?.context.audioRelativePaths, ["mic.m4a"])
    }

    func testReturnsNilForMalformed() {
        XCTAssertNil(TranscriptFrontmatterReader.readFromString("# no frontmatter"))
        XCTAssertNil(TranscriptFrontmatterReader.readFromString("---\nstatus: pending\nno end"))
        XCTAssertNil(TranscriptFrontmatterReader.readFromString("---\ntitle: missing status\n---"))
    }
}
