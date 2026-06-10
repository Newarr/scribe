# Troubleshooting

Common Scribe failure modes and their diagnostic steps.

If something below doesn't help, open Diagnostics (menu bar → Diagnostics…) and click "Export…" to capture the current state — then file an issue with that JSON attached.

## Recording won't start

### Setup Required popover appears

The preflight gate denied the record attempt. Each unmet permission has a dedicated row with a "Open System Settings" deep-link. After fixing each one, click "Recheck" inside the popover to re-run the audit.

Common causes:

- **Microphone access denied** — System Settings → Privacy & Security → Microphone, enable Scribe.
- **Screen & System Audio Recording denied** (label is "Screen & System Audio Recording" on macOS 15+, may show as "Screen Recording" on older versions) — System Settings → Privacy & Security, enable Scribe, then **restart the app** (the entitlement is checked at process start).
- **ElevenLabs API key missing** (Cloud mode) — Settings → Engine, paste your key.
- **Cohere model not ready** (Local mode) — Settings → Engine shows the Local card status and a repair action. Local cannot start until the pinned model is verified and MLX is available; Scribe does not silently switch to Cloud.
- **Output folder unwritable** — Settings → Output, pick a different folder, or fix the permissions on the current one.
- **Output folder in synced storage** — only a warning, not a blocker. The folder shows a yellow warning if it looks like iCloud Drive, Dropbox, Google Drive, OneDrive, or Box. Recording into synced storage can race the cloud sync and corrupt audio mid-write. Recommended: move the folder to local-only storage.

### Permission toggle is on, but Scribe still reports it denied

macOS pins each privacy grant to the code signature of the binary that requested it. If Scribe's signing identity changes between installs (typically a from-source build signed with a different or ad-hoc certificate replacing a previous install), the old grant no longer matches the new binary: System Settings keeps showing the toggle as enabled, but the running app fails the check. Screen & System Audio Recording is where this usually bites.

Fix:

```
tccutil reset ScreenCapture com.szymonsypniewicz.scribe
```

Then re-enable Scribe under System Settings → Privacy & Security → Screen & System Audio Recording and restart the app. The same reset works for other services (`Microphone`, `Calendar`) showing the same symptom.

Release builds are Developer ID signed with a stable identity, so normal updates never trigger this. If you build from source, install via `scripts/dev-install.sh` so dev builds are signed with a stable identity too; see the header comment in that script for the details.

### Privacy acknowledgement window appears every launch

The privacy modal is gated on `transcriber.settings.v1` in UserDefaults. If you keep seeing it:

- Check `defaults read com.szymonsypniewicz.scribe transcriber.settings.v1` — it should contain `"privacyAcknowledged":true` after acknowledgement. The key name kept the historical `transcriber` prefix, but the preferences domain is the Scribe bundle ID.
- If the value isn't sticking, your UserDefaults may be unwritable (rare, usually a permissions issue on `~/Library/Preferences/`).

### Menu bar shows "Starting…" forever

A capture session is in `.starting` state but never reached `.recording`. The most likely cause is a stuck SCStream initialization. Quit the app via cmd-q (the quit handler has a 10-second drain budget), then relaunch.

If the issue persists, check `~/Library/Logs/Scribe/` for the most recent capture session error.

## Recording succeeds but no transcript appears

The session went to `pending` or `retrying` and the worker hasn't completed. Open Diagnostics and look at the "Recent sessions" section:

- **Pending count > 0** — a worker is still running. Cloud mode uploads the audio to ElevenLabs; Local mode runs Cohere on your Mac. Long meetings can take minutes for either engine to process. Wait or check `~/Library/Logs/Scribe/`.
- **Retrying count > 0** — the selected engine returned a transient error (rate limit/network for Cloud, recoverable setup/runtime interruption for Local). The worker is in a bounded backoff loop.
- **Failed count > 0** — terminal failure. Open the session folder; the `transcript.md` body explains the reason and `audio.m4a` remains the retryable asset. Use the Recents `Retry`/`Repair` action after fixing the selected engine; do not delete artifacts to force recovery.

### Orphaned with audio (no transcript)

A session folder containing `mic.m4a` or `system.m4a` (or their `.partial` siblings) but no `transcript.md`. This happens when the app crashed between writing audio and writing the pending transcript. The supervisor scan on next launch picks these up via `OrphanRecoverer` and dispatches a worker, OR (if rename failed) defers them.

If a session is permanently stuck in this state:

