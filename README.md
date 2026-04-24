# Transcriber

Spec workspace for a menu-bar-first macOS meeting recorder/transcriber.

Core promise:

> Never miss the record of an important meeting.

This is not an AI notes app. It is call-capture insurance: when a calendar meeting starts, the app prompts the user, records microphone plus system audio, saves audio by default, transcribes the call, and writes a durable `transcript.md`.

## Current V1 Contract

- Menu-bar-first macOS app.
- Apple Calendar/EventKit watcher first.
- Prompt at meeting start.
- One-click start.
- Capture microphone and system audio.
- Default mode: transcribe and save audio.
- Default engine: ElevenLabs.
- Record-only product surface. No import flow.
- No live transcript display.
- No transcript history UI.
- Files saved to Finder in one folder per meeting.
- Every session ends with `transcript.md`, even if transcription fails.

## Key Files

- [docs/SPEC.md](docs/SPEC.md) - product and technical spec.
- [docs/DECISIONS.md](docs/DECISIONS.md) - accepted decisions from the planning discussion.
- [docs/QUESTIONS.md](docs/QUESTIONS.md) - uniquely named open questions.
- [docs/AGENT_REVIEW_NOTES.md](docs/AGENT_REVIEW_NOTES.md) - synthesized GStack agent recommendations.
- [docs/QA.md](docs/QA.md) - quality checklist and acceptance criteria.
- [docs/REFERENCES.md](docs/REFERENCES.md) - useful code/API/product references.
