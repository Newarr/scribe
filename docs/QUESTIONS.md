# Open Questions

Each question has a stable unique ID for future agent work.

## Product And UX

- `q_target_wedge`: Should v1 target a narrower persona first, such as founder/customer calls, sales calls, recruiting calls, or research calls?
- `q_start_reminder_duration`: Should ignored start prompts continue for 3 minutes, 5 minutes, or while call-like audio is active?
- `q_preflight_prompt`: Should broken setup preflight appear 2 minutes before meeting start, 5 minutes before, or only at app launch?
- `q_skip_semantics`: Should `Skip` suppress only this occurrence, or every recurring instance of the same meeting?
- `q_late_join_prompt`: If the app launches during an active calendar event, should it prompt immediately even if the event started long ago?

## End Guard

- `q_end_audio_threshold`: What audio-level threshold counts as low mic plus low system audio?
- `q_end_grace_seconds`: Should end-detection grace be fixed at 30 seconds or configurable?
- `q_keep_recording_snooze_minutes`: Should `Keep Recording` snooze for 5, 10, or 15 minutes?
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

## Local Mode

- `q_cohere_runtime`: What macOS runtime path can run Cohere Transcribe reliably from the app?
- `q_local_model_v1_scope`: Should local mode be excluded from v1, included as experimental, or required before release?
- `q_local_model_fallback`: If Cohere is not practical, should Parakeet v3 or WhisperKit be the fallback local engine?

## Storage

- `q_audio_retention`: Should v1 include optional audio auto-delete, or keep until manually deleted only?
- `q_synced_folder_warning`: Should the app only warn on synced folders, or require explicit confirmation?
- `q_disk_full_behavior`: What should happen when disk space is low before or during recording?

## Release

- `q_repo_shape`: Should the implementation split into `TranscriberApp`, `TranscriberCore`, and `TranscriberCoreTests` immediately?
- `q_diagnostics_bundle`: What exact fields should diagnostics export include?
- `q_packaging`: Is the first release a signed `.app`, signed/notarized `.dmg`, or Homebrew cask?

