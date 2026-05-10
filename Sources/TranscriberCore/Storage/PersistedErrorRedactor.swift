import Foundation

/// Redacts error strings before they are persisted to user-visible artifacts
/// (`transcript.md` and `metadata.json`). This is intentionally separate from
/// diagnostics redaction because failed-session artifacts are durable local
/// records, but they must still exclude bearer tokens, signed URLs, raw paths,
/// emails, stack traces, and other copy/paste secrets from provider errors.
public enum PersistedErrorRedactor {
    public static func redact(_ raw: String, maxLength: Int = 240) -> String {
        var value = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        // URL-first redaction is required: signed URLs often contain path-like
        // segments and query tokens. If generic path redaction runs first it can
        // leave `?token=...` fragments behind.
        value = value.replacingOccurrences(
            of: #"https?://[^\s\"'<>)]*"#,
            with: "[url]",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"www\.[^\s\"'<>)]*"#,
            with: "[url]",
            options: [.regularExpression, .caseInsensitive]
        )

        // Header/bearer redaction must run before generic key-value
        // redaction. Inputs such as `Authorization=Bearer abc123` would
        // otherwise redact only `Authorization=Bearer` and leave `abc123`.
        value = value.replacingOccurrences(
            of: #"(?i)\bauthorization\s*[:=]\s*bearer[ \t]+[A-Za-z0-9._~+/=-]+"#,
            with: "Authorization: Bearer [redacted]",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)\b(x-api-key|api-key|authorization|proxy-authorization|x-auth-token)\s*[:=]\s*(?!bearer\b)[A-Za-z0-9._~+/=-]+"#,
            with: "$1: [redacted]",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#,
            with: "Bearer [redacted]",
            options: .regularExpression
        )

        // Strip token-like query/header fragments even when a provider reports
        // only the query string or header value instead of the full URL.
        value = value.replacingOccurrences(
            of: #"(?i)([?&;]\s*)?(token|access_token|api_key|apikey|signature|sig|expires|x-amz-[a-z0-9_-]+|password|passcode|secret|key)=([^\s&;]+)"#,
            with: "[redacted]",
            options: .regularExpression
        )

        value = value.replacingOccurrences(
            of: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,
            with: "[email]",
            options: [.regularExpression, .caseInsensitive]
        )

        // Generic absolute path redaction after URLs/tokens. Handles POSIX and
        // common file URL remnants without trying to redact harmless relative
        // artifact names such as audio.m4a.
        value = value.replacingOccurrences(
            of: #"(?i)\b[A-Za-z0-9_-]*secret[A-Za-z0-9_-]*\b"#,
            with: "[redacted]",
            options: .regularExpression
        )

        value = value.replacingOccurrences(
            of: #"file://[^\s\"'<>)]*"#,
            with: "[path]",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"/(Users|Volumes|private|var|tmp|Applications|Library)/[^\s\"'<>)]*"#,
            with: "[path]",
            options: .regularExpression
        )

        while value.contains("  ") { value = value.replacingOccurrences(of: "  ", with: " ") }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "Transcription failed" : trimmed).prefix(maxLength))
    }
}
