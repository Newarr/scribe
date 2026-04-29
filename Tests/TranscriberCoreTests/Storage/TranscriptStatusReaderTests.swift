import XCTest
@testable import TranscriberCore

final class TranscriptStatusReaderTests: XCTestCase {
    func testParsesPending() {
        let md = """
        ---
        schema: transcriber/v1
        status: pending
        title: "Test"
        ---

        # Test
        """
        XCTAssertEqual(TranscriptStatusReader.readFromString(md), .pending)
    }

    func testParsesAllStatuses() {
        for status in [TranscriptStatus.pending, .retrying, .complete, .failed] {
            let md = "---\nstatus: \(status.rawValue)\n---\n\nbody"
            XCTAssertEqual(TranscriptStatusReader.readFromString(md), status, "for \(status.rawValue)")
        }
    }

    func testReturnsNilForMissingFrontmatter() {
        XCTAssertNil(TranscriptStatusReader.readFromString("# Body only, no frontmatter"))
    }

    func testReturnsNilForUnterminatedFrontmatter() {
        XCTAssertNil(TranscriptStatusReader.readFromString("---\nstatus: pending\nno end marker"))
    }

    func testReturnsNilForUnknownStatus() {
        XCTAssertNil(TranscriptStatusReader.readFromString("---\nstatus: half-baked\n---\n"))
    }

    /// Round-trip: TranscriptWriter.writePending must produce a file the reader
    /// classifies as .pending. Catches drift between writer output and reader input.
    func testWriterOutputIsReadable() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let context = TranscriptContext(
            title: "Round Trip", date: "2026-04-29", engine: "elevenlabs",
            audioRelativePaths: ["mic.m4a"],
            startedAt: "2026-04-29T14:30:00Z", endedAt: "2026-04-29T15:00:00Z",
            attendees: [], language: nil
        )
        try TranscriptWriter.writePending(at: tmp, context: context)
        XCTAssertEqual(TranscriptStatusReader.read(at: tmp), .pending)
    }
}
