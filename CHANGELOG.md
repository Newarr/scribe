# Changelog

## 1.0.0-rc1 - 2026-04-30

Code-complete release candidate. Validate against `docs/TESTING.md` before tagging `v1.0.0`.

### New

- **Track 1 (Durability)**:
  - Phase α: PermissionDoctor + EngineReadiness preflight gates record-time. Calendar marked optional per spec.
  - Phase β: single dual-output ScreenCaptureKit stream replaces the prior dual-`SCStream` model so mic and system share a sync clock. Per-buffer PTS log feeds streaming finalize and the future AEC. Transactional capture stop with explicit happens-before ordering.
  - Phase γ: atomic per-session SessionClaim using POSIX `O_CREAT|O_EXCL` + `boot_time` + 15s heartbeat lease. Defends against PID reuse.
  - Phase δ: EndGuard state machine — bidirectional silence detection, 10s grace countdown, 15min snooze, 4h session safety net.
  - Phase ε: streaming `AudioFinalizer` with chunked read+mix+write (100ms chunks, bounded resident memory). Power-preserving mix coefficient. Atomic `.inflight` temp + move-to-output. Real read-error vs EOF distinction. EOF-aware retry on AAC nilError.

- **Track 2 (UX + Privacy)**:
  - Phase ζ: OrphanRecoverer requires both tracks — one-sided sessions get a `.partialAudio` failed transcript referencing the surviving file (spec line 339); rename failures emit `.recoveryDeferred` to leave the session retryable. Single-blob JSON `SettingsStore` with HMAC-isolated UserDefaults wrapper.
  - Phase η: SwiftUI Settings window, first-run Privacy Acknowledgement modal (spec line 348), Setup Required popover with deep-links to System Settings panes.
  - Phase θ: typed `DiagnosticsExporter` + DiagnosticsView with mandatory redaction tests (no transcript content, no attendee names, no API key fragments, no stray session-folder content). HMAC-SHA256 path hashing keyed with per-install secret. Recursive schema-shape test pins every nested field.
  - Phase ι: `keep_raw_streams` default-OFF correctly deletes raw streams after `audio.m4a` is on disk and the terminal `.complete` state is written.
  - Phase κ: SPEC documents BS.1770 LUFS as deferred to V1.1; rc1 ships RMS-style approximation.
  - Phase λ: `docs/PRIVACY.md`, `docs/SECURITY.md`, `docs/TROUBLESHOOTING.md`, `docs/RELEASE.md`.

- **Track 3 (Engines)**:
  - Phase μ: ElevenLabs parser handles both `words[]` (single-channel diarized) and `transcripts[]` (multichannel) shapes with chronological flattening.
  - Phase ν: `LanguageDetector` protocol + `WhisperKitLanguageDetector` placeholder (real WhisperKit integration is research-gated, post-rc1 spike).
  - Phase ξ: `AECPrePass` protocol + `WebRTCAECBackend` placeholder. `aec_status: succeeded | failed` wire format pinned.
  - Phase ο: `CohereRustBackend` (TranscriptionEngine) + `EngineSelector` dispatch. Local mode binary integration is research-gated.

- **Track 4 (Detection + Release)**:
  - Phase π: 60s prompt auto-dismiss in StartPromptCoordinator. `AudioActivityProbe` protocol seam.
  - Phase σ: hardened-runtime entitlements (audio-input, no JIT, no library-validation bypass). `scripts/release.sh` reads credentials from Keychain only — never inline secrets.
  - Phase τ: `Casks/transcriber.rb.template` for Homebrew distribution, with `zap` block matching the manual-wipe steps in PRIVACY.md.
  - Phase υ: `scripts/bump-version.sh` keeps every version surface in lockstep. `docs/TESTING.md` is the gating doc.

### Tests

- 221 swift-test green at rc1 cut.
- Four mandatory diagnostics-redaction guards under
  `Tests/TranscriberCoreTests/Storage/DiagnosticsExporterTests.swift`.
- Recursive schema-shape test prevents accidental nested-field
  additions from bypassing the redaction contract.

### Deferred to V1.1 (research-gated, documented in SPEC + PRIVACY)

- BS.1770 LUFS normalization (rc1 ships RMS approximation).
- WhisperKit-backed language detection (rc1 falls back to engine
  auto-detect).
- WebRTC-rs / AUVoiceProcessing AEC pre-pass (rc1 takes
  single-channel diarized fallback per spec line 119).
- Cohere Rust subprocess local engine (rc1 cloud-only).
- Real per-PID audio activity detection (rc1 uses
  presence-based dwell + bidirectional silence).
- Signed/notarized `.app` and Homebrew tap submission (requires the
  user's Developer ID cert + tap repo).

### Codex-driven hardening

Six max-effort codex reviews ran at phase boundaries (α, β, ε, ζ,
η, θ). Every REJECT verdict was followed by P0/P1 fixes before
moving on.
