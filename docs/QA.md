# QA And Acceptance Criteria

## V1 Acceptance Criteria

- `ac_calendar_prompt`: User gets prompted when a calendar meeting begins and an allowlisted meeting app has been running for the dwell window. (Process-detection-with-calendar-enrichment per `decision_prompt_trigger_v1`.)
- `ac_one_click_start`: One click starts microphone plus system audio recording.
- `ac_visible_recording`: Menu bar clearly shows active recording, elapsed time, and meeting title.
- `ac_state_distinguishability`: Each menu-bar state is distinguishable by shape, not by color alone.
- `ac_live_capture_meter_menu_bar`: Menu-bar icon shows live `MIC` and `SYS` indicators next to elapsed time during Recording. Indicators dim/amber when their channel is silent for >5 seconds. At-a-glance trust without opening the popover.
- `ac_live_capture_meter_popover`: Active-recording popover shows larger `MIC` and `SYS` meters for users who explicitly verify.
- `ac_privacy_status_block`: Active-recording popover opens with a Privacy Status block at top showing audio destination path, what is captured, what is NOT captured, and the active engine. Always visible, never collapsed.
- `ac_required_permissions_block`: Missing required permissions (mic, system audio, output folder write, ElevenLabs key when Cloud is selected) block recording loudly.
- `ac_recommended_permissions_badge`: Missing recommended permissions (calendar, notifications) surface `Setup Required` in the menu bar but do not block recording.
- `ac_audio_saved_first`: Audio is saved durably before transcription starts.
- `ac_every_session_transcript`: Every session folder contains `transcript.md`.
- `ac_failure_transcript`: If transcription fails, `transcript.md` exists with failure status and saved audio reference.
- `ac_failure_transcript_recovery`: Failure transcripts include `error_code`, `retry_count`, audio metadata, and a `## What you can do` body section listing concrete recovery actions.
- `ac_audio_default`: Default output includes `audio.m4a`.
- `ac_default_output_root`: Default output root is `~/Transcriber/`, not `~/Documents/Transcriber/`.
- `ac_auto_stop`: App auto-stops after end guard timeout if user does not click `Keep Recording`.
- `ac_stop_prompt_hud`: Stop prompt is a floating HUD; it does not steal focus from the active app.
- `ac_keep_recording_snooze_escalation`: `Keep Recording` snoozes 3 / 9 / 27 minutes per session click count.
- `ac_context_keyterms`: ElevenLabs receives bounded calendar-derived keyterms by default.
- `ac_no_content_logs`: Logs do not include transcript, audio, or raw calendar content.
- `ac_window_sharing_none`: Every Transcriber-owned window sets `NSWindow.sharingType = .none` so prompts and popovers do not appear in shared screen video.
- `ac_recents_max_5`: Menu-bar Recents popover shows at most 5 saved sessions.
- `ac_recents_actions`: Each Recents item exposes `Open Folder` and `Open Transcript`; failed items also expose `Retry`.
- `ac_saved_signal`: Saved success fires a transient `UNUserNotificationCenter` notification with `Open Folder` and `Open Transcript` actions plus a brief menu-bar `Saved` glyph; no persistent in-app toast.
- `ac_cohere_staged_in_onboarding`: Cohere model downloads in the background during onboarding regardless of which engine the user picks.
- `ac_no_silent_engine_fallback`: Engine switches are explicit user actions; no silent fallback in either direction.
- `ac_late_join_threshold`: Late-join prompt fires only if at least 10 minutes remain on the scheduled event or a meeting app is currently in-call.
- `ac_late_join_metadata`: Late-joined sessions write `joined_late: true` and `elapsed_at_start_seconds` to frontmatter; `scheduled_start` and `actual_start` already encode schedule and recording-start timestamps.
- `ac_two_button_prompt`: Both standard and late-join prompts present exactly two buttons: `Start Recording` and `Not now`.
- `ac_not_now_dismisses_occurrence`: `Not now` dismisses the current prompt; future calendar occurrences and future process-detection candidates re-prompt normally.
- `ac_more_options_disclosure`: A `More options ▾` disclosure under the buttons (closed by default) exposes `Stop asking about this meeting` and `Stop detecting [App] for 30 minutes`.
- `ac_quiet_meetings_settings`: Suppressed recurring meetings appear in Settings → Quiet Meetings with a `Re-enable` action per series.
- `ac_synced_folder_warning_third_party`: Third-party File Provider clouds (Dropbox, Google Drive, OneDrive, etc.) trigger a one-time warning per synced root.
- `ac_synced_folder_no_warning_icloud`: iCloud Drive does not trigger a blocking warning; surfaces a passive Settings note instead.
- `ac_low_disk_warning`: Pre-record warning fires if free disk is below ~1 GB at recording start.
- `ac_status_conditional`: Frontmatter `status` is omitted on success; required on `partial` or `failed`.
- `ac_no_schema_field`: Frontmatter does not include a `schema` field in v1.
- `ac_speaker_h3_block`: Each speaker block in the transcript body is rendered as `### [HH:MM:SS] Speaker A` with one timestamp per block, not per utterance.
- `ac_body_orientation_first`: Transcript body opens with H1 → metadata blockquote → attendees → calendar notes → `## Transcript`. Calendar notes are not intermixed with the transcript.
- `ac_onboarding_one_screen_per_permission`: Onboarding presents one screen per permission with pre-framed copy before triggering the system dialog.
- `ac_onboarding_resumable`: Onboarding resumes at the first un-granted required permission if the user quits mid-flow.

