# Validation Contract — scribe-visual-rebuild

Behavioral assertions for visual + interaction fidelity against the official Scribe Design System (`design-reference/`). All assertions are black-box and based on what a user sees and can do; none reference Swift implementation specifics.

Tools:
- `agent-browser` is N/A (this is a native macOS app). Use `manual-visual` (orchestrator/user opens the app, takes screenshots, compares to JSX/CSS reference) for any assertion that depends on rendered appearance or interaction.
- `swift-test` runs the unit-test target. Used for token-resolution and indicator-rendering assertions that have unit-test coverage.
- `xcode-build` confirms the app compiles. Used as a hard gate.

Evidence types: `screenshot(label)`, `console-errors`, `test-pass(suite/case)`, `build-output`.

---

## Area: Tokens & Foundation

### VAL-TOKENS-001: Live indicator color matches design
The live-recording indicator dot color, when rendered in the popover header during an active recording, resolves to the sRGB equivalent of `oklch(0.55 0.14 35)` within ΔE<2 against the reference swatch in `design-reference/colors_and_type.css` (`--live-dot`).
Tool: manual-visual + swift-test
Evidence: screenshot(popover-recording-header), test-pass(DesignSystemTests/testLiveDotColor)

### VAL-TOKENS-002: Accent color matches design
The accent color used by primary buttons and focus rings resolves to the sRGB equivalent of `oklch(0.50 0.09 255)` within ΔE<2.
Tool: manual-visual + swift-test
Evidence: screenshot(focus-ring), test-pass(DesignSystemTests/testAccentColor)

### VAL-TOKENS-003: Inter Variable is the primary UI font
All Scribe-rendered text in the popover, settings window, HUD, and toast uses Inter Variable (or its italic variant). No system font fallback is visible in any baseline screenshot.
Tool: manual-visual
Evidence: screenshot(popover), screenshot(settings-window), screenshot(hud), screenshot(toast)

### VAL-TOKENS-004: Display headlines use tight tracking
Display-class headlines (idle empty headline, HUD count, settings pane h2) render at letter-spacing -0.04em, semibold (600).
Tool: manual-visual
Evidence: screenshot(idle-empty), screenshot(hud), screenshot(settings-pane)

### VAL-TOKENS-005: No status pills anywhere
No filled or bordered "pill" appears anywhere in the UI for status. Status is always a colored dot followed by mono caps text (the `.indicator` pattern).
Tool: manual-visual
Evidence: screenshot(popover-all-tabs), screenshot(settings-window-all-panes)

### VAL-TOKENS-006: No emoji in UI
No emoji glyph appears in any rendered text in any pane, window, HUD, or toast.
Tool: manual-visual
Evidence: screenshot(popover-all-tabs), screenshot(settings-window), screenshot(hud), screenshot(toast)

---

## Area: Popover Chrome & Tabs

### VAL-POPOVER-001: Popover dimensions match design
The popover renders at 380pt wide with 12pt corner radius. The chrome material is a translucent dark vibrancy approximating `rgba(22,22,22,0.78)` with a backdrop blur (HUD-window or popover material in AppKit).
Tool: manual-visual
Evidence: screenshot(popover-frame)

### VAL-POPOVER-002: Header layout
The popover header shows, left-to-right: the four-bar Scribe mark glyph, the lowercase `scribe` word in semibold, then horizontal flex space, then a conditional `LIVE` indicator (rust dot + caps text) on the right ONLY when recording is active. The header has a 1px hairline divider beneath it (alpha ~0.05).
Tool: manual-visual
Evidence: screenshot(popover-header-idle), screenshot(popover-header-recording)

### VAL-POPOVER-003: Four-tab segmented control
A four-tab row appears below the header with labels `Idle`, `Recording`, `Transcript`, `Settings` (sentence case, in this order). The selected tab has a distinct active treatment (raised background or strong color); inactive tabs are muted.
Tool: manual-visual
Evidence: screenshot(tab-idle-selected), screenshot(tab-recording-selected), screenshot(tab-transcript-selected)

### VAL-POPOVER-004: Settings tab opens the settings window
Clicking the `Settings` tab in the popover opens (or brings to front) the settings window. The popover stays open. No in-popover settings pane is shown when Settings is "selected" — the Idle pane (or the previously selected non-Settings pane) remains visible in the popover body.
Tool: manual-visual
Evidence: screenshot(before-settings-tap), screenshot(after-settings-tap-with-window)

