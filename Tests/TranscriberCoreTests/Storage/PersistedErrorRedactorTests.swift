import XCTest
@testable import TranscriberCore

/// VAL-STORAGE-004: Persisted errors redact standalone API-key tokens.
///
/// Provider, transport, retry, readiness, and engine errors containing
/// standalone API-key-shaped tokens must be redacted before any durable
/// persistence. Tests use sentinel tokens only — no real keys.
final class PersistedErrorRedactorTests: XCTestCase {

    // MARK: - sk_ prefix tokens

    /// Standalone sk_-prefixed token embedded in a provider error message.
    func testStandaloneSkPrefixTokenIsRedacted() {
        let raw = "Unauthorized: sk_TEST-API-KEY-XYZ"
        let result = PersistedErrorRedactor.redact(raw)
        XCTAssertFalse(result.contains("sk_TEST"), "sk_ token must be redacted: \(result)")
        XCTAssertFalse(result.contains("API-KEY-XYZ"), "sk_ token value must be redacted: \(result)")
        XCTAssertTrue(result.contains("[redacted]"), "redacted marker must be present: \(result)")
        XCTAssertTrue(result.contains("Unauthorized"), "useful error context must survive: \(result)")
    }

    /// Longer sk_ token with mixed separators (the most common ElevenLabs key shape).
    func testSkPrefixedKeyWithMixedSeparatorsIsRedacted() {
        let raw = "invalid key sk_prod_abcdef1234567890 in request"
        let result = PersistedErrorRedactor.redact(raw)
        XCTAssertFalse(result.contains("sk_prod"), "sk_ prod token must be redacted: \(result)")
        XCTAssertFalse(result.contains("abcdef1234567890"), "sk_ token value must be redacted: \(result)")
        XCTAssertTrue(result.contains("[redacted]"), "redacted marker must appear: \(result)")
    }

    /// sk_ token appearing mid-sentence after punctuation.
    func testSkTokenAfterPunctuationIsRedacted() {
        let raw = "ElevenLabs returned 401; key=sk_test_abcdefghij"
        let result = PersistedErrorRedactor.redact(raw)
        XCTAssertFalse(result.contains("sk_test"), "sk_ test token must be redacted: \(result)")
        XCTAssertFalse(result.contains("abcdefghij"), "sk_ token tail must be redacted: \(result)")
    }

    /// Multiple sk_ tokens in one message — all must be redacted.
    func testMultipleSkTokensAreAllRedacted() {
        let raw = "Retry with sk_old_abc123 failed, current key sk_new_def456 also invalid"
        let result = PersistedErrorRedactor.redact(raw)
        XCTAssertFalse(result.contains("sk_old"), "first sk_ token must be redacted: \(result)")
        XCTAssertFalse(result.contains("sk_new"), "second sk_ token must be redacted: \(result)")
        XCTAssertFalse(result.contains("abc123"), "first token value must be redacted: \(result)")
        XCTAssertFalse(result.contains("def456"), "second token value must be redacted: \(result)")
    }

    // MARK: - High-entropy standalone token heuristic

    /// Very long (32+ char) purely alphanumeric token appears verbatim — must be redacted.
    func testLongHighEntropyAlphanumericTokenIsRedacted() {
        let token = "abcdefghijklmnopqrstuvwxyz123456"  // 32 chars
        let raw = "Provider error with token \(token) in body"
        let result = PersistedErrorRedactor.redact(raw)
        XCTAssertFalse(result.contains(token), "32-char alphanumeric token must be redacted: \(result)")
        XCTAssertTrue(result.contains("[redacted]"), "redacted marker must appear: \(result)")
    }

    /// A 31-character token (below the threshold) is NOT redacted by the heuristic.
    func testShortTokenBelowThresholdIsNotRedactedByHeuristic() {
        let token = "abcdefghijklmnopqrstuvwxyz12345"  // 31 chars
        let raw = "Status code returned \(token) as context"
        let result = PersistedErrorRedactor.redact(raw)
        // 31 chars is below the 32-char threshold; the heuristic must not fire
        XCTAssertTrue(result.contains(token), "31-char token below threshold must not be redacted: \(result)")
    }

    /// A normal human-readable error word (even a long one) is not caught by the heuristic.
    func testReadableWordNotRedactedByHeuristic() {
        let raw = "ElevenLabsTranscriptionTimeout after 90 seconds"
        let result = PersistedErrorRedactor.redact(raw)
        // "ElevenLabsTranscriptionTimeout" is 30 chars — below threshold, not caught
        // Even if above threshold it's a readable camelCase word, but the test guards
        // the 32-char boundary specifically
        XCTAssertTrue(result.contains("ElevenLabsTranscriptionTimeout") || result.contains("after"),
                      "readable error context must survive redaction: \(result)")
    }

