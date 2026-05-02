# Style guide — voice + microcopy

This is the reference for any user-facing string in Scribe. If you're touching a button label, a menu item, an alert, a transcript header, or any doc the user reads, this file is the contract.

The guide is opinionated. Disagreement should produce edits to the guide, not exceptions to it.

## Voice

Scribe is a tool, not a personality. It speaks like a calm coworker who's been doing this job for years:

- **Direct.** Say what happened, whether the recording is safe, what to do next.
- **Sentence case.** "Record now", not "Record Now". Buttons, menu items, alert titles.
- **No jargon.** The user records meetings; they don't manage capture sessions or finalize multichannel uploads.
- **Plain language about scary things.** Privacy, errors, lost data — no euphemisms, no jargon, no AI-generated paragraphs of warmth. Tell them what's true and what to do.
- **No emoji in chrome.** SF Symbols only.
- **No exclamation marks.** The recording isn't excited.

## Canonical terms

| Concept | Use | Don't use |
|---|---|---|
| The user's primary action | **Record**, **Recording** | Capture, Session, Take |
| The thing the user produces | **Transcript** | Markdown contract, schema, output, document |
| Audio source 1 | **Microphone** | Mic input, mic stream |
| Audio source 2 | **Call audio** | System audio, system stream, output capture |
| Both audio streams together | **Recording** (in user surfaces); "mic + call audio" (when distinguishing) | Multichannel, dual-stream |
| macOS permission for #2 | **Screen & System Audio Recording** (macOS 15+ label) | Screen Recording (older), TCC permission |
| Provider | **ElevenLabs** | Cloud backend, transcription engine, scribe-v2 |
| Per-session folder | **Recording folder** (in UI); session directory (in code) | Slot, capture dir |
| Local-on-device transcription | **Local transcription** | Cohere, on-device engine, offline mode |
| Source-separated audio files | **Separate mic and call audio files** | Raw streams, raw m4a, per-channel files |
| User recovery action | **Retry** | Re-run, resume, requeue |
| Canonical state names | **Saved**, **Recording**, **Transcribing**, **Failed**, **Setup required** | Finalized, retrying, orphaned, completed |

## Copy rules

1. **Never cite spec lines or commit IDs in UI.** "Spec line 102" means nothing to a user. Strip on-import.
2. **Never show Swift errors in user-facing text.** "Error: httpError(500)" is a debugging artifact. The transcript body should say what the user can do; the raw error goes in a backtick block at the end for support copy.
3. **Say what happened, whether their work is safe, the next action.** In that order. "Recording stopped. Audio saved as audio.m4a. Transcribing now."
4. **Disabled is better than selectable-and-failing.** If a feature can't work, hide it or render it disabled with a "coming later" label. Don't let the user pick a dead-end and discover it on Save.
5. **One primary action per surface.** The default button is the one we expect 90% of users to click. Other choices are secondary.
6. **Confirm before destructive actions.** Cmd-Q during recording, deleting a session, switching engines mid-recording — confirmation, default button is the safe choice.
7. **Prefer "your" over "the".** "Your Scribe folder" not "the output directory."
8. **Write button text the user could click without context.** Not "Continue" — "Start recording", "Open folder", "Choose key file".
9. **Privacy claims are tested invariants, not marketing.** If the modal says "audio is deleted from ElevenLabs after processing", that has to be true and traceable.

## Status states

The menu bar item is the trust surface. Pick exactly one of these states at any moment:

| State | Trigger | Menu shows | Icon |
|---|---|---|---|
| **Idle** | App ready, no recording | "Record now" | `T` neutral |
| **Setup required** | Preflight failed | "Setup Required…" + reason | `T` warning |
| **Meeting detected** | Detection layer wants to prompt | n/a (alert active) | `T` amber dot |
| **Recording** | Capture active | "Stop and save" + elapsed time | `T` red dot |
| **Stopping** | Stop requested, finalizing | "Saving recording…" | `T` spinner |
| **Transcribing** | Worker running | n/a (background) | `T` spinner |
| **Saved** | Just finished | "Open folder" + recents | `T` brief check |
| **Failed** | Terminal failure | "Retry…" + reason | `T` warning |

(Today's rc4 implements a subset; the full trust surface is a v1.1 deliverable.)

## When in doubt

- Read the modal aloud. If you wouldn't say it to a coworker, rewrite it.
- The user did not read the spec. They've never heard the word "supervisor" or "claim file."
- A label that's wrong is worse than a label that's missing.