### VAL-POPOVER-005: Recording tab auto-selects on capture start
When recording starts (manually or via auto-record), the popover, on next open, defaults the selection to the `Recording` tab. When recording ends, the popover defaults back to `Idle`.
Tool: manual-visual
Evidence: screenshot(popover-during-recording), screenshot(popover-after-stop)

### VAL-POPOVER-006: No NSPopover arrow caret
The popover frame does not show the default `NSPopover` triangular arrow / caret. Either the arrow is hidden or replaced by a 14px rotated square notch attached to the chrome.
Tool: manual-visual
Evidence: screenshot(popover-frame-top-edge)

### VAL-POPOVER-007: Confidential UI preserved
The popover's `NSWindow.sharingType` is `.none` so the popover is excluded from screen captures (per existing app spec). Verified by attempting a screen capture from a separate app and confirming the popover area shows blank/black.
Tool: manual-visual
Evidence: screenshot(screencap-attempt)

---

## Area: Idle Pane

### VAL-IDLE-001: Empty state — breathing dots + headline
With no recents and no upcoming calendar event, the Idle pane shows: three small breathing pulse dots (animating), the headline `Listening.` in display weight, and the sub-line `Auto-records Zoom, Meet, Teams, FaceTime.` in muted secondary text. No `READY` chip is visible.
Tool: manual-visual
Evidence: screenshot(idle-empty)

### VAL-IDLE-002: Up-next card when calendar event upcoming
When a calendar event is scheduled within the next start-prompt window, the Idle pane shows an `Up next` eyebrow followed by a single-row card with the event title (left, semibold) and a relative-time label (right, e.g., `in 5 min`).
Tool: manual-visual
Evidence: screenshot(idle-up-next)

### VAL-IDLE-003: Recents section
Below the empty/up-next region, an eyebrow `Recent` precedes a list of up to 5 recent transcripts. Each row shows: a 26pt rounded glyph (left) with the meeting initial or a generic mark, the title (semibold, single-line ellipsized), a meta line `<when> · <duration>` (caption color), and a right-end chevron `→` that slides 3px on row hover.
Tool: manual-visual
Evidence: screenshot(idle-recents-list), screenshot(idle-recents-row-hover)

### VAL-IDLE-004: Recents row click opens transcript tab
Clicking a recents row switches the popover to the `Transcript` tab populated with that session's `transcript.md`.
Tool: manual-visual
Evidence: screenshot(after-recents-click)

### VAL-IDLE-005: Empty recents state
When the user has zero saved sessions, the `Recent` section is hidden entirely (not shown with placeholder text).
Tool: manual-visual
Evidence: screenshot(idle-no-recents-no-events)

---

## Area: Recording Pane

### VAL-RECORDING-001: Source row + elapsed timer
While recording, the Recording pane shows a single row at the top: rust live dot + meeting title (semibold, ellipsized) + `via <source>` subtitle in muted text on the left, and a large `mm:ss` elapsed timer in tabular numerals (~22pt) on the right.
Tool: manual-visual
Evidence: screenshot(recording-source-row)

### VAL-RECORDING-002: Source data binding
The meeting title in the source row is bound to the matched calendar event title (when one exists) or the recording-source app name (Zoom / Meet / Teams / FaceTime / system). The `via X` subtitle reflects the audio source.
Tool: manual-visual
Evidence: screenshot(recording-with-calendar-match), screenshot(recording-no-calendar-match)

### VAL-RECORDING-003: Mirrored 56-bar waveform
Below the source row, a 56-bar waveform spans the full pane width. Bars are 2pt wide with 2pt gaps, mirrored so the heights form a natural-speech envelope (taller in the middle, varied per `RecordingScreen.jsx`). All bars animate continuously when recording, using a shared keyframe (~900ms loop) with staggered per-bar delays.
Tool: manual-visual
Evidence: screenshot(recording-waveform), screen-recording(recording-waveform-animation-2s)

### VAL-RECORDING-004: Outcome strip exact copy
Beneath the waveform, a strip reads `Recording locally · saved when you stop` in muted text. Exact copy, exact mid-dot character (· U+00B7).
Tool: manual-visual
Evidence: screenshot(recording-outcome-strip)

