import XCTest
@testable import TranscriberCore

final class MetadataJSONWriterTests: XCTestCase {
    private func makeContext(language: String? = "en") -> TranscriptContext {
        TranscriptContext(
            title: "Faris 1:1",
            date: "2026-04-29",
            engine: "elevenlabs",
            audioRelativePaths: ["audio.m4a"],
            startedAt: "2026-04-29T14:30:00Z",
            endedAt: "2026-04-29T15:00:00Z",
            attendees: ["[[Szymon]]", "[[Faris]]"],
            language: language
        )
    }

    func testRoundTripPreservesAllFields() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let metadata = MetadataJSONWriter.Metadata(
            status: .complete,
            context: makeContext(),
            audio: "audio.m4a"
        )
        try MetadataJSONWriter.write(at: tmp, metadata: metadata)

        let decoded = try JSONDecoder().decode(MetadataJSONWriter.Metadata.self, from: Data(contentsOf: tmp))
        XCTAssertEqual(decoded, metadata)
        XCTAssertEqual(decoded.schema, "transcriber/v1")
        XCTAssertEqual(decoded.status, "complete")
        XCTAssertEqual(decoded.audio, "audio.m4a")
        XCTAssertEqual(decoded.attendees, ["[[Szymon]]", "[[Faris]]"])
        XCTAssertEqual(decoded.language, "en")
    }

    func testNoLanguageOmittedFromJSON() throws {
        let metadata = MetadataJSONWriter.Metadata(
            status: .pending,
            context: makeContext(language: nil),
            audio: "audio.m4a"
        )
        let data = try JSONEncoder().encode(metadata)
        let json = String(data: data, encoding: .utf8) ?? ""
        // JSONEncoder default: nil Optional fields are dropped from the
        // output. Decoder side reads missing as nil so the round-trip is
        // lossless either way.
        XCTAssertFalse(json.contains("\"language\""), "nil language should be omitted, got: \(json)")

        let decoded = try JSONDecoder().decode(MetadataJSONWriter.Metadata.self, from: data)
        XCTAssertNil(decoded.language)
    }
}
