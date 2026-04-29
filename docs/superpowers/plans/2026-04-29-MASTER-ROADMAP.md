# Transcriber V1 — Master Implementation Roadmap

> **For agentic workers:** This is a roadmap, not an executable plan. Each slice listed here gets its own plan file in `docs/superpowers/plans/` before implementation. Use `superpowers:subagent-driven-development` to execute each slice's plan task-by-task.

**Source spec:** `docs/SPEC.md` (last updated 2026-04-29).

**Goal:** Ship Transcriber V1 — a menu-bar macOS app that captures meeting audio, AEC-cleans the mic, transcribes via ElevenLabs Scribe v2 multichannel mode, and writes a durable `transcript.md`.

**Slicing principle:** Each slice produces **working, shippable software end-to-end**. No horizontal slices ("write all the protocols, then write all the implementations"). Every slice ends with a runnable app that does something the previous slice couldn't.

---

## Slice list

| # | Slice | Output | Est. days | Dependencies |
|---|---|---|---|---|
| 0 | Project scaffolding | App builds, tests run, CI green | 1 | none |
| 1 | Manual record (no transcription) | Click record, get `mic.m4a` + `system.m4a` + PTS metadata on disk | 2-3 | 0 |
| 2 | Single-channel cloud transcription | Manual record → mixed mono upload to ElevenLabs → `transcript.md` with diarization | 2 | 1 |
| 3 | Multichannel cloud transcription | Manual record → 2-channel upload, channel-keyed speaker IDs, calendar attendee mapping | 2 | 2 + EventKit basics |
| 4 | AEC pre-pass | WebRTC AEC3 Rust subprocess cleans mic, multichannel upload uses cleaned mic | 3-4 | 3, AEC3 quality spike |
| 5 | Detection layer | Allowlisted process + bidirectional audio detection, start prompt, `Skip` semantics | 3-4 | 1 |
| 6 | Calendar enrichment full | EventKit watcher with rolling cache, attendee-derived keyterms, title precedence | 2 | 5 |
| 7 | Recovery + retry | Filesystem-as-queue, supervisor on launch, retry policy, pending badge | 2 | 2 |
| 8 | Local engine (Cohere) | Whisper-tiny lang ID + Cohere via Rust subprocess + per-channel VAD segmentation | 4-5 | 4, Polish-quality spike |
| 9 | Polish & ship | Diagnostics panel, settings UI, permissions UX, signing, notarization, Homebrew cask | 4-5 | all |

**Total estimate:** ~26-32 working days. Solo, full-time. Realistic calendar time: 6-10 weeks given other commitments.

---

## Slice ordering rationale

**Why Slice 0 (scaffolding) first:** Tests-first development needs a working test runner. CI catches regressions cheaply. Without this, every later slice is slower.

**Why Slice 1 (manual record) before Slice 5 (detection):** Capture is the hardest technical risk. ScreenCaptureKit permission flow, two-stream audio writing, atomic file handling, PTS metadata propagation — all of these can and will surface bugs that have nothing to do with detection. Validating capture against a manual `Record Now` button first means Slice 5's detection logic can be tested against a working capture pipeline.

**Why Slice 2 (single-channel) before Slice 3 (multichannel):** Single-channel cloud transcription validates the entire engine layer (Keychain key storage, HTTP client, multipart upload, response parsing, frontmatter serialization, status lifecycle) on the simplest possible upload. Slice 3 then changes only the WAV builder and the call params — bugs in Slice 3 are isolated to multichannel-specific code.

**Why Slice 4 (AEC) before Slice 5 (detection):** AEC validates the PTS metadata pipeline end-to-end. If PTS doesn't propagate cleanly, AEC won't converge — and we want to find that out before adding detection complexity on top.

**Why Slice 7 (recovery) before Slice 8 (local engine):** Recovery is needed for cloud retries. Local engine doesn't need retries (failures are bugs, not transient). Doing recovery first means Slice 8 inherits a working filesystem-queue model and just plugs in a different engine.

**Why Slice 9 (polish) last:** Until the audio path works end-to-end, polish is decoration. Don't paint a building that doesn't have walls.

---

## Pre-V1 spikes (blocking)

Three spikes from the spec must complete before their dependent slices ship:

### Spike A: Polish quality (`spike_polish_quality`)

Sample 5-10 minutes of real Polish meeting audio. Run through:
1. Cohere Transcribe 03-2026 (via `mlx-audio` Python or `second-state/cohere_transcribe_rs`)
2. WhisperKit + whisper-large-v3
3. ElevenLabs Scribe v2 multichannel

Read all three transcripts side-by-side. Pick the V1 local engine. **Blocks Slice 8.**

### Spike B: AEC3 quality (`q_aec3_quality_validation`)

Capture a real call from a MacBook with internal speakers (no headphones, deliberately worst case). Mic + system as separate `.m4a` files. Run through `webrtc-audio-processing ~2.0` AEC3 with system as render. Listen to `mic.cleaned.wav`.

