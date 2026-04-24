# Decisions

## Product

- `decision_product_promise`: Product promise is "Never miss the record of an important meeting."
- `decision_product_type`: The app is call-capture insurance, not an AI meeting-notes app.
- `decision_v1_surface`: Menu-bar-first app.
- `decision_record_only`: Record-only; no import flow.
- `decision_no_live_transcript`: No live transcript display in v1.
- `decision_no_history`: No transcript history UI in v1; Finder is the database.

## Defaults

- `decision_default_mode`: Default is `Transcribe + save audio`.
- `decision_default_engine`: Default engine is ElevenLabs.
- `decision_default_output`: One folder per meeting.
- `decision_default_audio`: Save `audio.m4a` by default.
- `decision_every_session_transcript`: Every session ends with `transcript.md`.

## Calendar

- `decision_calendar_v1`: Use Apple Calendar/EventKit first.
- `decision_google_calendar_via_apple`: Google Calendar is supported in v1 only if synced into macOS Calendar.
- `decision_direct_calendar_apis_deferred`: Native Google Calendar, Outlook, and other direct APIs are deferred.

## Prompting

- `decision_prompt_at_start`: Prompt when a meeting starts.
- `decision_no_per_call_mode_choice`: Prompt does not ask the user to choose transcribe-only vs recording; that is a setting.
- `decision_start_button_label`: Primary prompt action is `Start Recording`.
- `decision_skip_button_label`: Secondary prompt action is `Skip`.

## Capture

- `decision_capture_mic_and_system`: Capture both microphone and system audio.
- `decision_no_mic_only_fallback`: If system audio permission is missing, do not pretend the app is working.
- `decision_permission_fail_closed`: Missing required permissions block recording.

## End Guard

- `decision_auto_stop_required`: Auto-stop guard is core v1 behavior.
- `decision_end_grace_default`: Default end-detection grace period is 30 seconds.
- `decision_stop_timeout_default`: Default stop prompt timeout is 10 seconds.
- `decision_keep_recording_snooze`: `Keep Recording` snoozes stop prompts, not forever.

## Output

- `decision_folder_name`: Folder name includes date, time, and title.
- `decision_file_names`: Session folder contains `transcript.md`, `audio.m4a`, and `metadata.json`.
- `decision_failure_transcript`: If transcription fails, `transcript.md` still exists and points to saved audio.

## Privacy

- `decision_keychain`: ElevenLabs key stored only in Keychain.
- `decision_context_to_elevenlabs`: Calendar metadata can be used to improve recognition.
- `decision_keyterms_default`: ElevenLabs receives bounded keyterms by default, not full calendar descriptions.
- `decision_no_recurring_consent`: No recurring per-call consent reminder.
- `decision_visible_indicator`: Recording indicator must be visible in the menu bar.

## Local Model

- `decision_local_model_target`: Cohere Transcribe is the target local model.
- `decision_local_model_spike`: Cohere/local mode is a spike until macOS runtime is proven.
- `decision_no_silent_cloud_fallback`: Local mode cannot silently fall back to ElevenLabs.

