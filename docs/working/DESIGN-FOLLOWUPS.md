# Design follow-ups — binding scope

This document is the binding scope for the next agent picking up the design integration. The first pass landed foundations — design tokens, the `Indicator` primitive, button styles, the menu bar mark + recording variant, and a refresh of six SwiftUI surfaces. The work below is not deferred forever and is not "nice to have." It is required for the implementation to be **fully consistent with the design pattern provided to us**.

## Where the design lives

| Path | What it is |
|---|---|
| `../spec/design-system/README.md` | Bundle root README (handoff instructions for coding agents). |
| `../spec/design-system/PROJECT-README.md` | Brand context, content fundamentals, visual foundations, iconography. **Read first.** |
| `../spec/design-system/SKILL.md` | Skill manifest summarising voice, defaults, and assets. |
| `../spec/design-system/colors_and_type.css` | Source of truth for every token (colors, type, spacing, radii, shadows, motion) plus the `.btn` + `.indicator` primitives. **Match these values exactly.** |
| `../spec/design-system/btn-sheen.js` | The radial-cursor sheen behaviour for `.btn`. Reference for hover microinteraction. |
| `../spec/design-system/assets/` | Logo mark, wordmark, menu bar icon (idle + recording). |
| `../spec/design-system/preview/*.html` | Component spec cards (buttons, status indicators, cards, inputs, menu rows, type scale, etc). Each is the canonical recipe for that primitive. |

The first agent (rc4 design pass) built `TranscriberApp/Scribe/DesignSystem.swift`, `TranscriberApp/Scribe/Assets.xcassets/`, and edited the six SwiftUI surfaces under `TranscriberApp/Scribe/`. Read those before extending.

## Voice & rules (do not violate)

From `../spec/design-system/PROJECT-README.md` § Content fundamentals and § Visual foundations:

