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
            attendees: [TranscriptPerson(name: "Szymon"), TranscriptPerson(name: "Faris")],
            language: "en"
        )
        try TranscriptWriter.writePending(at: tmp, context: context)

        let parsed = TranscriptFrontmatterReader.read(at: tmp)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.status, .pending)
        XCTAssertEqual(parsed?.context.title, "1:1 with Faris")
        XCTAssertEqual(parsed?.context.audioRelativePaths, ["mic.m4a", "system.m4a"])
        XCTAssertEqual(parsed?.context.attendees, [TranscriptPerson(name: "Szymon"), TranscriptPerson(name: "Faris")])
        XCTAssertEqual(parsed?.context.language, "en")
        XCTAssertEqual(parsed?.attempts, 0)
    }


    func testWriterEscapedQuotesAndBackslashesRoundTripExactly() throws {
        let context = TranscriptContext(
            title: #"Project "Alpha" \ Beta"#,
            date: "2026-04-29",
            engine: "elevenlabs",
            audioRelativePaths: [#"folder\audio "final".m4a"#, #"system\side "B".m4a"#],
            scheduledStart: "2026-04-29T14:30:00Z",
            scheduledEnd: "2026-04-29T15:00:00Z",
            actualStart: "2026-04-29T14:31:00Z",
            actualEnd: "2026-04-29T15:01:00Z",
            organizer: TranscriptPerson(name: #"Org "Lead" \ Owner"#, email: #"owner+\"test"@example.com"#),
            location: #"Room "A" \ Floor 2"#,
            calendarEventID: #"event\id"quoted""#,
            attendees: [
                TranscriptPerson(name: #"Alice "A" \ Remote"#, email: #"alice+\"qa"@example.com"#),
                TranscriptPerson(name: #"Bob \ Builder "B""#, email: #"bob\team@example.com"#)
            ],
            language: "en"
        )
        let markdown = TranscriptWriter.frontmatter(status: "pending", context: context) + "\n\nbody"

        let parsed = TranscriptFrontmatterReader.readFromString(markdown)
        XCTAssertEqual(parsed?.status, .pending)
        XCTAssertEqual(parsed?.context.title, context.title)
        XCTAssertEqual(parsed?.context.audioRelativePaths, context.audioRelativePaths)
        XCTAssertEqual(parsed?.context.organizer, context.organizer)
        XCTAssertEqual(parsed?.context.location, context.location)
        XCTAssertEqual(parsed?.context.calendarEventID, context.calendarEventID)
        XCTAssertEqual(parsed?.context.attendees, context.attendees)
        XCTAssertEqual(parsed?.context.language, context.language)
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
        XCTAssertEqual(TranscriptFrontmatterReader.readFromString("---\ntitle: success has no status\n---")?.status, .complete)
    }

    // MARK: - readStatusAndAttemptsStreaming

    private func writeTempFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testStreamingParsesValidStatusAndAttempts() throws {
        let url = try writeTempFile("---\nstatus: retrying\nattempts: 2\n---\n\nbody\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = TranscriptFrontmatterReader.readStatusAndAttemptsStreaming(at: url)
        XCTAssertEqual(result?.status, .retrying)
        XCTAssertEqual(result?.attempts, 2)
    }

    func testStreamingStatuslessFrontmatterIsComplete() throws {
        let url = try writeTempFile("---\ntitle: Done\n---\n\nbody\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = TranscriptFrontmatterReader.readStatusAndAttemptsStreaming(at: url)
        XCTAssertEqual(result?.status, .complete)
        XCTAssertEqual(result?.attempts, 0)
    }

    func testStreamingReturnsNilForUnknownStatus() throws {
        let url = try writeTempFile("---\nstatus: half-baked\n---\n\nbody\n")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(TranscriptFrontmatterReader.readStatusAndAttemptsStreaming(at: url))
    }

    func testStreamingReturnsNilForUnterminatedFrontmatter() throws {
        let url = try writeTempFile("---\nstatus: pending\nno end marker\n")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(TranscriptFrontmatterReader.readStatusAndAttemptsStreaming(at: url))
    }
}