### VAL-RECORDING-005: Pause + Stop actions
The footer of the Recording pane shows two right-aligned buttons: `Pause` (ghost variant) and `Stop` (secondary variant), in that order.
Tool: manual-visual
Evidence: screenshot(recording-actions)

### VAL-RECORDING-006: Pause maps to Stop (v1)
Clicking `Pause` produces the same effect as `Stop` in v1 — the recording finalizes and the popover returns to Idle. (This is the locked v1 behavior; real pause is deferred per `OQ-PAUSE-V2` in SPEC.)
Tool: manual-visual
Evidence: screenshot(after-pause-click)

### VAL-RECORDING-007: Stop ends the recording
Clicking `Stop` finalizes the recording, transitions the popover body to the Idle pane on next interaction, and the saved-notification toast appears.
Tool: manual-visual
Evidence: screenshot(after-stop-click), screenshot(saved-toast)

---

## Area: Transcript Pane

### VAL-TRANSCRIPT-001: Title + meta line
The Transcript pane header shows the session title (h3 weight) and a single meta line `<relative-day> <HH:MM> · <minutes> min · <speaker-count> speakers` in caption color.
Tool: manual-visual
Evidence: screenshot(transcript-header)

### VAL-TRANSCRIPT-002: Body — speaker-prefixed lines
The transcript body renders one line per utterance with a speaker label (left, semibold, accent-tinted) and the spoken text (right, body color). Line spacing is comfortable (relaxed leading, ~1.5).
Tool: manual-visual
Evidence: screenshot(transcript-body)

### VAL-TRANSCRIPT-003: Footer actions
The footer shows three text-with-icon buttons (`Copy`, `Export`, `Reveal`) on the left and one icon-only delete button on the right.
Tool: manual-visual
Evidence: screenshot(transcript-footer)

### VAL-TRANSCRIPT-004: Copy puts transcript in clipboard
Clicking `Copy` places the rendered transcript content (markdown source) on the system clipboard.
Tool: manual-visual
Evidence: screenshot(post-copy-paste-into-textedit)

### VAL-TRANSCRIPT-005: Reveal opens session folder in Finder
Clicking `Reveal` opens the session directory in Finder with the `transcript.md` selected.
Tool: manual-visual
Evidence: screenshot(finder-window-after-reveal)

### VAL-TRANSCRIPT-006: Export triggers an export sheet
Clicking `Export` presents a save sheet defaulting to the session title and `.md` extension.
Tool: manual-visual
Evidence: screenshot(export-sheet)

### VAL-TRANSCRIPT-007: Empty state
With no recents, the Transcript pane shows a muted line `No transcripts yet.` (sentence case, period). No CTA.
Tool: manual-visual
Evidence: screenshot(transcript-empty)

### VAL-TRANSCRIPT-008: Active-session live view
While a recording is in progress, the Transcript pane shows that session's title and the transcript body if streamed updates exist; otherwise it shows `Transcribing after stop.` (per spec — no live transcript). The footer actions are hidden for in-progress sessions.
Tool: manual-visual
Evidence: screenshot(transcript-during-recording)

---

## Area: Settings Window (Restyle)

### VAL-SETTINGS-WINDOW-001: Window dimensions and chrome
The settings window is 760pt × 700pt, with a 12pt corner radius and a translucent dark vibrancy chrome. Title bar shows the standard macOS traffic-light dots (left) and a centered title `Settings`.
Tool: manual-visual
Evidence: screenshot(settings-window-frame)

### VAL-SETTINGS-WINDOW-002: Sidebar layout
The window body uses a two-column grid: a 180pt sidebar on the left listing pane names with leading 16pt icons, and a content pane on the right. The sidebar has a 1px hairline separator, slightly darker background.
Tool: manual-visual
Evidence: screenshot(settings-window-sidebar)

### VAL-SETTINGS-WINDOW-003: Sidebar panes
The sidebar enumerates the panes the existing settings system already exposes (General, Storage, Diagnostics — and any others currently shipped). Each row has an icon, label, hover treatment, and selected treatment (lighter background).
Tool: manual-visual
Evidence: screenshot(sidebar-each-pane-selected)

