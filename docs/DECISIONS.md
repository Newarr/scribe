# Decisions

## Product

- `decision_product_promise`: Product promise is "Never miss the record of an important meeting."
- `decision_product_type`: The app is call-capture insurance, not an AI meeting-notes app.
- `decision_v1_surface`: Menu-bar-first app.
- `decision_record_only`: Record-only; no import flow.
- `decision_no_live_transcript`: No live transcript display in v1.
- `decision_no_history`: No transcript history UI in v1; Finder is the database. The menu-bar Recents popover (max 5 items) is a shortcut, not a browser.

## Design Principles

- `decision_never_silent_failure`: Any state where the app appears to be working but isn't (mic muted, system audio routing broken, transcription timed out, file not saved, permission revoked while running) must surface immediately on the menu-bar trust surface.
- `decision_cost_asymmetric_prompts`: Start-prompt UX is aggressive (modal + activate-ignoring-other-apps) because missing the start = losing the whole meeting; stop-prompt UX is non-focus-stealing (floating HUD) because missing the stop = losing ~10s of post-call audio.
- `decision_confidential_ui`: Every Transcriber-owned window sets `NSWindow.sharingType = .none` so prompts and popovers never appear in shared screen video.

## Defaults

- `decision_default_mode`: Default is `Transcribe + save audio`.
- `decision_default_engine`: Default engine is ElevenLabs (cloud).
- `decision_cohere_staged_in_onboarding`: Cohere downloads in the background during onboarding regardless of which engine the user picks. Keyless users get a working app and keyed users get a fallback when cloud fails.
- `decision_default_output_root`: Default output root is `~/Transcriber/`. Avoid `~/Documents/Transcriber/` because Documents may be inside iCloud Desktop & Documents sync. `~/Movies/Transcriber/` is an acceptable alternative.
- `decision_default_output_per_meeting`: One folder per meeting.
- `decision_default_audio`: Save `audio.m4a` by default.
- `decision_every_session_transcript`: Every session ends with `transcript.md`.

## Calendar

- `decision_calendar_v1`: Use Apple Calendar/EventKit first.
- `decision_google_calendar_via_apple`: Google Calendar is supported in v1 only if synced into macOS Calendar.
- `decision_direct_calendar_apis_deferred`: Native Google Calendar, Outlook, and other direct APIs are deferred.
- `decision_skip_declined_tentative`: Watcher skips declined and tentative events; respects EventKit participation status.
- `decision_skip_stale_past_end`: Watcher skips events whose end time is already in the past per EventKit, even if a stale calendar cache shows them as active.
- `decision_wake_dedupe_skipped`: After wake-from-sleep, do not re-prompt for an event the user already dismissed via `Not now` or suppressed via `More options ▾ → Stop asking about this meeting` in this session.

## Prompting

- `decision_prompt_at_start`: Prompt when a meeting starts.
- `decision_prompt_trigger_v1`: Process-detection-with-calendar-enrichment is the primary trigger in v1: an allowlisted meeting app (Zoom/Meet/Teams) running for the dwell window fires the prompt; the title is enriched with the overlapping calendar event. The pure calendar-event-at-scheduled-start trigger may layer in as a secondary path later (see `q_calendar_or_process_first_trigger`).
- `decision_start_prompt_modal`: Start prompt is an `NSAlert` modal with `NSApp.activate(ignoringOtherApps: true)`. Focus-stealing is intentional and justified by `decision_cost_asymmetric_prompts`.
- `decision_start_prompt_redundant_channels`: Menu-bar glyph flip + `UNUserNotificationCenter` notification fire in parallel as redundant channels for cases where the modal is missed (DND, fullscreen Zoom, screen-share suppression). Redundant, not replacement.
- `decision_start_prompt_multi_monitor`: The modal is positioned on the screen containing the active meeting-app window, not the keyWindow's screen.
- `decision_no_per_call_mode_choice`: Prompt does not ask the user to choose transcribe-only vs recording; that is a setting.
- `decision_start_button_label`: Primary prompt action is `Start Recording`.
- `decision_two_button_prompt`: All start prompts (standard and late-join) use the same two buttons — `Start Recording` (primary) and `Not now` (secondary). The two-button shape keeps the cognitive surface constant and prevents the user from having to learn four different suppression mechanics.
- `decision_suppression_disclosure`: Rare suppression flows live behind a `More options ▾` disclosure under the buttons (closed by default). Two options inside: `Stop asking about this meeting` (suppresses recurring calendar series, keys on recurrence-series ID) and `Stop detecting [App] for 30 minutes` (app-level false-positive defense). Replaces the previous four-mechanism `Not a meeting` / `Skip for now` / `Not this event` / `Don't ask for this meeting` model.
- `decision_quiet_meetings_settings`: Suppressed recurring meetings are listed in Settings → Quiet Meetings with a `Re-enable` action per series. Without this, suppression is invisible to the user once applied. Resolves `q_skip_semantics`.
- `decision_late_join_threshold`: Late-join prompt fires only if at least 10 minutes remain on the scheduled event OR a meeting app is currently in-call. Otherwise the watcher leaves the menu bar in `Meeting detected` and lets the user click in. Resolves `q_late_join_prompt`.
- `decision_late_join_copy`: Late-join prompt copy is factual, not apologetic: `Record 'Acme Weekly'? This event started 22 minutes ago. Recording will capture from now onward.`
- `decision_late_join_metadata`: Late-joined sessions write `joined_late: true` and `elapsed_at_start_seconds` to frontmatter. The standard `scheduled_start` and `actual_start` fields already encode the schedule and recording-start timestamps; do not add `scheduled_start_at` / `recording_started_at` aliases.
- `decision_late_join_buttons`: Late-join prompt uses the same two-button shape as the standard prompt (`Start Recording` / `Not now`) plus the same `More options ▾` disclosure. Superseded the earlier "swap to `Not this event` and drop `Skip for now`" model in favor of a constant cognitive surface.

