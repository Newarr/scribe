# References And Useful Pointers

This project is separate from OpenOats. Use these references for implementation ideas only; do not inherit old product scope such as import, live transcript, vector search, LLM notes, or history UI.

## Local Code References

OpenOats source tree:

- `/Users/szymonsypniewicz/Documents/code/OpenOats/app/OpenOats`

Potentially useful files:

- `Sources/OpenOats/Transcription/ElevenLabsScribeBackend.swift` - ElevenLabs multipart request, key validation, retry handling.
- `Sources/OpenOats/Transcription/WAVEncoder.swift` - Float32 PCM to WAV encoding.
- `Sources/OpenOats/Transcription/Data+Multipart.swift` - multipart form-data helper.
- `Sources/OpenOats/Transcription/CloudASRSupport.swift` - cloud ASR error and retry pattern.
- `Sources/OpenOats/Transcription/WhisperKitBackend.swift` - WhisperKit backend wrapper.
- `Sources/OpenOats/Transcription/WhisperKitManager.swift` - WhisperKit model download and transcription setup.
- `Sources/OpenOats/Transcription/ParakeetBackend.swift` - FluidAudio/Parakeet backend wrapper.
- `Sources/OpenOats/Transcription/BatchAudioTranscriber.swift` - chunked audio-file transcription and resampling helpers.
- `Sources/OpenOats/Audio/SystemAudioCapture.swift` - system audio capture ideas.
- `Sources/OpenOats/Audio/AudioRecorder.swift` - durable audio writing ideas.
- `Sources/OpenOats/Storage/SessionRepository.swift` - session/file persistence patterns.
- `Sources/OpenOats/Intelligence/MarkdownMeetingWriter.swift` - Markdown/frontmatter formatting ideas.
- `Sources/OpenOats/App/MenuBarController.swift` - menu bar controller pattern.
- `Sources/OpenOats/Views/MenuBarPopoverView.swift` - menu bar popover pattern.
- `Sources/OpenOats/App/MeetingDetectionController.swift` - meeting lifecycle ideas, but do not copy product behavior blindly.
- `Sources/OpenOats/Settings/SettingsStore.swift` - settings persistence patterns.

Use OpenOats cautiously:

- It is broader than this product.
- It includes live transcript, notes, vector search, sidecast, import, batch retranscription, onboarding, updater, and history behavior that should not enter v1 unless explicitly re-approved.

## Apple APIs

Likely required:

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

## External Service References

ElevenLabs:

- Use ElevenLabs as v1 primary transcription engine.
- Send audio plus bounded keyterms only by default.
- Do not send full calendar descriptions, meeting URLs, attendee emails, dial-in codes, or passwords unless a future setting explicitly enables full context.

Local model:

- Target local model is Cohere Transcribe.
- Treat local mode as a spike until there is a proven macOS app runtime.
- Requirements before calling it supported:
  - pinned model version
  - checksum verification
  - license review
  - disk/RAM estimate
  - one-command download
  - golden audio test
  - no Python/dev-environment dependency for normal users

## Product Inspiration

Handy:

- GitHub: `https://github.com/cjpais/Handy`
- Useful as inspiration for a small, polished, focused macOS menu-bar utility.
- Do not copy feature scope blindly.

OpenOats:

- Useful as a technical reference.
- Not the product model for this app.

## GStack Review Inputs

The planning discussion used these GStack perspectives:

- `office-hours`
- `plan-ceo-review`
- `plan-eng-review`
- `plan-design-review`
- `cso`
- `plan-devex-review`

Their synthesized recommendations are captured in `docs/AGENT_REVIEW_NOTES.md`.

