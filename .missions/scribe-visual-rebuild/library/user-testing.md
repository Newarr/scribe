# User Testing — Scribe Visual Rebuild

## Testing surface

Native macOS app. The validation contract requires manual visual QA — a human (or the orchestrator with screen-capture tools) launches the built app and walks through each pane comparing to `design-reference/`.

## Required tools

- `screencapture` (built into macOS) for screenshot evidence.
- `xcrun simctl` is NOT applicable — this is a Mac app, not iOS.
- Optional: `peek`, `gifox`, or QuickTime screen recording for animation evidence.

## How to launch

```
xcodebuild -project /Users/szymonsypniewicz/Documents/code/scribe/TranscriberApp/Scribe.xcodeproj \
  -scheme Scribe -destination 'platform=macOS' -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Scribe-*/Build/Products/Debug/Scribe.app
```

The status item appears in the macOS menu bar. Click to open the popover.

## Resource cost classification per surface

| Surface | Setup cost | Test cost | Notes |
|---|---|---|---|
| Popover | low | low | Click status item; no permission flows needed |
| Idle pane (empty) | low | low | Fresh user state |
| Idle pane (with recents) | medium | low | Requires at least one prior recording session — can stage by running a 10-sec session manually |
| Idle pane (with up-next) | medium | medium | Requires a calendar event in the next ~10 min — can stage via the Calendar app or set a fixture event for the test |
| Recording pane | medium | medium | Requires actually starting a recording (mic + screen-record permissions granted) |
| Transcript pane | medium | low | Requires a saved session; reuse the staging session |
| Settings window | low | low | Open via popover Settings tab or menu |
| End-countdown HUD | high | medium | Requires triggering silence detection or scheduled-end logic; orchestrator may need a dev hotkey (existing in code) to trigger |
| Saved-notification toast | medium | low | Triggered by stopping a recording |
| Menu bar icon | low | low | Visible in menu bar at all times |

## Calendar fixture

To stage an "Up next" calendar event:
1. Open Calendar.app.
2. Create an event 5 minutes in the future, title `Acme Q3 sync`, with one attendee `someone@example.com`.
3. Open the Scribe popover. The Idle pane should show the `Up next` card.

## Reduced-motion check

System Settings → Accessibility → Display → Reduce motion. Toggle ON, reopen popover during a recording, confirm waveform freezes.

## Confidential UI check

- Open the popover (or settings window).
- In a separate app (e.g., QuickTime → New Screen Recording), start a screen capture covering the popover.
- Stop the capture and review: the popover area should appear blank or excluded.

## Knowledge persistence

Workers and validators may discover environment-specific gotchas during this mission (e.g., specific permission grant order needed, specific menu-bar interaction quirks). Append findings here under a `## Findings` heading so future runs benefit.

## Findings

(populated by validators during the run)
