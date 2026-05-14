# Scribe

Menu-bar-first macOS app that makes sure every important meeting becomes a timestamped Markdown transcript with the original audio saved next to it.

The product feels like a seatbelt, not a dashboard. It stays out of the way until risk appears: missed start, missing permission, active recording, runaway recording, silent capture failure.

This document is the single source of truth: product spec, design decisions, open questions, and acceptance criteria. Where it conflicts with anything else, it prevails.

## Contents

- [Product](#product)
- [Design Principles](#design-principles)
- [Visual Language](#visual-language)
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
- **Confidential UI by default.** Every Scribe-owned window sets `NSWindow.sharingType = .none` so prompts and popovers never appear in screen-shared video, regardless of where they render.
- **Finder is the database.** No transcript-history UI in v1. The menu-bar Recents section is a 5-item shortcut.
- **Inspectable proof, not marketing claims.** Trust UI shows where audio goes, what is captured, what is excluded, and which engine ran — not just "your data is private."

## Visual Language

Source: a design bundle from `claude.ai/design` (Vercel-aesthetic, dark-first). The bundle owns the exact values — OKLCH coordinates, spacing scale, type sizes, asset SVGs. This section captures the visual rules that govern any surface Scribe renders, without speaking to which surfaces ship and when.

### Adopted (normative)

- **Dark-first menu bar surfaces.** The popover and HUD render dark regardless of system appearance. Parity with macOS native menu-bar surfaces, and keeps the recording dot legible. Light mode is reserved for the full Settings window.
- **No status pills.** Status is rendered as a colored dot plus mono uppercase text (the `.indicator` pattern in `colors_and_type.css`). Pills imply selectability; status is read-only.
- **Color encodes meaning, not atmosphere.** Palette: eleven-step OKLCH neutral gray, one accent (quiet ink blue, `oklch(0.50 0.09 255)`), one recording color (warm rust, `oklch(0.55 0.14 35)`), and the three semantics. Semantics appear as a tinted dot or 1px border, never a filled banner.
- **Recording is rust, not red.** The recording indicator is warm rust (lower chroma than fire-engine red) — alarm without panic, consistent with the calm-monochrome aesthetic. Wherever the spec or code says "red dot," read it as the recording token, not literal `#ff0000`.
- **Borders carry elevation in dark mode.** 1px hairlines separate surfaces. Shadows are reserved for the popover lift; light-mode card hover may also use them.
- **Type.** Inter (variable, OFL) for sans, JetBrains Mono (variable, OFL) for mono. Both ship as local woff2; do not load fonts from a CDN at runtime. Mono is required for indicators, eyebrow labels, `kbd`, file paths, timestamps, and code — never for body. (The bundle README mentions Geist as design intent; Inter is what shipped, and Inter is the call.)
- **Casing.** Sentence case for headings, buttons, labels. Uppercase only for mono indicators and eyebrow labels. No Title Case.
- **No emoji in UI.** Mono text labels (`LIVE`, `READY`, `SENT`, `FAILED`, `TRANSCRIBING`) carry the weight emoji would.
- **Four button variants.** Primary (inverted black/white per mode), secondary (transparent + 1px border), ghost (transparent, hover background), danger (rust fill). Press transform `scale(0.97)` for ~90ms. No other button styles.
- **Focus ring.** `outline: 2px solid var(--accent); outline-offset: 2px`. Never a soft inset glow.
- **Motion is deferential.** 120ms hover/press, 180ms state transitions. No bounces, no springs in product UI. Continuous animation is reserved for the audio meters and the in-popover recording dot ping.
- **State distinguishability by shape, not color.** Idle vs recording are separate static SVGs (`menubar-icon.svg` vs `menubar-icon-recording.svg`), consistent with the Menu Bar UI rule.

### Adjusted from the bundle

- **No animated dot in the menu bar icon.** The bundle mock shows a pulsing dot in the menu bar. Do not ship that. macOS HIG discourages animated menu-bar items — they distract in steady-state and prevent the user from forgetting the app is quietly doing its job. The menu-bar recording icon stays static; the live ping animation belongs inside the popover only.
- **No JS hover sheen on buttons.** The bundle's radial-gradient cursor sheen requires per-button pointer tracking. Skip in V1; color hover + `scale(0.97)` press is enough. Revisit if perceived quality ever demands it.
- **Native vibrancy, not CSS backdrop blur.** The bundle popover uses `backdrop-filter: blur(24px)` over `rgba(18,18,18,0.94)`. In SwiftUI map this to `NSVisualEffectView` with the `.hudWindow` (or `.popover`) material. Native vibrancy is cheaper and matches OS expectations.
- **Live audio meters stay data-driven.** The bundle's recording mock shows a decorative sine-wave waveform. The `MIC`/`SYS` meters defined in Menu Bar UI must remain driven by audio level, because they encode silent-channel detection.

### Component reference

Where to find the visual primitives in the bundle:

- `colors_and_type.css` — design tokens (CSS variables) and base element styles. Translate to SwiftUI `Color` extensions and font registrations; the CSS file is the source of truth for exact values.
- `ui_kits/menubar/` — popover frame, indicator pattern, button styles, recording surface, transcript surface, settings surface.
- `ui_kits/settings/` — full Preferences window pattern (sidebar + main, 980×660). The integration-list row pattern (mark · name + meta · indicator · action button) is the canonical layout for any list-of-things-with-status surface.
- `preview/` — small spec cards for type, color, components.
- `assets/menubar-icon.svg`, `assets/menubar-icon-recording.svg` — template-style menu bar icons that inherit the system tint via `currentColor`.

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

## Recovery

The app must survive crashes, force-quits, and power loss without losing audio. On launch, the `SessionSupervisor` scans the output root and dispatches a `TranscriptionWorker` for any session whose `transcript.md` is in a non-terminal status.

Supervisor scan behavior:

- Runs on app launch, gated by privacy acknowledgement (the cloud engine cannot run before the user has acknowledged what leaves the device).
- For each session directory under `outputRoot/`:
  - If `transcript.md` shows `status: pending` or `status: retrying`, dispatch a worker to resume.
  - If `mic.m4a.partial` or `system.m4a.partial` exists from a crashed `CaptureSession.stop()`, the `OrphanRecoverer` atomically renames `.partial` → `.m4a` and dispatches a worker.
  - If only one of `mic.m4a` or `system.m4a` survives (one-sided audio), the supervisor writes a `failed` transcript referencing the surviving stream and does NOT call the engine. One-sided audio is not transcribable per the no-mic-only-fallback rule.
  - If a `.partial` rename fails this scan (immutable flag, permission denied, transient I/O), the session stays in its current state; the next scan retries. This case is reported separately as `recoveryDeferred` so it doesn't get conflated with terminal failures.
  - Sessions with no audio at all are stamped `failed` so they don't loop forever.
- After a successful resume to `complete`, raw `mic.m4a` / `system.m4a` are deleted unless `keepRawStreams` is on.

Session claim:

- Each running session holds an exclusive `flock`-backed claim file (`session.claim`) in its directory. A second app instance, a relaunched supervisor, or a debugger-attached worker cannot race the live capture or finalize.
- Claims are released on clean shutdown. Stale claims left by a crash are detected by missing process / file-handle checks before being overridden.

## Default Settings

- Mode: `Transcribe + save audio`.
- Primary engine: explicit user-selected `cloud` or `local`. Cloud is ElevenLabs (`scribe_v2`); Local is Cohere via `mlx-audio-swift` + `MLXAudioSTT.CohereTranscribeModel` with pinned model ID `beshkenadze/cohere-transcribe-03-2026-mlx-fp16`. Cohere (local) downloads in the background during onboarding regardless of which engine the user picks. A keyless user gets a working app; a keyed user gets a ready explicit alternative when cloud fails.
- Output: one folder per meeting under `~/Scribe/`. Avoid `~/Documents/Scribe/` because Documents may be inside iCloud Desktop & Documents sync. `~/Movies/Scribe/` is an acceptable alternative.
- Calendar context sharing: keyterms only.
- Auto-stop guard: enabled.
- End-detection grace period: 30 seconds.
- Stop prompt timeout: 10 seconds.
- `Keep Recording` snooze: flat 15 minutes for v1. Audio activity resets the silence detector and renders the snooze inert until the next silence stretch. Hard ceiling: force-prompt at scheduled-end + 4 hours.
- Audio retention: keep until manually deleted. No background auto-delete in v1.
- Notifications: `UNUserNotificationCenter` permission requested during onboarding. Without it the redundant-channel pattern collapses; the menu-bar `Setup Required` state fires.

Settings JSON shape (persisted as a single blob under UserDefaults key `transcriber.settings.v1` for atomic write):

- `outputRoot` (URL): per Output and Storage.
- `engineMode` (`cloud` | `local`): which transcription engine drives new sessions.
- `keepRawStreams` (Bool, default `false`): when off, raw `mic.m4a` + `system.m4a` are deleted after `audio.m4a` is mixed and `metadata.json` is committed. Debug knob; enable to inspect per-channel originals.
- `aecEnabled` (Bool, default `true`): when on, the worker runs the AEC pre-pass before upload (see Audio Capture). When off, force single-channel diarized over the raw mix.
- `privacyAcknowledged` (Bool, one-way): tracks first-launch privacy acknowledgement. Once `true`, never written back to `false` by the app. Recording AND supervisor recovery are gated until this is `true`.

Settings snapshot is taken at session start. The supervisor, capture session, and transcription worker do NOT poll back into the store mid-session; settings changes take effect on the next session.

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

- Trigger is process-detection-with-calendar-enrichment in v1: an allowlisted meeting app that has been running for **30 seconds** without quitting fires a candidate; the prompt title is enriched with the overlapping calendar event if one is in cache. Per-bundle suppression via `Stop detecting [App] for 30 minutes` ticks an in-memory map cleared on app restart; suppression is NOT persisted across launches.
- Allowlist (12 bundle IDs in v1; one source of truth in `MeetingApps.allowlist`):
  - Native: `us.zoom.xos`, `com.microsoft.teams2`, `com.microsoft.teams` (legacy), `org.whispersystems.signal-desktop`, `com.apple.FaceTime`.
  - Browsers (any tab triggers; per-URL detection deferred): `com.google.Chrome`, `com.apple.Safari`, `company.thebrowser.Browser` (Arc), `com.microsoft.Edge`, `org.mozilla.firefox`, `com.brave.Browser`, `im.helium.helium`.
- The pure calendar-event-at-scheduled-start trigger may layer in as a secondary path later (see `q_calendar_or_process_first_trigger`).
- Delivery is an `NSAlert` modal with `NSApp.activate(ignoringOtherApps: true)`. Focus-stealing is intentional: missing the start dominates the politeness cost of the interruption.
- Two buttons only: `Start Recording` (primary) and `Not now` (secondary). Both standard and late-join prompts use the same two-button shape so the cognitive surface is constant.
- Below the buttons: a small `More options ▾` disclosure that hides the rare suppression flows. Closed by default. When opened, exposes:
  - `Stop asking about this meeting` — suppresses the recurring calendar series indefinitely (keys on recurrence-series ID). (Later work.)
  - `Stop detecting [App] for 30 minutes` — app-level suppression that defends against false-positive process detection.
- Suppressed meetings are managed in Settings → Quiet Meetings, where users can re-enable any series they previously suppressed. (Later work.)
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
  - `Audio: local · ~/Scribe/Customer Call - Acme/`
  - `Captured: mic + system audio · no video, no screenshots`
  - `Engine: ElevenLabs (cloud)` or `Engine: Cohere (local)` — explicit, never abbreviated.
- Live audio meters: two thin bars labelled `MIC` and `SYS` (larger than the menu-bar indicator; same data source).
- `Recording 12:34 - Mic + System Audio` text.
- Primary action: `Stop Now`.
- Secondary actions: `Open Folder`, `Settings`.

Recents section (in the menu bar's main popover, not the active-recording popover):

- Last 5 saved sessions, sourced from `outputRoot/` by mtime.
- Each item shows: title, duration, time-of-day or relative day (`12:34 today`, `Yesterday`, `Tue`).
- Inline actions per item: `Open Folder`, `Open Transcript`. Failed sessions show `Retry` when saved audio exists and the persisted engine is ready; if the persisted Local engine needs setup, the action routes to Cohere repair instead of Cloud or a new recording.
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
3. Calendar — `So Scribe can label your recordings with meeting context.`
4. Notifications — `So you don't miss meeting prompts.`
5. Screen Recording — the showpiece (see below). Cohere model download starts as a background task here.
6. ElevenLabs API Key — optional; if skipped, default engine flips to Local once Cohere finishes downloading.
7. Choose Engine — side-by-side: Cloud ready ✓ if key entered, Local ready when download completes.
8. Output Folder — default `~/Scribe/`; pick alternative; warn if user picks a third-party File Provider cloud (see Output and Storage).
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

### AEC pre-pass and engine mode

Before upload, the transcription worker runs an acoustic-echo-cancellation pre-pass on the mic stream using the system audio as the reference signal. This produces `mic.cleaned.wav`. The AEC outcome decides the engine mode:

- **AEC succeeds** → engine runs in **multichannel** mode. The worker uploads two channels: cleaned mic on channel 0, raw system on channel 1. ElevenLabs is told `use_multi_channel=true, diarize=false`; the speaker mapping builder labels `speaker_0` as local and `speaker_1` as remote in 1:1 calls. This is the high-quality path.
- **AEC fails or is disabled** → fall back to **single-channel diarized**. The worker uploads the mixed `audio.m4a` (mono AAC) with `diarize=true`; speaker labels remain generic `Speaker 0 / Speaker 1 / ...`. This is the no-silent-fallback path: the engine pointer never silently swaps; the engine MODE swaps based on AEC.
- v1.0-rc1 ships a disabled AEC backend (`DisabledAECPrePass`), so all rc1 sessions take the single-channel-diarized fallback. The protocol surface is in place; a real WebRTC-rs or `AUVoiceProcessing` backend lands in a post-rc1 spike.
- The `metadata.json` `aec_status` field records which path ran (`succeeded` / `failed`) for triage.

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
- If user clicks `Keep Recording`, snooze end detection for 15 minutes.

False-stop guard:

- Long silences during an active meeting (reading documents, silent screen-share review, breakout transition, waiting room) must NOT silently terminate the session. The HUD + countdown gives the user a 10-second window to catch a false positive. Audible cue is the recommended hedge for users who are routinely in long-silence calls.

## Transcription

Primary engine: ElevenLabs (model pinned to `scribe_v2`).

Recognition context:

- Use bounded keyterms by default.
- Include title terms, attendee display names, company/domain terms, and acronyms.
- Do not send full calendar description, meeting URLs, attendee emails, dial-in codes, or passwords. The keyterm-only path is the canonical boundary; no opt-in "full context" setting ships in v1. URLs in particular are not useful as recognition hints.

Keyterm sanitization (`KeytermSanitizer`):

- Conservative-by-design: when in doubt, drop the token. Keyterm hints are a quality nudge, not load-bearing.
- Pre-tokenization scrubber runs first on the raw event title to catch space-separated digit groups that would otherwise tokenize past the per-token rules.
- Drop tokens matching: URLs (`https://`, `www.`, common TLDs), emails, phone numbers (E.164-ish, US-style, generic with `+`/separator/digit groups), or 4+ consecutive digits (PINs, conference IDs, postal codes).
- Drop secret-label tokens and the 1-2 tokens following them: `passcode, password, pin, code, id, meeting-id, meetingid, join-code, joincode, access-code, accesscode, kennwort`.

Retry policy (cloud transcription):

- 3 retries with backoff after the initial attempt: 60s, 5min, 30min. 4 total attempts before terminal failure.
- Transient errors (retry): rate-limited responses, HTTP 5xx, network timeout, DNS / connection failure.
- Terminal errors (no retry): unauthorized, missing API key, malformed response.
- Backoff state is persisted via `status: retrying` on disk so a relaunched supervisor resumes mid-loop.

Local mode (Cohere):

- Local runtime is native Swift/MLX: `mlx-audio-swift` with `MLXAudioSTT.CohereTranscribeModel`, not Rust, Python, shell, or an external executable.
- Pinned model ID: `beshkenadze/cohere-transcribe-03-2026-mlx-fp16`. Download, readiness, diagnostics, verification, and transcription all use this identity; no `latest` alias or alternate model is exposed.
- Local mode converts the transcription input to mono 16 kHz for inference while preserving the user-facing durable `audio.m4a` asset separately.
- Local mode must not send audio, transcript text, calendar context, keyterms, or API keys to any transcription provider. Local artifacts may still store allowed calendar metadata locally.
- No silent fallback in either direction (Local → Cloud or Cloud → Local). Engine switches are explicit Settings actions or explicit retries; active sessions keep the session-start engine snapshot.

Cohere lifecycle:

- Background download starts during the Screen Recording onboarding step, regardless of which engine the user picks. This guarantees a keyless user has a working app and a keyed user has a ready explicit alternative when cloud fails.
- Downloads write only `.partial` cache artifacts until all pinned artifacts complete, then atomically rename into the final cache.
- Verification checks pinned model identity and reviewed artifact integrity (manifest/size/checksum or equivalent) before Local is marked ready. File existence alone is not readiness.
- Local selection, Test Recording, manual recording, retry, and recovery are blocked until verification succeeds and MLX/runtime support is available.
- Disk-space preflight runs before starting or resuming a model download and blocks unsafe writes.
- If the download fails, is cancelled, is corrupt, or verification fails, surface a bounded reason plus Retry. Retry replaces failed partial cache state without touching session folders. Do not silently fall back.
- User can later Remove the Local model from Settings → Engine. Removal requires confirmation, deletes only model cache files, and makes Local unavailable until redownloaded; sessions under `~/Scribe/` are untouched.

End-to-end engine topology:

1. Settings/onboarding stores an explicit selected engine (`cloud` or `local`).
2. Preflight checks shared capture prerequisites for both engines, then Cloud key readiness or Local verified-cache + MLX readiness.
3. Capture always records mic + system audio and finalizes durable `audio.m4a` before transcription starts.
4. TranscriptionWorker uses the session-start engine snapshot: ElevenLabs receives audio plus bounded keyterms in Cloud mode; CohereMLXBackend runs locally with no provider calls or keyterms in Local mode.
5. TranscriptWriter and MetadataJSONWriter write normal artifacts with `engine: elevenlabs` or `engine: cohere`.
6. Retry/recovery reuse the existing session directory/audio and persisted engine; unavailable Local surfaces Cohere repair, unavailable Cloud surfaces key setup. Neither path invokes the other engine automatically.
7. Diagnostics report selected-engine readiness, active/recent session engine provenance, local model status, pinned model ID, cache existence, MLX availability, and redacted last download error without raw paths or content.

Engine failure:

- A failed transcription writes a `status: failed` transcript per the Markdown Contract, preserves `audio.m4a`, writes matching `metadata.json`, and surfaces `Retry` or repair on the failed session in the menu-bar Recents popover.
- The user may switch engines manually (Settings → Engine) and re-trigger transcription on the saved audio. Both engines must be ready for this to be a one-click move; that's the reason Cohere is staged during onboarding rather than on first need.

## Output and Storage

Every session creates one unique folder and always ends with `transcript.md`.

Default output root: `~/Scribe/`. `~/Movies/Scribe/` is an acceptable alternative. Avoid `~/Documents/Scribe/` because Documents may be inside iCloud Desktop & Documents sync.

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

- Total Scribe audio size on disk.
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
- `attendees` (list of `{name, email}` objects). Emails are stored because the artifact is for agent consumption; display names alone are ambiguous (multiple "John Smith"; renamed across calendars). Agents use email to dedupe across meetings, link to CRM records, and route follow-ups. **Important:** emails are stored LOCALLY only — they are scrubbed by `KeytermSanitizer` before any keyterm payload leaves the device, and the `decision_keyterms_default` rule prevents full calendar context from being sent to ElevenLabs.
- `organizer` (`{name, email}` object — same rationale as `attendees`).
- `location`
- `calendar_event_id`
- `engine` (e.g. `elevenlabs`, `cohere`)
- `audio` (relative path to the audio file)

Meeting URLs are NOT stored. The Zoom/Meet/Teams join link has no value to a downstream agent (the meeting is already over) and storing it expands the leak surface for nothing. The calendar-event mapping layer drops URLs before they reach `TranscriptContext`, frontmatter, or the markdown body. `KeytermSanitizer` enforces the same rule for any keyterm payload.

Conditional:

- `status` (when present) is one of `pending | retrying | complete | failed`. It is OMITTED when the session is `complete` (a file with no `status` field is complete by convention) and required for the other three states. `pending` and `retrying` are intermediate states emitted by the supervisor / transcription worker so a relaunch can resume mid-flow. `partial` is reserved for future use (see `q_partial_transcript`).
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

Order: H1 title → metadata blockquote → attendees list → calendar notes → `## Transcript`. Always include calendar notes as a `## Notes from calendar` section when the calendar event has a description; sanitize to plain text first (drop URLs, scrub digit runs and secret labels per `KeytermSanitizer` rules). When there is no description, omit the section entirely. Calendar notes are NEVER intermixed with the transcript.

```markdown
---
title: "Customer Call - Acme Weekly"
date: 2026-04-30
scheduled_start: 2026-04-30T14:30:00+02:00
scheduled_end: 2026-04-30T15:00:00+02:00
actual_start: 2026-04-30T14:30:12+02:00
actual_end: 2026-04-30T15:25:03+02:00
attendees:
  - name: "Szymon Sypniewicz"
    email: "szymon@ramp.network"
  - name: "Jane Doe"
    email: "jane.doe@acme.com"
organizer:
  name: "Szymon Sypniewicz"
  email: "szymon@ramp.network"
location: ""
calendar_event_id: "abc123..."
engine: "elevenlabs"
audio: "audio.m4a"
---

# Customer Call - Acme Weekly

> 14:30-15:25 (Apple Calendar) · Mic + System Audio · ElevenLabs

## Attendees
- Szymon Sypniewicz <szymon@ramp.network> (organizer)
- Jane Doe <jane.doe@acme.com>

## Notes from calendar

{sanitized calendar description — URLs dropped, digit runs and secret labels scrubbed; section omitted entirely if the event has no description}

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
  - name: "Szymon Sypniewicz"
    email: "szymon@ramp.network"
  - name: "Jane Doe"
    email: "jane.doe@acme.com"
organizer:
  name: "Szymon Sypniewicz"
  email: "szymon@ramp.network"
location: ""
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

- Retry from the Scribe menu bar: click the icon, then `Retry` next to this session.
- Or transcribe locally: Settings → Engine → Cohere (local), then retry.
- Or transcribe outside Scribe: open `audio.m4a` in any other tool.
```

Retry is available from the menu-bar Recents popover for failed sessions with saved audio, reuses the existing session directory/audio, and honors the persisted engine. If the failed session used Cohere and Local setup is unavailable, Recents routes to Cohere repair/setup; it never starts a new recording, exposes import, or silently switches to Cloud.

### metadata.json sidecar

Each session folder ships a machine-readable `metadata.json` next to `transcript.md`. Body utterances are NOT duplicated here; the JSON is a metadata mirror of the frontmatter so downstream agent pipelines can pick whichever surface they prefer (markdown for humans, JSON for agents).

Required fields:

- `schema` (string, e.g. `"transcriber/v1"`) — the JSON sidecar IS versioned, unlike the `transcript.md` frontmatter. Bump on incompatible field changes.
- `status` (`pending | retrying | complete | failed`)
- `title`, `date`, `engine`, `language`, `audio`
- `started_at`, `ended_at`, `attendees` (list of `{name, email}` objects, mirroring the markdown frontmatter)
- `aec_status` (`succeeded | failed | null`) — records which transcription mode ran (multichannel vs single-channel diarized fallback) per Audio Capture.

Written atomically (`.partial` → rename) on every state transition so a crash mid-write leaves the previous good blob intact.

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
- First-run privacy acknowledgement: cloud mode sends audio plus selected keyterms to ElevenLabs; local mode sends no audio, transcript text, calendar context, keyterms, or API keys off device for transcription. Local model setup may download pinned public Cohere/MLX artifacts without user content.
- No recurring consent reminder.
- No transcript/audio/calendar content in app logs.
- Logs contain lifecycle only: prompted, started, stopped, failed, provider used.
- Escape YAML and Markdown correctly.
- Redact meeting URLs by default.
- Attendees and organizer are stored as structured `{name, email}` objects in `transcript.md` frontmatter and `metadata.json` (local artifacts are for agent consumption — emails enable CRM linkage, dedupe, follow-up routing). The third-party-leak boundary is at the upload path, not the local-storage path: `KeytermSanitizer` scrubs emails (and URLs, phone numbers, digit runs, secret labels) from any keyterm payload before it leaves the device.
- Confidential UI: every Scribe-owned window sets `NSWindow.sharingType = .none` (start prompt modal, stop prompt HUD, active-recording popover, settings, setup-required popover, diagnostics, privacy acknowledgement sheet). Prompts and popovers must not appear in shared screen video, regardless of which display they render on.

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
- Local pinned model ID.
- Local cache existence (boolean only, no raw path).
- MLX/runtime availability.
- Redacted last local download error.
- Selected-engine readiness and active/recent session engine provenance.
- Output path.

Export diagnostics:

- Redact secrets.
- Redact calendar text.
- Do not include transcript or audio content.
- Replace the output-folder path with its SHA-256 hex hash, so the user can correlate exports across time without leaking their folder hierarchy.
- The exported `DiagnosticsSnapshot` is a typed, fixed-shape struct: every exportable field is enumerated in code, and the test suite has a redaction guard that fails CI if a new field bypasses the contract. New PII-bearing fields require explicit review.

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

- `q_end_grace_seconds`: Should end-detection grace be fixed at 30 seconds or configurable?
- `q_calendar_end_plus_audio`: Should auto-stop only arm after scheduled calendar end, or also after long silence before scheduled end?

### Calendar Metadata

(no open questions — see Resolved trail)

### Transcription

- `q_partial_transcript`: If transcription partially succeeds, should `transcript.md` include partial text plus failure metadata?
- `q_word_level_timestamps_sidecar`: Should ElevenLabs's word-level timestamps be persisted to a sibling `transcript.json` for downstream tooling?

### Local Mode

(no open questions — see Resolved trail)

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
- `q_keep_recording_snooze_minutes` — resolved as a flat 15-minute snooze in [End Guard](#end-guard).
- `q_synced_folder_warning` — resolved by per-provider-class detection in [Output and Storage](#output-and-storage).
- `q_audio_retention` — resolved by keep-until-deleted + Settings → Storage panel in [Output and Storage](#output-and-storage).
- `q_transcription_retry_policy` — resolved by 60s / 5min / 30min, 4 total attempts, with persisted `status: retrying` for cross-launch resume. See [Transcription](#transcription).
- `q_elevenlabs_model` — resolved: `scribe_v2` pinned in `EngineRequest` default and backend response.
- `q_end_audio_threshold` — resolved: 0.01 RMS (~ -40 dBFS) per `EndGuard.Config.silenceThreshold` default.
- `q_attendee_email_retention` — resolved: emails ARE stored locally as structured `{name, email}` objects in `transcript.md` frontmatter and `metadata.json`. Local artifacts are designed for agent consumption (CRM linkage, dedupe, follow-up routing); display names alone are ambiguous. The third-party-leak boundary is enforced separately: `KeytermSanitizer` scrubs emails from keyterm payloads before any upload to ElevenLabs, and `decision_keyterms_default` prevents full calendar context from being sent.
- `q_calendar_url_retention` — resolved: meeting URLs are NOT stored. They have no value to a downstream agent (the meeting is over by the time the artifact is read) and storing them adds leak surface for nothing. The calendar-event mapping drops URLs before they reach `TranscriptContext`, frontmatter, the markdown body, or any keyterm payload.
- `q_calendar_description_markdown` — resolved: always include sanitized calendar notes as `## Notes from calendar` when the event has a description. Sanitization drops URLs and scrubs digit runs / secret labels per `KeytermSanitizer` rules. The section is omitted entirely when the event has no description.
- `q_full_context_setting` — resolved: NOT shipped in v1. The keyterm-only path with `KeytermSanitizer` is the canonical boundary; URLs aren't useful as recognition hints anyway. An opt-in "full context to cloud" setting can be revisited later if a concrete use case emerges.
- `q_context_keyterm_limit` — resolved: 16 keyterms per request, deduped, in insertion order (`CalendarEvent.swift:73`).
- `q_local_model_v1_scope` — resolved: Cohere is staged in onboarding as a background download regardless of which engine the user picks.
- `q_cohere_runtime` — resolved: Local mode runs native Swift/MLX through `mlx-audio-swift` and `MLXAudioSTT.CohereTranscribeModel`; unsupported MLX/runtime states block Local with repair/setup instead of fallback.
- `q_cohere_model_size` — resolved: the pinned Cohere/MLX model is `beshkenadze/cohere-transcribe-03-2026-mlx-fp16` and is large enough to require progress, disk-space preflight, `.partial` cache writes, integrity verification, Retry, and Remove controls.
- `q_local_model_fallback` — resolved: no alternate local engine fallback ships. Cohere/MLX is the Local path; failures preserve audio and surface repair or explicit engine switching.

---

## Known Code-vs-Spec Drift

These items are unresolved drift between SPEC.md and the rc1 implementation. They are NOT spec changes — the spec captures the intended behavior and the code needs to align. Recommended landing order at the bottom.

- **Output root drift.** Spec says default is `~/Scribe/`. Code (`AppDelegate.defaultSettingsFallback`) defaults to `~/Documents/Scribe/`. The spec's choice is deliberate (avoids iCloud Desktop & Documents sync collisions). **Code action:** change default to `~/Scribe/`.
- **Start-prompt button shape drift.** Spec: two buttons (`Start Recording` / `Not now`) plus a `More options ▾` disclosure exposing `Stop asking about this meeting` (recurring-series suppress, keys on recurrence-series ID) AND `Stop detecting [App] for 30 minutes`. Code (`StartPromptCoordinator.swift`): three flat buttons (`Start recording` / `Not now` / `Stop detecting [App] for 30 min`); the `More options` disclosure and the recurring-series suppress are entirely absent. **Code action:** collapse to two buttons + disclosure; persist suppressed-series IDs (likely under the `transcriber.settings.v1` JSON blob).
- **Quiet Meetings settings panel missing.** Spec: `Settings → Quiet Meetings` lists suppressed recurring series with a `Re-enable` action per series. Code: no UI, no persistence. Depends on the start-prompt button shape change above. **Code action:** add the Settings panel and the read/write surface backing it.

Recommended landing order: **button shape collapse → Quiet Meetings panel**. Rationale: the Quiet Meetings panel depends on the button-shape change because it needs something to persist. Recents failed-session Retry/repair is current behavior and is documented in the Menu Bar UI, Transcription, Markdown Contract, Acceptance, and QA sections above.

When any of the above lands in code, delete the corresponding bullet here.

---

## Acceptance and QA

### V1 Acceptance Criteria

- Recording captures both microphone and system audio.
- Audio is saved durably before transcription starts.
- Every session folder contains `transcript.md`. Failure transcripts include `error_code`, `retry_count`, audio metadata, and a `## What you can do` body section.
- Default output root is `~/Scribe/`, not `~/Documents/Scribe/`.
- Required permissions block recording loudly. Recommended permissions only show the `Setup Required` badge.
- Auto-stop fires after the end-guard timeout if `Keep Recording` is not clicked.
- `Keep Recording` snoozes for 15 minutes.
- Both standard and late-join prompts present exactly two buttons: `Start Recording` and `Not now`. The `More options ▾` disclosure is closed by default and exposes meeting-suppress and app-suppress.
- Suppressed recurring meetings appear in Settings → Quiet Meetings with a `Re-enable` action per series. (Later work.)
- Late-join prompt fires only if at least 10 minutes remain on the scheduled event or a meeting app is currently in-call.
- Late-joined sessions write `joined_late: true` and `elapsed_at_start_seconds`; `scheduled_start` and `actual_start` already carry the timestamps.
- Stop prompt is a floating HUD; it does not steal focus.
- Menu bar icon shows live `MIC` and `SYS` indicators next to elapsed time during Recording. They dim/amber when their channel is silent for >5 seconds.
- Active-recording popover opens with a Privacy Status block at top showing destination path, captured sources, exclusions, and full engine label.
- Recents popover shows at most 5 saved sessions, with `Open Folder` / `Open Transcript` and failed-session `Retry` or Cohere repair as appropriate.
- Saved success fires a transient notification and a brief menu-bar `Saved` glyph; no persistent in-app toast.
- Cohere downloads in the background during onboarding regardless of which engine the user picks, using `mlx-audio-swift` + `CohereTranscribeModel` and pinned model `beshkenadze/cohere-transcribe-03-2026-mlx-fp16`.
- No silent fallback between engines; Local and Cloud switches are explicit user actions and failed transcriptions preserve audio with failed transcripts.
- Frontmatter has no `schema` field. `status` is omitted on success and required on `partial` / `failed`.
- Speaker blocks render as `### [HH:MM:SS] Speaker A` with one timestamp per block.
- Body opens with H1 → metadata blockquote → attendees → calendar notes → `## Transcript`. Calendar notes are not intermixed with the transcript.
- Onboarding presents one screen per permission with pre-framed copy before triggering each system dialog. Quitting mid-flow resumes at the first un-granted required permission.
- ElevenLabs key is in Keychain only.
- Logs contain lifecycle events only.
- Every Scribe-owned window sets `NSWindow.sharingType = .none`.
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
- Settings → Quiet Meetings lists suppressed series; `Re-enable` reverses suppression. (Later work.)
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
- `Keep Recording` snoozes for 15 minutes.
- Force-prompt fires at 4 hours past scheduled end regardless of snooze.
- `Stop Now` finalizes immediately.
- Stop prompt HUD does not pull focus.
- Stop prompt HUD does not appear in shared screen video.

**Transcription**

- Success path produces transcript and the .md has no `status` field.
- 401 / 429 / timeout / partial each produce the documented failure transcript shape.
- Failed session retries are available from the Recents popover when saved audio exists, reuse the existing session directory/audio, and route unavailable Local sessions to Cohere repair.
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
- Recents popover shows at most 5 sessions; failed items expose `Retry` when saved audio exists or a repair/setup action when the persisted engine needs attention.
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
- `NSWindow.sharingType = .none` confidential-UI requirement on every Scribe-owned window.
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
- Cohere Transcribe is the supported Local model through `mlx-audio-swift` + `CohereTranscribeModel`, pinned to `beshkenadze/cohere-transcribe-03-2026-mlx-fp16`. Local readiness requires verified cache integrity and MLX/runtime support; no Python, Rust, shell, or external executable path is required for normal users.

Product inspiration:

- Handy (`https://github.com/cjpais/Handy`) — useful as inspiration for a small, polished, focused macOS menu-bar utility. Do not copy feature scope.

Design system:

- Scribe Design System bundle, exported from `claude.ai/design` (export id `TAH8RSaJm-oh52jDPSukPA`). Contains design tokens (`colors_and_type.css`), brand assets (logo mark, wordmark, menu bar icons), preview cards, and HTML/JSX UI kits for the menu bar popover, the full Settings window, and the marketing site. Treat the UI kits as conceptual visual exploration — they show how surfaces would look, not which surfaces ship. The Visual Language section above is the spec-side filter; the bundle is the canonical source for exact token values. Copied into the repo at [`design-system/`](design-system/) (sibling to this spec) so asset paths resolve at implementation time.