- Check that both `mic.m4a` and `system.m4a` are present (or their `.partial` versions). Spec line 339: one-sided audio is NOT transcribable; the supervisor will write a failed transcript pointing at the surviving file.
- Check `chflags` (`ls -lO`) for the immutable flag on `.partial` files. If set, `chflags nouchg` releases the file so the supervisor can rename it.

## Re-transcription of completed sessions

Default `keep_raw_streams=false` (spec line 102) deletes `mic.m4a` and
`system.m4a` once a session reaches `complete`. The session folder
keeps `audio.m4a` (the mixed playback file), `transcript.md`, and
`metadata.json` — but the per-channel originals are gone.

If you want the option to re-process per-channel audio later (different
engine, different speaker mapping, post-hoc AEC), enable Settings →
Output → "Keep raw mic / system streams after mix" **before** recording.
The toggle takes effect on the next session, never to a session already
in progress.

The mixed `audio.m4a` is suitable for cloud single-channel diarized
re-runs, but per-channel diarization or AEC re-runs require the raws.

## Audio quality issues

### Doubled remote speaker

Hearing the same voice transcribed twice (once attributed to mic, once to system). This is the AEC failure mode — without echo cancellation, your speaker's audio leaks into your microphone. AEC integration is a future phase; until it ships, the workaround is to use headphones.

### Quiet recordings

The mix recipe in `AudioFinalizer` is power-preserving (single-active sides pass through at unity, dual-active scaled by 1/√2 each), with a hard peak limit at 0.891 ≈ -1 dBFS. If your recording sounds quieter than expected on first listen, the limit is conservative — playback level is still consistent across sessions.

True LUFS-based normalization (target -16 LUFS / -1 dBTP) is deferred to V1.1.

## Local Cohere repair

Local mode depends on a verified Cohere/MLX model cache and a supported MLX runtime. Settings → Engine and Setup Required identify the state and the repair action.

- **Not downloaded** — click Retry/Download in Settings → Engine. Scribe downloads only the pinned `beshkenadze/cohere-transcribe-03-2026-mlx-fp16` artifacts.
- **Downloading** — progress is observable. Engine-dependent actions wait until verification completes; Local is not selectable while only `.partial` files exist.
- **Verification failed / corrupt cache** — click Retry. Scribe removes or supersedes failed partial artifacts, redownloads the pinned artifacts, and verifies integrity before enabling Local.
- **Low disk** — free space for the model plus partial/write overhead, then click Retry. Scribe blocks unsafe downloads before writing final cache files.
- **Unsupported MLX/runtime** — Local cannot run on this Mac/runtime. Select Cloud explicitly if you want ElevenLabs; Scribe will not switch automatically.
- **Removed cache** — if you used Remove Local Model, Local becomes unavailable until redownloaded. Existing `~/Scribe/` sessions, `audio.m4a`, `transcript.md`, and `metadata.json` are untouched.
- **Failed Local session** — keep the session folder intact. Retry reuses saved `audio.m4a` in the same folder when the model is ready; if the model is unavailable, the action opens Local setup/repair instead of Cloud.

No repair state silently changes engines. Local → Cloud and Cloud → Local are explicit Settings choices, and in-flight sessions keep the engine selected at recording start.

## Diagnostics export

`~/Library/Logs/Scribe/diagnostics-<timestamp>.json` contains:

- App version + export timestamp.
- Settings (engine mode, raw-stream policy, AEC enable, privacy ack, **HMAC-hashed** output root, writability flag).
- Permission states (granted / denied / notDetermined).
- Engine readiness (cloud-key state: configured / missing / unreadable; Local model status, pinned model ID, cache-exists boolean, MLX availability, selected-engine readiness, active/recent session engine provenance, and bounded/redacted last download error).
- Session aggregate counts (total, pending, retrying, complete, failed, unknown, orphaned-with-audio, total-retries).

The export does NOT contain transcript bodies, attendee names, calendar event titles, audio bytes, the API key value, or raw paths. Safe to share with support.

## Common Console.app filters

Subsystem `com.szymonsypniewicz.transcriber`. Useful categories:

- `category:lifecycle` — startup, recording start/stop, quit, supervisor scan results.
- `category:engine` — transcription worker, retry behavior, engine errors.
- `category:calendar` — calendar permission requests, event lookups, store-changed refreshes.

## Known limitations (V1.0)

These are not bugs but documented gaps that will close in later releases:

- AEC is not implemented; use headphones for dual-speaker calls.
- BS.1770 LUFS normalization is approximated as RMS; see SPEC § Audio normalization.
- Process-mic-release detection is not available; bidirectional silence at 30s is the only end-of-call signal.
- Real audio-activity detection (process-by-process) is not implemented; presence-based dwell triggers the start prompt.
