# Transcriber Spec

## Product Definition

Transcriber is a menu-bar-first macOS app that makes sure every important meeting becomes a timestamped Markdown transcript with the original audio saved next to it.

The product should feel like a seatbelt, not a dashboard. It stays out of the way until risk appears: missed start, missing permission, active recording, or runaway recording.

## Design Principles

- **Never fail silently.** Any state where the app appears to be working but isn't (mic muted, system audio routing broken, transcription timed out, file not saved, permission revoked while running) must surface immediately on the menu-bar trust surface. The product promise is "never miss the record"; an app that runs but doesn't capture violates it.
- **Cost-asymmetric prompts.** Missing the start prompt = lose the whole meeting; missing the stop prompt = lose ~10s of post-call audio. Start UX is aggressive (modal + activate-ignoring-other-apps); stop UX is non-focus-stealing (floating HUD).
- **Confidential UI by default.** Every Scribe-owned window sets `NSWindow.sharingType = .none` so prompts and popovers never appear in screen-shared video, regardless of where they render.
- **Finder is the database.** No transcript-history UI in v1. The menu-bar `Recents` section is a 5-item shortcut, not a browser.

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
- Primary engine: ElevenLabs (cloud). Cohere (local) downloads in the background during onboarding regardless of which engine the user picks. A keyless user gets a working app; a keyed user gets a fallback when cloud fails.
- Output: one folder per meeting under `~/Transcriber/`. Avoid `~/Documents/Transcriber/` because Documents may be inside iCloud Desktop & Documents sync.
- Calendar context sharing: keyterms only, enabled for ElevenLabs.
- Auto-stop guard: enabled.
- End-detection grace period: 30 seconds.
- Stop prompt timeout: 10 seconds.
- `Keep Recording` snooze: 3 minutes on first click in a session, 9 on second, 27 on third+. Audio activity resets the silence detector and renders the snooze inert until the next silence stretch. Hard ceiling: regardless of snooze count, force-prompt at scheduled-end + 4 hours.
- Audio retention: keep until manually deleted. No background auto-delete in v1. Bulk delete from Settings → Storage.
- Notifications: `UNUserNotificationCenter` permission requested during onboarding. Without it the redundant-channel pattern collapses; the menu-bar `Setup Required` state fires.

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
- Skip declined and tentative events (respect EventKit participation status).
- Skip events whose end time is already in the past per EventKit, even if a stale calendar cache shows them as active.
- After wake-from-sleep, do not re-prompt for an event the user already skipped or marked `Not this event` in this session.

Late-join (app launches into an active event):

- Prompt only if at least 10 minutes remain on the scheduled event, OR a meeting app is currently running and detected as in-call. Otherwise leave the menu bar in `Meeting detected` state and let the user click in.
- Prompt copy frames the join factually, not apologetically: `Record 'Acme Weekly'? This event started 22 minutes ago. Recording will capture from now onward.`
- Late-joined sessions write `joined_late: true` and `elapsed_at_start_seconds` plus `scheduled_start_at` and `recording_started_at` to frontmatter.

V1 is calendar-first. Google Calendar works if synced into macOS Calendar. Direct Google/Outlook APIs are deferred.

## Start Prompt

Before meeting:

- Show quiet preflight 2 minutes before start only if setup is broken.
- Broken setup includes missing permission, missing ElevenLabs key, or unwritable output folder.

At meeting start:

- Trigger is process-detection-with-calendar-enrichment in v1: an allowlisted meeting app (Zoom/Meet/Teams) that has been running for the dwell window fires the prompt; the title is enriched with the overlapping calendar event. The calendar-event-at-scheduled-start trigger may layer in as a secondary path later (see `q_calendar_or_process_first_trigger`).
- Delivery is an `NSAlert` modal with `NSApp.activate(ignoringOtherApps: true)`. Focus-stealing is intentional: missing the start = losing the entire meeting, which dominates the politeness cost of the interruption.
- Buttons (three): `Start Recording` (primary), `Not this event` (event-specific suppression for the event ID; replaces the older `Not a meeting` label which suppressed the app for 30 minutes — keep that 30-min app-suppression as a separate `Skip for now` semantic), `Skip for now` (just-this-occurrence dismissal).
- Footer link: `Don't ask for this meeting →` for users who never want this recurring calendar series prompted again. Suppression keys on the recurrence-series ID.
- The modal's window must set `NSWindow.sharingType = .none` so it does not appear in shared screen video.
- Position the modal on the screen containing the active meeting-app window, not the keyWindow's screen.
- Audible cue is OFF by default; user-configurable in Settings.

Redundant channels (backup for the modal, never replacement):

