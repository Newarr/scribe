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
            attendees: [TranscriptPerson(name: "Szymon"), TranscriptPerson(name: "Faris")],
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
        XCTAssertEqual(decoded.actual_start, "2026-04-29T14:30:00Z")
        XCTAssertEqual(decoded.actual_end, "2026-04-29T15:00:00Z")
        XCTAssertEqual(decoded.attendees, [TranscriptPerson(name: "Szymon"), TranscriptPerson(name: "Faris")])
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


    func testFailedMetadataAudioReferencesMatchTranscript() throws {
        let noAudio = TranscriptContext(
            title: "No audio",
            date: "2026-05-20",
            engine: "elevenlabs",
            audioRelativePaths: [],
            startedAt: "2026-05-20T10:00:00Z",
            endedAt: "2026-05-20T10:05:00Z",
            attendees: [],
            language: nil
        )
        XCTAssertEqual(MetadataJSONWriter.primaryAudioReference(context: noAudio), "")
        let noAudioMetadata = MetadataJSONWriter.Metadata(
            status: .failed,
            context: noAudio,
            audio: MetadataJSONWriter.primaryAudioReference(context: noAudio)
        )
        XCTAssertEqual(noAudioMetadata.audio, "")

        let oneSided = TranscriptContext(
            title: "One sided",
            date: "2026-05-20",
            engine: "cohere",
            audioRelativePaths: ["system.m4a"],
            startedAt: "2026-05-20T10:00:00Z",
            endedAt: "2026-05-20T10:05:00Z",
            attendees: [],
            language: nil
        )
        let oneSidedMetadata = MetadataJSONWriter.Metadata(
            status: .failed,
            context: oneSided,
            audio: MetadataJSONWriter.primaryAudioReference(context: oneSided)
        )
        XCTAssertEqual(oneSidedMetadata.audio, "system.m4a")
    }

    func testFailedMetadataIncludesFailureDetails() throws {
        let details = TranscriptFailureDetails(
            errorCode: "elevenlabs_timeout",
            errorMessage: "Job did not complete within 90s",
            retryCount: 2,
            attemptCount: 3,
            audioDurationSeconds: 3291,
            audioSizeBytes: 52_840_192
        )
        let metadata = MetadataJSONWriter.Metadata(
            status: .failed,
            context: makeContext(),
            audio: "audio.m4a",
            failureDetails: details
        )
        XCTAssertEqual(metadata.error_code, "elevenlabs_timeout")
        XCTAssertEqual(metadata.error_message, "Job did not complete within 90s")
        XCTAssertEqual(metadata.retry_count, 2)
        XCTAssertEqual(metadata.attempt_count, 3)
        XCTAssertEqual(metadata.audio_duration_seconds, 3291)
        XCTAssertEqual(metadata.audio_size_bytes, 52_840_192)
    }


    func testFailedMetadataUsesSharedSignedURLTokenRedaction() throws {
        let details = TranscriptFailureDetails(
            errorCode: "provider_error",
            errorMessage: "GET https://cdn.example.com/private/audio.m4a?signature=SECRET&token=abc failed for /Users/alice/Scribe/audio.m4a; Authorization=Bearer super-secret",
            retryCount: 3,
            attemptCount: 4,
            audioDurationSeconds: nil,
            audioSizeBytes: nil
        )
        let metadata = MetadataJSONWriter.Metadata(
            status: .failed,
            context: makeContext(),
            audio: "audio.m4a",
            failureDetails: details
        )
        let encoded = String(data: try JSONEncoder().encode(metadata), encoding: .utf8) ?? ""
        XCTAssertEqual(metadata.error_message, PersistedErrorRedactor.redact("GET https://cdn.example.com/private/audio.m4a?signature=SECRET&token=abc failed for /Users/alice/Scribe/audio.m4a; Authorization=Bearer super-secret"))
        XCTAssertFalse(encoded.contains("cdn.example.com"), encoded)
        XCTAssertFalse(encoded.contains("signature=SECRET"), encoded)
        XCTAssertFalse(encoded.contains("token=abc"), encoded)
        XCTAssertFalse(encoded.contains("/Users/alice"), encoded)
        XCTAssertFalse(encoded.contains("super-secret"), encoded)
        XCTAssertEqual(metadata.retry_count, 3)
        XCTAssertEqual(metadata.attempt_count, 4)
    }


    /// VAL-STORAGE-004: standalone sk_-prefixed token must be redacted from
    /// persisted metadata.json failure details.
    func testFailedMetadataRedactsStandaloneSkPrefixedToken() throws {
        let raw = "ElevenLabs returned 401. xi-api-key: sk_TEST-API-KEY-SENTINEL was rejected."
        let details = TranscriptFailureDetails(
            errorCode: "unauthorized",
            errorMessage: raw,
            retryCount: 0,
            attemptCount: 1,
            audioDurationSeconds: nil,
            audioSizeBytes: nil
        )
        let metadata = MetadataJSONWriter.Metadata(
            status: .failed,
            context: makeContext(),
            audio: "audio.m4a",
            failureDetails: details
        )
        let encoded = String(data: try JSONEncoder().encode(metadata), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("sk_TEST"), "sk_ token must be redacted from metadata: \(encoded)")
        XCTAssertFalse(encoded.contains("SENTINEL"), "sk_ token value must be redacted: \(encoded)")
        XCTAssertTrue((metadata.error_message ?? "").contains("[redacted]"),
                      "redacted marker must appear in error_message: \(metadata.error_message ?? "")")
    }

    func testFailedMetadataRedactsAuthorizationBearerHeaderFormsBeforeGenericKeyValueRedaction() throws {
        let raw = "Provider returned Authorization=Bearer abc123 and Authorization: Bearer def456 plus bearer ghi789 and X-API-Key = jkl012"
        let details = TranscriptFailureDetails(
            errorCode: "provider_error",
            errorMessage: raw,
            retryCount: 1,
            attemptCount: 2,
            audioDurationSeconds: nil,
            audioSizeBytes: nil
        )
        let metadata = MetadataJSONWriter.Metadata(
            status: .failed,
            context: makeContext(),
            audio: "audio.m4a",
            failureDetails: details
        )
        let encoded = String(data: try JSONEncoder().encode(metadata), encoding: .utf8) ?? ""
        XCTAssertTrue((metadata.error_message ?? "").contains("Authorization: Bearer [redacted]"), metadata.error_message ?? "")
        XCTAssertFalse(encoded.contains("abc123"), encoded)
        XCTAssertFalse(encoded.contains("def456"), encoded)
        XCTAssertFalse(encoded.contains("ghi789"), encoded)
        XCTAssertFalse(encoded.contains("jkl012"), encoded)
    }

}