## Capture

- `decision_capture_mic_and_system`: Capture both microphone and system audio.
- `decision_no_mic_only_fallback`: If system audio permission is missing, do not pretend the app is working.
- `decision_permission_fail_closed`: Missing required permissions block recording.
- `decision_live_audio_meter`: Live mic and system-audio meters appear in two places. (1) The menu-bar icon shows a small `MIC` and `SYS` indicator next to the elapsed time during Recording — at-a-glance proof, no click required. Indicators dim/amber when their channel is silent for >5 seconds. (2) The active-recording popover shows larger versions of the same meters for users who explicitly check.
- `decision_privacy_status_block`: Active-recording popover opens with a Privacy Status block (always at top, never collapsed) showing audio destination path, what is captured (mic + system audio), what is NOT captured (no video, no screenshots), and the active engine. This is inspectable proof, not a marketing claim. A paranoid user gets one-click verification.
- `decision_one_active_recording`: Only one recording active at a time.
- `decision_no_prompt_during_active_recording`: While Capturing, all start-prompt triggers (process-detection candidates, calendar-event start times) are suppressed. New events are queued, not prompted.
- `decision_queued_event_in_popover`: A queued next event is surfaced in the active-recording popover (`Next: 'Customer Call - Acme' at 15:00`) under the Privacy Status block. No modal interruption during recording.
- `decision_queue_then_fire_on_stop`: When the current recording ends, if the queued event is still active and process-detection still positive, fire its prompt immediately. If the queued event has expired, drop it.
- `decision_no_automatic_context_switch`: User confirms each new recording explicitly. No "stop A and start B" single-button transition.

## Menu Bar UI

- `decision_visible_indicator`: Recording indicator must be visible in the menu bar.
- `decision_state_distinguishability`: Each menu-bar state must be distinguishable by shape, not by color alone. `Setup Required` and `Failed/recoverable` must look different even though both are warnings.
- `decision_recents_count`: The menu-bar popover Recents section shows the last 5 saved sessions only. Past 5 is a history UI, which v1 does not ship.
- `decision_recents_actions`: Recent items expose `Open Folder` and `Open Transcript` actions; failed items also expose `Retry`. No audio-delete action lives in Recents — bulk audio management is in Settings → Storage.
- `decision_saved_signal`: Saved success is a transient `UNUserNotificationCenter` notification (auto-dismiss per macOS default) plus a brief menu-bar `Saved` glyph. The Recents popover is the durable record of recent saves.

## End Guard

- `decision_auto_stop_required`: Auto-stop guard is core v1 behavior.
- `decision_end_grace_default`: Default end-detection grace period is 30 seconds.
- `decision_stop_timeout_default`: Default stop prompt timeout is 10 seconds.
- `decision_stop_prompt_hud`: Stop prompt is a floating HUD (`NSPanel` with `.floatingWindowLevel`, non-activating), not a focus-stealing modal. Visible across spaces and over fullscreen meeting apps.
- `decision_stop_prompt_countdown`: Big numeric countdown is primary (`10`, `9`, `8`...). Progress ring secondary in the HUD. Menu-bar icon shows the same countdown digit.
- `decision_stop_prompt_audible_cue`: Optional audible cue, off by default, configurable in Settings. Recommended for users who often present.
- `decision_keep_recording_snooze`: `Keep Recording` snoozes stop prompts, not forever.
- `decision_keep_recording_snooze_escalation`: Snooze duration escalates 3 / 9 / 27 minutes per session click count. Audio activity resets the silence detector and renders the snooze inert until the next silence stretch. Resolves `q_keep_recording_snooze_minutes`.
- `decision_runaway_hard_ceiling`: Regardless of snooze count, force-prompt the user when recording extends 4 hours past scheduled end.

## Output

