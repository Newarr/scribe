# Agent Review Notes

These notes synthesize the GStack review agents launched during initial planning. They are kept as a historical record of the review inputs that shaped the spec.

**This document is historical.** Where it conflicts with `SPEC.md`, `DECISIONS.md`, or `QUESTIONS.md`, the current docs prevail. Notable later refinements not captured here include: the eight-state menu-bar UI (this doc lists six), live mic+system audio meters in the active-recording popover, the floating-HUD stop prompt, the Cohere-during-onboarding background download, the disambiguated three-button standard / two-button late-join prompts, and the confidential-UI (`NSWindow.sharingType = .none`) requirement.

## Office Hours

Tightening:

- Define the wedge as Mac users who take important calendar calls and cannot afford to miss transcript/audio.
- Frame the product as call-capture insurance.
- Reliability is more important than transcription feature breadth.
- Prompt at scheduled start; remind every 60 seconds for a bounded window.
- Do not overpromise app/browser call detection in v1.
- App is not ready until Calendar, Mic, and System Audio permissions are granted.

Recommended cuts:

- Defer direct Google/Outlook APIs.
- Defer local model unless privacy mode becomes the core wedge.
- Defer transcript history, import, live transcript, polishing, vector DB, search, chat, diarization.

## CEO/Product Review

Tightening:

- Core promise: "Never miss the record of a meeting."
- V1 should be a menu-bar meeting recorder for macOS.
- Calendar-first, not call-detection-first.
- Default `Transcribe + save audio`.
- End-of-call guard is v1, not optional.
- Menu bar item is the trust surface.
- Failure handling must preserve audio.

Acceptance criteria:

- Prompt when calendar meeting starts.
- One click starts mic + system audio recording.
- Active recording is obvious in menu bar.
- Missing permissions block loudly.
- Auto-stop after end guard timeout.
- `.md` and `.m4a` saved in a meeting folder.
- ElevenLabs uses calendar-derived context.
- Transcription failure does not lose audio.

## Engineering Review

Tightening:

- Target macOS 15+ for ScreenCaptureKit.
- Define explicit state machine.
- Watch EventKit rolling window from `now - 15m` to `now + 24h`.
- Listen for calendar changes, poll every 60s, and re-check on wake.
- De-dupe prompts by event ID plus occurrence start time.
- Capture mic and system audio as separate timestamped streams.
- Stream to disk continuously.
- Save audio before transcription.
- Failed transcription jobs should be recoverable.
- Write files atomically.

Required tests:

- Event de-dupe.
- Recurring meetings.
- Sleep/wake catch-up.
- Permission states and revoked permissions.
- Prompt timing and ignored reminders.
- Auto-stop countdown and keep-recording snooze.
- Active-audio cancellation.
- Filename sanitization and collision handling.
- API failure recovery.
- Disk-full behavior.

## Design Review

Tightening:

- Prompt at meeting start, plus quiet preflight only if setup is broken.
- Primary action: `Start Recording`.
- Secondary action: `Skip`.
- Menu bar states: idle, meeting detected, recording, stopping soon, finalizing, blocked.
- Active recording popover should show meeting title, elapsed time, capture sources, and stop action.
- Stop-after-call countdown must be an explicit app state.
- Settings should be compact and grouped:
  - Recording.
  - Calendar.
  - Transcription.
  - Permissions.
  - Stop Guard.
- Permission rows should say exactly what is missing and why.

Design principle:

> This app should feel like a seatbelt, not a dashboard.

## Security Review

Tightening:

- Treat audio, transcripts, calendar metadata, attendee lists, and ElevenLabs key as sensitive.
- First-run privacy screen is acceptable; no per-call consent nag.
- ElevenLabs context should be keyterms-only by default.
- Store ElevenLabs key only in Keychain.
- Fail closed on permissions.
- Menu bar indicator is mandatory.
- Warn if output folder is synced.
- Do not log content.
- Temporary chunks should live in app container, not shared `/tmp`.
- Redact meeting URLs by default.
- Attendees default to display names only.
- Local mode means no transcription-provider network calls and no calendar-context upload.
- Add content-free audit trail.

## Developer Experience Review

Tightening:

- Make this its own git repo.
- Split implementation into app, core, and tests.
- Define contributor time-to-hello-world target: under 5 minutes with `make bootstrap && make app`.
- Add docs:
  - `ARCHITECTURE.md`
  - `PERMISSIONS.md`
  - `LOCAL_MODELS.md`
  - `RELEASE.md`
  - `CONTRIBUTING.md`
  - `SECURITY.md`
  - `PRIVACY.md`
  - `TROUBLESHOOTING.md`
- Add `PermissionDoctor`.
- Add diagnostics menu.
- Add `make test`, `make app`, `make dmg`, `make release-check`.
- CI should build, test, and fail if docs mention unsupported features.

