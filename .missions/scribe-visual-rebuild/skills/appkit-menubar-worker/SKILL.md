---
name: appkit-menubar-worker
description: Replaces the menu-bar status-item icon with the design-system four-bar template SVG and adds the recording variant with rust dot + pulse animation.
---

# Worker procedure: appkit-menubar-worker

You replace the `NSStatusItem` icon with the design-system glyphs.

## Read first

1. `.missions/scribe-visual-rebuild/AGENTS.md`
2. `.missions/scribe-visual-rebuild/library/architecture.md`
3. `.missions/scribe-visual-rebuild/library/design-tokens.md`
4. `design-reference/assets/menubar-icon.svg` (idle).
5. `design-reference/assets/menubar-icon-recording.svg` (active — has the rust dot baked in).
6. `design-reference/states.css` — search `.mb-bars`, `.mb-bars.live`, `.mb-dot`, `.mb-counter`.
7. `TranscriberApp/Scribe/AppDelegate.swift` — the file owns the `NSStatusItem`. Locate where its image is set today.

## Procedure

### Step 1: Add SVG assets

Bundle the SVGs into `TranscriberApp/Scribe/Assets.xcassets/` as image sets configured for template rendering (Render As → Template Image). Two image sets:
- `menubar-icon` (idle)
- `menubar-icon-recording` (active)

Both must be vector-preserving so AppKit can scale and tint correctly. Set `Resizing` to `Vector` and `Render As: Template Image`.

### Step 2: Set the status item image

Replace the current image-setting code with:

```swift
let image = NSImage(named: "menubar-icon")!
image.isTemplate = true
statusItem.button?.image = image
```

For recording state, swap to `menubar-icon-recording` (which has the dot baked into the SVG; alternatively, draw the dot programmatically as an `NSView` overlay if you prefer).

### Step 3: Pulse animation

The bars pulse with scale-Y 0.7 → 1.25, 900ms ease-in-out, infinite, staggered per bar by 110ms. Approach options:

A. **Programmatic Core Animation:** subclass the status item's button view; replace its image with a custom `CALayer`-based view containing four `CAShapeLayer` bars. Drive each bar's `transform.scale.y` with a `CAKeyframeAnimation`.

B. **Rasterized animation:** generate ~20 frames of the pulse animation as `NSImage`s, cycle through them at 45ms per frame (~22 fps).

A is cleaner; B is simpler. Use A unless A turns out to require more hooks into the status item than expected.

Reduce Motion: pause animation. Subscribe to `NSWorkspace.shared.notificationCenter` for `accessibilityDisplayOptionsDidChangeNotification` and toggle.

### Step 4: Inline elapsed counter (optional)

If a settings toggle for "Show elapsed time in menu bar" exists (or you add a single boolean in SettingsStore), render the counter to the right of the icon during recording:
- 11pt tabular numerals, color `rgba(255,255,255,0.85)`, tracking 0.03em, format `mm:ss`.
- Updates every second from the existing `elapsedTickTimer` in AppDelegate.

If the toggle doesn't exist, do NOT add it in this feature — note in handoff and defer.

### Step 5: Click handling

Verify the existing click handler still fires (toggles popover). If you added a custom button view, you may need to re-wire `target` and `action`.

### Step 6: Verify

```
swift test --package-path /Users/szymonsypniewicz/Documents/code/scribe
xcodebuild -project ... build
```

Manual:
1. Launch app → check menu-bar icon shape against `menubar-icon.svg`.
2. Start recording → icon swaps to recording variant + dot + pulse.
3. Enable Reduce Motion → pulse stops.
4. Click icon → popover toggles.

### Step 7: Commit

## Handoff requirements

Return:
- `successState`, `featureId: menu-bar-icon`, `commitId`, `repoPath`
- `summary`
- `pulseImplementation`: `core-animation` or `rasterized`
- `inlineCounterState`: `wired` / `deferred` / `not-needed`
- `discoveredIssues`, `whatWasLeftUndone`