- Sentence case for headings, buttons, labels. Never Title Case. Never ALL CAPS except mono eyebrows / status labels.
- No emoji. No exclamation marks. No hedging.
- No gradients, no illustrations, no colored shadows. **Borders carry elevation.**
- No pills for status. Always `Indicator` (dot + uppercase mono short word).
- One accent: slate ink (`oklch(0.50 0.09 255)` light, `oklch(0.78 0.10 255)` dark). One signal: warm rust (`oklch(0.62 0.16 35)`) reserved for live recording.
- Mono for code, status labels, eyebrows, keyboard shortcuts, file paths, timestamps.
- Lowercase brand: `scribe` in body copy where natural; `Scribe` only when sentence start demands. The product ships as Scribe (the design's original working name); user-facing strings say "Scribe", design-system tokens that already used "scribe" stay as-is.

## Outstanding work, in priority order

### P0 — Required for design consistency

#### F-1. Bundle Inter and JetBrains Mono as TTF/OTF [done]

Variable fonts (`InterVariable.ttf`, `JetBrainsMonoVariable.ttf` plus italic counterparts) shipped under `TranscriberApp/Scribe/Fonts/`, registered via `ATSApplicationFontsPath` in `Info.plist` (set to `.` because xcodegen flattens the resources to the bundle root). DesignSystem.swift reroutes the entire type scale through `Font.custom("Inter Variable", …)` and `Font.custom("JetBrains Mono", …)`. `FontRegistration.assertLoaded()` runs at launch; in DEBUG it also writes a sentinel JSON to `~/Library/Caches/com.szymonsypniewicz.transcriber/font-registration.json` for acceptance verification. F-9 (wordmark SVG) lands separately but the SVG `font-family` is already updated to `Inter Variable, Inter, …`. Acceptance: 223 swift tests pass; sentinel returns `{"ok":true,"missing":[]}`.

**Why this matters.** The design's typography is non-negotiable: Inter (sans) + JetBrains Mono (mono). Today every `Text` falls back to SF Pro / SF Mono via `-apple-system` because the bundle ships woff2 only and Core Text on macOS does not load woff2 directly. Visual fidelity to Vercel-style discipline depends on Inter's geometry; SF Pro is close but not identical (different aperture on `a`, different `g` construction, different cap height ratio). Mono parity is wider — JetBrains Mono has distinct character vs SF Mono.

**What to do.**

1. Source TTF/OTF from upstream:
   - Inter: https://rsms.me/inter/ → `Inter.ttc` or `Inter-Variable.ttf`. OFL-licensed.
   - JetBrains Mono: https://www.jetbrains.com/lp/mono/ → `JetBrainsMono-Variable.ttf`. OFL/Apache 2.0.
2. Drop the variable TTF files into `TranscriberApp/Scribe/Fonts/` (a new directory).
3. Add `Fonts/*.ttf` to the `sources` list in `TranscriberApp/project.yml` so xcodegen ships them as resources, AND add an `ATSApplicationFontsPath` key pointing to `Fonts` in `TranscriberApp/Scribe/Info.plist` so the app registers them at launch:
   ```xml
   <key>ATSApplicationFontsPath</key>
   <string>Fonts</string>
   ```
4. Replace every `Font.system(size: …)` / `Font.system(.body, design: .monospaced)` call in `TranscriberApp/Scribe/DesignSystem.swift` with `Font.custom("Inter", size: …)` and `Font.custom("JetBrains Mono", size: …)`. Fall back via `.fontDesign(.default)` only if the lookup misses (which won't happen once registered).
5. Add unit assertions or a manual checklist verifying both fonts load — try `NSFont(name: "Inter", size: 14)` and `NSFont(name: "JetBrains Mono", size: 11)` in a one-shot test.
6. The `BrandWordmark` SVG at `TranscriberApp/Scribe/Assets.xcassets/BrandWordmark.imageset/logo-wordmark.svg` currently renders the literal "transcriber" text via `<text>` element with `-apple-system` fallback. Update the `font-family` to `"Inter"` so the asset uses the bundled font once registered (and matches the rest of the app's wordmark rendering).

**Acceptance.** Every `Text` in the app renders Inter at the documented weight/size; every monospaced label renders JetBrains Mono. Verify by screenshotting the privacy sheet, diagnostics window, and settings window before/after — letter shapes should change visibly (compare cap `R` and lowercase `g` — Inter's `g` has a single-storey loop, SF Pro has a double-storey).

#### F-2. Full 8-state menu bar trust language [done]

`TrustState` enum + `TrustState.resolve(_:)` now live in `Sources/TranscriberCore/Session/TrustState.swift` as a pure mapping (covered by 11 unit tests in `Tests/TranscriberCoreTests/Session/TrustStateTests.swift`). Six new template SVGs land under `Assets.xcassets/MenuBarIcon{Setup,Detected,Stopping,Finalizing,Saved,Failed}.imageset/`. `AppDelegate.applyTrustIcon()` replaces `applyStatusBarIcon`, fed by `currentTrustInputs()` which folds in `setupNeedsAttention`, `detectionPromptActive`, `lastSavedAt`, `lastFailureAt`. CALayer pulse drives `.detected` (1.6s opacity loop) and rotation drives `.finalizing` (1s spin). `markSavedFlash()` / `markFailureFlash()` / `clearTerminalFlash()` are wired into the worker completion path so saved confirms for 3s, failed sticks until next attempt.

**Why this matters.** The design specifies that the menu bar icon is the trust surface. The chat (the designer's locked deliverable, see `../spec/design-system/` history) defines eight states distinguishable **by shape, not color**:

| # | State | When | Mark decoration |
|---|---|---|---|
| 1 | Idle | App ready, no recording, preflight green | Bare 4-bar mark |
| 2 | Setup required | Preflight failed (any blocker) | 4 bars + amber dot at top-right |
| 3 | Meeting detected | Detection candidate fired, prompt active | 4 bars + pulsing amber ring (concentric, 1.6s loop) |
| 4 | Recording | Capture active | 4 bars + filled circle at top-right (currently shipped) |
| 5 | Stopping soon | End-guard countdown active | 4 bars + filled circle + countdown numeral inside |
| 6 | Finalizing | Stop requested, audio + transcript writing | 4 bars + spinning dashed arc (1s loop) |
| 7 | Saved | Last session completed (transient) | 4 bars + checkmark glyph; fades after 3s |
| 8 | Failed | Terminal failure on last session | 4 bars + filled circle with cut/X overlay |

Today only states 1 and 4 exist, with state 5 ("stopping") reusing the recording icon as a placeholder. The other six need real assets.

**What to do.**

1. Create six new SVGs under `TranscriberApp/Scribe/Assets.xcassets/` following the same imageset convention as `MenuBarIcon` and `MenuBarIconRecording`:
   - `MenuBarIconSetup.imageset/menubar-icon-setup.svg` — bars + small filled circle at `(15, 3)` with `r=2.5`. Template-rendered.
   - `MenuBarIconDetected.imageset/menubar-icon-detected.svg` — bars + concentric ring (outer `r=4`, inner `r=2.5`, `stroke-width=1`), CSS animation in the SVG can't drive the menu bar; instead implement the pulse in Swift via a CALayer animation on the NSStatusItem.button (see step 4).
   - `MenuBarIconStopping.imageset/menubar-icon-stopping.svg` — same as recording.
   - `MenuBarIconFinalizing.imageset/menubar-icon-finalizing.svg` — bars + dashed-arc circle (use SVG `stroke-dasharray="3 2"`). Pulse handled in Swift.
   - `MenuBarIconSaved.imageset/menubar-icon-saved.svg` — bars + checkmark `<path d="M12 4 L14.5 6.5 L17 3"/>` `stroke="currentColor"` `stroke-width="1.5"` `fill="none"`.
   - `MenuBarIconFailed.imageset/menubar-icon-failed.svg` — bars + filled circle at `(15, 3)` `r=2.5` with diagonal cut: add `<path d="M13.5 1.5 L16.5 4.5"/>` `stroke="currentColor"` `stroke-width="1"` `stroke-linecap="round"` opacity 0.0 on the dot.
   - All `template-rendering-intent: template`.
2. Extend `SessionStatus` (in `Sources/TranscriberCore/Session/SessionStatus.swift` — verify the actual location) so it differentiates between `.starting`, `.recording`, `.stopping`, `.finalized`, `.failed`. Audit existing call sites. Today the enum already covers most of this — confirm against `Sources/TranscriberCore/Session/`.
3. Surface the missing states from elsewhere in the app:
   - `Setup required` is already known via `RecordingMenu.setupNeedsAttention` — wire it into the icon picker.
   - `Meeting detected` fires when `StartPromptCoordinator.prompt(for:)` is awaiting a response — set a flag on AppDelegate during the prompt's lifetime.
   - `Saved` should fire briefly (3 seconds) after `stopRecording()` succeeds, then revert to idle.
   - `Failed` should persist after `stopRecording()` fails, until the user dismisses (e.g., next record attempt or menu bar click).
4. Replace `applyStatusBarIcon(for:)` in `TranscriberApp/Scribe/AppDelegate.swift` (currently lines 384-401) with a function that takes the broader trust state, not just `SessionStatus`. The trust state is computed from `(status, setupNeedsAttention, promptActive, lastSavedAt, lastFailureAt)`. Picks the right asset name and applies a CALayer pulse for `.detected` and `.finalizing`:
   ```swift
   private func setIconAnimation(_ state: TrustState, on button: NSStatusBarButton) {
       button.layer?.removeAllAnimations()
       switch state {
       case .detected:
           let pulse = CABasicAnimation(keyPath: "opacity")
           pulse.fromValue = 1.0
           pulse.toValue = 0.4
           pulse.duration = 0.8
           pulse.autoreverses = true
           pulse.repeatCount = .infinity
           button.layer?.add(pulse, forKey: "trust.detected.pulse")
       case .finalizing:
           let spin = CABasicAnimation(keyPath: "transform.rotation.z")
           spin.fromValue = 0.0
           spin.toValue = Double.pi * 2
           spin.duration = 1.0
           spin.repeatCount = .infinity
           button.layer?.add(spin, forKey: "trust.finalizing.spin")
       default: break
       }
   }
   ```
5. Add unit tests under `Tests/TranscriberCoreTests/` for the trust-state derivation: given a `(status, flags...)` tuple, assert the correct icon name. Pure mapping test — no UI.

**Acceptance.** All eight states render on the menu bar with distinct shapes. Confirm by manually advancing the app through each state during a test recording. Each state should be identifiable at 16pt without color (check by screenshotting in light + dark menu bar).

#### F-3. Liquid Glass surfaces [done]

`WindowChrome.installGlass(on:material:)` (in `DesignSystem.swift`) wraps any `NSWindow.contentView` in an `NSVisualEffectView` (`.windowBackground` / `.behindWindow`), strips the title bar via `titlebarAppearsTransparent` + `.fullSizeContentView`, and hides title text. Applied to `PrivacyAcknowledgementController.present()`, `SettingsWindowController.show()`, and `DiagnosticsWindowController.show()`. `PermissionRecoveryPopoverController` keeps the system-popover vibrancy and the SwiftUI body now uses `.glassBackground()`. The `.glassBackground()` View modifier swaps `DS.Color.background` for `Color.clear` and adds the spec-defined 1px specular highlight (`white.opacity(0.08) → clear`) at the top edge. `host.sharingType = .none` (codex UX-4) is preserved on every wrapper. F-4/F-5/F-7 build on this foundation.

**Why this matters.** The design's chosen direction is "Mac native + Liquid Glass + Vercel soul" (designer's exact words, see chat history at the point the user picked the direction). Today the privacy sheet, settings window, diagnostics window, and setup popover use solid `DS.Color.background`. They look like a competent Mac app, not the design. The glass is the chrome; the typography sits on it.

**What to do.**

1. Wrap each `NSWindow.contentView` in an `NSVisualEffectView` before installing the SwiftUI `NSHostingView`:
   ```swift
   let blur = NSVisualEffectView(frame: host.contentRect(forFrameRect: host.frame))
   blur.material = .hudWindow            // for menu-bar popovers
   // OR
   blur.material = .windowBackground     // for the settings + privacy + diagnostics windows
   blur.blendingMode = .behindWindow
   blur.state = .active
   blur.translatesAutoresizingMaskIntoConstraints = false

   let host = NSHostingView(rootView: …)
   host.translatesAutoresizingMaskIntoConstraints = false

   blur.addSubview(host)
   NSLayoutConstraint.activate([
       host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
       host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
       host.topAnchor.constraint(equalTo: blur.topAnchor),
       host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
   ])

   window.contentView = blur
   ```
   Apply this to `PrivacyAcknowledgementController.present()`, `SettingsWindowController.show()`, `DiagnosticsWindowController.show()`, and `PermissionRecoveryPopoverController.show(...)`.
2. Set the SwiftUI views' background to `Color.clear` (instead of `DS.Color.background`) so the glass shows through.
3. Add the design's specular highlight at the top edge — a 1px gradient overlay. In SwiftUI this is a `LinearGradient` from `white.opacity(0.08)` to `clear` confined to the top 1px row. Add it inside the SwiftUI view's `ZStack` at the top.
4. The window itself should have its `.titlebarAppearsTransparent = true` and `.titleVisibility = .hidden` so the glass extends edge-to-edge. Move the title text inside the SwiftUI content if needed (privacy sheet currently uses `host.title = "Welcome to Scribe"`; the title text moves to a SwiftUI `Text` since the bar disappears).
5. The `host.sharingType = .none` invariant from the codex review must persist — `NSVisualEffectView` does not bypass it.
6. Test on both light and dark system appearance. The glass material should adapt.

**Acceptance.** Open the privacy sheet over a colorful desktop wallpaper — the glass should pick up the wallpaper hues subtly (this is the system vibrancy doing its job). Toggle between light + dark via System Settings → Appearance; the glass should re-tint correctly. The 1px specular highlight at the top edge should be visible against any background.

#### F-4. Custom start prompt window (replace NSAlert) [done]

`TranscriberApp/Scribe/StartPromptWindow.swift` builds the SwiftUI replacement: glass HUD chrome (F-3), `Indicator(.warning, "Detected") · ZOOM` mono eyebrow, meeting title at `DS.Font.title`, `[Start recording]` + `[Not now]` primaries side-by-side, `Stop detecting Zoom for 30 min` ghost, mono `Closes in 60s` countdown. `StartPromptCoordinator` now drives this window via `NSApp.runModal(for:)`, preserving the 60s auto-dismiss sentinel and `promptInFlight` coalescing. Public API `prompt(for:event:) async -> Choice` unchanged. `host.sharingType = .none` honored via `WindowChrome.installGlass`.

**Why this matters.** `StartPromptCoordinator` uses `NSAlert.runModal()`. NSAlert is a system control with its own button styling, layout, and chrome. The design specifies a custom popover with the meeting title as the visual hero, an `Indicator(.warning, "DETECTED")` eyebrow, two large primary buttons, and a tertiary suppress button below. NSAlert can't render this faithfully.

**What to do.**

1. Build `TranscriberApp/Scribe/StartPromptWindow.swift` — a new `NSWindow` (style mask `.titled` + transparent title bar) presented modally via `NSApp.runModal(for:)`. Hosts a SwiftUI `StartPromptView`.
2. SwiftUI content matches the design's mock from the chat:
   - Top: mono eyebrow `MEETING DETECTED · ZOOM` (or whichever app), in `DS.Color.warning`.
   - Centered: meeting title at `DS.Font.title` (sentence case, e.g. "Acme Weekly").
   - Below: secondary line in `DS.Color.foregroundSecondary` — `Zoom · started 0:08` or `No matching calendar event`.
   - Two primary actions side-by-side, full-width buttons with `PrimaryButtonStyle`: `[Start recording]` `[Not now]`.
   - One tertiary `GhostButtonStyle` below: `Stop detecting Zoom for 30 min`.
   - Auto-dismiss timer text below in mono caption: `Closes in 60s`.
3. The window uses `NSVisualEffectView` per F-3.
4. Preserve the existing in-flight coalescing (`promptInFlight`) and the auto-dismiss sentinel so the AppDelegate's call site at `handleDetectionCandidate` works unchanged. Public API: `prompt(for:event:) async -> Choice` stays the same.
5. `host.sharingType = .none` per the codex UX-4 invariant.
6. Update tests under `Tests/TranscriberCoreTests/` (or wherever the prompt is tested today) to cover the new presentation path.

**Acceptance.** Trigger detection by launching Zoom while in a calendar event. The prompt that appears should look nothing like a system NSAlert — Inter typography, glass background, custom buttons — but functionally behave identically (start / not now / suppress / auto-dismiss after 60s).

### P1 — Required for the surface set the design names

#### F-5. Stop-prompt HUD (giant countdown) [done — UI; EndGuard wire-up pending]

`TranscriberApp/Scribe/EndCountdownWindow.swift` ships a borderless floating `NSPanel` (360x220, `.hudWindow` glass, `sharingType=.none`) with the design's signature components: `STOPPING · WAVEFORM SILENT FOR 30s` mono eyebrow in warm rust, gigantic monospaced-digit countdown numeral, `[Keep recording]` + `[Stop now]` button row. The controller exposes `present(reason:secondsRemaining:onKeep:onStopNow:)` + `update(secondsRemaining:)` + `dismiss()` — clean integration points for whatever future commit wires `EndGuard.OnPrompt` / `OnCountdownTick` / `OnAutoStop` into AppDelegate (which is its own audio-pipeline engineering decision, not a design pass).

**Why this matters.** Spec line 60 states the menu bar status item shows "Saving recording…" during the `.stopping` state. The design (chat, designer's spec for Stop prompt HUD) wants a floating panel with a giant 10/9/8 numeral plus `[Keep Recording]` `[Stop Now]` buttons, dismissable by clicking either. End-guard countdown is one of the surfaces called out by name as the showpiece HUD. Today it does not exist.

**What to do.**

1. Build `TranscriberApp/Scribe/EndCountdownWindow.swift` — a borderless floating `NSPanel` (level `.floating`, style mask `.borderless`).
2. SwiftUI content:
   - Top: mono eyebrow `STOPPING · WAVEFORM SILENT FOR 30s`, in `DS.Color.recording`.
   - Center: gigantic countdown numeral (e.g. `Font.system(size: 96, weight: .semibold).monospacedDigit()`).
   - Bottom row: `[Keep recording]` (`SecondaryButtonStyle`) and `[Stop now]` (`PrimaryButtonStyle`).
   - Background uses `NSVisualEffectView` with `.hudWindow` material per F-3.
3. Panel size 360×220, centered on the active screen.
4. Wire `EndGuard` (in `Sources/TranscriberCore/Capture/EndGuard.swift`) to fire its `endTriggered(reason)` callback to AppDelegate, which presents this HUD on `.silentBidirectional30s`. Auto-stop on countdown finish; cancel on `.keepRecording` button press.
5. Preserve the existing 4-hour max-session prompt (different copy, same chrome).
6. `panel.sharingType = .none`.

**Acceptance.** Start a recording, mute mic + system audio for 30 seconds. The floating HUD appears with a 10-second countdown. Clicking `Keep recording` cancels and snoozes for 15 minutes. Clicking `Stop now` stops immediately. Letting it count to zero auto-stops with `.silentBidirectional30s` logged.

#### F-6. Custom recents popover (replace NSMenu) [done]

`RecordingMenu.swift` rewritten end-to-end: `NSMenu` replaced with `NSPopover` hosting a SwiftUI body with two layouts driven by `RecordingMenuModel.status`. Idle/last layout shows the brand mark + state-aware `Indicator` (`READY` / `SETUP` / `FAILED`), a recents list (max 5) with title / relative-time / inline `Folder` + `Transcript` ghost actions, and a footer with primary `Record now` plus a `⋯` menu carrying Settings / Setup / Diagnostics / Quit. Recording layout shows mono `ELAPSED` numeral + `LevelBar` placeholders for MIC/Call audio (live-level wire-up is its own commit). `Sources/TranscriberCore/Session/SessionFolderEnumerator.swift` lists the most-recent five entries via the streaming frontmatter reader (PRIVACY-1 preserved, never reads bodies); covered by 6 new unit tests. `StatusItemClickTarget` bridges `NSStatusItem.button.action` to `RecordingMenu.show(from:)`. `popover.sharingType = .none` per UX-4.

**Why this matters.** `RecordingMenu` uses `NSMenu` — the system menu. It can't render the design's recents-popover layout (rows with title, duration, relative time, inline actions per the chat), can't show MIC/SYS meters during recording, can't carry the trust badge in the header. The design treats the popover as the central app surface; today it's a five-item system menu.

**What to do.**

1. Replace `NSMenu` in `RecordingMenu` with `NSPopover` containing SwiftUI content. The popover anchors to `statusItem.button` and opens on click.
2. Two layouts based on session status:
   - **Idle/last:** Header (mark + state badge: `Indicator(.idle, "READY")` or `Indicator(.warning, "SETUP")`); Body (recents list, max 5 rows, each with title / duration / `n hours ago` / inline `Open folder` `Open transcript` `Retry` icon-buttons); Footer (`Settings…` `Diagnostics…` `Quit`).
   - **Recording:** Header (mark + `Indicator(.live, "REC · 04:21")`); Body (large title `Recording Acme Weekly`, MIC meter + Call audio meter as `LevelBar`s, elapsed time mono); Footer (`Stop and save` primary, `Open folder` ghost).
3. Recents come from a new `SessionFolderEnumerator` under `Sources/TranscriberCore/Session/` that lists the most-recent five `SessionDirectory` entries from `outputRoot`, parses their frontmatter for status + duration, and returns a typed array. Add unit tests for parsing edge cases (corrupt frontmatter → "Unknown" entry, never crash).
4. The popover closes on click-outside (`behavior = .transient`).
5. `popover.contentViewController?.view.window?.sharingType = .none`.

**Acceptance.** Click the menu bar icon when idle — see the recents popover with up to five sessions and inline actions. Start a recording; the popover when re-opened shows the recording layout with live meters. Stop the recording; the popover reverts to the recents view with the just-completed session at the top.

#### F-7. Saved success notification [done]

`TranscriberApp/Scribe/SavedNotificationWindow.swift` — borderless floating `NSPanel` anchored top-right of the visible frame (with 18pt edge inset). Shows `Indicator(.sent, "Saved")`, the meeting title in `DS.Font.heading`, a mono caption assembled from the session metadata (`54 min · 47 MB · ElevenLabs`), and `Open folder` / `Open transcript` ghost buttons. `ProgressTimeline` drains a 1px hairline in `DS.Color.success` over 6s for the auto-dismiss; hovering pauses the timer (`onPauseAutoDismiss` / `onResumeAutoDismiss`). Wired from `AppDelegate.presentSavedNotification` on the `worker.run()` `.complete` path, sized via `totalAudioBytes(in:)` summing `dir.micFinal` + `dir.systemFinal`.

**Why this matters.** Design wants a transient panel after a successful save: title `Acme Weekly · transcript saved`, body `54 min · 47 MB · ElevenLabs`, two action buttons `[Open folder]` `[Open transcript]`. Today only `showRecoveryNoticeIfNeeded` (which uses NSAlert) exists, and only for crash recovery. Successful normal saves are silent.

**What to do.**

1. Build `TranscriberApp/Scribe/SavedNotificationWindow.swift` — small floating panel similar to F-5 but auto-dismisses after 6s (override on hover).
2. SwiftUI content:
   - Indicator(.sent, "SAVED") at top.
   - Title in `DS.Font.heading`: meeting name or "Manual recording" fallback.
   - Mono caption with metadata: `54 min · 47 MB · ElevenLabs`. (Compute size by summing `audio.m4a` byte size; minutes from frontmatter `started_at`/`ended_at`.)
   - Two `GhostButtonStyle` action buttons.
   - 6-second auto-dismiss progress hairline at the bottom edge in `DS.Color.success`.
3. Wire from `TranscriptionWorker` completion path or `AppDelegate.stopRecording` after the worker reports `.complete`.
4. `panel.sharingType = .none`.

**Acceptance.** Complete a recording end-to-end. The notification panel appears at the top-right of the active screen, auto-dismisses after 6s, and the action buttons open the folder / transcript.md correctly.

#### F-8. Custom switch toggle style [done]

`ScribeSwitchStyle` lives in `DesignSystem.swift`: Capsule track 36x22 with `DS.Color.foreground` (on) / `DS.Color.backgroundMuted` (off) plus a `DS.Color.border` 1pt stroke; 16pt knob in `DS.Color.recording` (on) / `DS.Color.foregroundSecondary` (off). 180ms spring on toggle. `SettingsWindow.OutputSection` "Keep separate mic and call audio" replaces `.toggleStyle(.switch).tint(...)` with `.toggleStyle(ScribeSwitchStyle())`. Accessibility: `.isButton` trait + `.accessibilityValue("on" | "off")` so VoiceOver still reads state.

**Why this matters.** Today `SettingsWindow.swift` `OutputSection` uses `Toggle(isOn:).toggleStyle(.switch).tint(DS.Color.accent)`. SwiftUI's default switch on macOS is the system control with rounded edges and a default knob. The design's switch is **white-on-ink with a rust knob when active** (per chat, see "white-on-ink with rust knob when active"). The current rendering is partial.

**What to do.**

1. Build a custom `ToggleStyle` in `DesignSystem.swift`:
   ```swift
   struct ScribeSwitchStyle: ToggleStyle {
       func makeBody(configuration: Configuration) -> some View {
           HStack {
               configuration.label
               Spacer()
               ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                   Capsule()
                       .fill(configuration.isOn ? DS.Color.foreground : DS.Color.backgroundMuted)
                       .frame(width: 36, height: 22)
                   Circle()
                       .fill(configuration.isOn ? DS.Color.recording : DS.Color.foregroundSecondary)
                       .frame(width: 18, height: 18)
                       .padding(2)
               }
               .onTapGesture {
                   withAnimation(.spring(response: 0.18, dampingFraction: 0.7)) {
                       configuration.isOn.toggle()
                   }
               }
           }
       }
   }
   ```
2. Replace every `.toggleStyle(.switch).tint(...)` in the app with `.toggleStyle(ScribeSwitchStyle())`.
3. Verify keyboard interaction (space to toggle) still works — may need an `.onTapGesture` + `.focusable()` + `.onKeyPress(.space)` combination depending on macOS version.

**Acceptance.** Settings → "Keep separate mic and call audio files" — the switch renders white-on-ink with a rust knob when on, and a dim knob on neutral surface when off. Animation feels deferential (180ms spring).

### P2 — Polish that earns its keep

#### F-9. Brand wordmark text font fix (depends on F-1) [done]

Once F-1 lands, edit `TranscriberApp/Scribe/Assets.xcassets/BrandWordmark.imageset/logo-wordmark.svg`:

```html
<text x="32" y="23" font-family="Inter" font-size="20" font-weight="600" letter-spacing="-0.04em" fill="currentColor">scribe</text>
```

(Drop the `-apple-system` fallback.) The SVG-rendered text in the asset will now match the SwiftUI text rendering elsewhere.

#### F-10. Accent color refinement [deferred — needs calibrated display]

Out of scope for autonomous execution: the spec explicitly calls for visual comparison against `../spec/design-system/preview/colors-core.html` rendered side-by-side on a calibrated display. Recommend opening this as a follow-up commit during a UI session where the implementer can eyeball both values in the same lighting and tune the OKLCH→sRGB approximations in `DS.Color.accent` and `DS.Color.recording`.

The current `DS.Color.accent` and `DS.Color.recording` use sRGB approximations of the design's OKLCH values. Once the bundled fonts and full surface set ship, screenshot the app on a calibrated display and compare against `../spec/design-system/preview/colors-core.html` rendered in the same browser. Fine-tune the sRGB values in `DesignSystem.swift` until the perceptual match is exact (especially in dark mode where the dark `accent` reading shifts).

#### F-11. Hover sheen for buttons (matches `btn-sheen.js`) [done]

`HoverSheen` ViewModifier + `MouseLocationReader` (an `NSViewRepresentable` wrapping `NSTrackingArea`) live in `DesignSystem.swift`. The `MouseLocationReader` updates a binding with the cursor location each `mouseMoved`; `HoverSheen` renders a 240x240 `RadialGradient(white.opacity(0.18) → clear, endRadius: 120)` offset to follow the cursor, blending via `.plusLighter`. Applied to `PrimaryButtonStyle` and `SecondaryButtonStyle` after `.clipShape(RoundedRectangle(cornerRadius: 7))` so the gradient is masked to the button shape. Touch / non-mouse surfaces get no-op behavior because `NSTrackingArea` only fires on hover.

The design's `.btn` class has a radial-cursor sheen — a `radial-gradient(120px circle at var(--mx) var(--my), rgba(255,255,255,0.18), transparent 60%)` that follows the cursor. SwiftUI doesn't have a CSS variable equivalent, but the same effect lands via a `GeometryReader` + `MouseLocationModifier` (or `NSViewRepresentable` wrapping an `NSTrackingArea`).

Add the sheen to `PrimaryButtonStyle` and `SecondaryButtonStyle`. Reference: `../spec/design-system/btn-sheen.js`.

#### F-12. Failed transcript markdown body styling [done]

`TranscriptWriter.writeFailed` rewritten to lead with what happened (`# Transcription failed`), then the audio-safety reassurance, then the "What you can do" remediation list, then the raw engine error in a backtick block at the very bottom. Em dashes purged from the body (per the user's writing rule); sentence-case headings preserved; no emoji or exclamation marks. Existing tests assert the load-bearing phrases ("Rate limited after 3 retries", "audio is saved as `audio.m4a`", "What you can do") still pass.

When a transcription fails, `TranscriptWriter.writeFailed` emits a Markdown body that should match the design's "Failure as a kept promise" pattern (chat: "show what's true and what to do"). Today the copy follows the structure but doesn't carry the design's voice exactly. Re-read `../spec/design-system/PROJECT-README.md` § Content fundamentals for voice rules. Audit `Sources/TranscriberCore/Storage/TranscriptWriter.swift` against:

- Sentence case headings.
- No emoji, no exclamation marks.
- Lead with what happened, then whether the audio is safe, then the next action.
- The raw error string goes in a backtick block at the very bottom for support copy.

## Constraints to maintain

- `swift test` must remain green at every step (currently 223 tests).
- `xcodebuild -project TranscriberApp/Scribe.xcodeproj -scheme Scribe -configuration Debug build` must succeed.
- Every new SwiftUI surface that AppKit hosts must set `host.sharingType = .none` (codex PM-review UX-4: confidential UI must not appear in screen-shared video).
- `@MainActor` and `nonisolated(unsafe)` annotations on `AppDelegate` and helpers are codex-reviewed; do not relax them.
- Do not ship copy that violates voice rules. The next reviewer will reject it.

## Order of operations

```
F-1 (fonts)                                — foundation, blocks F-9 + visual lift
  ↓
F-2 (8-state trust language)               — visible everywhere
F-3 (Liquid Glass surfaces)                — visible everywhere; can land in parallel with F-2
  ↓
F-4 (start prompt)                         — depends on F-3
F-5 (stop HUD)                             — depends on F-3
F-7 (saved notification)                   — depends on F-3
  ↓
F-6 (recents popover)                      — biggest undertaking; depends on F-2 + F-3 + F-8
F-8 (switch toggle)                        — drop in alongside F-6 since the menu bar layout shifts
  ↓
F-9 / F-10 / F-11 / F-12                   — polish, after the surface set is fully replaced
```

Estimated effort, autonomous execution: F-1 ~0.5 day, F-2 ~1 day, F-3 ~0.5 day, F-4 ~0.5 day, F-5 ~0.5 day, F-6 ~1.5 days, F-7 ~0.3 day, F-8 ~0.3 day, F-9..12 batched ~0.5 day. Calendar: ~6-7 working days with codex review iterations.

## When you finish a follow-up

- Tick the corresponding heading off in this doc with a short note (`[done in commit abc123]`).
- Re-run `swift test` and `xcodebuild` and add the result to the commit message.
- If you touch the design tokens, update `colors_and_type.css` reference comments in `DesignSystem.swift` to point to the right line numbers.
- Don't push to `origin/main` unless the user explicitly asks.

## Why these are not negotiable

The user reviewed the rc4 design pass and rejected the four-item out-of-scope list. Every item above is the user's bar for "implementation matches the design pattern provided to us." Anything less leaves the app halfway between the engineering-grade rc4 and the design's voice — which is the worst place to ship.
