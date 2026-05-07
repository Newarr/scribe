---
name: swiftui-overlay-worker
description: Restyles the floating end-countdown HUD and the saved-notification toast. Both are NSWindow-backed overlays that present briefly during the recording lifecycle.
---

# Worker procedure: swiftui-overlay-worker

You restyle two existing windows: `EndCountdownWindow.swift` and `SavedNotificationWindow.swift`.

## Read first

1. `.missions/scribe-visual-rebuild/AGENTS.md`
2. `.missions/scribe-visual-rebuild/library/architecture.md`
3. `.missions/scribe-visual-rebuild/library/design-tokens.md`
4. `design-reference/states.css` — search for `.hud` (end-countdown) and `.toast` (saved notification).
5. `design-reference/Popovers.jsx` — search for the HUD and toast component sections (large file, large variety of states).
6. `TranscriberApp/Scribe/EndCountdownWindow.swift` (148 lines, current implementation).
7. `TranscriberApp/Scribe/SavedNotificationWindow.swift` (191 lines, current implementation).

## Procedure

### End-countdown HUD

Target spec (from `.hud` in states.css):
- Width 320pt, corner radius 14pt.
- Chrome: dark vibrancy (NSVisualEffectView `.hudWindow` material + ~85% alpha).
- Border: 1px `rgba(255,255,255,0.10)`.
- Shadow: `0 24px 60px rgba(0,0,0,0.55), 0 0 0 0.5px rgba(0,0,0,0.4)`.
- Padding: 16pt 16pt 14pt.
- Vertical stack with 12pt gap.

Content:
- Eyebrow: 10pt uppercase mono caps, color `rgba(255,255,255,0.55)`, tracking 0.12em. Copy: per existing SPEC. If unset, use `Stopping in`.
- Count: 56pt tabular numerals, weight 300, color `#fff`, tracking -0.02em, leading 1.0. Followed by an 18pt `s` unit suffix at `rgba(255,255,255,0.55)`.
- Description text: 13pt body color `rgba(255,255,255,0.78)`, leading 1.45. Copy: per existing SPEC.
- Progress bar: 3pt tall, `rgba(255,255,255,0.10)` track, `rgba(255,255,255,0.55)` fill, 2pt corner radius. Fill width contracts toward 0 over the countdown duration.
- Actions: two buttons (primary + secondary), each `flex: 1` (equal width). Primary: `Stop now` (or current SPEC copy). Secondary: `Keep recording` (or current SPEC copy).

Position: top-center of the active screen, ~40pt from top.

`NSWindow.sharingType = .none`. Use the existing `WindowChrome` helper if available.

Reduce Motion: opacity-only entrance (no slide), no progress-bar transition (jump per-second).

### Saved-notification toast

Target spec (from `.toast` in states.css):
- Width 340pt, corner radius 12pt.
- Chrome: dark vibrancy (`.hudWindow` material + ~90% alpha).
- Border: 1px `rgba(255,255,255,0.10)`.
- Shadow: `0 12px 40px rgba(0,0,0,0.45)`.
- Padding: 12pt 14pt.
- Grid: 30pt-icon-tile + flexible-content + when-column.

Content:
- Icon tile: 30×30pt, 7pt corner radius, `rgba(255,255,255,0.06)` bg, 1px `rgba(255,255,255,0.08)` border, with a 14pt icon (success check or save glyph).
- Title (`tt`): `Saved.` 13pt semibold, tracking -0.01em.
- Sub (`ts`): session title (or generic `Recording saved`), 11.5pt color `rgba(255,255,255,0.65)`, leading 1.45.
- Path eyebrow (`tx`): mono caption 10pt color `rgba(255,255,255,0.45)`, tracking 0.06em — relative session folder path (e.g., `~/Scribe/2026-05-07-acme-q3-sync`).
- When (`when`): mono 10pt color `rgba(255,255,255,0.5)`, tracking 0.04em — relative timestamp (e.g., `just now`, `1 min ago`).

Position: top-right of active screen, ~16pt from top, ~16pt from right edge.
Slide-in: 220ms ease-out, 12pt translate-x from right.
Auto-dismiss: 5s after presentation, fade-out 220ms.
Click action: `NSWorkspace.shared.activateFileViewerSelecting([sessionURL])` (open Finder selecting the session dir).

`NSWindow.sharingType = .none`.

Reduce Motion: opacity-only entrance.

## Verify

```
swift test --package-path /Users/szymonsypniewicz/Documents/code/scribe
xcodebuild -project ... build
```

Manual:
1. Trigger countdown (existing dev hotkey or silence simulation in tests).
2. Complete a recording → toast appears with correct layout.
3. Click toast → Finder opens.
4. Wait 5s → toast auto-dismisses.
5. Enable Reduce Motion → re-trigger both → opacity-only entrance.

## Commit and handoff

Return:
- `successState`, `featureId: hud-toast-restyle`, `commitId`, `repoPath`
- `summary`
- `discoveredIssues`, `whatWasLeftUndone`
