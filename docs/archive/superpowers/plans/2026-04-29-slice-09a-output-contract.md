# Slice 9a — Output Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans`.

**Goal:** Make the session output match the V1 spec contract (lines 218-227): every successfully transcribed session produces `audio.m4a` (mono mixed playback file) + `metadata.json` (JSON mirror of transcript frontmatter) + `transcript.md`. Codex extensive review flagged this as P1.4. The `mic.m4a` / `system.m4a` raw streams stay on disk (default `keep_raw_streams: true` for now — explicit setting toggle is part of slice 9b polish).

**Why now:** Real spec violation, self-contained, doesn't need spikes or signing certs. Closes the largest remaining gap in the per-session output deliverable.

**Architecture:**
- **`AudioFinalizer`** — new helper. Given `mic.m4a` + `system.m4a`, produces `audio.m4a` (AAC m4a, mono, 48kHz). Reuses the slice 2 `AudioMixer` math but writes m4a instead of WAV.
- **`MetadataJSONWriter`** — JSON mirror of `TranscriptContext` + completion status. Same fields as the YAML frontmatter, machine-readable. No utterance bodies — those stay in `transcript.md`.
- **`TranscriptionWorker`** on success path: produces `audio.m4a`, writes `metadata.json`, writes `transcript.md` with `audio: audio.m4a` (single string, not the slice 2 list). On failure path: unchanged — raw streams stay accessible.
- **`TranscriptContext`** keeps `audioRelativePaths: [String]` for the pending/retrying / failed states (where raw streams are the canonical reference). Worker swaps to `["audio.m4a"]` only when writing the completed transcript.

**Tech stack:** AVFoundation (AAC encoding via AVAssetWriter, same pattern as slice 1's `AudioFileWriter`), Foundation `JSONEncoder`. No new third-party deps.

**Spec sections covered:** Output lines 218-227 (folder structure), 251-255 (`audio: audio.m4a` frontmatter), 285-288 (metadata.json contract).

---

## Tasks

**T1. AudioFinalizer + tests** — `static func finalize(mic: URL, system: URL, output: URL) async throws`. Produces an AAC m4a file at `output`. Mono, 48kHz, equal-gain sum with peak clip (same recipe as slice 2 mixer, target format swapped). 2 tests: silent inputs produce non-empty m4a; round-trip via AVAudioFile gets the right format/duration.

**T2. MetadataJSONWriter + tests** — writes `metadata.json` with the same fields as the YAML frontmatter (schema, status, title, date, engine, language, audio, started_at, ended_at, attendees) using `JSONEncoder` with sorted keys + pretty-printed. 2 tests: round-trip via JSONDecoder, includes language only when set.

**T3. TranscriptionWorker integration** — on success (after writeComplete), call `AudioFinalizer.finalize` to produce `audio.m4a`, then `MetadataJSONWriter.write` to write `metadata.json`. Re-write transcript with `audioRelativePaths: ["audio.m4a"]` for the completed body. New worker-level test asserts that a successful run produces all three files with correct content.

**T4. AppDelegate** — no change required. Worker handles the new files internally.

**T5. Acceptance + codex + merge + tag**.

---

## Definition of done

- [ ] Successful session produces `audio.m4a` + `metadata.json` + `transcript.md` in the session folder
- [ ] `transcript.md` frontmatter `audio: "audio.m4a"` (single value) post-completion
- [ ] `metadata.json` parses with same fields as transcript frontmatter
- [ ] `mic.m4a` / `system.m4a` still on disk (default `keep_raw_streams: true`; toggle is slice 9b)
- [ ] Failure path unchanged — raw streams + transcript with status: failed
- [ ] All XCTest tests pass; CI green; codex review clean