Pass criteria: remote speaker bleed reduced enough that an ElevenLabs single-channel transcription of `mic.cleaned.wav` no longer contains remote utterances as "Szymon" lines. **Blocks Slice 4.**

### Spike C: Multichannel billing (`q_multichannel_billing_model`)

Upload a 60-minute 2-channel WAV with `use_multi_channel=true`. Compare actual ElevenLabs credit deduction vs a single-channel 60-min upload. Document whether multichannel bills as 60 or 120 minutes. **Soft blocker on Slice 3** — we can ship multichannel before this spike completes, but pricing strategy needs the answer before we publicize.

These spikes belong in scratch worktrees, not the main branch. Their output goes into `QUESTIONS.md` as resolved entries with the measured numbers.

---

## Risk register

| Risk | Mitigation | Slice |
|---|---|---|
| ScreenCaptureKit permission flow surprises | Implement manual record first (Slice 1); validate before adding detection | 1 |
| AEC3 doesn't converge on real-world bleed | Pre-V1 spike (B), with fallback path baked into spec | 4 |
| Cohere Polish quality is poor | Pre-V1 spike (A), fallback to WhisperKit | 8 |
| ElevenLabs multichannel billing is 2x | Spike (C), accept as cost of correctness | 3 |
| `CMSampleBuffer.presentationTimeStamp` drift between mic + system streams | Single SCK clock domain mitigates; cross-correlation backup | 1, 4 |
| Codesigning / notarization friction | Set up entitlements early, signed builds in CI from Slice 0 | 0, 9 |
| EventKit returns stale events on wake | Watcher polls every 60s + re-checks on `NSWorkspace.willWakeNotification` | 6 |

---

## Definition of done for V1

A V1 build is shippable when:

- [ ] `Record Now` from menu bar produces a valid `transcript.md` with frontmatter for an English call and a Polish call
- [ ] Detector triggers a start prompt for a real Zoom/Meet call within 30 seconds of bidirectional audio
- [ ] `Skip` correctly suppresses re-prompting
- [ ] Cloud transcription succeeds on a 60-min call within 5 minutes of session end
- [ ] AEC pre-pass produces `mic.cleaned.wav` for at least 95% of test sessions; fallback path produces correct transcripts for the remaining 5%
- [ ] App recovers from a crash mid-transcription (relaunch → pending sessions queued and processed)
- [ ] All 4 required permissions have explicit recovery flows (mic, screen, calendar optional, output folder)
- [ ] Diagnostics export contains zero secrets, zero transcript content, zero calendar text
- [ ] Signed `.app` and notarized `.dmg` artifacts available; install from Homebrew cask works
- [ ] All `q_*_validation` questions in `QUESTIONS.md` have measured answers committed

---

## Slice expansion protocol

When starting a slice:

1. Re-read the spec sections relevant to that slice
2. Re-read the previous slice's plan to recall conventions established
3. Create the plan file at `docs/superpowers/plans/YYYY-MM-DD-slice-NN-<name>.md` using `superpowers:writing-plans` rigor
4. Create a worktree: `git worktree add ../transcriber-slice-NN slice-NN`
5. Execute via `superpowers:subagent-driven-development` — fresh subagent per task, two-stage review
6. On completion, merge worktree, tag a build, demo to yourself

Never start a slice with the previous slice's bugs unfixed. Never start a slice without a written plan. Never bypass the spike for a slice that depends on one.

---

## Status

| Slice | Plan written | Worktree | Status |
|---|---|---|---|
| 0 | ✅ `2026-04-29-slice-00-scaffolding.md` | `transcriber-slice-0` | shipped 2026-04-29 |
| 1 | ✅ `2026-04-29-slice-01-manual-record.md` | `transcriber-slice-1` | shipped 2026-04-29 (TCC grant deferred to user first-launch) |
| 2 | ✅ `2026-04-29-slice-02-single-channel-cloud.md` | `transcriber-slice-2` | shipped 2026-04-29 (TCC grant + ElevenLabs API key deferred to user setup) |
| 3 | ✅ `2026-04-29-slice-03-multichannel-calendar.md` | `transcriber-slice-3` | shipped 2026-04-29 (TCC + calendar permission + headphones for clean multichannel until slice 4 AEC) |
| 4 | ⏳ expand when starting (depends on Spike B) | — | not started |
| 5 | ⏳ expand when starting | — | not started |
| 6 | ⏳ expand when starting | — | not started |
| 7 | ✅ `2026-04-29-slice-07-recovery-retry.md` | `transcriber-slice-7` | shipped 2026-04-29 (jumped slice 4-6 because slice 4 needs Spike B) |
| 8 | ⏳ expand when starting (depends on Spike A) | — | not started |
| 9 | ⏳ expand when starting | — | not started |

Update this table as plans are written and slices ship.
