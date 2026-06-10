import Foundation

/// Engine-thrown errors adopt this so the recovery layer can classify
/// failures without importing concrete backend error types. Each engine
/// owns its own transience and diagnostic-code mapping; the worker only
/// dispatches on the protocol (plus a URLError fallback for network
/// errors, since retroactively conforming Foundation's type is a
/// footgun).
protocol RetryClassifiableError: Error {
    /// Whether the failure is worth retrying with backoff (rate limits,
    /// server 5xx) versus terminal (auth failures, malformed payloads,
    /// deterministic decode failures).
    var isTransient: Bool { get }

    /// Stable machine-readable code persisted into transcript
    /// frontmatter and metadata.json, or nil to fall back to the
    /// worker's reason-string sniffing.
    var persistedErrorCode: String? { get }
}