### VAL-SETTINGS-WINDOW-004: Grouped rows
Each pane uses grouped rows: `s-group` containers with a 1px border, optional eyebrow group label, and rows separated by 1px hairlines. Rows use a `lab` (label) + `help` (caption) on the left and a control on the right.
Tool: manual-visual
Evidence: screenshot(general-pane), screenshot(storage-pane), screenshot(diagnostics-pane)

### VAL-SETTINGS-WINDOW-005: macOS-style toggle
Boolean settings render as the macOS-style switch (`osw`): 30×18pt, rounded full, off=neutral 10% white, on=oklch(0.55 0.18 145) (system green-equivalent), 14pt knob with subtle drop shadow.
Tool: manual-visual
Evidence: screenshot(settings-toggles-on-off)

### VAL-SETTINGS-WINDOW-006: KeyChain key field
The ElevenLabs API key field shows masked dots, has a focused border treatment matching the `s-input` spec, and never displays the actual key.
Tool: manual-visual
Evidence: screenshot(settings-api-key)

### VAL-SETTINGS-WINDOW-007: Diagnostic strip
The diagnostics pane shows a 4-cell grid (`diag`) with an eyebrow label and a value per cell (e.g., `Sessions / 12`, `Errors / 0`, `Engine / OK`, `Disk / 84 GB free`).
Tool: manual-visual
Evidence: screenshot(diagnostics-pane)

### VAL-SETTINGS-WINDOW-008: Storage row + Reveal
The Storage pane has a `Save to` row with `~/Scribe` (or current path) on the right and a `Choose…` ghost button. A `Reveal in Finder` row reveals the folder.
Tool: manual-visual
Evidence: screenshot(storage-pane-rows)

### VAL-SETTINGS-WINDOW-009: Delete-all-audio confirmation
The destructive `Delete all audio` action is gated behind a confirmation alert with body copy that matches the existing safety wording (audio-only deletion, sessions still pending/retrying are skipped).
Tool: manual-visual
Evidence: screenshot(delete-confirmation-alert)

### VAL-SETTINGS-WINDOW-010: Confidential UI preserved
The settings window's `NSWindow.sharingType` is `.none`. Verified by screen-capture attempt.
Tool: manual-visual
Evidence: screenshot(screencap-attempt-settings)

---

## Area: End-Countdown HUD

### VAL-HUD-001: HUD dimensions and chrome
The end-countdown HUD is 320pt wide, 14pt corner radius, dark vibrancy chrome with stronger shadow than the popover (per spec). Floats top-center of the active screen.
Tool: manual-visual
Evidence: screenshot(hud-frame)

### VAL-HUD-002: Eyebrow + count
The HUD shows an uppercase eyebrow (`Stopping in` or similar) above a tabular-numerals count rendering at 56pt, weight 300, with a small unit suffix (`s`).
Tool: manual-visual
Evidence: screenshot(hud-count-10s), screenshot(hud-count-3s)

### VAL-HUD-003: Progress bar
A 3pt-tall progress bar appears below the count, with a moving fill that contracts toward zero as the countdown decrements.
Tool: manual-visual
Evidence: screen-recording(hud-progress-2s)

### VAL-HUD-004: Two actions
The HUD footer has two equal-weight buttons: a primary `Stop now` and a secondary `Keep recording`. (Exact copy may be adjusted to match SPEC.)
Tool: manual-visual
Evidence: screenshot(hud-actions)

---

## Area: Saved-Notification Toast

### VAL-TOAST-001: Toast dimensions and chrome
The saved-notification toast is 340pt wide, 12pt corner radius, dark vibrancy chrome. Slides in from the top-right of the active screen.
Tool: manual-visual
Evidence: screenshot(toast-frame)

### VAL-TOAST-002: Layout
The toast uses a 30pt icon (left, in a rounded 7pt-radius tile), a stacked title + sub + path eyebrow (center), and a relative-time `when` (right). Title is `Saved.` in semibold; sub is the session title; path is the session folder relative path in mono caption.
Tool: manual-visual
Evidence: screenshot(toast-layout)

### VAL-TOAST-003: Auto-dismiss
The toast auto-dismisses after a fixed timeout (~5s) with a fade-out, unless the user clicks it (which opens the session in Finder).
Tool: manual-visual
Evidence: screen-recording(toast-lifecycle-6s)

---

## Area: Menu Bar Icon

