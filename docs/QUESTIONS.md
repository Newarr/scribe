# Open Questions

Each question has a stable unique ID for future agent work. Resolved questions move to `DECISIONS.md` rather than being marked resolved here.

## Product And UX

- `q_target_wedge`: Should v1 target a narrower persona first, such as founder/customer calls, sales calls, recruiting calls, or research calls?
- `q_start_reminder_duration`: Should ignored start prompts continue for 3 minutes, 5 minutes, or while call-like audio is active?
- `q_preflight_prompt`: Should broken setup preflight appear 2 minutes before meeting start, 5 minutes before, or only at app launch?
- `q_calendar_or_process_first_trigger`: V1 fires the start prompt on process-detection-with-calendar-enrichment (`decision_prompt_trigger_v1`). Should a pure calendar-event-at-scheduled-start trigger layer in as a secondary path so calendar events with no allowlisted-app launch still get prompted? Belt-and-suspenders coverage vs. risk of duplicate prompts.
- `q_audible_cue_default`: Should the optional audible cue on the stop prompt be on by default for any user segment (e.g., users who often present)?

## End Guard

- `q_end_audio_threshold`: What audio-level threshold counts as low mic plus low system audio?
- `q_end_grace_seconds`: Should end-detection grace be fixed at 30 seconds or configurable?
- `q_calendar_end_plus_audio`: Should auto-stop only arm after scheduled calendar end, or also after long silence before scheduled end?

## Calendar Metadata

- `q_calendar_description_markdown`: Should full calendar notes/description always be included in local Markdown?
- `q_calendar_url_retention`: Should meeting URLs be fully redacted by default, or should domain plus redacted URL be stored?
- `q_attendee_email_retention`: Should attendee emails ever be stored, or display names only?
- `q_full_context_setting`: Should "full calendar context to ElevenLabs" exist in v1 or be deferred?

## Transcription

- `q_elevenlabs_model`: Which ElevenLabs model/version should be pinned for v1?
- `q_context_keyterm_limit`: What max number of recognition keyterms should be sent to ElevenLabs?
- `q_transcription_retry_policy`: How many automatic retries should failed ElevenLabs jobs get?
- `q_partial_transcript`: If transcription partially succeeds, should `transcript.md` include partial text plus failure metadata?
- `q_word_level_timestamps_sidecar`: Should ElevenLabs's word-level timestamps be persisted to a sibling `transcript.json` for downstream tooling, even though the .md only renders per-block timestamps?

## Local Mode

- `q_cohere_runtime`: What macOS runtime path can run Cohere Transcribe reliably from the app?
- `q_cohere_model_size`: What is the actual Cohere model size, and does it justify the onboarding-time download (`decision_cohere_staged_in_onboarding`) or does it warrant deferred lazy-download?
- `q_local_model_fallback`: If Cohere is not practical, should Parakeet v3 or WhisperKit be the fallback local engine?

## Storage

- `q_synced_folder_warning_persistence`: Where is the "user-acknowledged synced folders" list stored — UserDefaults, or in the Settings JSON blob?
- `q_disk_full_behavior`: What should happen when disk space is low before or during recording? `decision_low_disk_warning` covers pre-record; mid-record disk-full handling is still open.

## Release

- `q_repo_shape`: Should the implementation split into `TranscriberApp`, `TranscriberCore`, and `TranscriberCoreTests` immediately?
- `q_diagnostics_bundle`: What exact fields should diagnostics export include?
- `q_packaging`: Is the first release a signed `.app`, signed/notarized `.dmg`, or Homebrew cask?

## Resolved

These IDs are referenced from `DECISIONS.md` ("Resolves `q_*`"). They are kept here as a stable trail so backrefs do not break.

- `q_skip_semantics` — resolved by `decision_skip_semantics`.
- `q_late_join_prompt` — resolved by `decision_late_join_threshold`, `decision_late_join_copy`, `decision_late_join_metadata`, `decision_late_join_buttons`.
- `q_keep_recording_snooze_minutes` — resolved by `decision_keep_recording_snooze_escalation`.
- `q_synced_folder_warning` — resolved by `decision_synced_folder_warning`.
- `q_audio_retention` — resolved by `decision_audio_retention`.
