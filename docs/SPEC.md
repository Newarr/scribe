# Transcriber Spec

## Product Definition

Transcriber is a menu-bar-first macOS app that makes sure every important meeting becomes a timestamped Markdown transcript with the original audio saved next to it.

The product should feel like a seatbelt, not a dashboard. It stays out of the way until risk appears: missed start, missing permission, active recording, or runaway recording.

## Non-Goals

- No audio import flow.
- No live transcript display.
- No transcript history UI.
- No AI notes, summaries, polishing, or post-processing.
- No vector database, knowledge base, search, chat, or side panel.
- No native Google Calendar or Outlook API in v1.
- No diarization unless it is effectively free through the transcription provider.

## Platform

- macOS 15+ for v1.
- SwiftUI + menu bar app.
- EventKit for Apple Calendar.
- ScreenCaptureKit for microphone and system audio capture.

## Default Settings

- Mode: `Transcribe + save audio`.
- Engine: ElevenLabs.
- Output: one folder per meeting.
- Calendar context sharing: keyterms only, enabled for ElevenLabs.
- Auto-stop guard: enabled.
- End-detection grace period: 30 seconds.
- Stop prompt timeout: 10 seconds.
- Audio retention: keep until manually deleted.

## State Machine

```text
SetupRequired -> Ready -> StartPrompt -> Capturing
Capturing -> EndSuspected -> StopPrompt -> Finalizing
Finalizing -> Transcribing -> Saved
Finalizing/Transcribing -> FailedRecoverable
```

Rules:

- One active recording at a time.
- Capture never starts without user click.
- Audio is durably saved before transcription starts.
- Every session ends with a `transcript.md`.
- If transcription fails, `transcript.md` records failure status and points to saved audio.

## Calendar Watcher

Use EventKit with Apple Calendar full access.

Watcher behavior:

- Watch rolling window from `now - 15 minutes` to `now + 24 hours`.
- Listen for calendar change notifications.
- Poll every 60 seconds.
- Re-evaluate on app launch and wake from sleep.
- Prompt if app launches during an active meeting.
- De-dupe by calendar event ID plus occurrence start time, not title.
- Ignore all-day and free events by default.

V1 is calendar-first. Google Calendar works if synced into macOS Calendar. Direct Google/Outlook APIs are deferred.

## Start Prompt

Before meeting:

- Show quiet preflight 2 minutes before start only if setup is broken.
- Broken setup includes missing permission, missing ElevenLabs key, or unwritable output folder.

At meeting start:

- Show prompt exactly at scheduled start.
- Primary button: `Start Recording`.
- Secondary button: `Skip`.
- No per-call mode choice.
- Prompt copy should name the meeting, for example: `Start recording "Acme Weekly"?`
- Show calendar source subtly, for example: `From Apple Calendar`.

Ignored prompt:

- Keep menu-bar badge active.
- Re-prompt once after 60 seconds.
- After about 3 minutes, stop reminding unless call-like audio is active, then show one final prompt.

## Menu Bar UI

The menu bar item is the trust surface.

Required states:

- Idle: neutral waveform icon.
- Setup required: warning icon.
- Meeting detected: amber dot.
- Recording: red dot plus elapsed time.
- Stopping soon: red dot plus countdown.
- Finalizing/transcribing: spinner.
- Saved: short success notification.
- Failed/recoverable: warning state with retry action.

Clicking the icon should always answer:

- What is happening?
- Which meeting is it for?
- What action is available?

Active recording popover:

- Meeting title.
- `Recording 12:34 - Mic + System Audio`.
- Primary action: `Stop Now`.
- Secondary actions: `Open Folder`, `Settings`.
- Show engine as low-priority metadata.

## Permissions

The app is not ready until all required setup is complete:

- Calendar access.
- Microphone access.
- Screen/system audio capture permission.
- ElevenLabs API key, unless local mode is selected.
- Output folder write access.

Fail closed:

- No mic-only fallback.
- If system audio is missing, recording must not start.
- User-facing copy: `System Audio is required to capture other people in calls.`

Permission recovery:

- Each missing permission gets one `Open System Settings` action.
- Auto-recheck after returning from System Settings.
- Menu bar state should show `Setup Required` until fixed.

## Audio Capture

Use ScreenCaptureKit `SCStream`.

Capture requirements:

- Capture microphone and system audio.
- Keep streams timestamped.
- Exclude current app audio.
- Stream audio to disk continuously.
- Never hold a whole meeting in memory.
- Save mixed `audio.m4a` for user output.
- Keep source separation internally for reliability/debugging where feasible.

For future `Transcribe only` mode:

- Temporary audio may exist until transcript succeeds.
- Delete temporary audio after successful transcription.

### Audio normalization

The mixed `audio.m4a` should be loudness-normalized so playback levels
are consistent across sessions and devices.

- Target: -16 LUFS integrated loudness, true-peak ≤ -1 dBTP.
- Reference: ITU-R BS.1770-4 with EBU R128 gating.

V1.0 status: **deferred to V1.1**.

V1.0-rc1 ships an RMS-style approximation in `AudioFinalizer`:
power-preserving mix (single-active passes through at unity, dual-active
sums at 1/√2 each) with a hard per-sample peak limit at 0.891 (≈ -1
dBFS). This produces consistent perceived volume on synthetic and
typical-call inputs but is not BS.1770-compliant — true BS.1770 is a
~400-line gating + true-peak-oversampling pass that landed too late
for V1.0. Files written by V1.0-rc1 will read back at slightly
different LUFS than a future V1.1 file mixed via real BS.1770.

This deviation is intentional and documented; V1.1 will replace the
RMS approximation with a real BS.1770 pass and the audio.m4a contract
will not change (still mono AAC, 48 kHz). Files written under either
implementation remain valid input for the engine.

## End Guard

The app must prevent runaway recordings.

Detection:

- Do not stop solely because scheduled calendar end time passes.
- After scheduled end, watch for low mic plus low system audio.
- If both remain low for 30 seconds, enter stop prompt flow.

Stop prompt:

- Text: `Call seems over`.
- Primary action: `Keep Recording`.
- Secondary action: `Stop Now`.
- Countdown: `Stopping in 10`.
- If user does nothing, stop automatically.
- If audio resumes during grace/countdown, cancel stop flow.
- If user clicks `Keep Recording`, snooze stop prompts for 15 minutes.

## Transcription

Primary engine:

- ElevenLabs.

Recognition context:

- Use bounded keyterms by default.
- Include title terms, attendee display names, company/domain terms, and acronyms.
- Do not send full calendar description, meeting URLs, attendee emails, dial-in codes, or passwords unless user enables full context.

Local mode:

- Target local model: Cohere Transcribe.
- Treat as a spike until macOS runtime is proven.
- Local mode must not send audio or calendar context to any transcription provider.
- No silent fallback from local to ElevenLabs.

## Output

Every session creates one unique folder and always ends with `transcript.md`.

Example:

```text
2026-04-24-1430 - Customer Call/
  transcript.md
  audio.m4a
  metadata.json
```

Collision example:

```text
2026-04-24-1430 - Customer Call-2/
  transcript.md
  audio.m4a
  metadata.json
```

Write files atomically:

- Write `.partial` files first.
- Rename after successful write.

Folder permissions:

- Owner-only where possible.
- Warn if output folder is in iCloud Drive, Dropbox, Google Drive, or another synced location.

## Markdown Contract

`transcript.md` must exist for every session.

Frontmatter should include:

- `schema`
- `status: complete | partial | failed`
- `title`
- `date`
- `scheduled_start`
- `scheduled_end`
- `actual_start`
- `actual_end`
- `attendees`
- `organizer`
- `location`
- `meeting_url_redacted`
- `calendar_event_id`
- `engine`
- `audio`

Body should include:

- Calendar description/notes, sanitized as plain text.
- Raw timestamped transcript.

Failure transcript:

```markdown
---
schema: transcriber/v1
status: failed
audio: "audio.m4a"
engine: "ElevenLabs"
---

# Transcription Failed

Audio was saved as `audio.m4a`.

Error: ElevenLabs timeout.
```

## Security And Privacy

Sensitive data:

- Audio.
- Transcripts.
- Calendar metadata.
- Attendee lists.
- ElevenLabs key.

Requirements:

- Store ElevenLabs key only in macOS Keychain.
- Never store secrets in UserDefaults, plist files, logs, crash reports, Markdown, or metadata.
- First-run privacy acknowledgement: cloud mode sends audio plus selected keyterms to ElevenLabs; local mode does not.
- No recurring consent reminder.
- No transcript/audio/calendar content in app logs.
- Logs should contain lifecycle only: prompted, started, stopped, failed, provider used.
- Escape YAML and Markdown correctly.
- Redact meeting URLs by default.
- Attendees default to display names only; emails require explicit setting.

## Diagnostics

Add menu item: `Diagnostics...`.

Show:

- OS version.
- App version.
- Permission status.
- Active calendar source.
- Audio levels.
- ElevenLabs key validity.
- Local model status.
- Output path.

Export diagnostics:

- Redact secrets.
- Redact calendar text.
- Do not include transcript or audio content.