- `decision_folder_name`: Folder name includes date, time, and title.
- `decision_file_names`: Session folder contains `transcript.md`, `audio.m4a`, and `metadata.json`.
- `decision_failure_transcript`: If transcription fails, `transcript.md` still exists and points to saved audio.
- `decision_synced_folder_detection`: Detect synced folders generically via `~/Library/CloudStorage/*` (catches all File Provider clouds), the iCloud path, and legacy paths. Run detection at folder selection, app launch, and recording start only.
- `decision_synced_folder_warning`: No blocking warning for iCloud Drive (it's macOS-default storage); passive Settings note instead. Warn once per synced root for third-party File Provider clouds with soft copy. Resolves `q_synced_folder_warning`.

## Markdown Contract

- `decision_no_schema_field`: Frontmatter does not include a `schema` field in v1. Add only when v2 actually breaks compatibility.
- `decision_status_conditional`: `status` is omitted when the session is complete, required when `partial` or `failed`. A file with no `status` field is `complete` by convention.
- `decision_body_orientation_first`: Body opens with H1 → metadata blockquote → attendees list → calendar notes (if any) → `## Transcript`. Calendar notes are not intermixed with the transcript.
- `decision_speaker_h3_block`: Each speaker block is rendered as `### [HH:MM:SS] Speaker A`. One timestamp per speaker block, not per utterance. Consecutive same-speaker utterances are grouped into one block.
- `decision_no_speaker_rename_v1`: Speaker labels stay as `Speaker A / B / C` in v1; no in-app rename UI. Users sed/find-replace in their editor of choice.
- `decision_failure_transcript_artifact`: Failure transcripts use a superset of the success frontmatter (adding `error_code`, `error_message`, `retry_count`, `audio_duration_seconds`, `audio_size_bytes`) and include a `## What you can do` body section listing concrete recovery actions.
- `decision_retry_in_recents`: Retry is a one-click affordance in the menu-bar Recents popover for any failed session within the last 24 hours, not just the most recent.

## Storage

- `decision_audio_retention`: Audio is kept until manually deleted in v1. No background auto-delete. Resolves `q_audio_retention`.
- `decision_storage_panel`: Settings → Storage panel shows total Transcriber audio size on disk with `Reveal in Finder` and `Delete all audio (keep transcripts)` (behind confirmation).
- `decision_low_disk_warning`: Pre-record disk-space warning if free disk is below ~1 GB at recording start.
- `decision_audio_size_in_save_signal`: Saved notification body shows audio size (e.g. `54 min · 47 MB · ElevenLabs`) so users see accumulation without surprise.

## Privacy

- `decision_keychain`: ElevenLabs key stored only in Keychain.
- `decision_context_to_elevenlabs`: Calendar metadata can be used to improve recognition.
- `decision_keyterms_default`: ElevenLabs receives bounded keyterms by default, not full calendar descriptions.
- `decision_no_recurring_consent`: No recurring per-call consent reminder.
- `decision_window_sharing_none`: Every Transcriber-owned window sets `NSWindow.sharingType = .none`. Encoded in `decision_confidential_ui` under Design Principles; cross-referenced here for the privacy section.

## Onboarding

- `decision_onboarding_one_screen_per_permission`: One dedicated screen per permission, in this order: Welcome → Microphone → Calendar → Notifications → Screen Recording → ElevenLabs API Key (optional) → Choose Engine → Output Folder → Test Recording → Done.
- `decision_onboarding_screen_recording_showpiece`: The Screen Recording screen explicitly shows what IS captured (audio, speaker labels) and what is NOT (video, screenshots, keystrokes, browser history) with explicit cross-out marks. Required to convert macOS's "Screen Recording" framing into an explained one before the system dialog fires.
- `decision_onboarding_resumable`: If the user quits mid-onboarding, the next launch resumes at the first un-granted required permission, not the welcome screen.
- `decision_setup_required_reuses_onboarding`: The same per-permission screens are reused for the Setup-Required popover when permissions get revoked later. Same UI, different entry point.
- `decision_test_recording_waits_for_engine`: Test recording at the end of onboarding waits until at least one engine is ready (cloud key entered or Cohere finished downloading).
- `decision_notifications_permission_required`: `UNUserNotificationCenter` permission is part of required setup. Without it the redundant-channel pattern collapses; the menu-bar `Setup Required` state fires.

## Local Model

- `decision_local_model_target`: Cohere Transcribe is the target local model.
- `decision_local_model_spike`: Cohere/local mode is a spike until macOS runtime is proven.
- `decision_no_silent_engine_fallback`: No silent fallback in either direction (local → cloud or cloud → local). Engine switches are explicit user actions. Updated from `decision_no_silent_cloud_fallback` to be symmetric.
- `decision_cohere_atomic_install`: Cohere downloads atomically (`.partial` → rename) with checksum verification. While unverified, the engine pointer stays on the user's chosen primary; switching to Local is blocked until verification.
