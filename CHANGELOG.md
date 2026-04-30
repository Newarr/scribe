# Changelog

## 1.0.0-rc2 - 2026-04-30

Addresses 4 P0 + 9 P1 + 4 P2 findings from the rc1-final codex review.

### Privacy + correctness fixes

- **mixed.wav cleanup orphan removed** (P0.1, P0.2): the engine
  upload path no longer writes a second copy of the mix to a
  buffered WAV file. Audio.m4a (streamed by Phase ε's
  AudioFinalizer) is uploaded directly. 4hr session no longer
  balloons to ~700MB resident on the upload path.
- **Output path no longer leaks via `.public` log**: outputRoot
  mkdir error now logs the path with `.private` privacy, matching
  SECURITY.md's documented log policy.
- **Metadata write failure no longer triggers raw cleanup** (P1.1):
  writeMetadata now returns Bool; raw-stream cleanup runs only after
  the metadata commit succeeds.
- **Launch-time sweep for stranded raw streams** (P1.2):
  SessionSupervisor catches up on raw cleanup for terminal-complete
  sessions whose prior cleanup failed (immutable flag, transient I/O,
  half-written metadata).
- **`aec_status` is now actually written to metadata.json** (P1.3):
  rc1 stamps `failed` (placeholder AEC backend; spec-line-119
  fallback). The wire format was pinned in Phase ξ but the field
  was never populated.
- **EngineSelector adopted by makeWorker** (P1.4): the dispatcher
  existed but was bypassed; AppDelegate hard-coded
  ElevenLabsScribeBackend. Now dispatches per `settings.engineMode`.
- **Concurrent prompts coalesced** (P1.5): StartPromptCoordinator
  guards against NSApp.stopModal targeting the wrong modal when
  multiple prompts queue up.
- **KeychainStore sets `kSecAttrAccessibleAfterFirstUnlock`** (P1.9):
  matches SECURITY.md's documented policy.

### Release pipeline integrity

- **release.sh no longer masks failures** (P0.4): xcodebuild archive,
  spctl assess, codesign verify, stapler validate all fail loudly.
  Stale build dir wiped before each run. xcbeautify is conditional.
- **Worktree integrity gates** (P1.6): both bump-version.sh and
  release.sh refuse to run on a dirty worktree. release.sh
  additionally verifies BuildInfo.version matches the requested
  release version.
- **create-dmg invocation fixed** (P1.7): correct arg order
  (`<output.dmg> <source-folder>`); failure no longer masked.
- **Cask template** (P1.8): `{{DOWNLOAD_URL}}` placeholder added;
  invalid `delete:` shell-command stanza removed (Homebrew Cask DSL
  doesn't execute commands via `delete:`); Keychain wipe documented
  in caveats + cross-referenced from PRIVACY.md.

### Polish

- CohereRustBackend.BackendError gains `.notImplemented` (distinct
  from `.binaryUnavailable`).
- `testVersionIsSemver` strips both `-prerelease` AND `+build`
  metadata suffixes.
- TROUBLESHOOTING.md documents that `keep_raw_streams=false`
  (default) gates per-channel re-transcription on pre-recording
  opt-in.

### Worker terminal-failure on missing audio.m4a

A new short-circuit: if AudioFinalizer fails to produce audio.m4a
AND the engine request points at audio.m4a (rc2 default), the worker
writes a failed transcript immediately rather than retrying against
a missing file. Raw streams are preserved on .failed for manual
recovery.


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