## QA Scenarios

### Setup

- `qa_setup_all_missing`: Fresh install with no permissions granted.
- `qa_setup_calendar_missing`: Calendar access missing.
- `qa_setup_mic_missing`: Microphone access missing.
- `qa_setup_system_audio_missing`: System audio/screen capture missing.
- `qa_setup_notifications_missing`: Notifications permission missing; redundant-channel pattern degrades and `Setup Required` fires.
- `qa_setup_api_key_missing`: ElevenLabs key missing; default engine flips to Local once Cohere finishes downloading.
- `qa_setup_output_unwritable`: Output folder not writable.
- `qa_setup_permission_revoked`: Permission revoked while app is running.
- `qa_onboarding_resume_after_quit`: User quits mid-onboarding; next launch resumes at first un-granted permission.
- `qa_onboarding_screen_recording_pre_prompt`: Screen Recording onboarding screen displays the "what is and is not captured" visual before triggering the system dialog.
- `qa_onboarding_test_recording_waits`: Test recording at the end of onboarding waits until at least one engine is ready (cloud key entered or Cohere finished downloading).

### Calendar Watcher

- `qa_calendar_prompt_start`: Prompt appears at meeting start (or on detection candidate per `decision_prompt_trigger_v1`).
- `qa_calendar_launch_mid_meeting_above_threshold`: App launches during active meeting with >=10 min remaining; prompt fires.
- `qa_calendar_launch_mid_meeting_below_threshold`: App launches during active meeting with <10 min remaining; menu bar shows `Meeting detected` but no prompt fires unless a meeting app is in-call.
- `qa_calendar_recurring_dedupe`: Recurring meeting prompts de-dupe by occurrence.
- `qa_calendar_changed_event`: Calendar event updates while app is running.
- `qa_calendar_sleep_wake`: Mac sleeps before meeting and wakes during meeting.
- `qa_calendar_sleep_wake_skipped_event`: Mac wakes after user already skipped an event in this session; no re-prompt.
- `qa_calendar_all_day_ignored`: All-day/free events are ignored by default.
- `qa_calendar_declined_ignored`: Declined and tentative events are skipped per EventKit participation status.
- `qa_calendar_stale_past_end_ignored`: Events whose end time is past per EventKit are skipped.

### Recording

