# Plan: fix Scribe permission setup flow

## Context

Four separate permission UX failures need to be fixed together:

1. After a macOS permission prompt is allowed, the Scribe setup/model window gets pushed behind the previously frontmost app.
2. Calendar `Allow` is inert: clicking it does not trigger the macOS EventKit permission flow or a visible state change.
3. Screen Recording can be toggled on in System Settings while Scribe still reports `Denied`.
4. If the standalone permissions modal is closed, the menu-bar `Setup needs attention` state does not provide a reliable visible route back into the permissions flow.

The intended outcome is a permission flow that is always recoverable: permission requests visibly start and finish, Scribe returns to the front after macOS prompts, Screen Recording explains/relaunches when macOS requires it, and the menu bar always has an obvious route back to setup.

## Approach

Use the existing permission onboarding/settings surfaces, but implement a real permission-flow state machine rather than relying on visual copy or mock/Framer suggestions:

- Every in-app permission button follows the same lifecycle: `idle → requesting → refresh status → restore Scribe window → final UI state`.
- The window restore is tied to permission completion and app reactivation. It temporarily raises the relevant Scribe window above the app that macOS returns to, then demotes it back to normal so System Settings remains usable.
- Calendar `Allow` must call the real EventKit full-access request. If macOS does not show a prompt or EventKit returns/errors without granting access, the row must stop being `Not asked` and become actionable (`Denied` / `Open in System Settings` / logged failure), not silently reset to another inert `Allow`.
- Screen Recording gets its own remediation state. After the user opens the Screen & System Audio Recording pane, if Scribe still sees denied, the UI must show an explicit `Restart Scribe` path and copy explaining the macOS/TCC propagation issue.
- The menu-bar `Setup needs attention` popover always closes itself and reopens/raises the standalone permissions window through the existing setup action. The CTA must be visible without relying on recents layout or fixed popover height.

## Files to modify

These are the critical code paths to change after confirming the exact current implementations; the patch should follow AppKit/EventKit/TCC behavior, not a design/mock recipe.

- `Sources/TranscriberCore/Permissions/PermissionsService.swift`
  - Calendar request/status implementation and logging.
- `Sources/TranscriberCore/Permissions/PermissionDoctor.swift`
  - Reuse the shared Calendar status mapping so app surfaces agree.
- `TranscriberApp/Scribe/SettingsWindow.swift`
  - `PermissionsPanelModel`, `FidelityPermissionsPanel`, and `PermissionsOnboardingWindowController` for request state, focus restore, Screen Recording restart CTA, and Done gating.
- `TranscriberApp/Scribe/OnboardingWindow.swift`
  - Ensure first-run permission prompts use the same front-restore behavior.
- `TranscriberApp/Scribe/AppDelegate.swift`
  - Route `openSetupRequired` to the permissions onboarding window reliably and close the menu popover before presenting it.
- `TranscriberApp/Scribe/RecordingMenu.swift`
  - Make `Setup needs attention` visibly actionable and sized so the setup CTA is not hidden/cropped by recents/fixed height.

## Reuse

- `OnboardingWindowController.bringFront()` and `PermissionsOnboardingWindowController.bringFront()` patterns for temporary floating + `orderFrontRegardless()`.
- `PermissionsPanelModel.refreshStatuses()` and existing auto-poll/on-activate refresh.
- `presentScreenRecordingRestartRequiredAlert()` and `AppDelegate.relaunchAndTerminate()` for the Screen Recording relaunch path.
- Existing `RecordingMenu.Action.openSetupRequired` instead of adding a new menu action.
- Existing System Settings deep links in `FidelityPermissionsPanel.openSystemSettings(_:)`.

## Steps