### VAL-MENUBAR-001: Idle icon
The menu-bar icon at idle uses the four-bar SVG template, rendered monochrome via `currentColor` (template-rendered NSImage). Bar heights match `mb-bars[data-state="idle"]` (5, 8, 6, 4).
Tool: manual-visual
Evidence: screenshot(menubar-icon-idle)

### VAL-MENUBAR-002: Recording icon + dot
While recording, the menu-bar icon swaps to the four-bar SVG with a 2.5pt rust dot on the top-right corner (`mb-dot`). The bars subtly pulse (scale-Y 0.7 → 1.25, 900ms loop, staggered).
Tool: manual-visual
Evidence: screenshot(menubar-icon-recording), screen-recording(menubar-icon-pulse-2s)

### VAL-MENUBAR-003: Inline elapsed counter (optional)
If the user has enabled the inline elapsed counter (settings toggle), the menu-bar shows a tabular-numerals `mm:ss` next to the icon while recording.
Tool: manual-visual
Evidence: screenshot(menubar-icon-with-counter)

### VAL-MENUBAR-004: Click opens popover
Clicking the menu-bar icon opens the popover anchored to the icon. Clicking again (or clicking outside) dismisses it.
Tool: manual-visual
Evidence: screenshot(popover-anchored-to-menubar)

---

## Cross-Area Flows

### VAL-CROSS-001: Idle → Recording → Saved end-to-end
Starting from the popover open in Idle empty state, the user clicks Record (via menu bar, hotkey, or Idle CTA — depending on which entry point exists). The popover advances to the Recording pane with a live waveform. After ~5 seconds the user clicks Stop. The saved-notification toast appears top-right; the popover returns to Idle (now showing one item under `Recent`); the menu-bar icon returns to its idle template.
Tool: manual-visual
Evidence: screen-recording(end-to-end-flow-15s)

### VAL-CROSS-002: Recents row → Transcript tab
From Idle with at least one recent, clicking a recents row switches the popover to the Transcript tab populated with that session.
Tool: manual-visual
Evidence: screenshot(before-row-click), screenshot(after-row-click)

### VAL-CROSS-003: Settings tab → Settings window
From any popover tab, clicking the `Settings` tab opens the (restyled) settings window. The popover stays open. The selection in the popover does not change (the previously selected non-Settings pane remains visible).
Tool: manual-visual
Evidence: screen-recording(settings-tab-flow-3s)

### VAL-CROSS-004: Settings window changes affect popover
Toggling `Auto-record on meeting apps` in the settings window affects the menu-bar icon recording behavior on the next call attempt. Changing the storage path is reflected the next time a session is saved (toast path updates).
Tool: manual-visual
Evidence: screenshot(toggle-before), screenshot(toggle-after-effect-on-next-call)

### VAL-CROSS-005: HUD → end of recording
When the end-countdown HUD engages (silence detection or scheduled end), the user can `Stop now` (immediate finalize) or `Keep recording` (cancel countdown and continue). Both paths produce the correct downstream UI (toast on Stop; HUD dismiss + Recording pane intact on Keep).
Tool: manual-visual
Evidence: screen-recording(hud-stop-flow-5s), screen-recording(hud-keep-flow-5s)

### VAL-CROSS-006: Permission-revoked-while-recording
If the user revokes microphone or screen-recording permission while a session is active, the popover surfaces the Permission Recovery view (existing flow) — unchanged from the current implementation. The visual rebuild does NOT regress this safety surface.
Tool: manual-visual
Evidence: screenshot(permission-revoked-mid-recording)

### VAL-CROSS-007: Reduced-motion respected
With System Settings → Accessibility → `Reduce motion` enabled, the recording-pane waveform animation freezes at a static state, the menu-bar pulse stops, and the live-dot ping is disabled. All other UI (transitions, hover states) renders without animated transforms.
Tool: manual-visual
Evidence: screenshot(reduce-motion-on-recording-pane)

### VAL-CROSS-008: Test suite passes
The full `swift test` target passes. Baseline: 253 tests. After the rebuild: ≥253 tests, no regressions.
Tool: swift-test
Evidence: test-pass(TranscriberCoreTests/all)

### VAL-CROSS-009: Xcode build clean
`xcodebuild build` for the Scribe scheme exits 0 with no new warnings beyond the pre-existing `nonisolated(unsafe)` notices.
Tool: xcode-build
Evidence: build-output(xcodebuild)
