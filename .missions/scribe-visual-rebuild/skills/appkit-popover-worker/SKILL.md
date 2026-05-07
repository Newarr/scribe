---
name: appkit-popover-worker
description: Rebuilds the NSPopover chrome and the four-tab shell of the Scribe popover. Wires header (mark + scribe + LIVE indicator) and tab routing (Idle / Recording / Transcript / Settings, where Settings is an action that opens the settings window).
---

# Worker procedure: appkit-popover-worker

You are an AppKit + SwiftUI worker rebuilding the popover frame and tab shell.

## Read first

1. `.missions/scribe-visual-rebuild/AGENTS.md`
2. `.missions/scribe-visual-rebuild/library/architecture.md`
3. `.missions/scribe-visual-rebuild/library/design-tokens.md`
4. `.missions/scribe-visual-rebuild/design-reference/Popover.jsx` (4-tab shell)
5. `.missions/scribe-visual-rebuild/design-reference/states.css` (`.pop`, `.pop-h`, `.pop-tabs` styles — search the file)
6. `TranscriberApp/Scribe/AppDelegate.swift` (NSPopover lifecycle)
7. `TranscriberApp/Scribe/RecordingMenu.swift` (current popover content)
8. `TranscriberApp/Scribe/SettingsWindow.swift` (the existing window the Settings tab opens)

## Procedure

### Step 1: Plan the structure

The popover's content view becomes a `PopoverChrome` SwiftUI view with three regions:
1. Header (mark + 'scribe' + conditional LIVE indicator)
2. Tab bar (4 tabs: Idle, Recording, Transcript, Settings)
3. Body (switches based on selected tab; `Settings` is special — see below)

Add a `TabSelection` enum:

```swift
enum PopoverTab: String, Hashable, CaseIterable {
    case idle, recording, transcript, settings
}
```

The Settings tab is an ACTION, not a navigation target. When tapped:
1. Call the existing `SettingsWindow.show()` (or equivalent — locate the entry point in SettingsWindow.swift).
2. Do NOT change `selectedTab` to `.settings`. Keep the previously selected non-Settings tab.
3. Visually, the Settings tab in the segmented row may briefly highlight on tap then revert.

### Step 2: Chrome material

The popover should render with an HUD-window or popover material. Options:

- Use `NSPopover.appearance` and the popover's contentView's `wantsLayer = true` with a `CAEAGLLayer` or backing layer set to an `NSVisualEffectView` with `.material = .hudWindow`.
- Or wrap the SwiftUI content with an `NSVisualEffectView`-backed SwiftUI `VisualEffectView` wrapper (a thin NSViewRepresentable that hosts an NSVisualEffectView with `.hudWindow` material and `.active` state).

Prefer the second (cleaner SwiftUI integration). Existing `WindowChrome` in `DesignSystem.swift` may already provide a usable wrapper — check there first.

### Step 3: Hide the popover arrow caret

`NSPopover` shows a triangular caret by default. Either:
- Set `popover.behavior = .applicationDefined` and use a custom `NSWindow` for full control.
- Or accept the caret and document the choice in the handoff. The design intent is no caret, but the validation contract allows either if the chrome is otherwise correct.

If you take the custom-window path, you also need to handle anchoring to the menu-bar status item and dismiss-on-click-outside behavior. This is significant work — discuss in handoff if you go this route.

### Step 4: Header

Render header at fixed height (~38pt). Content:
- Left: 14pt four-bar Scribe mark glyph (use existing `BrandMark` from `DesignSystem.swift` if present and correct; otherwise build from the SVG at `design-reference/assets/menubar-icon.svg`) + lowercase `scribe` in semibold tracking-tight.
- Right: When `appDelegate.isRecording`, show `Indicator(state: .live, label: "LIVE")` (verify this initializer; adjust to match the existing `Indicator` view in DesignSystem.swift). Otherwise show nothing.
- 1px hairline divider beneath header in `--border-subtle` (alpha ~0.05).

### Step 5: Tab bar

Render a four-tab segmented control with labels `Idle`, `Recording`, `Transcript`, `Settings`. Style: low-contrast inactive buttons; selected button has a slightly raised background and white text. Match `.pop-tab` and `.pop-tab.on` styles from states.css (or the equivalent in Popover.jsx). Height ~32pt.

Wire selection: tapping Idle/Recording/Transcript updates `@State selectedTab`. Tapping Settings calls `SettingsWindow.show()` (or equivalent) and does NOT change `selectedTab`.

### Step 6: Body placeholder

For features 3-5 to fill in, expose a `body` switch:

```swift
switch selectedTab {
case .idle: IdlePane()  // placeholder for now: Text("Loading…")
case .recording: RecordingPane()
case .transcript: TranscriptPane()
case .settings: EmptyView()  // never reached if tap routing is correct
}
```

Create `IdlePane`, `RecordingPane`, `TranscriptPane` as separate Swift files (`TranscriberApp/Scribe/PopoverPanes/IdlePane.swift` etc.). Each has a placeholder body for now. Other workers will fill them.

### Step 7: Auto-select Recording on capture start

Subscribe to AppDelegate's recording state. When a recording starts, set `selectedTab = .recording`. When it stops, set `selectedTab = .idle`. Use the existing recording state publisher; if there isn't one, expose one via an `ObservableObject` viewmodel that wraps AppDelegate's relevant signals.

### Step 8: Confidential UI

Verify the popover's `NSWindow.sharingType = .none`. If not enforced, set it after the popover shows.

### Step 9: Verify

```
swift test --package-path /Users/szymonsypniewicz/Documents/code/scribe
xcodebuild -project ... build
```

Manual: open the app, click the menu-bar icon, verify popover renders with header + tabs + placeholder body. Click each tab. Click Settings — verify settings window opens. Start a recording (via existing hotkey or Idle pane button if one is wired) — verify Recording tab auto-selects and LIVE indicator appears.

### Step 10: Commit

## Handoff requirements

Return:
- `successState`, `featureId: popover-shell`, `commitId`, `repoPath`
- `summary`
- `chromeApproach`: `nspopover-with-arrow` or `custom-window-no-arrow` (record which path you took)
- `panesCreated`: list of new SwiftUI views (`IdlePane`, `RecordingPane`, `TranscriptPane`, etc.)
- `recordingStateBinding`: how you subscribed to AppDelegate's recording state
- `discoveredIssues`, `whatWasLeftUndone`
