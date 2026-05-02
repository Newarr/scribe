# Agent Context

Use this directory as the source of truth for the Scribe product spec.

## GStack

Future agents should use GStack workflows for this project when the task matches them:

- Use `plan-ceo-review` for product scope, defaults, reminders, and v1/v2 tradeoffs.
- Use `plan-eng-review` for architecture, state machine, EventKit, ScreenCaptureKit, output durability, and failure modes.
- Use `plan-design-review` for menu bar UX, prompts, settings, permission recovery, and stop countdown flows.
- Use `cso` for audio/privacy/security review, Keychain handling, calendar metadata, ElevenLabs context, retention, and diagnostics redaction.
- Use `qa` for browser/app QA once there is a runnable UI to test and fix.
- Use `qa-only` for report-only QA when fixes are not requested.
- Use `review` before landing meaningful implementation changes.
- Use `document-release` after product or architecture changes so docs stay aligned.
- Use `ship` only when the user asks to commit/push/create a PR.

If the user asks for broad planning, run the relevant GStack plan reviews before editing implementation. If the user asks for implementation, read the docs below first and then use GStack review/QA as verification where appropriate.

Before implementing, read `docs/spec/SPEC.md` — the consolidated single source of truth (product spec, design decisions, open questions, acceptance criteria, references).

Important constraints:

- Every session ends with `transcript.md`.
- Product is record-only. Do not add import.
- Default behavior is transcribe and save audio.
- Missing system audio permission blocks recording.
- No mic-only fallback.
- No live transcript UI.
- No transcript history UI.
- No LLM notes, summaries, polishing, vector DB, or chat.
- Calendar context sent to ElevenLabs is keyterms-only by default.
- ElevenLabs key belongs only in Keychain.
- Audio is the durable asset; transcription failure must not lose it.

When adding open questions, use stable unique IDs in the `## Open Questions` section of `docs/spec/SPEC.md`.