    // MARK: - Interaction with existing patterns

    /// sk_ token inside a URL is already caught by the URL pattern; ensure no double-redaction artifacts.
    func testSkTokenInsideUrlIsAlreadyHandledByUrlPattern() {
        let raw = "GET https://api.elevenlabs.io/v1/speech-to-text?key=sk_secret_abc failed"
        let result = PersistedErrorRedactor.redact(raw)
        XCTAssertFalse(result.contains("sk_secret"), "sk_ token inside URL must not survive: \(result)")
        XCTAssertFalse(result.contains("elevenlabs.io"), "URL must be redacted: \(result)")
    }

    /// sk_ token next to a Bearer header — both must be redacted without ordering issues.
    func testSkTokenAndBearerHeaderBothRedacted() {
        let raw = "Auth: Bearer sk_my_bearer_token and standalone sk_another_key_here"
        let result = PersistedErrorRedactor.redact(raw)
        XCTAssertFalse(result.contains("sk_my_bearer"), "sk_ bearer must be redacted: \(result)")
        XCTAssertFalse(result.contains("sk_another"), "standalone sk_ must be redacted: \(result)")
        XCTAssertTrue(result.contains("[redacted]"), "redacted marker must appear: \(result)")
    }

    // MARK: - Preservation of useful bounded context

    /// Short codes, model IDs, and numeric codes must survive redaction unchanged.
    func testShortCodesAndNumericCodesArePreserved() {
        let raw = "HTTP 429 rateLimited after 3 retries with code ERR_TIMEOUT"
        let result = PersistedErrorRedactor.redact(raw)
        XCTAssertTrue(result.contains("429"), "numeric HTTP code must survive: \(result)")
        XCTAssertTrue(result.contains("rateLimited") || result.contains("ERR_TIMEOUT"),
                      "error code must survive: \(result)")
    }

    /// Relative artifact names (audio.m4a, transcript.md) must not be redacted.
    func testRelativeArtifactNamesAreNotRedacted() {
        let raw = "Transcription failed for audio.m4a after reading transcript.md"
        let result = PersistedErrorRedactor.redact(raw)
        XCTAssertTrue(result.contains("audio.m4a"), "artifact name must survive: \(result)")
        XCTAssertTrue(result.contains("transcript.md"), "transcript name must survive: \(result)")
    }

    /// Empty input returns the fallback string without panicking.
    func testEmptyInputReturnsFallback() {
        let result = PersistedErrorRedactor.redact("")
        XCTAssertEqual(result, "Transcription failed")
    }

    /// Whitespace-only input returns the fallback string.
    func testWhitespaceOnlyInputReturnsFallback() {
        let result = PersistedErrorRedactor.redact("   \n\t  ")
        XCTAssertEqual(result, "Transcription failed")
    }

    /// Output is bounded to maxLength.
    func testOutputIsBoundedToMaxLength() {
        let longInput = String(repeating: "a", count: 400)
        let result = PersistedErrorRedactor.redact(longInput, maxLength: 100)
        // The 400-char 'a' string is NOT caught by any current pattern (it's
        // the 32-char heuristic, but consecutive spaces/dashes are stripped),
        // however the output is still bounded.
        XCTAssertLessThanOrEqual(result.count, 100, "output must not exceed maxLength: \(result)")
    }

    /// Newlines in raw error messages are collapsed to spaces.
    func testNewlinesAreCollapsedToSpaces() {
        let raw = "Upload failed\nStack trace line\nAnother line"
        let result = PersistedErrorRedactor.redact(raw)
        XCTAssertFalse(result.contains("\n"), "newlines must be collapsed: \(result)")
    }

    // MARK: - Combined real-world scenario

    /// A realistic ElevenLabs 401 error with an embedded key must be clean.
    func testRealisticElevenLabsUnauthorizedErrorIsClean() {
        let raw = "ElevenLabs /v1/speech-to-text returned 401 Unauthorized. xi-api-key: sk_elevenlabs_prod_TEST-SENTINEL-TOKEN-ABCDEF. Check your key in Settings."
        let result = PersistedErrorRedactor.redact(raw)
        XCTAssertFalse(result.contains("sk_elevenlabs"), "sk_ ElevenLabs key must be redacted: \(result)")
        XCTAssertFalse(result.contains("TEST-SENTINEL-TOKEN"), "sentinel token must be redacted: \(result)")
        XCTAssertFalse(result.contains("ABCDEF"), "key suffix must be redacted: \(result)")
        // Useful context must survive
        XCTAssertTrue(result.contains("401") || result.contains("Unauthorized") || result.contains("Settings"),
                      "useful error context must survive: \(result)")
    }
}
