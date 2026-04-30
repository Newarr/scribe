import Foundation

/// Spec line 127 / D1: local engine option uses
/// `second-state/cohere_transcribe_rs` as a bundled Rust subprocess.
/// Phase ο ships the TranscriptionEngine surface + the integration
/// seam; the actual binary bundling, signing, and subprocess wiring
/// is gated on a post-rc1 research spike (same constraint shape as
/// Phase ξ AEC backend).
///
/// Until the spike lands, attempting to use this backend in local
/// mode results in a `.binaryUnavailable` error. The PreflightDoctor
/// catches this earlier (Phase α: `missingLocalEngineBinary`), so
/// the user can't actually start a record session in local mode
/// without first setting the binary path. This class is the runtime
/// fallback if the user bypasses the gate.
public final class CohereRustBackend: TranscriptionEngine, @unchecked Sendable {
    public enum BackendError: Error, Equatable {
        case binaryUnavailable
        case binaryFailed(exitCode: Int)
        case malformedOutput
        case audioReadFailed(URL)
    }

    /// Path to the Cohere binary. `nil` means the binary isn't bundled
    /// (rc1 default); the backend immediately throws
    /// `.binaryUnavailable`.
    private let binaryURL: URL?
    /// Optional working directory for the subprocess. Defaults to a
    /// per-session temp dir if nil.
    private let workingDirectory: URL?

    public init(binaryURL: URL? = nil, workingDirectory: URL? = nil) {
        self.binaryURL = binaryURL
        self.workingDirectory = workingDirectory
    }

    public func transcribe(_ request: EngineRequest) async throws -> EngineResponse {
        guard let binaryURL else {
            // rc1 path: binary not bundled. The preflight gate (Phase α)
            // surfaces this before the user can start a session, but
            // surface a clear error here too in case anything bypasses
            // it (programmatic API consumers, tests, future paths).
            throw BackendError.binaryUnavailable
        }
        // TODO Phase ο.next: subprocess invocation. The integration
        // shape:
        //   1. Spawn `cohere_transcribe_rs` via Process / Foundation
        //      subprocess API.
        //   2. Pass `--audio <request.audioURL>` and per-mode flags.
        //   3. Stream stdout, parsing JSON-line-delimited utterances
        //      so we can populate EngineResponse.utterances without
        //      buffering the full transcript.
        //   4. On exit code != 0, throw .binaryFailed.
        //   5. On JSON parse error, throw .malformedOutput.
        _ = binaryURL
        _ = workingDirectory
        throw BackendError.binaryUnavailable
    }
}

/// Picks the right `TranscriptionEngine` for the configured engine
/// mode. Phase ο gives the AppDelegate / worker factory a single
/// place to swap engines based on `SessionSettings.engineMode`.
public enum EngineSelector {
    public static func makeEngine(
        for mode: EngineMode,
        cloudAPIKey: () -> String,
        cohereBinary: URL? = nil,
        urlSession: URLSession = .shared
    ) -> TranscriptionEngine {
        switch mode {
        case .cloud:
            return ElevenLabsScribeBackend(apiKey: cloudAPIKey(), session: urlSession)
        case .local:
            return CohereRustBackend(binaryURL: cohereBinary)
        }
    }
}
