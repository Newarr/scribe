# QA And Acceptance Criteria

## V1 Acceptance Criteria

- `ac_calendar_prompt`: User gets prompted when a calendar meeting starts.
- `ac_one_click_start`: One click starts microphone plus system audio recording.
- `ac_visible_recording`: Menu bar clearly shows active recording, elapsed time, and meeting title.
- `ac_permissions_block`: Missing mic, system audio, calendar, key, or output permission blocks recording loudly.
- `ac_audio_saved_first`: Audio is saved durably before transcription starts.
- `ac_every_session_transcript`: Every session folder contains `transcript.md`.
- `ac_failure_transcript`: If transcription fails, `transcript.md` exists with failure status and saved audio reference.
- `ac_audio_default`: Default output includes `audio.m4a`.
- `ac_auto_stop`: App auto-stops after end guard timeout if user does not click `Keep Recording`.
- `ac_context_keyterms`: ElevenLabs receives bounded calendar-derived keyterms by default.
- `ac_no_content_logs`: Logs do not include transcript, audio, or raw calendar content.

## QA Scenarios

### Setup

- `qa_setup_all_missing`: Fresh install with no permissions granted.
- `qa_setup_calendar_missing`: Calendar access missing.
- `qa_setup_mic_missing`: Microphone access missing.
- `qa_setup_system_audio_missing`: System audio/screen capture missing.
- `qa_setup_api_key_missing`: ElevenLabs key missing.
- `qa_setup_output_unwritable`: Output folder not writable.
- `qa_setup_permission_revoked`: Permission revoked while app is running.

### Calendar Watcher

- `qa_calendar_prompt_start`: Prompt appears at meeting start.
- `qa_calendar_launch_mid_meeting`: App launches during active meeting and prompts.
- `qa_calendar_recurring_dedupe`: Recurring meeting prompts de-dupe by occurrence.
- `qa_calendar_changed_event`: Calendar event updates while app is running.
- `qa_calendar_sleep_wake`: Mac sleeps before meeting and wakes during meeting.
- `qa_calendar_all_day_ignored`: All-day/free events are ignored by default.

### Recording

- `qa_record_mic_and_system`: Capture includes microphone and system audio.
- `qa_record_browser_call`: Browser meeting audio is captured.
- `qa_record_zoom_call`: Zoom meeting audio is captured.
- `qa_record_teams_call`: Teams meeting audio is captured.
- `qa_record_no_mic_only`: App blocks rather than recording mic-only when system audio permission is missing.
- `qa_record_app_audio_excluded`: App audio is excluded from capture.
- `qa_record_disk_stream`: Long meeting streams to disk and memory stays bounded.

### Start Prompt

- `qa_prompt_primary`: Primary action starts recording.
- `qa_prompt_skip`: Skip suppresses current occurrence.
- `qa_prompt_ignored_reprompt`: Ignored prompt reappears after configured delay.
- `qa_prompt_broken_preflight`: Broken setup prompts before meeting start.
- `qa_prompt_active_recording_conflict`: Meeting starts while another recording is active.

### End Guard

- `qa_end_after_calendar_and_silence`: Scheduled end plus silence triggers stop prompt.
- `qa_end_audio_resumes`: Audio resumes during grace period and stop flow cancels.
- `qa_end_countdown_auto_stop`: Countdown auto-stops if ignored.
- `qa_end_keep_recording`: Keep Recording snoozes stop prompts.
- `qa_end_stop_now`: Stop Now finalizes immediately.
- `qa_end_before_calendar`: Long silence before calendar end does not incorrectly stop unless spec allows it.

### Transcription

- `qa_transcription_success`: ElevenLabs produces transcript and Markdown status is complete.
- `qa_transcription_401`: Invalid API key produces recoverable failure.
- `qa_transcription_429`: Rate limit produces recoverable failure.
- `qa_transcription_timeout`: Timeout preserves audio and writes failed transcript.
- `qa_transcription_partial`: Partial transcript includes partial text plus failure metadata if supported.
- `qa_transcription_retry`: Recoverable failed job can retry from saved audio.

### Output

- `qa_output_folder_structure`: Folder contains `transcript.md`, `audio.m4a`, `metadata.json`.
- `qa_output_collision`: Duplicate title/time creates unique folder.
- `qa_output_filename_sanitize`: Unsafe title characters are sanitized.
- `qa_output_atomic_write`: Partial files are renamed atomically.
- `qa_output_synced_warning`: Synced output folders trigger warning.
- `qa_output_disk_full`: Low disk space fails safely without losing already captured audio where possible.

### Security

- `qa_security_keychain`: ElevenLabs key stored only in Keychain.
- `qa_security_no_userdefaults_secret`: Key is not in UserDefaults or plist.
- `qa_security_keyterms_only`: ElevenLabs context excludes full description, URLs, emails, dial-in codes by default.
- `qa_security_url_redacted`: Meeting URLs are redacted in Markdown by default.
- `qa_security_logs_redacted`: Logs contain lifecycle events only.
- `qa_security_diagnostics_redacted`: Diagnostics export redacts secrets and calendar text.

