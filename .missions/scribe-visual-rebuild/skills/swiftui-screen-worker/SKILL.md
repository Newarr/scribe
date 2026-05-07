---
name: swiftui-screen-worker
description: Builds individual SwiftUI screens / panes inside the popover (Idle, Recording, Transcript) per the design system reference. Receives the specific screen target via the feature description.
---

# Worker procedure: swiftui-screen-worker

You build one popover pane per feature assignment (Idle, Recording, or Transcript — read your feature's `id` and `description`).

## Read first

1. `.missions/scribe-visual-rebuild/AGENTS.md` — copy strings, voice, and behavior locks (Pause = Stop in v1).
2. `.missions/scribe-visual-rebuild/library/architecture.md`
3. `.missions/scribe-visual-rebuild/library/design-tokens.md`
4. The relevant JSX reference for your pane:
   - Idle: `design-reference/IdleScreen.jsx`
   - Recording: `design-reference/RecordingScreen.jsx`
   - Transcript: `design-reference/TranscriptScreen.jsx`
   - Cross-flows: `design-reference/Popovers.jsx` (large file with all state variants — search by section for your pane)
5. `design-reference/states.css` for the exact CSS-equivalent specs (search for the relevant class names: `.empty`, `.up-next`, `.row`, `.rec-screen`, `.cap`, `.wf`, `.outcome`, `.tx-head`, `.tx-body`, `.tx-foot`).
6. The placeholder pane file the popover-shell worker created (e.g., `TranscriberApp/Scribe/PopoverPanes/RecordingPane.swift`).

## Procedure (general)

### Step 1: Locate data sources

For Idle:
- Recents source — grep AppDelegate / TranscriberCore for `recents` / `RecentSession` / similar. Reuse it.
- Calendar event upcoming — `CalendarLookup` exposes the next upcoming event. AppDelegate likely has an observable or callback for this.

For Recording:
- Active session metadata — AppDelegate exposes `recordingSourceLabel`, `outcomeFolderName`, `currentSessionDirectory`, and elapsed timer (added in prior polish). Verify and reuse.
- Audio level (optional) — for the waveform's height modulation; if not exposed yet, drive bars purely from animation envelope without level data.

For Transcript:
- Saved sessions — same recents source as Idle.
- Transcript content — read `<sessionDir>/transcript.md` directly. Use `TranscriptStatusReader` and `TranscriptFrontmatterReader` for metadata.
- Active-session view — bind to AppDelegate's currentSession.

### Step 2: Implement the pane

Use `DS.*` tokens for every color, font, spacing, radius, shadow. Do NOT hardcode values.

For the Recording pane specifically:
- The 56-bar waveform: precompute the heights array with the same envelope formula as `RecordingScreen.jsx`:
  ```swift
  let heights: [CGFloat] = (0..<56).map { i in
      let env = sin(Double(i) / 56.0 * .pi)
      let grain = abs(sin(Double(i) * 0.9) + cos(Double(i) * 1.7) * 0.7)
      return CGFloat(0.18 + env * 0.55 + grain * 0.28)
  }
  ```
- Animate each bar with a 900ms ease-in-out keyframe and per-bar phase delay `(i * 60) % 1800 - 900` ms.
- Use `TimelineView(.animation)` or `withAnimation(.easeInOut(duration: 0.9).repeatForever())` per bar.
- Reduce Motion: when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is true, render bars at a static envelope (no animation).

For Transcript:
- Render markdown with `Text(AttributedString(markdown:))` for simple speaker-prefixed lines, or use a small custom parser if speaker labels need accent coloring.
- The `Reveal` action: `NSWorkspace.shared.activateFileViewerSelecting([transcriptURL])`.
- The `Export` action: `NSSavePanel` with `.allowedContentTypes = [.plainText]` and `.nameFieldStringValue = "<title>.md"`.

### Step 3: Voice & copy strings

NEVER paraphrase locked copy. Verbatim from `AGENTS.md`:

- `Listening.`
- `Auto-records Zoom, Meet, Teams, FaceTime.`
- `Up next`
- `Recent`
- `Recording locally · saved when you stop` (note the U+00B7 mid-dot, NOT a regular period)
- `Pause`
- `Stop`
- `Copy`
- `Export`
- `Reveal`
- `Saved.`
- `No transcripts yet.`
- `Transcribing after stop.`

### Step 4: Behavior locks

- Pause maps to Stop in v1. Add `// TODO: real pause (post-v1)` at the action handler. Update `docs/spec/SPEC.md` to add `OQ-PAUSE-V2` under `## Open Questions` (only if your feature is `recording-pane`).
- Settings tab is owned by popover-shell — don't touch its routing.

### Step 5: Verify

```
swift test --package-path /Users/szymonsypniewicz/Documents/code/scribe
xcodebuild -project ... build
```

Manual visual QA against your JSX reference.

### Step 6: Commit

## Handoff requirements

Return:
- `successState`, `featureId`, `commitId`, `repoPath`
- `summary`
- `dataBindings`: which existing types/properties you bound to (recents source, active session, etc.)
- `paneFile`: path to the pane file you built
- `discoveredIssues`, `whatWasLeftUndone`
