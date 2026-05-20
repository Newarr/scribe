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
            attendees: [TranscriptPerson(name: "Szymon"), TranscriptPerson(name: "Faris")],
            language: nil
        )

        try TranscriptWriter.writePending(at: url, context: context)
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("status: pending"))
        XCTAssertTrue(content.contains("title: \"Test\""))
        XCTAssertTrue(content.contains("audio: \"audio.m4a\""))
        XCTAssertTrue(content.contains("# Test"))
    }

    func testCompleteOverwritesWithBody() throws {
        let url = tmp.appendingPathComponent("transcript.md")
        let context = TranscriptContext(
            title: "Faris Sync", date: "2026-04-29",
            engine: "elevenlabs", audioRelativePaths: ["audio.m4a"],
            startedAt: "2026-04-29T14:30:00Z", endedAt: "2026-04-29T15:00:00Z",
            attendees: [TranscriptPerson(name: "Szymon Sypniewicz"), TranscriptPerson(name: "Faris Riaz")],
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
        XCTAssertFalse(content.contains("status: complete"))
        XCTAssertFalse(content.contains("schema:"))
        XCTAssertTrue(content.contains("language: en"))
        XCTAssertTrue(content.contains("attendees:\n  - name: \"Szymon Sypniewicz\"\n  - name: \"Faris Riaz\""))
        XCTAssertTrue(content.contains("### [00:00:00] Szymon Sypniewicz\n\nHi"))
        XCTAssertTrue(content.contains("### [00:00:01] Faris Riaz\n\nHello"))
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
        // Codex PM-review UX-29: error string is present (for support
        // copy) but no longer leads the body. The user-facing
        // headline is "transcription failed" + "what you can do".
        XCTAssertTrue(content.contains("Rate limited after 3 retries"))
        XCTAssertTrue(content.contains("Audio is saved at `audio.m4a`"))
        XCTAssertTrue(content.contains("error_code: \"transcription_failed\""))
        XCTAssertTrue(content.contains("retry_count: 0"))
        XCTAssertTrue(content.contains("attempt_count: 1"))
        XCTAssertTrue(content.contains("audio_duration_seconds:"))
        XCTAssertTrue(content.contains("audio_size_bytes:"))
        XCTAssertTrue(content.contains("What you can do"))
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
        XCTAssertTrue(pending.contains("audio:\n  - \"mic.m4a\"\n  - \"system.m4a\""))
        XCTAssertTrue(pending.contains("`mic.m4a` and `system.m4a`"))

        try TranscriptWriter.writeFailed(at: url, context: context, errorMessage: "boom")
        let failed = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(failed.contains("Captured audio streams are preserved at `mic.m4a` and `system.m4a`"), failed)
    }


    func testNoAudioFailureCopyDoesNotPromiseIntactRecording() throws {
        let url = tmp.appendingPathComponent("no-audio.md")
        let context = TranscriptContext(
            title: "No Audio", date: "2026-05-20", engine: "elevenlabs",
            audioRelativePaths: [],
            startedAt: "2026-05-20T10:00:00Z", endedAt: "2026-05-20T10:05:00Z",
            attendees: [], language: nil
        )

        try TranscriptWriter.writeFailed(at: url, context: context, errorMessage: "Session audio is missing")

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("No usable audio was captured"), content)
        XCTAssertFalse(content.localizedCaseInsensitiveContains("intact and complete"), content)
        XCTAssertFalse(content.contains("Retry from the Scribe menu bar"), content)
        XCTAssertFalse(content.localizedCaseInsensitiveContains("transcribe locally"), content)
        XCTAssertFalse(content.localizedCaseInsensitiveContains("transcribe outside Scribe"), content)
        XCTAssertFalse(content.contains("open `"), content)
    }

    func testOneSidedFailureCopyDoesNotPromiseScribeRetry() throws {
        let url = tmp.appendingPathComponent("one-sided.md")
        let context = TranscriptContext(
            title: "One Sided", date: "2026-05-20", engine: "cohere",
            audioRelativePaths: ["mic.m4a"],
            startedAt: "2026-05-20T10:00:00Z", endedAt: "2026-05-20T10:05:00Z",
            attendees: [], language: nil
        )

        try TranscriptWriter.writeFailed(at: url, context: context, errorMessage: "Only mic survived")

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("Only `mic.m4a` was preserved"), content)
        XCTAssertTrue(content.contains("requires both microphone and system audio"), content)
        XCTAssertFalse(content.localizedCaseInsensitiveContains("intact and complete"), content)
        XCTAssertFalse(content.contains("Retry from the Scribe menu bar"), content)
        XCTAssertFalse(content.localizedCaseInsensitiveContains("transcribe locally"), content)
    }

    func testFailureGuidanceMatchesAvailableAudioAndSupportedActions() throws {
        let canonicalURL = tmp.appendingPathComponent("canonical.md")
        let canonical = TranscriptContext(
            title: "Canonical", date: "2026-05-20", engine: "elevenlabs",
            audioRelativePaths: ["audio.m4a"],
            startedAt: "2026-05-20T10:00:00Z", endedAt: "2026-05-20T10:05:00Z",
            attendees: [], language: nil
        )
        try TranscriptWriter.writeFailed(at: canonicalURL, context: canonical, errorMessage: "timeout")
        let canonicalContent = try String(contentsOf: canonicalURL, encoding: .utf8)
        XCTAssertTrue(canonicalContent.contains("Retry from the Scribe menu bar"), canonicalContent)
        XCTAssertTrue(canonicalContent.contains("open `audio.m4a`"), canonicalContent)

        let rawURL = tmp.appendingPathComponent("raw.md")
        let raw = TranscriptContext(
            title: "Raw", date: "2026-05-20", engine: "elevenlabs",
            audioRelativePaths: ["mic.m4a", "system.m4a"],
            startedAt: "2026-05-20T10:00:00Z", endedAt: "2026-05-20T10:05:00Z",
            attendees: [], language: nil
        )
        try TranscriptWriter.writeFailed(at: rawURL, context: raw, errorMessage: "audio finalizer failed")
        let rawContent = try String(contentsOf: rawURL, encoding: .utf8)
        XCTAssertTrue(rawContent.contains("canonical `audio.m4a` was not created"), rawContent)
        XCTAssertFalse(rawContent.contains("Retry from the Scribe menu bar"), rawContent)
    }

    func testFailedTranscriptIncludesBoundedFailureDetails() throws {
        let url = tmp.appendingPathComponent("transcript.md")
        let context = TranscriptContext(
            title: "T", date: "2026-04-29", engine: "cohere",
            audioRelativePaths: ["audio.m4a"],
            startedAt: "2026-04-29T14:30:00Z", endedAt: "2026-04-29T15:00:00Z",
            attendees: [], language: nil
        )
        let details = TranscriptFailureDetails(
            errorCode: "Cohere Timeout!!",
            errorMessage: "Failed at /Users/alice/Scribe/Secret/transcript.md with token https://example.com/signed?token=abc and alice@example.com\nStack trace line",
            retryCount: 3,
            attemptCount: 4,
            audioDurationSeconds: 3291,
            audioSizeBytes: 52_840_192
        )

        try TranscriptWriter.writeFailed(at: url, context: context, errorMessage: details.errorMessage, details: details)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("engine: cohere"), content)
        XCTAssertTrue(content.contains("error_code: \"cohere_timeout\""), content)
        XCTAssertTrue(content.contains("retry_count: 3"), content)
        XCTAssertTrue(content.contains("attempt_count: 4"), content)
        XCTAssertTrue(content.contains("audio_duration_seconds: 3291"), content)
        XCTAssertTrue(content.contains("audio_size_bytes: 52840192"), content)
        XCTAssertFalse(content.contains("/Users/alice"), content)
        XCTAssertFalse(content.contains("alice@example.com"), content)
        XCTAssertFalse(content.contains("https://example.com"), content)
        XCTAssertFalse(content.contains("token=abc"), content)
        XCTAssertFalse(content.contains("\nStack trace line"), content)
    }


    func testFailedTranscriptRedactsSignedURLBeforePathAndStripsQueryTokens() throws {
        let url = tmp.appendingPathComponent("transcript.md")
        let context = TranscriptContext(
            title: "Signed URL", date: "2026-04-29", engine: "elevenlabs",
            audioRelativePaths: ["audio.m4a"],
            startedAt: "2026-04-29T14:30:00Z", endedAt: "2026-04-29T15:00:00Z",
            attendees: [], language: nil
        )
        let raw = "Upload failed for https://storage.example.com/Users/alice/Scribe/audio.m4a?X-Amz-Signature=SECRET&token=abc123 and retry_url=?access_token=def456 at /Users/alice/Scribe/session/audio.m4a"
        try TranscriptWriter.writeFailed(
            at: url,
            context: context,
            errorMessage: raw,
            details: TranscriptFailureDetails(errorMessage: raw)
        )
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("[url]"), content)
        XCTAssertTrue(content.contains("[path]"), content)
        XCTAssertFalse(content.contains("storage.example.com"), content)
        XCTAssertFalse(content.contains("X-Amz-Signature"), content)
        XCTAssertFalse(content.contains("SECRET"), content)
        XCTAssertFalse(content.contains("token=abc123"), content)
        XCTAssertFalse(content.contains("access_token=def456"), content)
        XCTAssertFalse(content.contains("/Users/alice"), content)
    }


    /// VAL-STORAGE-004: standalone sk_-prefixed token embedded in a provider
    /// error must not appear in the persisted failed transcript.
    func testFailedTranscriptRedactsStandaloneSkPrefixedToken() throws {
        let url = tmp.appendingPathComponent("transcript.md")
        let context = TranscriptContext(
            title: "SK Token Test", date: "2026-05-20", engine: "elevenlabs",
            audioRelativePaths: ["audio.m4a"],
            startedAt: "2026-05-20T10:00:00Z", endedAt: "2026-05-20T10:30:00Z",
            attendees: [], language: nil
        )
        let raw = "ElevenLabs returned 401 Unauthorized. xi-api-key: sk_TEST-API-KEY-XYZ used in request. Check your Keychain."
        try TranscriptWriter.writeFailed(
            at: url,
            context: context,
            errorMessage: raw,
            details: TranscriptFailureDetails(errorMessage: raw)
        )
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(content.contains("sk_TEST"), "sk_ token must be redacted from transcript: \(content)")
        XCTAssertFalse(content.contains("API-KEY-XYZ"), "sk_ token value must be redacted: \(content)")
        XCTAssertTrue(content.contains("status: failed"), "failed status must be set: \(content)")
        XCTAssertTrue(content.contains("[redacted]"), "redacted marker must appear: \(content)")
    }

    func testFailedTranscriptRedactsAuthorizationBearerHeaderFormsBeforeGenericKeyValueRedaction() throws {
        let url = tmp.appendingPathComponent("transcript.md")
        let context = TranscriptContext(
            title: "Bearer", date: "2026-04-29", engine: "elevenlabs",
            audioRelativePaths: ["audio.m4a"],
            startedAt: "2026-04-29T14:30:00Z", endedAt: "2026-04-29T15:00:00Z",
            attendees: [], language: nil
        )
        let raw = "Provider returned Authorization=Bearer abc123 and Authorization: Bearer def456 plus bearer ghi789 and X-Auth-Token: jkl012"
        try TranscriptWriter.writeFailed(
            at: url,
            context: context,
            errorMessage: raw,
            details: TranscriptFailureDetails(errorMessage: raw)
        )
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("Authorization: Bearer [redacted]"), content)
        XCTAssertTrue(content.contains("Bearer [redacted]"), content)
        XCTAssertFalse(content.contains("abc123"), content)
        XCTAssertFalse(content.contains("def456"), content)
        XCTAssertFalse(content.contains("ghi789"), content)
        XCTAssertFalse(content.contains("jkl012"), content)
    }

}
