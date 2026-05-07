# AGENTS.md — scribe-visual-rebuild

Operational guidance for workers on this mission.

## Mission Boundaries (NEVER VIOLATE)

**Scope:**
- Touch only `TranscriberApp/Scribe/**/*.swift`, app `Assets.xcassets`, and `Tests/**`. Read-only access to `Sources/TranscriberCore/**` for rendering data only.
- Do NOT modify the audio engine, ASR pipeline, calendar watcher, session lifecycle, recovery system, or `transcript.md` writer.
- Do NOT add new Swift packages or third-party dependencies. Use AppKit + SwiftUI only.
- Do NOT introduce mocked data paths into production code; bind real `SettingsStore`, real `TranscriptStatusReader`, real `CalendarLookup`.

**Off-limits:**
- `Sources/TranscriberCore/Engines/` and any audio capture code.
- `Sources/TranscriberCore/Recovery/` (preserve as-is).
- `docs/spec/SPEC.md` — read-only context unless the orchestrator explicitly schedules a SPEC update.

## Coding Conventions (per existing repo)

- Swift 6, macOS 15+ deployment target.
- SwiftUI for screen-level views; AppKit for window chrome / `NSPopover` / `NSStatusItem` work.
- All token references go through `DS.*` namespace (in `TranscriberApp/Scribe/DesignSystem.swift`). Do NOT hardcode hex colors, font sizes, or spacing values in screen views.
- File top-level `// swiftlint:disable` directives are off-limits unless the existing file already has one.
- Defaults: do not write multi-line comments; do not narrate code; rely on identifier names. Inline TODOs only when there is a documented deferred-work item that the orchestrator has acknowledged.

## Voice & Microcopy (locked from design system)

- Lowercase brand `scribe` in body copy.
- Sentence case for all labels and buttons. No Title Case. No ALL CAPS except in mono indicators (`LIVE`, `READY`, `SENT`).
- No emoji anywhere in UI. Use `Indicator` (dot + caps text).
- Approved copy strings (verbatim — do not paraphrase):
  - Idle empty: `Listening.` / `Auto-records Zoom, Meet, Teams, FaceTime.`
  - Up-next eyebrow: `Up next`
  - Recents section eyebrow: `Recent`
  - Recording outcome strip: `Recording locally · saved when you stop`
  - Recording actions: `Pause` / `Stop`
  - Transcript actions: `Copy` / `Export` / `Reveal`
  - Saved toast title: `Saved.` (sentence case + period)
  - Settings link: `Open full settings…`

## Design Token Discipline

- Every color, font size, spacing, radius, and shadow value MUST be referenced through `DS.*` (extending `DesignSystem.swift` if needed).
- `DesignSystem.swift` is the OKLCH→sRGB translation layer. If a token is missing, ADD it to `DS` rather than inlining the value.
- Live-recording color is the rust token `oklch(0.55 0.14 35)`. Never `Color.red`. Never `#ff0000`.
- Accent is the slate-ink blue `oklch(0.50 0.09 255)`. Reserved for primary CTAs and focus rings.

## Testing & Validation Guidance

- Workers must run `swift test --package-path /Users/szymonsypniewicz/Documents/code/scribe` before declaring a feature complete. Baseline: 253 tests passing.
- Workers must run `xcodebuild build` before declaring a feature complete. Baseline: clean build (the `nonisolated(unsafe)` warnings are pre-existing and not blocking).
- Visual QA: open the running app and compare side-by-side with the design reference HTML/JSX in `design-reference/`. Capture screenshots for the validator.
- Validators treat the JSX/CSS files in `design-reference/` as authoritative ground truth.

## Pre-existing State (informational)

- `DesignSystem.swift` already has 1012 lines of token + typography + indicator + button + window-chrome scaffolding. Audit and gap-fill rather than rebuild from scratch.
- Inter / Geist / JetBrains Mono fonts already bundled at `TranscriberApp/Scribe/Fonts/`.
- 253 unit tests currently pass (after prior P1/P2 fixes).
- `docs/spec/SPEC.md` has a comprehensive Visual Language section that is consistent with the design system; do not duplicate.

## Pause Action (locked)

For v1, `Pause` is a UI affordance only. Wire it to the same handler as `Stop`. Add `// TODO: real pause (post-v1)` comment in the action handler. Add a single bullet under `## Open Questions` in `docs/spec/SPEC.md` with stable ID `OQ-PAUSE-V2`.

## Settings Tab Behavior (locked)

In the popover, the Settings tab is an action, not a pane. Tapping it opens the (restyled) settings window via `SettingsWindow.show()` and keeps the popover open. The 4-tab segmented control still shows `Settings` as the fourth tab visually, but the underlying selection model treats it as a button-tab that does not change the popover body content.
