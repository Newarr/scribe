# Mission: post-local-transcription-quality

Launch this mission **after the local transcription model is integrated and can produce a transcript from Scribe's canonical `audio.m4a` path**.

## User outcome

Make Scribe produce transcripts that users trust without replaying the audio:

1. **Correct words** — fewer missed, duplicated, or garbled phrases.
2. **Correct attribution** — clearly distinguish what `Me` said vs what `Them` said.
3. **Privacy/control** — local transcription remains a first-class path.
4. **Reliability** — never weaken Scribe's durable record: audio is saved, `transcript.md` always exists, failures are explicit.
5. **Recovery/improvement** — saved audio can be re-transcribed with a different model/strategy later.

## Context from research

Granola Desktop validates a pragmatic source-attribution approach: `Me` corresponds to microphone input and `Them` corresponds to system audio. That is enough for Scribe's desktop workflow because Scribe does not show a live transcript and users primarily need a trustworthy final `transcript.md` after recording stops.

Most OSS transcription stacks downmix to mono and then try to infer speakers afterward. The better meeting-specific pattern is to preserve mic/system separation and either label by source or transcribe separate tracks and merge timelines. True AEC + multichannel is rare and risky; it should be treated as a later optimization, not the first quality step.

Cohere context: the local-model mission should land first as a focused `audio.m4a -> CohereMLXBackend -> EngineResponse -> transcript.md` path using `MLXAudioSTT.CohereTranscribeModel` and `beshkenadze/cohere-transcribe-03-2026-mlx-fp16`. This mission should build on that engine/model seam afterward; do not fold `Me`/`Them` separate-track merging into the initial Cohere integration.

## Product strategy

Do **not** start with full AEC. First build a model-agnostic transcription quality layer that preserves Scribe's reliability contract.

Recommended path:

```text
1. Current fallback: audio.m4a -> selected engine -> transcript.md
2. Add provenance + strategy metadata
3. Add local/cloud engine abstraction over the same canonical path
4. Add guarded separate-track transcription: mic.m4a -> Me, system.m4a -> Them, merge timelines
5. Keep mixed-mono transcription as fallback
6. Revisit AEC + multichannel only after measuring quality wins
```

## Non-goals

- No notes editing.
- No LLM summaries, polishing, vector DB, or chat.
- No transcript history UI.
- No import flow.
- No live transcript UI.
- No live speaker attribution or live speaker-state tracking.
- No silent fallback from local to cloud or cloud to local.
- No claims that `Them` identifies individual remote participants.

## Architecture principles

### Separate source attribution from human identity

Do not conflate audio source with a specific human identity.

```text
source: microphone | system | mixed
role: me | them | unknown
identity: unknown | me | remote_participants
```

For the first implementation, Scribe can confidently label:

- microphone-derived text as `Me`
- system-derived text as `Them`

But `Them` may contain multiple remote participants and should not be presented as one named person.

#### Edge case: shared microphone

`Me = microphone` assumes one user per mic. When multiple people share a laptop, the mic side is `shared`, not `me`. The renderer must support a per-session mode:

- solo (default): mic -> `Me`, system -> `Them`
- shared mic: mic -> `Mic` (or named), system -> `Them`

This is a renderer/metadata concern, not an engine concern. No live detection required for V1; the user picks the mode per session or in settings.

#### Optional follow-up: mic-side diarization

After the local Cohere engine is integrated and stable, consider running lightweight diarization on `mic.m4a` only (not the whole mixed stream). This is cheaper than full multi-speaker diarization because it just needs a count of distinct speakers on the mic channel. When the count is >1, render as `Mic A` / `Mic B` and let the user rename post-hoc. Treat this as a Milestone 3.5 enhancement layered on top of separate-track transcription, not a V1 requirement.

### Persist strategy and provenance

Every transcript should record:

- engine id
- model id
- transcription strategy
- input asset(s)
- whether output came from mixed audio or separate tracks
- language hint/detected language where available
- fallback reason if a higher-quality path was skipped

Avoid silent downgrades. If Scribe falls back, make it explicit in metadata and/or transcript frontmatter.

### Validate before planning

Before running any non-trivial plan, validate:

- file exists
- file is readable
- duration is non-zero
- channel count/sample rate known where possible
- mic/system durations are close enough for timeline merge
- PTS/alignment metadata is available or drift is below threshold

If validation fails, use mixed-mono fallback and record the reason.

## Proposed milestones

### Milestone 1: Engine abstraction over existing mixed path

Goal: make ElevenLabs and the new local model interchangeable for `audio.m4a` without changing user-visible behavior.

