# Architecture — scribe-visual-rebuild

## What lives where

```
TranscriberApp/Scribe/
├── ScribeApp.swift              SwiftUI App entry; minimal — delegates to AppDelegate
├── AppDelegate.swift            (1283 lines) Owns NSStatusItem, NSPopover, recording lifecycle, timers, calendar matching, low-disk guard, and all top-level UI presentation
├── DesignSystem.swift           (1012 lines) DS namespace — tokens, typography, indicator, button styles, brand mark, window chrome, hover sheen, switch toggle, code block / waveform helpers
├── RecordingMenu.swift          (545 lines) The popover content view (currently empty-state-driven; needs the four-tab restructure)
├── SettingsWindow.swift         (593 lines) Existing settings window (utilitarian; needs full restyle to sidebar layout)
├── DiagnosticsView.swift        Diagnostics pane content
├── EndCountdownWindow.swift     Floating HUD shown during the silence-detected countdown
├── SavedNotificationWindow.swift   Top-right toast shown after a successful save
├── PrivacyAcknowledgementSheet.swift   First-run privacy ack
├── PermissionRecoveryView.swift  Surfaced when permissions are revoked mid-session
├── StartPromptCoordinator.swift  Modal start prompt for upcoming/active calls
├── Fonts/                       Inter / Geist / JetBrains Mono variable woff2 + ttf bundled
├── Assets.xcassets/             App icon + image assets
└── Info.plist
```

## Surface inventory (what gets rebuilt)

1. **Popover** — `RecordingMenu.swift` (the SwiftUI body) and `AppDelegate.swift` (the `NSPopover` chrome). Today: empty-state-only with a single primary "Record now" button. Target: header + four-tab segmented + Idle/Recording/Transcript panes (Settings tab is an action that opens the settings window).
2. **Settings window** — `SettingsWindow.swift` and `DiagnosticsView.swift`. Today: utilitarian list of toggles + Storage panel + Diagnostics. Target: 760×700pt with sidebar layout, grouped rows, macOS-style switches, diagnostic 4-cell strip.
3. **End-countdown HUD** — `EndCountdownWindow.swift`. Today: basic countdown view. Target: 320pt-wide chrome, eyebrow, 56pt count, 3pt progress bar, two actions.
4. **Saved-notification toast** — `SavedNotificationWindow.swift`. Today: simple notification. Target: 340pt chrome, 30pt icon tile, title + sub + path eyebrow, top-right slide-in.
5. **Menu bar icon** — managed in `AppDelegate.swift` via `NSStatusItem`. Today: existing template icon. Target: four-bar SVG template + recording variant with rust dot + pulse animation.

## Data sources (read-only for the visual rebuild)

- **Recents:** Workers should locate the existing recents data source in `AppDelegate.swift` / `DesignSystem.swift` or the `TranscriberCore` storage layer. Do NOT add a new persistence layer; reuse what's there.
- **Calendar match:** `Sources/TranscriberCore/Calendar/CalendarLookup.swift`. The `CalendarEvent.title`, `CalendarEvent.attendees`, and the matched event for the current session are exposed via existing AppDelegate plumbing.
- **Active session:** `AppDelegate` already exposes `currentSessionDirectory` / `recordingSourceLabel` / `outcomeFolderName` (added in the prior polish pass).
- **Transcripts:** `TranscriptStatusReader` and `TranscriptFrontmatterReader` in `Sources/TranscriberCore/Storage/`. Render the markdown content of `transcript.md` from the session directory.
- **Settings store:** existing `SettingsStore` (find via grep). Bind the settings-window controls to it.

## Dependencies between features

```
1. tokens-foundation   ──┬──> 2. popover-shell ──┬──> 3. idle-pane
                         │                       ├──> 4. recording-pane
                         │                       └──> 5. transcript-pane
                         ├──> 6. menu-bar-icon
                         ├──> 7. settings-window-restyle
                         └──> 8. hud-toast-restyle
```

Feature 1 (tokens-foundation) gates everything else. Features 2 and downstream (3–5) form the popover slice. Features 6, 7, 8 are independent surfaces and can run in any order after 1.

## Invariants

1. The popover's `NSWindow.sharingType = .none` rule applies to ALL Scribe-rendered windows. New windows must enforce this.
2. The recording lifecycle is owned by `AppDelegate`. Views never call AudioEngine / ASR directly. Views invoke handlers like `appDelegate.startRecording()` / `appDelegate.stopRecording()`.
3. The menu-bar icon state is a function of the recording lifecycle state. Workers must subscribe to a state publisher (existing or added) rather than poll.
4. `transcript.md` is the durable artifact. Views render it; views never mutate it.
5. Reduce Motion (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`) disables continuous animations.

## Known surface mappings (CSS class → Swift target)

- `.pop` → the `NSPopover.contentViewController.view` host + a SwiftUI `PopoverChrome` view containing header/tabs/body.
- `.indicator-live` → `Indicator(state: .live)` in `DesignSystem.swift` (already exists; verify color matches).
- `.wf .bar` → a SwiftUI `Waveform56Bar` view (new) using `TimelineView` for the per-bar phase animation.
- `.osw` → `ScribeSwitchStyle` already exists in `DesignSystem.swift` (verify against design spec; gap-fill if needed).
- `.settings-win` + `.win-side` + `.win-pane` → AppKit window with a `NSSplitViewController` or SwiftUI `NavigationSplitView`. Workers may use either, with a strong preference for SwiftUI for the body and AppKit only for the window chrome.

## Out of scope

- Any logic change to recording, transcription, calendar, recovery, or storage subsystems.
- New product features (AI summaries, history browser, etc. — explicitly disallowed by SPEC).
- Marketing site or landing page work.
