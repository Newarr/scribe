import Foundation

/// Spec line 117 / D2: AEC pre-pass cleans the mic channel BEFORE
/// uploading multichannel audio so the remote speaker doesn't double
/// up between mic and system. Phase ξ ships the protocol surface +
/// the TranscriptionWorker integration seam; the real WebRTC-rs
/// or AUVoiceProcessing backend lands in a post-rc1 spike (per
/// docs/AEC-RESEARCH.md once the spike completes).
public enum AECStatus: String, Sendable, Codable, Equatable {
    /// Pre-pass ran and produced a cleaned mic file. Worker proceeds
    /// with multichannel mode using the cleaned mic + raw system.
    case succeeded
    /// Pre-pass attempted but failed (backend unavailable, model
    /// missing, transient error). Spec line 119: fall back to
    /// single-channel diarized using the raw mix.
    case failed
}

public struct AECResult: Sendable, Equatable {
    public let status: AECStatus
    /// URL of the cleaned mic file when status == .succeeded.
    /// `nil` when status == .failed (raw streams remain on disk).
    public let cleanedMicURL: URL?
    /// Optional diagnostic message when status == .failed (logged but
    /// not surfaced to the user beyond the diagnostics export).
    public let failureReason: String?

    public init(status: AECStatus, cleanedMicURL: URL?, failureReason: String? = nil) {
        self.status = status
        self.cleanedMicURL = cleanedMicURL
        self.failureReason = failureReason
    }
}

/// Pre-upload AEC processor. Produces `mic.cleaned.wav` from
/// `mic.m4a` + `system.m4a`, with the system audio used as the
/// reference signal for echo subtraction.
public protocol AECPrePass: Sendable {
    func process(mic: URL, system: URL, output: URL) async -> AECResult
}

/// No-op AEC implementation. Always reports `.failed`. Used by default
/// (rc1) so the worker takes the spec-line-119 single-channel-diarized
/// fallback path. Replacing this with a real backend is a one-line
/// change at the worker factory.
public struct DisabledAECPrePass: AECPrePass {
    public init() {}
    public func process(mic: URL, system: URL, output: URL) async -> AECResult {
        AECResult(status: .failed, cleanedMicURL: nil, failureReason: "AEC backend disabled in rc1 (deferred to spike)")
    }
}

/// Placeholder for the future WebRTC-rs-backed AEC backend. Currently
/// returns `.failed` with a deferral message; replacing the body with
/// a real WebRTC-rs / AUVoiceProcessing call enables the multichannel
/// path. Spec line 119 keeps single-channel as the explicit fallback,
/// so the worker behavior is correct even with this placeholder.
///
/// To wire WebRTC-rs:
///   1. Pin the binary build via `scripts/build-webrtc-aec-binary.sh`.
///   2. Sign with the same Team ID as the app (same flow as the
///      future Cohere binary).
///   3. Bundle into `Resources/` and reference via Bundle.module.
///   4. Replace the body of `process` with the binary subprocess call.
public struct WebRTCAECBackend: AECPrePass {
    public init() {}
    public func process(mic: URL, system: URL, output: URL) async -> AECResult {
        Log.engine.info("WebRTCAECBackend: deferred to spike — returning .failed for single-channel fallback")
        return AECResult(status: .failed, cleanedMicURL: nil, failureReason: "WebRTC-rs backend deferred to post-rc1 spike")
    }
}