- `qa_record_mic_and_system`: Capture includes microphone and system audio.
- `qa_record_browser_call`: Browser meeting audio is captured.
- `qa_record_zoom_call`: Zoom meeting audio is captured.
- `qa_record_teams_call`: Teams meeting audio is captured.
- `qa_record_no_mic_only`: App blocks rather than recording mic-only when system audio permission is missing.
- `qa_record_app_audio_excluded`: App audio is excluded from capture.
- `qa_record_disk_stream`: Long meeting streams to disk and memory stays bounded.
- `qa_record_meter_sys_silent`: System-audio channel drops to zero for >5s during recording; the menu-bar `SYS` indicator dims/turns amber and the popover meter does the same.
- `qa_record_meter_mic_silent`: Mic channel drops to zero for >5s during recording; the menu-bar `MIC` indicator dims/turns amber and the popover meter does the same.
- `qa_privacy_status_block_visible`: Active-recording popover opens with the Privacy Status block at top, showing destination path, captured sources, exclusions, and engine.
- `qa_privacy_status_engine_explicit`: Engine in Privacy Status is the full label (`ElevenLabs (cloud)` or `Cohere (local)`), not abbreviated.

### Start Prompt

- `qa_prompt_primary`: Primary action `Start Recording` begins capture.
- `qa_prompt_not_now`: `Not now` dismisses the current prompt; subsequent calendar occurrences and process-detection candidates re-prompt normally.
- `qa_prompt_more_options_closed_default`: `More options ▾` disclosure is closed by default; users do not see the suppression options unless they expand it.
- `qa_prompt_more_options_meeting_suppress`: Expanding `More options ▾` and clicking `Stop asking about this meeting` adds the recurring series to the suppress list; future occurrences do not prompt.
- `qa_prompt_more_options_app_suppress`: Expanding `More options ▾` and clicking `Stop detecting [App] for 30 minutes` suppresses the triggering app for 30 minutes.
- `qa_prompt_quiet_meetings_re_enable`: Settings → Quiet Meetings lists suppressed series; `Re-enable` reverses the suppression so future occurrences prompt again.
- `qa_prompt_late_join_same_buttons`: Late-join prompt presents the same `Start Recording` / `Not now` buttons as the standard prompt; the disclosure surfaces the same two suppression options.
- `qa_prompt_ignored_reprompt`: Ignored prompt re-fires a fresh notification after 60 seconds.
- `qa_prompt_broken_preflight`: Broken setup prompts before meeting start.
- `qa_prompt_active_recording_conflict`: Meeting starts while another recording is active.
- `qa_prompt_redundant_channels`: Notification fires in parallel with the modal; menu-bar glyph flips to `Meeting detected`.
- `qa_prompt_modal_sharing_none`: Start-prompt modal does not appear in shared screen video.
- `qa_prompt_modal_multi_monitor`: Modal appears on the screen containing the active meeting-app window, not the keyWindow's screen.
- `qa_prompt_late_join_copy`: Late-join prompt copy reads "Recording will capture from now onward", not "won't be captured".
- `qa_prompt_late_join_disclosure_includes_event_suppress`: When the late-join `More options ▾` is expanded, the meeting-suppression option still suppresses the recurring series (same wording as standard prompt). No special "this event only" affordance is needed because the recurring-series suppression covers the case.

### End Guard

- `qa_end_after_calendar_and_silence`: Scheduled end plus silence triggers stop prompt.
- `qa_end_audio_resumes`: Audio resumes during grace period and stop flow cancels.
- `qa_end_audio_resumes_in_countdown`: Audio resumes during the 10-second countdown; stop flow cancels and re-prompt is suppressed for 60 seconds.
- `qa_end_countdown_auto_stop`: Countdown auto-stops if ignored.
- `qa_end_keep_recording_first`: First `Keep Recording` click snoozes 3 minutes.
- `qa_end_keep_recording_second`: Second `Keep Recording` click in the session snoozes 9 minutes.
- `qa_end_keep_recording_third`: Third+ `Keep Recording` click snoozes 27 minutes.
- `qa_end_runaway_hard_ceiling`: Force-prompt fires when recording is 4 hours past scheduled end regardless of snooze.
- `qa_end_stop_now`: `Stop Now` finalizes immediately.
- `qa_end_before_calendar`: Long silence before calendar end does not incorrectly stop unless spec allows it.
- `qa_end_hud_no_focus_steal`: Stop prompt HUD does not pull focus from the active app.
- `qa_end_hud_sharing_none`: Stop prompt HUD does not appear in shared screen video.

### Transcription

