# Security

## Threat model (V1.0-rc1)

Scribe is a single-user macOS desktop app. The threat model focuses on:

- **Local file integrity** — the app should never lose audio or transcripts due to crashes, unexpected quits, or transient I/O.
- **API key confidentiality** — the cloud-mode API key must not appear in logs, transcripts, diagnostics exports, or anywhere on disk in plaintext.
- **Per-session correlation** — diagnostics exports shared with support must let support correlate the same user across exports without revealing their filesystem layout or identifiable paths.
- **Privacy invariants** — no data leaves the device before the user acknowledges; no calendar/attendee information is exported via diagnostics; transcript content never reaches the diagnostics surface.

The threat model does NOT include:

- Multi-user attacks on the same Mac. Anyone with admin rights on your Mac can read your Keychain and your output folder.
- Network adversaries between you and ElevenLabs (cloud mode). The engine is reached via HTTPS; certificate pinning is not implemented.
- Adversarial process injection. Scribe relies on macOS hardened runtime + sandbox to isolate from other apps.

## Keychain policy

Two Keychain entries (service `com.szymonsypniewicz.transcriber`):

- `elevenlabs-api-key` — the cloud-mode API key, written when the user pastes it into Settings → Engine. Read on session start (preflight engine readiness probe) and on every transcription request. Deleted when the user clears the field in Settings.
- `diagnostics-instance-id` — a 256-bit random secret (hex-encoded). Generated lazily on first diagnostics export. Used as the HMAC-SHA256 key for `outputRootHash` so two users sharing the same path string get different hashes. Never deleted by the app; users who want to re-randomize must delete via Keychain Access.

Both entries use `KeychainStore` (`Sources/TranscriberCore/Storage/KeychainStore.swift`) which wraps `SecItemAdd / SecItemCopyMatching / SecItemDelete` with a constant `kSecAttrAccessibleAfterFirstUnlock` policy. The entries are not bound to a specific bundle signing identity, so reinstalling the app does not regenerate them.

## Log policy

Logs use Apple's `os_log` API. Subsystem is `com.szymonsypniewicz.transcriber`; categories are `lifecycle`, `engine`, `calendar`. Privacy levels:

- **Lifecycle events** (start / stop / quit / state transitions) — `.public` so the support flow can correlate them.
- **File paths** (output root, diagnostics export path) — `.private` so user identifiers (`/Users/<name>`) are elided in shared logs.
- **Errors** — `.public` for the error type/message; the underlying `Error` is wrapped via `String(describing:)` which intentionally exposes the type name + reason without revealing per-record content.
- **Permission states** — `.public` (the names `granted`/`denied`/`notDetermined` are not personally identifying).

The app NEVER logs:

- API key values.
- Transcript text or utterance content.
- Calendar event titles or attendee names.
- Diagnostics instance ID values.

## Hardened runtime + entitlements

V1.0-rc1 ships with hardened runtime enabled in xcodegen (`ENABLE_HARDENED_RUNTIME: YES`). The entitlements file `TranscriberApp/Scribe/Scribe.entitlements` contains:

- `com.apple.security.device.audio-input` — required for `AVCaptureDevice` access under hardened runtime.
- `com.apple.security.cs.disable-library-validation: false` — only the system + signed-by-same-team libraries can be loaded.
- `com.apple.security.cs.allow-jit: false` — no runtime code generation.

The app is currently distributed as ad-hoc-signed for development. The Phase σ release flow signs with a Developer ID + notarizes; until then, do not redistribute the binary.

## Privacy invariants enforced by tests

Four mandatory redaction tests in `Tests/TranscriberCoreTests/Storage/DiagnosticsExporterTests.swift` enforce the diagnostics-redaction contract:

- `testDiagnosticsContainsNoTranscriptContent` — plants a sentinel inside a complete transcript body, exports, asserts the sentinel is absent.
- `testDiagnosticsContainsNoAttendeeNames` — plants sentinel attendee names + a sentinel-prefixed event title in frontmatter, asserts both are absent.
- `testDiagnosticsContainsNoAPIKey` — asserts the schema cannot carry a key value (no String field exists for it).
- `testDiagnosticsRedactionWalksWholeSessionFolder` — plants sentinels in stray files inside a session folder; asserts neither filenames nor contents (raw, base64, or hex) leak.

Plus `testRecursiveSchemaShape` asserts the EXACT key set of every nested object in the export. Adding a new field to any view (`SettingsView`, `EngineView`, etc.) trips the test, forcing explicit security review.

## Privacy acknowledgement gating

Spec line 348 + Phase η:

- `SettingsStore.privacyAcknowledged` is a one-way `Bool` (default false). `SettingsStore.commit(_:)` refuses to write `false` over a prior `true` (`testCommitCannotDemotePrivacyAcknowledgement`).
- AppDelegate's `startRecording` short-circuits to the privacy modal if the flag is false. Same for the supervisor scan in `applicationDidFinishLaunching` — orphan recovery is deferred until the ack.
- The privacy modal is non-closable via cmd-w / title-bar close. Only "I understand" or app-quit dismisses it.
- The modal explicitly mentions calendar-derived keyterms upload, audio upload in cloud mode, and on-device storage in local mode.

## Reporting security issues

File at the project's GitHub repository. For embargoed reports, contact the maintainer directly with details and a proposed disclosure timeline.
