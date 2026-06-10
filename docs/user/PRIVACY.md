# Privacy

Scribe records meeting audio on your Mac and turns it into a Markdown transcript. This document is the complete description of what data the app handles, where it lives, and what leaves your device.

This is reference material, not a mission statement: Scribe's design priority is seamless capture (see `docs/spec/SPEC.md` → Priorities). Knowing exactly what leaves the device, and being able to choose Local for sensitive calls, exists to remove hesitation before hitting record.

## What stays on your Mac

- **Raw audio captures** — `mic.m4a` and `system.m4a`, one per session, written to your output folder. Default output folder: `~/Scribe/`.
- **Mixed audio** — `audio.m4a` is produced from the two raw streams. Default-OFF `keep_raw_streams` deletes the raws after `audio.m4a` is on disk.
- **Transcript** — `transcript.md` per session, with frontmatter (status, engine, language, calendar event title and attendees if granted) and a Markdown body of utterances.
- **Metadata** — `metadata.json` per session, mirror of the frontmatter for JSON consumers.
- **Settings** — engine choice, output folder, keep-raw-streams, AEC enable, privacy acknowledgement. Stored in macOS UserDefaults under `transcriber.settings.v1` (key kept stable across the product rename).
- **Diagnostics instance ID** — a 256-bit random secret used to HMAC-hash your output folder path in diagnostics exports. Stored in macOS Keychain (service `com.szymonsypniewicz.scribe`, account `diagnostics-instance-id`). Generated once per install; never sent to any external service.
- **API keys** — if you've configured a cloud-mode API key, it lives in your macOS Keychain (service `com.szymonsypniewicz.scribe`, account `elevenlabs-api-key`). Legacy Transcriber entries are copied to this service only when macOS permits a noninteractive read. Never written to disk in plaintext.
- **Logs** — `~/Library/Logs/Scribe/` contains lifecycle and engine logs. Per Apple's `os_log` privacy contract, file paths are marked `.private` and never appear in shared logs.

## What leaves your Mac

### Cloud mode

Cloud mode uploads audio and a few selected metadata fields to ElevenLabs for transcription. Specifically:

- **Audio** — the full mixed audio of each session, encoded as AAC m4a, posted as a multipart form to ElevenLabs Scribe (the upstream model name).
- **Calendar-derived "keyterms"** — if Calendar permission is granted AND a calendar event overlaps the recording window, the event's title and attendee names are sent as `keyterms` form fields. This biases the transcription toward the names of people in the meeting. If Calendar is denied or no event matches, no keyterms are sent.
- **Language hint** — if a language preference is set, the BCP-47 tag (e.g. `en`, `pl`) is sent. Otherwise the language is auto-detected by the engine.

Nothing else is sent. The app does not phone home, does not collect telemetry, and does not contact ElevenLabs except to upload audio for transcription when Cloud is selected.

### Local mode

Local mode uses Cohere (local) through `mlx-audio-swift` and `CohereTranscribeModel` with the pinned model `beshkenadze/cohere-transcribe-03-2026-mlx-fp16`. During transcription, Scribe sends no audio, transcript text, calendar context, keyterms, or API keys to ElevenLabs, Cohere-hosted APIs, or any other transcription provider.

Local model setup is separate from transcription: Scribe may download the pinned public Cohere/MLX model artifacts into its model cache, writing `.partial` files first and only marking Local ready after integrity verification succeeds. That download contains no user audio, transcripts, calendar data, keyterms, or API keys. Retry repairs failed or corrupt partial downloads; Remove deletes only the model cache, never your session folders.

There is no silent fallback. If Local is selected but the model is missing, downloading, corrupt, removed, low on disk, or unsupported by the MLX runtime, Scribe blocks transcription with a repair action instead of switching to Cloud. Cloud likewise does not switch to Local unless you explicitly change engines and retry.

## Calendar access (optional)

Calendar permission is **optional**. Denying it disables session tagging (event title, attendees, keyterms), but recording always proceeds. Without calendar, sessions are titled `Manual recording <session-id>` and keyterms are empty.

## What the diagnostics export contains

The "Export Diagnostics…" menu item writes a JSON file to `~/Library/Logs/Scribe/diagnostics-<timestamp>.json`. The file's complete schema is:

- App version and ISO8601 export timestamp.
- Settings: engine mode, keep-raw-streams flag, AEC-enabled flag, privacy-acknowledged flag, **HMAC-SHA256 hash** of the output folder path (keyed with the per-install secret in Keychain), and a writability flag.
- Permissions: granted / denied / notDetermined per permission (mic, screen recording, calendar).
- Engine readiness: `cloudKey ∈ {configured, missing, unreadable}` plus fixed-shape Local fields: selected engine readiness, normalized local model status (`notDownloaded`, `downloading`, `verifying`, `verified`, `failed`, `unsupported`), pinned model ID, cache-exists boolean, MLX availability, and bounded/redacted last download error.
- Session aggregate counts: total, pending, retrying, complete, failed, unknown, orphaned-with-audio, total-retries.
- Live RMS levels for microphone/system audio when safe live capture state exists; when no level source has populated live state, this field is absent/unknown rather than fabricated.

The export does **not** contain transcript bodies, attendee names, calendar event titles, keyterms, audio file contents, model cache paths, the API key value, raw output folder paths, or any other per-session content. The four mandatory redaction tests (`testDiagnosticsContainsNoTranscriptContent`, `testDiagnosticsContainsNoAttendeeNames`, `testDiagnosticsContainsNoAPIKey`, `testDiagnosticsRedactionWalksWholeSessionFolder`) enforce this contract.

## How to wipe everything

To remove all Scribe data:

1. Quit the app.
2. Delete `~/Scribe/` (or whichever folder you configured as output).
3. Open Keychain Access and delete the entries under service `com.szymonsypniewicz.scribe`. There are two accounts: `elevenlabs-api-key` (your API key, if any) and `diagnostics-instance-id` (the per-install HMAC secret). If you upgraded from a Transcriber-era build, also remove any leftover entries under `com.szymonsypniewicz.transcriber`.
4. Delete `~/Library/Preferences/com.szymonsypniewicz.scribe.plist`.
5. Delete `~/Library/Logs/Scribe/`.
6. Drag the app to the Trash.

## Privacy acknowledgement

On first launch, Scribe presents a modal explaining what data leaves the device. Recording is gated until you click "I understand." The modal cannot be dismissed via the title-bar close button. Your only options are to acknowledge or quit the app. The acknowledgement is stored in `transcriber.settings.v1` (UserDefaults) as a one-way flag; the Settings UI cannot demote it back to false (enforced by `SettingsStore.commit`).

## Reporting privacy concerns

File issues at the project's GitHub repository. For sensitive reports, contact the maintainer directly.