Deliverables:

- `TranscriptionEngine` protocol with stable engine/model ids.
- Normalized transcript result shape.
- Existing ElevenLabs adapter returns normalized result.
- Local model adapter returns normalized result.
- `transcript.md` output remains deterministic.
- Existing retry/recovery behavior preserved.

Acceptance:

- Cloud path still works.
- Local path works for `audio.m4a`.
- Failed local/cloud transcription still produces a failed `transcript.md` pointing to saved audio.
- No silent cloud fallback from local mode.

### Milestone 2: Strategy metadata and provenance

Goal: make transcript quality/debuggability observable.

Deliverables:

- Persist selected strategy: `mixed_mono`, `separate_tracks_merge`, or future `multichannel`.
- Persist engine/model.
- Persist input asset list.
- Persist fallback reason when applicable.
- Add utterance-level provenance internally where practical: source asset, source role, confidence if available.

Acceptance:

- A recovered transcription resumes the same selected strategy.
- Diagnostics can explain which model/strategy produced a transcript.
- Hints unsupported by an engine are recorded as ignored, not silently lost.

### Milestone 3: Guarded separate-track transcription

Goal: improve final transcript attribution from inferred speaker labels to reliable `Me` / `Them` source labels.

Pipeline:

```text
mic.m4a    -> selected engine -> source role: Me
system.m4a -> selected engine -> source role: Them
merge utterances by timeline
render transcript.md
```

Guardrails:

- Only run after recording stops.
- Only run when both tracks pass validation.
- Merge only when durations/alignment are within safe thresholds.
- Preserve overlapping speech instead of forcing one exclusive source.
- If merge confidence is low, fall back to `audio.m4a` mixed-mono transcription.
- Record fallback reason.

Acceptance:

- 1:1 and group calls produce clearer `Me` / `Them` attribution than mixed mono.
- Remote leakage into mic does not create obvious duplicate transcript blocks in common cases.
- Bad alignment fails safe to mixed mono.
- Existing durable session contract remains intact.

### Milestone 4: Re-transcribe saved audio

Goal: let users improve bad transcripts after the fact using saved audio.

Deliverables:

- Retry failed transcript with same engine/model.
- Re-run transcript with local vs cloud engine, explicitly chosen.
- Re-run with mixed-mono vs separate-track strategy where supported.

Acceptance:

- Existing audio assets are never overwritten or deleted by re-transcription.
- Old transcript is either backed up or replaced atomically.
- The final `transcript.md` records which strategy/model produced it.

### Milestone 5: Evaluate AEC + multichannel later

Goal: decide with evidence whether true AEC/multichannel is worth the complexity.

Only pursue if separate-track transcription still has unacceptable duplication/attribution issues.

Evaluation criteria:

- measurable reduction in duplicate remote speech
- improved `Me`/`Them` attribution
- no speech destruction from bad echo cancellation
- no new recovery ambiguity
- provider/local model actually benefits from multichannel input

## Suggested implementation shape

```swift
enum AudioSourceRole {
    case microphone
    case system
}

enum AssetKind {
    case captured
    case derivedMixed
    case converted
    case cleaned
}

struct TranscriptionAsset {
    let id: String
    let role: AudioSourceRole?
    let kind: AssetKind
    let url: URL
    let duration: TimeInterval?
    let sampleRate: Int?
    let channels: Int?
    let checksum: String?
}

enum TranscriptionPlanKind {
    case singleMixedAsset
    case separateAssetsMerge
}

struct TranscriptionPlan {
    let version: Int
    let kind: TranscriptionPlanKind
    let engineID: String
    let modelID: String
    let inputAssetIDs: [String]
}
```

Keep the first implementation small: `singleMixedAsset` for ElevenLabs/local parity, then add `separateAssetsMerge` behind validation.

## Validation requirements

Before declaring the mission complete:

- Run the Swift package test suite.
- Build the macOS app target.
- Test cloud mixed-mono transcription.
- Test local mixed-mono transcription.
- Test transcription failure writes a durable failed transcript.
- Test recovery resumes the same selected strategy.
- Test separate-track path with a short known recording.
- Test fallback when one track is missing/corrupt/misaligned.

## Key reminders

- Scribe's core promise is **never lose the record of an important meeting**.
- Quality improvements must fail safe.
- Source attribution is the desktop story: `Me` / `Them` is useful without identifying every remote participant.
- All attribution work happens after recording stops; do not add live transcript or live speaker-state machinery.
- AEC/multichannel should be an optimization after measurement, not a prerequisite.
