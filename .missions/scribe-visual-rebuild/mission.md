# Mission: scribe-visual-rebuild

Port the official Scribe Design System (delivered as `Scribe Design System.zip`, extracted at `.missions/scribe-visual-rebuild/design-reference/`) into the macOS app surfaces so the product looks "incredibly polished" and matches the design intent 1:1.

## Plan Overview

The previous polish pass added small touches (timer tick, hover sheen, fade-in) but did not restructure the popover or restyle the settings window. The popover still uses an empty-state-driven layout with a single primary button and lacks the four-tab structure the design system specifies. The settings window is the existing utilitarian layout. The menu-bar icon, end-countdown HUD, and saved-notification toast are not visually aligned with the design system.

This mission rebuilds:

1. The popover (chrome + four-tab shell + Idle / Recording / Transcript panes)
2. The full settings window (sidebar layout per `.settings-win`)
3. The end-countdown HUD and saved-notification toast
4. The menu-bar icon (template SVG + recording variant + pulse)

While auditing and gap-filling design tokens, ensuring 1:1 fidelity with `design-reference/colors_and_type.css`.

## Expected Functionality

### Single milestone: design-system-v1

A vertical slice that leaves every Scribe-rendered surface coherent against the design system. The popover, settings window, HUD, toast, and menu-bar icon all read as one polished product.

## Environment Setup

Repo: `/Users/szymonsypniewicz/Documents/code/scribe`
SwiftPM package + Xcode app project in `TranscriberApp/Scribe.xcodeproj`.
Fonts already bundled: Inter Variable, Inter Variable Italic, Geist Variable, JetBrains Mono Variable (in `TranscriberApp/Scribe/Fonts/`).

## Infrastructure

No services, no external APIs needed for the visual rebuild. The Xcode build + `swift test` harness are the entire toolchain.

**Boundaries:**
- No new Swift packages or third-party dependencies.
- Touch only files under `TranscriberApp/Scribe/`, `Sources/TranscriberCore/Storage/` (read-only for rendering transcripts), and tests under `Tests/`. Do not touch the audio engine, ASR, calendar watcher, or session lifecycle code.
- Do not regress the 253 existing tests.
- Do not violate the spec rules in `docs/spec/SPEC.md` (record-only, no live transcript, no history UI, no LLM features).

## Testing Strategy

- `swift test --package-path /Users/szymonsypniewicz/Documents/code/scribe` for unit tests (token resolution, indicator rendering, etc.).
- `xcodebuild -project /Users/szymonsypniewicz/Documents/code/scribe/TranscriberApp/Scribe.xcodeproj -scheme Scribe -destination 'platform=macOS' build` for app build.
- Manual visual QA against the design references (`design-reference/Popover.jsx`, etc.) — rendered next to the running app.

## User Testing Strategy

The orchestrator (or human user) launches the app, opens the popover from the menu bar, and walks through:
1. Idle pane (with and without an upcoming calendar event, with and without recents).
2. Recording pane during an active capture.
3. Transcript pane with a saved transcript selected.
4. Settings tab opens the (restyled) settings window.
5. End-of-call HUD when the countdown engages.
6. Saved-notification toast after a successful save.
7. Menu-bar icon idle vs recording state.

## Non-Functional Requirements

- Visual fidelity: every measurable distance, color, and animation parameter from `design-reference/states.css` and `colors_and_type.css` is replicated. ΔE<2 on all colors.
- Motion: 120ms hover/press, 180ms state transitions, no bounces in product UI, animation only on the recording-active waveform and live-dot pulse.
- Accessibility: respect `Reduce Motion`. All controls have AppKit-friendly accessibility labels.
- Performance: popover open within 100ms cold; recording-pane waveform animates at 60fps without dropped frames on M-series Macs.
