# Transcriber

Menu-bar-first macOS app that makes sure every important meeting becomes a timestamped Markdown transcript with the original audio saved next to it.

The product feels like a seatbelt, not a dashboard. It stays out of the way until risk appears: missed start, missing permission, active recording, runaway recording, silent capture failure.

This document is the single source of truth: product spec, design decisions, open questions, and acceptance criteria. Where it conflicts with anything else, it prevails.

## Contents

- [Product](#product)
- [Design Principles](#design-principles)
- [Platform](#platform)
- [State Machine](#state-machine)
- [Default Settings](#default-settings)
- [Calendar Watcher](#calendar-watcher)
- [Start Prompt](#start-prompt)
- [Menu Bar UI](#menu-bar-ui)
- [Permissions](#permissions)
- [Onboarding](#onboarding)
- [Audio Capture](#audio-capture)
- [End Guard](#end-guard)
- [Transcription](#transcription)
- [Output and Storage](#output-and-storage)
- [Markdown Contract](#markdown-contract)
- [Security and Privacy](#security-and-privacy)
- [Diagnostics](#diagnostics)
- [Open Questions](#open-questions)
- [Acceptance and QA](#acceptance-and-qa)
- [Appendix A: Origin Notes](#appendix-a-origin-notes)
- [Appendix B: References](#appendix-b-references)

---

## Product

- **Promise:** "Never miss the record of an important meeting."
- **Type:** Call-capture insurance, not an AI meeting-notes app.
- **v1 surface:** Menu-bar app.
- **Record-only:** No import flow. Record-only is intentional; importing existing audio is a different product.

### Non-goals

- No live transcript display.
- No transcript history UI. Finder is the database; the menu-bar Recents popover is a 5-item shortcut, not a browser.
- No AI notes, summaries, polishing, or post-processing.
- No vector database, knowledge base, search, chat, or side panel.
- No native Google Calendar or Outlook API in v1.
- No diarization unless it is effectively free through the transcription provider.

## Design Principles

- **Never fail silently.** Any state where the app appears to be working but isn't (mic muted, system audio routing broken, transcription timed out, file not saved, permission revoked while running) must surface immediately on the menu-bar trust surface. The product promise is "never miss the record"; an app that runs but doesn't capture violates it.
- **Cost-asymmetric prompts.** Missing the start prompt = lose the whole meeting. Missing the stop prompt = lose ~10s of post-call audio. Start UX is aggressive (modal + activate-ignoring-other-apps); stop UX is non-focus-stealing (floating HUD).
- **Confidential UI by default.** Every Transcriber-owned window sets `NSWindow.sharingType = .none` so prompts and popovers never appear in screen-shared video, regardless of where they render.
- **Finder is the database.** No transcript-history UI in v1. The menu-bar Recents section is a 5-item shortcut.
- **Inspectable proof, not marketing claims.** Trust UI shows where audio goes, what is captured, what is excluded, and which engine ran — not just "your data is private."

## Platform

- macOS 15+ for v1.
- SwiftUI + menu bar app.
- EventKit for Apple Calendar.
- ScreenCaptureKit for microphone and system audio capture.

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
- **Never interrupt an active recording with a new start prompt.** While Capturing, all start-prompt triggers (process-detection candidates, calendar-event start times) are suppressed. The watcher continues to track the next event but does not modal-prompt.
- **Surface the queued next event in the active-recording popover.** When a new event begins during recording, add a `Next: 'Customer Call - Acme' at 15:00` line under the Privacy Status block. No focus interruption.
- **Queue-then-fire on stop.** When the current recording ends (auto-stop, manual `Stop Now`, or finalize), if the queued event is still active and process-detection is still positive, fire its prompt immediately. If the queued event has expired, drop it.
- **No automatic context switching.** The user always confirms each new recording explicitly. There is no "stop A and start B" hotkey or single-button transition.

## Default Settings

- Mode: `Transcribe + save audio`.
- Primary engine: ElevenLabs (cloud). Cohere (local) downloads in the background during onboarding regardless of which engine the user picks. A keyless user gets a working app; a keyed user gets a fallback when cloud fails.
- Output: one folder per meeting under `~/Transcriber/`. Avoid `~/Documents/Transcriber/` because Documents may be inside iCloud Desktop & Documents sync. `~/Movies/Transcriber/` is an acceptable alternative.
- Calendar context sharing: keyterms only.
- Auto-stop guard: enabled.
- End-detection grace period: 30 seconds.
- Stop prompt timeout: 10 seconds.
- `Keep Recording` snooze: escalates 3 / 9 / 27 minutes per session click count. Audio activity resets the silence detector and renders the snooze inert until the next silence stretch. Hard ceiling: regardless of snooze count, force-prompt at scheduled-end + 4 hours.
- Audio retention: keep until manually deleted. No background auto-delete in v1.
- Notifications: `UNUserNotificationCenter` permission requested during onboarding. Without it the redundant-channel pattern collapses; the menu-bar `Setup Required` state fires.

## Calendar Watcher

Use EventKit with Apple Calendar full access.

Watcher behavior:

- Watch rolling window from `now - 15 minutes` to `now + 24 hours`.
- Listen for calendar change notifications.
- Poll every 60 seconds.
- Re-evaluate on app launch and wake from sleep.
- De-dupe by calendar event ID plus occurrence start time, not title.
- Ignore all-day and free events by default.
- Skip declined and tentative events (respect EventKit participation status).
- Skip events whose end time is already in the past per EventKit, even if a stale calendar cache shows them as active.
- After wake-from-sleep, do not re-prompt for an event the user already dismissed via `Not now` or suppressed via `More options ▾ → Stop asking about this meeting` in this session.

Late-join (app launches into an active event):

- Prompt only if at least 10 minutes remain on the scheduled event, OR a meeting app is currently running and detected as in-call. Otherwise leave the menu bar in `Meeting detected` state and let the user click in.
- Prompt copy frames the join factually, not apologetically: `Record 'Acme Weekly'? This event started 22 minutes ago. Recording will capture from now onward.`
- Late-joined sessions write `joined_late: true` and `elapsed_at_start_seconds` to frontmatter. The standard `scheduled_start` and `actual_start` fields already encode the schedule and the recording-start timestamps; no `scheduled_start_at` / `recording_started_at` aliases.

V1 is calendar-first. Google Calendar works if synced into macOS Calendar. Direct Google/Outlook APIs are deferred.

## Start Prompt

Before meeting:

- Show quiet preflight 2 minutes before start only if setup is broken.
- Broken setup includes a missing required permission, a missing ElevenLabs key when Cloud is the selected engine, or an unwritable output folder. Missing recommended permissions (Calendar, Notifications) do not count as broken; the `Setup Required` badge fires but recording can still proceed via manual `Record Now`.

At meeting start:

- Trigger is process-detection-with-calendar-enrichment in v1: an allowlisted meeting app (Zoom/Meet/Teams) that has been running for the dwell window fires the prompt; the title is enriched with the overlapping calendar event. The pure calendar-event-at-scheduled-start trigger may layer in as a secondary path later (see `q_calendar_or_process_first_trigger`).
- Delivery is an `NSAlert` modal with `NSApp.activate(ignoringOtherApps: true)`. Focus-stealing is intentional: missing the start dominates the politeness cost of the interruption.
- Two buttons only: `Start Recording` (primary) and `Not now` (secondary). Both standard and late-join prompts use the same two-button shape so the cognitive surface is constant.
- Below the buttons: a small `More options ▾` disclosure that hides the rare suppression flows. Closed by default. When opened, exposes:
  - `Stop asking about this meeting` — suppresses the recurring calendar series indefinitely (keys on recurrence-series ID).
  - `Stop detecting [App] for 30 minutes` — app-level suppression that defends against false-positive process detection.
- Suppressed meetings are managed in Settings → Quiet Meetings, where users can re-enable any series they previously suppressed.
- The modal's window must set `NSWindow.sharingType = .none`.
- Position the modal on the screen containing the active meeting-app window, not the keyWindow's screen.
- Audible cue is OFF by default; user-configurable in Settings.

Redundant channels (backup for the modal, never replacement):

- Menu-bar icon flips to the `Meeting detected` glyph the moment the prompt fires. Persists until the user acts.
- A `UNUserNotificationCenter` notification fires in parallel with action buttons matching the modal's two-button choice. The notification persists in Notification Center across DND, screen-share suppression, and fullscreen Zoom — channels the modal can't always reach.
- If the modal is dismissed (accidental ⌘W or Esc), the notification and menu-bar glyph remain so the user can recover.

Ignored prompt:

- Keep menu-bar badge active.
- Re-prompt with a fresh notification after 60 seconds (refresh, not silent badge persistence — pushed-down notifications don't re-elevate without a new fire).
- After about 3 minutes, stop reminding unless call-like audio is active, then show one final prompt.

Prompt copy:

- Default: `Start recording 'Acme Weekly'?`
- Calendar source subtly: `From Apple Calendar`.
- Late-join variant: `Record 'Acme Weekly'? This event started 22 minutes ago. Recording will capture from now onward.` Same two-button shape and the same `More options ▾` disclosure.

## Menu Bar UI

The menu bar item is the trust surface.

Each state must be distinguishable by shape, not by color alone. Color-only differentiation fails for color-blind users, when Bartender/Ice stows the icon in compressed form, and at small Retina sizes. `Setup Required` and `Failed/recoverable` must look different even though both are warnings.

Required states:

- Idle: neutral waveform icon.
- Setup Required: warning icon.
- Meeting detected: amber dot.
- Recording: red dot plus elapsed time, plus a live signal indicator (see below).
- Stopping soon: red dot plus countdown.
- Finalizing/transcribing: spinner.
- Saved: short success notification.
- Failed/recoverable: warning state with retry action.

Live signal indicator (Recording state only):

- Two small marks adjacent to the elapsed time, one for `MIC` and one for `SYS`. Default is a thin pulsing bar that animates with audio level.
- A mark dims and turns amber if its channel falls below the silent-channel threshold for >5 seconds. Both marks turn amber if both channels are silent.
- This is the at-a-glance trust signal: the user verifies capture is healthy without opening the popover.

Clicking the icon should always answer:

- What is happening?
- Which meeting is it for?
- What action is available?

Active recording popover:

- Meeting title.
- **Privacy Status block** (always at the top of the popover, never collapsed):
  - `Audio: local · ~/Transcriber/Customer Call - Acme/`
  - `Captured: mic + system audio · no video, no screenshots`
  - `Engine: ElevenLabs (cloud)` or `Engine: Cohere (local)` — explicit, never abbreviated.
- Live audio meters: two thin bars labelled `MIC` and `SYS` (larger than the menu-bar indicator; same data source).
- `Recording 12:34 - Mic + System Audio` text.
- Primary action: `Stop Now`.
- Secondary actions: `Open Folder`, `Settings`.

Recents section (in the menu bar's main popover, not the active-recording popover):

- Last 5 saved sessions, sourced from `outputRoot/` by mtime.
- Each item shows: title, duration, time-of-day or relative day (`12:34 today`, `Yesterday`, `Tue`).
- Inline actions per item: `Open Folder`, `Open Transcript`. Failed sessions also show `Retry`.
- 5 items only — past that is a history UI, which v1 does not ship.
- No `Delete audio` action here; bulk audio management lives in Settings → Storage.

Saved success signal:

- Transient `UNUserNotificationCenter` notification: title `Acme Weekly · transcript saved`, body `54 min · 47 MB · ElevenLabs`. Auto-dismisses per macOS default. Two action buttons: `Open Folder`, `Open Transcript`.
- Menu-bar `Saved` glyph for ~3 seconds, then revert to `Idle`.
- No persistent in-app toast. The Recents popover is the durable record.

## Permissions

Permissions split into two tiers.

Required (recording cannot start without these):

- Microphone access.
- Screen/system audio capture permission.
- Output folder write access.
- ElevenLabs API key when Cloud is the selected engine. Optional when Local (Cohere) is selected.

Recommended (app works in degraded mode without; menu bar shows `Setup Required`):

- Calendar access. Without it the calendar-driven prompt and event-aware metadata fall back to manual `Record Now`.
- `UNUserNotificationCenter` (Notifications) permission. Without it the redundant-channel pattern collapses to the modal only; users may miss prompts in fullscreen Zoom or DND.

Fail closed:

- No mic-only fallback.
- If system audio is missing, recording must not start.
- User-facing copy: `System Audio is required to capture other people in calls.`

Permission recovery:

- Each missing permission gets one `Open System Settings` action.
- Auto-recheck after returning from System Settings.
- Menu bar state shows `Setup Required` until all required and recommended permissions are granted. Required permissions block recording; recommended permissions only show the badge.

## Onboarding

One screen per permission, in this order:

1. Welcome.
2. Microphone — most-explainable; immediately tied to product purpose.
3. Calendar — `So Transcriber can label your recordings with meeting context.`
4. Notifications — `So you don't miss meeting prompts.`
5. Screen Recording — the showpiece (see below). Cohere model download starts as a background task here.
6. ElevenLabs API Key — optional; if skipped, default engine flips to Local once Cohere finishes downloading.
7. Choose Engine — side-by-side: Cloud ready ✓ if key entered, Local ready when download completes.
8. Output Folder — default `~/Transcriber/`; pick alternative; warn if user picks a third-party File Provider cloud (see Output and Storage).
9. Test Recording — waits until at least one engine is ready; runs immediately if cloud key was entered.
10. Done.

Each permission screen includes:

- Headline (what's being asked).
- One-sentence why, tied to user experience.
- Visual showing the captured artifact, not the technology. Screen-Recording specifically: two-column layout showing what IS captured (audio waveform + speaker labels icon) and what is NOT (greyed-out video frame, screenshots, keystrokes, browser history) with explicit cross-out marks. Tagline: `macOS calls this 'Screen Recording' for technical reasons, but no video or screen content ever leaves your machine.`
- `Continue` triggers the system permission prompt.
- After dialog returns, screen updates in place to ✓ granted, ✗ denied (with `Open System Settings` + retry), or ⚠ deferred. Hold the result for ~1 second before advancing so the user sees the ✓ land.
- `Skip` only on Calendar and Notifications (recommended tier; Mic and Screen Recording cannot be skipped).

Resumability:

- If the user quits mid-onboarding, the next launch resumes at the first un-granted required permission, not the welcome screen.
- The same per-permission screens are reused for the Setup-Required popover when permissions get revoked later. Same UI, different entry point.

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

The mixed `audio.m4a` should be loudness-normalized so playback levels are consistent across sessions and devices.

- Target: -16 LUFS integrated loudness, true-peak ≤ -1 dBTP.
- Reference: ITU-R BS.1770-4 with EBU R128 gating.

V1.0 status: deferred to V1.1. V1.0-rc1 ships an RMS-style approximation in `AudioFinalizer` (power-preserving mix at unity / 1/√2; per-sample peak limit at 0.891). V1.1 will replace the approximation with a real BS.1770 pass; the `audio.m4a` contract does not change (mono AAC, 48 kHz). Files written under either implementation remain valid input for the engine.

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
- Menu-bar icon flips to `Stopping soon` with the countdown digit so the user sees the same number even when the HUD is missed.
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

Primary engine: ElevenLabs.

Recognition context:

- Use bounded keyterms by default.
- Include title terms, attendee display names, company/domain terms, and acronyms.
- Do not send full calendar description, meeting URLs, attendee emails, dial-in codes, or passwords. Whether a "full context" opt-in setting ships in v1 is open (see `q_full_context_setting`).

Local mode (Cohere):

- Target local model. Treat as a spike until macOS runtime is proven.
- Local mode must not send audio or calendar context to any transcription provider.
- No silent fallback in either direction (local → cloud or cloud → local). Engine switches are explicit user actions.

Cohere lifecycle:

- Background download starts during the Screen Recording onboarding step, regardless of which engine the user picks. This guarantees a keyless user has a working app and a keyed user has a fallback when cloud fails.
- Atomic write (`.partial` → rename) and checksum verification on completion. While unverified, the engine pointer stays on the user's chosen primary; switching to Local is blocked until verification.
- If the download fails or is cancelled, surface clearly with a Retry action. Do not silently fall back.
- User can later trigger redownload from Settings → Engine.

Engine failure:

- A failed cloud transcription (timeout, 401, 429, 5xx after retries) writes a `status: failed` transcript per the Markdown Contract and surfaces a `Retry` affordance on the failed session in the menu-bar Recents popover.
- The user may switch engines manually (Settings → Engine) and re-trigger transcription on the saved audio. Both engines must be ready for this to be a one-click move; that's the reason Cohere is staged during onboarding rather than on first need.

## Output and Storage

Every session creates one unique folder and always ends with `transcript.md`.

Default output root: `~/Transcriber/`. `~/Movies/Transcriber/` is an acceptable alternative. Avoid `~/Documents/Transcriber/` because Documents may be inside iCloud Desktop & Documents sync.

Folder structure:

```text
2026-04-24-1430 - Customer Call/
  transcript.md
  audio.m4a
  metadata.json
```

Collisions add a numeric suffix:

```text
2026-04-24-1430 - Customer Call-2/
```

Atomic writes:

- Write `.partial` files first.
- Rename after successful write.

Folder permissions:

- Owner-only where possible.

Synced-folder detection:

- Detect generically via `~/Library/CloudStorage/*` (catches Dropbox, Google Drive, OneDrive, Box, Proton Drive, Sync.com, Tresorit, Nextcloud, etc. through the macOS File Provider extension), the iCloud path `~/Library/Mobile Documents/com~apple~CloudDocs/`, and legacy paths (`~/Dropbox`, `~/OneDrive*`, `/Volumes/GoogleDrive`, `~/Adobe Creative Cloud Files`).
- iCloud Drive: NO blocking warning (it's the macOS-default storage). Surface a passive note in Settings: `Saved sessions sync via iCloud Drive.`
- Third-party File Provider clouds: warn once per synced root, not per literal path. Soft copy: `Heads up: audio will sync to {provider}. Recordings (~30 MB per hour) will upload to {provider}'s servers as they save. Sync conflicts can produce duplicate files.` Two buttons: `Use this folder anyway`, `Choose a different folder`.
- Re-warn on root change (different provider account or different sync provider); not on subdirectory change within a known root.
- Detection runs at three deterministic moments only: folder selection, app launch, and recording start. No background scanning.

Settings → Storage panel:

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

- `status` is OMITTED when the session completed successfully. It is required when the session is `partial` or `failed`. A file with no `status` field is `complete` by convention.
- `joined_late: true` and `elapsed_at_start_seconds` are written only when the session was a late-join. `scheduled_start` and `actual_start` are the canonical timestamps; no `scheduled_start_at` / `recording_started_at` aliases.

Failure-only fields (in addition to the above):

- `error_code` (e.g. `elevenlabs_timeout`, `elevenlabs_401`, `network_offline`)
- `error_message` (one-line, no stack traces, no PII)
- `retry_count`
- `audio_duration_seconds`
- `audio_size_bytes`

When a required field is genuinely unavailable at failure time, the writer emits an empty value rather than omitting the key, so downstream agents see a stable shape.

Schema versioning is YAGNI in v1 — no `schema` field. Add when v2 actually breaks compatibility.

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

> 14:30-15:25 (Apple Calendar) · Mic + System Audio · ElevenLabs

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

- Each speaker block is an H3 heading: `### [HH:MM:SS] Speaker A`. H3 lets Obsidian outlines and markdown TOC tools render a navigable speaker timeline.
- One timestamp per speaker block, not per utterance. Word-level timestamps from ElevenLabs are not rendered in the .md; if needed for downstream tooling they can live in a sibling JSON file (see `q_word_level_timestamps_sidecar`).
- Consecutive same-speaker utterances are grouped into one block.
- Speaker labels stay as `Speaker A / B / C` in v1. No in-app rename.

### Failure transcript

Same body shape as success (H1, metadata blockquote, attendees, calendar notes), but the transcript section is replaced by `# Transcription Failed` plus a `## What you can do` block.

```markdown
---
status: failed
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
audio_duration_seconds: 3291
audio_size_bytes: 52840192
error_code: "elevenlabs_timeout"
error_message: "Job did not complete within 90s"
retry_count: 2
---

# Transcription Failed

Audio is saved at `audio.m4a` (54 MB, 54:51 duration). The recording itself is intact and complete; only transcription failed.

ElevenLabs returned a timeout after 2 retries.

## What you can do

- Retry from the Transcriber menu bar: click the icon, then `Retry` next to this session.
- Or transcribe locally: Settings → Engine → Cohere (local), then retry.
- Or transcribe outside Transcriber: open `audio.m4a` in any other tool.
```

Retry must be one-click from the menu-bar Recents popover for any failed session within the last 24 hours, not just the most recent.

## Security and Privacy

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
- Logs contain lifecycle only: prompted, started, stopped, failed, provider used.
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

---

## Open Questions

Each question has a stable unique ID for future agent work.

### Product and UX

- `q_target_wedge`: Should v1 target a narrower persona first (founder/customer calls, sales calls, recruiting calls, research calls)?
- `q_start_reminder_duration`: Should ignored start prompts continue for 3 minutes, 5 minutes, or while call-like audio is active?
- `q_preflight_prompt`: Should broken setup preflight appear 2 minutes before meeting start, 5 minutes before, or only at app launch?
- `q_calendar_or_process_first_trigger`: V1 fires the start prompt on process-detection-with-calendar-enrichment. Should a pure calendar-event-at-scheduled-start trigger layer in as a secondary path?
- `q_audible_cue_default`: Should the optional audible cue on the stop prompt be on by default for any user segment (e.g., users who often present)?

### End Guard

- `q_end_audio_threshold`: What audio-level threshold counts as low mic plus low system audio?
- `q_end_grace_seconds`: Should end-detection grace be fixed at 30 seconds or configurable?
- `q_calendar_end_plus_audio`: Should auto-stop only arm after scheduled calendar end, or also after long silence before scheduled end?

### Calendar Metadata

- `q_calendar_description_markdown`: Should full calendar notes/description always be included in local Markdown?
- `q_calendar_url_retention`: Should meeting URLs be fully redacted by default, or domain plus redacted URL stored?
- `q_attendee_email_retention`: Should attendee emails ever be stored, or display names only?
- `q_full_context_setting`: Should "full calendar context to ElevenLabs" exist in v1 or be deferred?

### Transcription

- `q_elevenlabs_model`: Which ElevenLabs model/version should be pinned for v1?
- `q_context_keyterm_limit`: What max number of recognition keyterms should be sent to ElevenLabs?
- `q_transcription_retry_policy`: How many automatic retries should failed ElevenLabs jobs get?
- `q_partial_transcript`: If transcription partially succeeds, should `transcript.md` include partial text plus failure metadata?
- `q_word_level_timestamps_sidecar`: Should ElevenLabs's word-level timestamps be persisted to a sibling `transcript.json` for downstream tooling?

### Local Mode

- `q_cohere_runtime`: What macOS runtime path can run Cohere Transcribe reliably from the app?
- `q_cohere_model_size`: What is the actual Cohere model size, and does it justify the onboarding-time download?
- `q_local_model_fallback`: If Cohere is not practical, should Parakeet v3 or WhisperKit be the fallback local engine?

### Storage

- `q_synced_folder_warning_persistence`: Where is the "user-acknowledged synced folders" list stored — UserDefaults, or in the Settings JSON blob?
- `q_disk_full_behavior`: What should happen when disk space is low before or during recording? Pre-record warning is decided; mid-record disk-full handling is open.

### Release

- `q_repo_shape`: Should the implementation split into `TranscriberApp`, `TranscriberCore`, and `TranscriberCoreTests` immediately?
- `q_diagnostics_bundle`: What exact fields should diagnostics export include?
- `q_packaging`: Is the first release a signed `.app`, signed/notarized `.dmg`, or Homebrew cask?

### Resolved

These IDs are kept as a stable trail; the resolution lives in the relevant section of this spec.

- `q_skip_semantics` — resolved by the two-button + `More options ▾` model in [Start Prompt](#start-prompt).
- `q_late_join_prompt` — resolved by [Calendar Watcher → Late-join](#calendar-watcher) and the same Start Prompt model.
- `q_keep_recording_snooze_minutes` — resolved by 3 / 9 / 27 escalation in [End Guard](#end-guard).
- `q_synced_folder_warning` — resolved by per-provider-class detection in [Output and Storage](#output-and-storage).
- `q_audio_retention` — resolved by keep-until-deleted + Settings → Storage panel in [Output and Storage](#output-and-storage).

---

## Acceptance and QA

### V1 Acceptance Criteria

- Recording captures both microphone and system audio.
- Audio is saved durably before transcription starts.
- Every session folder contains `transcript.md`. Failure transcripts include `error_code`, `retry_count`, audio metadata, and a `## What you can do` body section.
- Default output root is `~/Transcriber/`, not `~/Documents/Transcriber/`.
- Required permissions block recording loudly. Recommended permissions only show the `Setup Required` badge.
- Auto-stop fires after the end-guard timeout if `Keep Recording` is not clicked.
- `Keep Recording` snoozes 3 / 9 / 27 minutes per session click count.
- Both standard and late-join prompts present exactly two buttons: `Start Recording` and `Not now`. The `More options ▾` disclosure is closed by default and exposes meeting-suppress and app-suppress.
- Suppressed recurring meetings appear in Settings → Quiet Meetings with a `Re-enable` action per series.
- Late-join prompt fires only if at least 10 minutes remain on the scheduled event or a meeting app is currently in-call.
- Late-joined sessions write `joined_late: true` and `elapsed_at_start_seconds`; `scheduled_start` and `actual_start` already carry the timestamps.
- Stop prompt is a floating HUD; it does not steal focus.
- Menu bar icon shows live `MIC` and `SYS` indicators next to elapsed time during Recording. They dim/amber when their channel is silent for >5 seconds.
- Active-recording popover opens with a Privacy Status block at top showing destination path, captured sources, exclusions, and full engine label.
- Recents popover shows at most 5 saved sessions, with `Open Folder` / `Open Transcript` and (for failed sessions) `Retry`.
- Saved success fires a transient notification and a brief menu-bar `Saved` glyph; no persistent in-app toast.
- Cohere downloads in the background during onboarding regardless of which engine the user picks.
- No silent fallback between engines.
- Frontmatter has no `schema` field. `status` is omitted on success and required on `partial` / `failed`.
- Speaker blocks render as `### [HH:MM:SS] Speaker A` with one timestamp per block.
- Body opens with H1 → metadata blockquote → attendees → calendar notes → `## Transcript`. Calendar notes are not intermixed with the transcript.
- Onboarding presents one screen per permission with pre-framed copy before triggering each system dialog. Quitting mid-flow resumes at the first un-granted required permission.
- ElevenLabs key is in Keychain only.
- Logs contain lifecycle events only.
- Every Transcriber-owned window sets `NSWindow.sharingType = .none`.
- Third-party File Provider clouds trigger a one-time warning per synced root. iCloud does not.
- Pre-record disk-space warning fires if free disk is below ~1 GB.

### QA Scenarios

**Setup**

- Fresh install with no permissions granted.
- Each required permission individually missing.
- Notifications permission missing — redundant-channel pattern degrades, `Setup Required` fires.
- ElevenLabs key missing — engine flips to Local once Cohere finishes downloading.
- Output folder unwritable.
- Permission revoked while app is running.
- Quit mid-onboarding; resume at first un-granted permission.
- Test recording at end of onboarding waits until at least one engine is ready.
- Screen Recording onboarding screen displays the "what is and is not captured" visual before the system dialog.

**Calendar Watcher**

- Prompt appears at meeting start (per process-detection trigger with calendar enrichment).
- App launches mid-meeting with ≥10 min remaining — prompt fires.
- App launches mid-meeting with <10 min remaining — menu bar shows `Meeting detected` only.
- Recurring meeting prompts de-dupe by occurrence.
- Calendar event updates while app is running.
- Mac sleeps before meeting and wakes during meeting.
- Mac wakes after user already dismissed via `Not now` — no re-prompt for that event in this session.
- All-day, declined, tentative, and stale-past-end events are skipped.

**Recording**

- Capture includes microphone and system audio.
- Browser, Zoom, and Teams meeting audio are captured.
- Mic-only recording is blocked when system audio permission is missing.
- App audio is excluded from capture.
- Long meeting streams to disk; memory stays bounded.
- System-audio channel drops to zero for >5s during recording — `SYS` indicator dims/amber on menu bar AND popover meter.
- Mic channel drops to zero for >5s during recording — `MIC` indicator does the same.
- Privacy Status block visible in popover with full engine label (`ElevenLabs (cloud)` / `Cohere (local)`).

**Start Prompt**

- `Start Recording` begins capture.
- `Not now` dismisses; subsequent occurrences re-prompt normally.
- `More options ▾` is closed by default.
- `Stop asking about this meeting` adds the recurring series to the suppress list.
- `Stop detecting [App] for 30 minutes` suppresses the triggering app for 30 minutes.
- Settings → Quiet Meetings lists suppressed series; `Re-enable` reverses suppression.
- Late-join prompt presents the same two buttons and the same disclosure.
- Notification fires in parallel with the modal; menu-bar glyph flips to `Meeting detected`.
- Modal does not appear in shared screen video.
- Modal appears on the screen containing the active meeting-app window.
- Late-join prompt copy reads "Recording will capture from now onward".
- Ignored prompt re-fires a fresh notification after 60 seconds.
- New event during active recording — no modal; queued in popover as `Next: 'Title' at HH:MM`.
- On stop, the queued prompt fires immediately if still active and process-detection still positive.
- Queued event past expiry is dropped silently.
- No single button or hotkey stops the current recording and starts a new one.

**End Guard**

- Scheduled end + silence triggers stop prompt.
- Audio resumes during grace or countdown — stop flow cancels; re-prompt suppressed for 60 seconds.
- Countdown auto-stops if ignored.
- 1st / 2nd / 3rd `Keep Recording` snoozes 3 / 9 / 27 minutes.
- Force-prompt fires at 4 hours past scheduled end regardless of snooze.
- `Stop Now` finalizes immediately.
- Stop prompt HUD does not pull focus.
- Stop prompt HUD does not appear in shared screen video.

**Transcription**

- Success path produces transcript and the .md has no `status` field.
- 401 / 429 / timeout / partial each produce the documented failure transcript shape.
- Failed session retries one-click from the Recents popover.
- Engine switch (Settings → Engine) re-triggers transcription on saved audio without silent fallback.
- Failure transcript includes a `## What you can do` body section.

**Output and Storage**

- Folder contains `transcript.md`, `audio.m4a`, `metadata.json`.
- Title-collisions create unique folders.
- Unsafe title characters are sanitized.
- Partial files rename atomically.
- Third-party File Provider cloud output triggers a one-time warning per synced root.
- iCloud Drive output does not trigger a blocking warning; passive Settings note instead.
- Switching from Dropbox to Google Drive re-warns; subdir within Dropbox does not.
- Pre-record disk-space warning fires below ~1 GB free.
- Mid-recording disk-full fails safely without losing already-captured audio where possible.
- Recents popover shows at most 5 sessions; failed items expose `Retry`.
- Settings → Storage shows total audio size; `Delete all audio (keep transcripts)` requires confirmation.

**Markdown Contract**

- Frontmatter has no `schema` field.
- Success transcripts have no `status` field.
- Failure transcripts have `status: failed` plus the failure-only fields.
- Late-joined sessions write `joined_late: true` and `elapsed_at_start_seconds`; no `scheduled_start_at` / `recording_started_at` aliases.
- Body opens with H1 mirroring frontmatter title.
- Metadata blockquote sits between H1 and `## Attendees`.
- Attendees, calendar notes, and transcript live under separate `##` headings.
- Speaker blocks render as `### [HH:MM:SS] Speaker A`; consecutive same-speaker utterances collapse.

**Security**

- ElevenLabs key in Keychain only; not in UserDefaults / plist.
- ElevenLabs context excludes full description, URLs, emails, dial-in codes by default.
- Meeting URLs redacted in Markdown by default.
- Logs contain lifecycle events only.
- Diagnostics export redacts secrets and calendar text.
- Start-prompt modal, stop-prompt HUD, active-recording popover, settings window, setup-required popover, diagnostics window all set `NSWindow.sharingType = .none`.

---

## Appendix A: Origin Notes

This spec was synthesized from a sequence of GStack reviews (Office Hours / CEO / Engineering / Design / Security / DevEx) and a UX walk-through against Granola, Otter, Fireflies, Fathom, tldv, Krisp, Superwhisper, MacWhisper, and Wispr Flow patterns.

Where this spec conflicts with the original review notes (e.g., 6-state menu bar in the early Design Review vs. the 8-state list here, or generic "synced folder warn" vs. the per-provider-class rule here), this spec prevails.

Major refinements layered on top of the original reviews:

- Eight-state menu bar with per-state shape distinguishability and the live `MIC` / `SYS` signal indicators on the icon itself.
- Two-button + `More options ▾` start prompt model (replaces an earlier four-mechanism `Not a meeting` / `Skip for now` / `Not this event` / `Don't ask for this meeting` model).
- Privacy Status block at the top of the active-recording popover.
- Floating-HUD stop prompt (replaces a focus-stealing modal).
- Cohere downloaded in the background during onboarding regardless of engine choice.
- `NSWindow.sharingType = .none` confidential-UI requirement on every Transcriber-owned window.
- No new start prompt during active recording; queue-then-fire on stop.

## Appendix B: References

This product is separate from OpenOats. Use these as implementation pointers; do not inherit OpenOats product scope.

OpenOats source tree (`/Users/szymonsypniewicz/Documents/code/OpenOats/app/OpenOats`) — useful files:

- `Sources/OpenOats/Transcription/ElevenLabsScribeBackend.swift` — ElevenLabs multipart request, key validation, retry handling.
- `Sources/OpenOats/Transcription/WAVEncoder.swift` — Float32 PCM to WAV encoding.
- `Sources/OpenOats/Transcription/Data+Multipart.swift` — multipart form-data helper.
- `Sources/OpenOats/Transcription/CloudASRSupport.swift` — cloud ASR error and retry pattern.
- `Sources/OpenOats/Transcription/WhisperKitBackend.swift` — WhisperKit backend wrapper.
- `Sources/OpenOats/Transcription/WhisperKitManager.swift` — WhisperKit model download and transcription setup.
- `Sources/OpenOats/Transcription/ParakeetBackend.swift` — Parakeet backend wrapper.
- `Sources/OpenOats/Transcription/BatchAudioTranscriber.swift` — chunked file transcription helpers.
- `Sources/OpenOats/Audio/SystemAudioCapture.swift` — system audio capture ideas.
- `Sources/OpenOats/Audio/AudioRecorder.swift` — durable audio writing ideas.
- `Sources/OpenOats/Storage/SessionRepository.swift` — session/file persistence patterns.
- `Sources/OpenOats/Intelligence/MarkdownMeetingWriter.swift` — Markdown/frontmatter formatting ideas.
- `Sources/OpenOats/App/MenuBarController.swift` — menu bar controller pattern.
- `Sources/OpenOats/Views/MenuBarPopoverView.swift` — menu bar popover pattern.
- `Sources/OpenOats/App/MeetingDetectionController.swift` — meeting lifecycle ideas (do not copy product behavior blindly).
- `Sources/OpenOats/Settings/SettingsStore.swift` — settings persistence patterns.

OpenOats includes live transcript, notes, vector search, sidecast, import, batch retranscription, onboarding, updater, and history behavior that should not enter v1 unless explicitly re-approved.

Apple APIs (likely required):

- EventKit for Apple Calendar access and event detection.
- ScreenCaptureKit for system audio capture and microphone/system stream handling.
- AVFoundation for encoding/writing audio files.
- UserNotifications for meeting-start and saved-file notifications.
- Security framework for Keychain storage.
- OSLog for lifecycle-only logging.

Implementation notes:

- Treat EventKit as the v1 calendar source.
- Use a rolling window and poll because calendar notifications alone may not be enough.
- Screen/system audio permission is required; fail closed if missing.
- Store temporary capture chunks in app-controlled storage, not shared `/tmp`.

External services:

- ElevenLabs is the v1 primary transcription engine. Send audio plus bounded keyterms only by default. Do not send full calendar descriptions, meeting URLs, attendee emails, dial-in codes, or passwords unless a future setting explicitly enables full context.
- Cohere Transcribe is the target local model. Treat as a spike. Requirements before calling supported: pinned model version, checksum verification, license review, disk/RAM estimate, one-command download, golden audio test, no Python/dev-environment dependency for normal users.

Product inspiration:

- Handy (`https://github.com/cjpais/Handy`) — useful as inspiration for a small, polished, focused macOS menu-bar utility. Do not copy feature scope.