- Menu-bar icon flips to the `Meeting detected` glyph the moment the prompt fires. Persists until the user acts.
- A `UNUserNotificationCenter` notification fires in parallel with action buttons matching the modal's three-button choice. The notification persists in Notification Center across DND, screen-share suppression, and fullscreen Zoom — channels the modal can't always reach.
- If the modal is dismissed (accidental ⌘W or Esc), the notification and menu-bar glyph remain, so the user can recover.

Ignored prompt:

- Keep menu-bar badge active.
- Re-prompt with a fresh notification after 60 seconds (refresh, not silent badge persistence — pushed-down notifications don't re-elevate without a new fire).
- After about 3 minutes, stop reminding unless call-like audio is active, then show one final prompt.

Prompt copy:

- Default: `Start recording 'Acme Weekly'?`
- Calendar source subtly: `From Apple Calendar`.
- Late-join variant: `Record 'Acme Weekly'? This event started 22 minutes ago. Recording will capture from now onward.` Two buttons only on late-join: `Start Recording` / `Not this event`. Drop `Skip for now` because the late-join intent space is narrower.

## Menu Bar UI

The menu bar item is the trust surface.

Each state must be distinguishable by shape, not by color alone. Color-only differentiation fails for color-blind users, when Bartender/Ice stows the icon in compressed form, and at small Retina sizes. `Setup required` and `Failed/recoverable` must look different even though both are warnings.

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
- Live audio meters: two thin bars labelled `MIC` and `SYS`. If either bar drops to zero for >5 seconds while recording, the menu-bar icon flips to a warning variant and the popover surfaces the channel that went silent. Silent capture failure is the worst failure mode and must not be invisible.
- `Recording 12:34 - Mic + System Audio` text.
- Primary action: `Stop Now`.
- Secondary actions: `Open Folder`, `Settings`.
- Show engine as low-priority metadata.

Recents section (in the menu bar's main popover, not active-recording popover):

- Last 5 saved sessions, sourced from `outputRoot/` by mtime.
- Each item shows: title, duration, time-of-day or relative day (`12:34 today`, `Yesterday`, `Tue`).
- Inline actions per item: `Open Folder`, `Open Transcript`. Failed sessions also show `Retry`.
- 5 items only — past that is a history UI, which v1 does not ship.
- No "delete audio" action here; bulk audio management lives in Settings → Storage.

Saved success signal:

- Transient `UNUserNotificationCenter` notification: title `Acme Weekly · transcript saved`, body `54 min · 47 MB · ElevenLabs`. Auto-dismisses per macOS default. Two action buttons: `Open Folder`, `Open Transcript`.
- Menu-bar `Saved` glyph for ~3 seconds, then revert to `Idle`.
- No persistent in-app toast. The Recents popover is the durable record.

## Permissions

The app is not ready until all required setup is complete:

- Microphone access.
- Calendar access.
- `UNUserNotificationCenter` (Notifications) permission.
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

## Onboarding

One screen per permission, in this order:

1. Welcome.
2. Microphone (most-explainable; immediately tied to product purpose).
3. Calendar (`So Transcriber can label your recordings with meeting context.`).
4. Notifications (`So you don't miss meeting prompts.`).
5. Screen Recording (the showpiece — see below). Cohere model download starts as a background task here.
6. ElevenLabs API Key (optional; if skipped, default engine flips to Local once Cohere finishes downloading).
7. Choose Engine (side-by-side: Cloud ready ✓ if key entered, Local ready when download completes).
8. Output Folder (default `~/Transcriber/`; pick alternative; warn if user picks a third-party File Provider cloud — see Output).
9. Test Recording (waits until at least one engine is ready; runs immediately if cloud key was entered).
10. Done.

Each permission screen includes:

- Headline (what's being asked).
- One-sentence why, tied to user experience.
- Visual showing the captured artifact, not the technology. Screen-Recording screen specifically: two-column layout showing what IS captured (audio waveform + speaker labels icon) and what is NOT (greyed-out video frame, screenshots, keystrokes, browser history) with explicit cross-out marks. Tagline: `macOS calls this 'Screen Recording' for technical reasons, but no video or screen content ever leaves your machine.`
- `Continue` triggers the system permission prompt.
- After dialog returns, screen updates in place to ✓ granted, ✗ denied (with `Open System Settings` + retry), or ⚠ deferred. Hold the result for ~1 second before advancing so the user sees the ✓ land.
- `Skip` only on Calendar and Notifications (the optional ones; Mic and Screen Recording cannot be skipped because of fail-closed).

Resumability:

- If the user quits mid-onboarding, the next launch resumes at the first un-granted required permission, not the welcome screen.
- The same per-permission screens are reused for the Setup-Required popover when permissions get revoked later — same UI, different entry point.

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

- Delivery: a floating HUD (`NSPanel` with `.floatingWindowLevel`, non-activating). Visible across spaces and over fullscreen meeting apps. Does NOT steal focus from Zoom/Meet/Teams. The asymmetric-cost reasoning (start matters more than stop) justifies a less aggressive surface here than the start prompt's `NSAlert`.
- Text: `Call seems over`.
- Big numeric countdown is primary (`10`, `9`, `8`...). Progress ring secondary in the HUD.
- Menu-bar icon flips to `Stopping soon` with the countdown digit (`●5`, `●4`, ...) so the user sees the same number even when the HUD is missed.
- Primary action: `Keep Recording`. Secondary: `Stop Now`.
- A `UNUserNotificationCenter` notification fires in parallel as a redundant channel for users who walked away from screen.
- Optional audible cue (off by default, Settings toggle); recommended for users who often present.
- The HUD's window must set `NSWindow.sharingType = .none`.
- If user does nothing, stop automatically when countdown reaches 0.
- If audio resumes during grace or countdown, cancel the stop flow silently and suppress re-prompt for at least 60 seconds.
- If user clicks `Keep Recording`, escalating snooze: 3 / 9 / 27 minutes per session click count.

False-stop guard:

- Long silences during an active meeting (reading documents, silent screen-share review, breakout transition, waiting room) must NOT silently terminate the session. The HUD + countdown gives the user a 10-second window to catch a false positive. Audible cue is the recommended hedge for users who are routinely in long-silence calls.

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
- No silent fallback in either direction (local → cloud or cloud → local). Engine switches are explicit user actions.

Cohere lifecycle:

- Background download starts during the Screen Recording onboarding step, regardless of which engine the user picks. This guarantees a keyless user has a working app and a keyed user has a fallback when cloud fails.
- Atomic write (`.partial` → rename) and checksum verification on completion. While unverified, the engine pointer stays on the user's chosen primary; switching to Local is blocked until verification.
- If the download fails or is cancelled, surface clearly with a Retry action. Do not silently fall back; that would violate the no-silent-fallback rule.
- User can later trigger redownload from Settings → Engine.

Engine failure:

- A failed cloud transcription (timeout, 401, 429, 5xx after retries) writes a `status: failed` transcript per the Markdown Contract and surfaces a `Retry` affordance on the failed session in the menu-bar Recents popover.
- The user may switch engines manually (Settings → Engine) and re-trigger transcription on the saved audio. Both engines must be ready for this to be a one-click move; that's the reason Cohere is staged during onboarding rather than on first need.

## Output

Every session creates one unique folder and always ends with `transcript.md`.

Default output root: `~/Transcriber/`. Avoid `~/Documents/Transcriber/` because Documents may be inside iCloud Desktop & Documents sync. `~/Movies/Transcriber/` is an acceptable alternative if the user prefers a media-themed location.

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

Synced-folder detection:

- Detect generically via `~/Library/CloudStorage/*` (catches Dropbox, Google Drive, OneDrive, Box, Proton Drive, Sync.com, Tresorit, Nextcloud, etc. through the macOS File Provider extension), the iCloud path `~/Library/Mobile Documents/com~apple~CloudDocs/`, and legacy paths (`~/Dropbox`, `~/OneDrive*`, `/Volumes/GoogleDrive`, `~/Adobe Creative Cloud Files`).
- iCloud Drive: NO blocking warning (it's the macOS-default storage; warning iCloud users is friction for the modal case). Surface a passive note in Settings: `Saved sessions sync via iCloud Drive.`
- Third-party File Provider clouds: warn once per synced root, not per literal path. Soft copy: `Heads up: audio will sync to {provider}. Recordings (~30 MB per hour) will upload to {provider}'s servers as they save. Sync conflicts can produce duplicate files.` Two buttons: `Use this folder anyway`, `Choose a different folder`.
- Re-warn on root change (different provider account or different sync provider) but not on subdirectory change within a known root.
- Detection runs at three deterministic moments only: folder selection, app launch, and recording start. No background scanning.

## Storage

Settings → Storage panel (referenced here, not a separate spec section):

- Total Transcriber audio size on disk.
- `Reveal in Finder` action.
- `Delete all audio (keep transcripts)` action behind confirmation.
- Pre-record disk-space warning if free disk is below ~1 GB at recording start.
- Post-record audio size visible in the saved notification (`54 min · 47 MB · ElevenLabs`) so users see accumulation without surprise.
- No background auto-delete in v1.

## Markdown Contract

`transcript.md` must exist for every session.

### Frontmatter

Required for every session (success or failure):

- `title`
- `date` (ISO 8601 day, e.g. `2026-04-30`)
- `scheduled_start` (ISO 8601 datetime with offset)
- `scheduled_end`
- `actual_start`
- `actual_end`
- `attendees` (list of display names)
- `organizer`
- `location`
- `meeting_url_redacted`
- `calendar_event_id`
- `engine` (e.g. `elevenlabs`, `cohere`)
- `audio` (relative path to the audio file)

Conditional:

- `status` is OMITTED when the session completed successfully. It is required when the session is `partial` or `failed`. A file with no `status` field is `complete` by convention. (Same logic as HTTP not requiring a `200 OK` body.)
- `joined_late: true`, `elapsed_at_start_seconds`, `recording_started_at` are written only when the session was a late-join.

Failure-only fields (in addition to the above):

- `error_code` (e.g. `elevenlabs_timeout`, `elevenlabs_401`, `network_offline`)
- `error_message` (one-line, no stack traces, no PII)
- `retry_count`
- `audio_duration_seconds`
- `audio_size_bytes`

Schema versioning is YAGNI in v1 — no `schema` field. Add when v2 actually breaks compatibility; agents reading old unmarked files can assume v1.

### Body

Order: H1 title → metadata blockquote → attendees list → calendar notes (if any) → `## Transcript`. Calendar notes are NEVER intermixed with the transcript.

```markdown
---
title: "Customer Call - Acme Weekly"
date: 2026-04-30
scheduled_start: 2026-04-30T14:30:00+02:00
scheduled_end: 2026-04-30T15:00:00+02:00
actual_start: 2026-04-30T14:30:12+02:00
actual_end: 2026-04-30T15:25:03+02:00
attendees:
  - "Szymon Sypniewicz"
  - "Jane Doe"
organizer: "Szymon Sypniewicz"
location: ""
meeting_url_redacted: "[redacted zoom.us URL]"
calendar_event_id: "abc123..."
engine: "elevenlabs"
audio: "audio.m4a"
---

# Customer Call - Acme Weekly

> 14:30-15:25 (Apple Calendar) · Mic + System Audio · ElevenLabs Scribe v2

## Attendees
- Szymon Sypniewicz (organizer)
- Jane Doe

## Notes from calendar

{sanitized calendar description, if any}

## Transcript

### [14:30:12] Speaker A
Thanks for joining. Quick agenda today — we want to walk through the
Q2 numbers, then talk about the renewal timeline.

### [14:30:38] Speaker B
Sounds good. Should we start with revenue or churn?

### [14:30:42] Speaker A
Revenue. Jane has the deck queued up.
```

Speaker rendering rules:

- Each speaker block is an H3 heading: `### [HH:MM:SS] Speaker A`. H3 lets Obsidian outlines and markdown TOC tools render a navigable speaker timeline for free.
- One timestamp per speaker block, not per utterance. Word-level timestamps from ElevenLabs (when present) are not rendered in the .md; if needed for downstream tooling they can live in a sibling JSON file.
- Consecutive same-speaker utterances are grouped into one block. Otter's pattern.
- Speaker labels stay as `Speaker A / B / C` in v1. No in-app rename. Users sed/find-replace in their editor of choice.

### Failure transcript

Same body shape, with `status: failed` frontmatter, error metadata, and a `## What you can do` section listing concrete recovery actions:

```markdown
---
status: failed
title: "Customer Call - Acme Weekly"
date: 2026-04-30
actual_start: 2026-04-30T14:30:12+02:00
actual_end: 2026-04-30T15:25:03+02:00
audio: "audio.m4a"
audio_duration_seconds: 3291
audio_size_bytes: 52840192
engine: "elevenlabs"
error_code: "elevenlabs_timeout"
error_message: "Job did not complete within 90s"
retry_count: 2
---

# Transcription Failed

Audio is saved at `audio.m4a` (54 MB, 54:51 duration).

ElevenLabs returned a timeout after 2 retries. The recording itself is intact and complete.

## What you can do

- Retry from the Transcriber menu bar: click the icon, then `Retry` next to this session.
- Or transcribe locally: Settings → Engine → Cohere (local), then retry.
- Or transcribe outside Transcriber: open `audio.m4a` in any other tool.
```

Retry must be one-click from the menu-bar Recents popover for any failed session within the last 24 hours, not just the most recent.

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
- Confidential UI: every Transcriber-owned window sets `NSWindow.sharingType = .none` (start prompt modal, stop prompt HUD, active-recording popover, settings, setup-required popover, diagnostics, privacy acknowledgement sheet). Prompts and popovers must not appear in shared screen video, regardless of which display they render on.

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