- `qa_transcription_success`: ElevenLabs produces transcript and Markdown status is omitted (success).
- `qa_transcription_401`: Invalid API key produces recoverable failure.
- `qa_transcription_429`: Rate limit produces recoverable failure.
- `qa_transcription_timeout`: Timeout preserves audio and writes failed transcript.
- `qa_transcription_partial`: Partial transcript includes partial text plus failure metadata if supported.
- `qa_transcription_retry`: Recoverable failed job can retry from saved audio via the menu-bar Recents `Retry` action.
- `qa_transcription_engine_switch`: User switches engine in Settings → Engine and re-triggers transcription on saved audio without silent fallback.
- `qa_transcription_failure_recovery_section`: Failure transcript includes a `## What you can do` body section.

### Output

- `qa_output_folder_structure`: Folder contains `transcript.md`, `audio.m4a`, `metadata.json`.
- `qa_output_collision`: Duplicate title/time creates unique folder.
- `qa_output_filename_sanitize`: Unsafe title characters are sanitized.
- `qa_output_atomic_write`: Partial files are renamed atomically.
- `qa_output_synced_warning_third_party`: Third-party File Provider cloud output folders trigger a one-time warning per synced root.
- `qa_output_synced_no_warning_icloud`: iCloud Drive output folder does not trigger a blocking warning; passive note in Settings.
- `qa_output_synced_warning_root_change`: Switching from Dropbox to a different provider re-warns; switching subdirectories within the same provider does not.
- `qa_output_disk_full_pre_record`: Pre-record warning fires if free disk is below ~1 GB.
- `qa_output_disk_full_during`: Low disk space mid-recording fails safely without losing already captured audio where possible.
- `qa_output_recents_max_5`: Recents popover shows at most 5 saved sessions.
- `qa_output_recents_failed_session_retry`: Failed sessions in Recents expose a `Retry` action.

### Markdown Contract

- `qa_md_no_schema_field`: Frontmatter has no `schema` field.
- `qa_md_status_omitted_on_success`: Success transcripts have no `status` field.
- `qa_md_status_failed`: Failure transcripts have `status: failed` plus `error_code`, `error_message`, `retry_count`, `audio_duration_seconds`, `audio_size_bytes`.
- `qa_md_late_join_metadata`: Late-joined sessions write `joined_late: true` and `elapsed_at_start_seconds`. No `scheduled_start_at` / `recording_started_at` aliases — `scheduled_start` and `actual_start` carry those values.
- `qa_md_body_h1_title`: Body opens with H1 mirroring the frontmatter title.
- `qa_md_body_metadata_blockquote`: Metadata blockquote (duration, sources, engine) appears below the H1 and above the attendees list.
- `qa_md_body_attendees_separated`: Attendees, calendar notes, and transcript live under separate `##` headings.
- `qa_md_speaker_h3_block`: Speaker blocks render as `### [HH:MM:SS] Speaker A`.
- `qa_md_speaker_grouped`: Consecutive same-speaker utterances collapse into one block.
- `qa_md_one_timestamp_per_block`: One timestamp per speaker block, not per utterance.

### Storage

- `qa_storage_panel_total_size`: Settings → Storage shows total Transcriber audio size on disk.
- `qa_storage_delete_all_audio`: `Delete all audio (keep transcripts)` action requires confirmation.
- `qa_storage_save_signal_size`: Saved notification body includes audio size.

### Security

- `qa_security_keychain`: ElevenLabs key stored only in Keychain.
- `qa_security_no_userdefaults_secret`: Key is not in UserDefaults or plist.
- `qa_security_keyterms_only`: ElevenLabs context excludes full description, URLs, emails, dial-in codes by default.
- `qa_security_url_redacted`: Meeting URLs are redacted in Markdown by default.
- `qa_security_logs_redacted`: Logs contain lifecycle events only.
- `qa_security_diagnostics_redacted`: Diagnostics export redacts secrets and calendar text.
- `qa_security_window_sharing_start_modal`: Start prompt modal is excluded from screen capture.
- `qa_security_window_sharing_stop_hud`: Stop prompt HUD is excluded from screen capture.
- `qa_security_window_sharing_popover`: Active-recording popover is excluded from screen capture.
- `qa_security_window_sharing_settings`: Settings window is excluded from screen capture.
- `qa_security_window_sharing_diagnostics`: Diagnostics window is excluded from screen capture.