- [ ] Add/finish a shared front-restore helper used after every in-app permission request completes and after Scribe becomes active again from a macOS prompt/System Settings.
- [ ] Wire each permission row through a request lifecycle (`requesting` flag, disabled button, visible progress/copy, status refresh, then front-restore).
- [ ] Update Calendar request flow to use `try await EKEventStore.requestFullAccessToEvents()`, keep the event store alive through the request, return a fresh authorization status, and log errors.
- [ ] Normalize Calendar status mapping so `.fullAccess` / legacy `.authorized` are granted, `.denied` / `.restricted` / `.writeOnly` are denied, and only true `.notDetermined` keeps the in-app `Allow` button.
- [ ] If Calendar still has not triggered a prompt/status transition after the request returns, convert the row to an actionable failure state instead of leaving another inert `Allow` button.
- [ ] Add Screen Recording `Restart required` remediation after the user opens/toggles System Settings and Scribe still sees denied; surface `Restart Scribe` rather than an endless denied loop.
- [ ] Ensure `openSetupRequired` always closes the popover and reopens/raises `PermissionsOnboardingWindowController`, even if the user previously closed it.
- [ ] Adjust `RecordingMenu` setup-needs-attention layout so `Open setup` / `Check setup` is prominent and never hidden by fixed popover height or recents.
- [ ] Rebuild/reinstall, preserving any existing `~/Scribe/2026-05-18*` recordings before quitting/removing the app.

## Verification

### Build/install hygiene

- Before quitting/removing Scribe, copy aside any existing `~/Scribe/2026-05-18*` recording folders.
- Build with `xcodebuild -project TranscriberApp/Scribe.xcodeproj -scheme Scribe -configuration Debug -derivedDataPath ../build/dev build`.
- Prefer `scripts/dev-install.sh --build` / stable `Scribe Dev Signer 2` signing if the keychain is available; otherwise explicitly note ad-hoc signing and reset TCC for the tested scopes.
- Verify `/Applications/Scribe.app` passes `codesign --verify --verbose=2` before manual QA.

### Focus/z-order acceptance

- Put another app frontmost (browser/Zoom/cmux), open Scribe setup, and trigger Microphone/Calendar/Notifications permission prompts.
- After clicking macOS `Allow`, Scribe must return to the front without needing a menu-bar click.
- Within ~1–2 seconds, the Scribe window must demote back to normal level so System Settings and other apps can come forward normally.
- Capture before/after screenshots with Peekaboo to confirm the setup/model window is not pushed behind the previous app.

### Calendar acceptance

- Reset Calendar TCC for `com.szymonsypniewicz.scribe` and relaunch the installed app.
- Click Calendar `Allow` once.
- Expected: a macOS Calendar permission prompt appears, and after `Allow`, Scribe shows `Calendar Granted` without repeated clicks.
- If macOS refuses to show the prompt, expected fallback: the row leaves `Not asked`, logs the EventKit failure, and shows an actionable System Settings route. It must not remain an inert `Allow` button.

### Screen Recording acceptance

- Reset ScreenCapture TCC, open Scribe setup, and use `Open in System Settings` for Screen & System Audio Recording.
- Toggle Scribe on in System Settings.
- If Scribe still reports denied in the running process, expected: the permissions window shows `Restart Scribe` / `Quit & Reopen Scribe` with copy explaining macOS requires a relaunch.
- After relaunch, expected: Screen Recording is `Granted`; if not, logs should clearly show whether this is a signing/TCC identity mismatch.

### Menu-bar recovery acceptance

- Close the standalone permissions window while setup is still incomplete.
- Open the Scribe menu-bar popover.
- Expected: the `Setup needs attention` view has a visible setup CTA without scrolling/cropping.
- Click the CTA; expected: the popover closes and the standalone permissions window opens/raises every time.

### End-to-end recording acceptance

- After Microphone and Screen Recording are recognized as granted, start recording from the menu bar, wait ~8 seconds, and stop.
- Verify a new `~/Scribe/2026-05-18*` session appears with expected artifacts (`audio.m4a`, `transcript.md`, `metadata.json`, `pts.json`, `pts.jsonl` where applicable).
- Check unified logs for absence of `startRecording denied by preflight` after the permission fixes.
