# Troubleshooting

Common Transcriber failure modes and their diagnostic steps.

If something below doesn't help, open Diagnostics (menu bar → Diagnostics…) and click "Export…" to capture the current state — then file an issue with that JSON attached.

## Recording won't start

### Setup Required popover appears

The preflight gate denied the record attempt. Each unmet permission has a dedicated row with a "Open System Settings" deep-link. After fixing each one, click "Recheck" inside the popover to re-run the audit.

Common causes:

- **Microphone access denied** — System Settings → Privacy & Security → Microphone, enable Transcriber.
- **Screen & System Audio Recording denied** (label is "Screen & System Audio Recording" on macOS 15+, may show as "Screen Recording" on older versions) — System Settings → Privacy & Security, enable Transcriber, then **restart the app** (the entitlement is checked at process start).
- **ElevenLabs API key missing** (cloud mode) — Settings → Engine, paste your key.
- **Output folder unwritable** — Settings → Output, pick a different folder, or fix the permissions on the current one.
- **Output folder in synced storage** — only a warning, not a blocker. The folder shows a yellow warning if it looks like iCloud Drive, Dropbox, Google Drive, OneDrive, or Box. Recording into synced storage can race the cloud sync and corrupt audio mid-write. Recommended: move the folder to local-only storage.

### Privacy acknowledgement window appears every launch

The privacy modal is gated on `transcriber.settings.v1` in UserDefaults. If you keep seeing it:

- Check `defaults read com.szymonsypniewicz.transcriber transcriber.settings.v1` — it should contain `"privacyAcknowledged":true` after acknowledgement.
- If the value isn't sticking, your UserDefaults may be unwritable (rare, usually a permissions issue on `~/Library/Preferences/`).

### Menu bar shows "Starting…" forever

A capture session is in `.starting` state but never reached `.recording`. The most likely cause is a stuck SCStream initialization. Quit the app via cmd-q (the quit handler has a 10-second drain budget), then relaunch.

If the issue persists, check `~/Library/Logs/TranscriberApp/` for the most recent capture session error.

## Recording succeeds but no transcript appears

The session went to `pending` or `retrying` and the worker hasn't completed. Open Diagnostics and look at the "Recent sessions" section:

- **Pending count > 0** — a worker is still running. Cloud mode uploads the audio to ElevenLabs; long meetings can take minutes for the engine to process. Wait or check `~/Library/Logs/TranscriberApp/`.
- **Retrying count > 0** — the engine returned a transient error (rate limit, network blip). The worker is in a backoff loop. Retries are bounded; if they exhaust, the session moves to `failed` and the supervisor will skip it on next scan.
- **Failed count > 0** — terminal failure. Open the session folder; the `transcript.md` body explains the reason. If the failure was transient (e.g. network), you can re-trigger by deleting the failed transcript and relaunching the app — the supervisor will re-attempt.

### Orphaned with audio (no transcript)

A session folder containing `mic.m4a` or `system.m4a` (or their `.partial` siblings) but no `transcript.md`. This happens when the app crashed between writing audio and writing the pending transcript. The supervisor scan on next launch picks these up via `OrphanRecoverer` and dispatches a worker, OR (if rename failed) defers them.

If a session is permanently stuck in this state:

- Check that both `mic.m4a` and `system.m4a` are present (or their `.partial` versions). Spec line 339: one-sided audio is NOT transcribable; the supervisor will write a failed transcript pointing at the surviving file.
- Check `chflags` (`ls -lO`) for the immutable flag on `.partial` files. If set, `chflags nouchg` releases the file so the supervisor can rename it.

## Audio quality issues

### Doubled remote speaker

Hearing the same voice transcribed twice (once attributed to mic, once to system). This is the AEC failure mode — without echo cancellation, your speaker's audio leaks into your microphone. AEC integration is a future phase; until it ships, the workaround is to use headphones.

### Quiet recordings

The mix recipe in `AudioFinalizer` is power-preserving (single-active sides pass through at unity, dual-active scaled by 1/√2 each), with a hard peak limit at 0.891 ≈ -1 dBFS. If your recording sounds quieter than expected on first listen, the limit is conservative — playback level is still consistent across sessions.

True LUFS-based normalization (target -16 LUFS / -1 dBTP) is documented as deferred to V1.1 in `docs/SPEC.md` § Audio normalization.

## Diagnostics export

`~/Library/Logs/TranscriberApp/diagnostics-<timestamp>.json` contains:

- App version + export timestamp.
- Settings (engine mode, raw-stream policy, AEC enable, privacy ack, **HMAC-hashed** output root, writability flag).
- Permission states (granted / denied / notDetermined).
- Engine readiness (cloud-key state: configured / missing / unreadable; local binary + model presence in local mode).
- Session aggregate counts (total, pending, retrying, complete, failed, unknown, orphaned-with-audio, total-retries).

The export does NOT contain transcript bodies, attendee names, calendar event titles, audio bytes, the API key value, or raw paths. Safe to share with support.

## Common Console.app filters

Subsystem `com.szymonsypniewicz.transcriber`. Useful categories:

- `category:lifecycle` — startup, recording start/stop, quit, supervisor scan results.
- `category:engine` — transcription worker, retry behavior, engine errors.
- `category:calendar` — calendar permission requests, event lookups, store-changed refreshes.

## Known limitations (V1.0-rc1)

These are not bugs but documented gaps that will close in later releases:

- AEC is not implemented; use headphones for dual-speaker calls.
- Local engine binary is not bundled; cloud mode is the only working engine in rc1.
- Whisper-tiny language detection is not implemented; the engine auto-detects.
- BS.1770 LUFS normalization is approximated as RMS; see SPEC § Audio normalization.
- Process-mic-release detection is not available; bidirectional silence at 30s is the only end-of-call signal.
- Real audio-activity detection (process-by-process) is not implemented; presence-based dwell triggers the start prompt.
