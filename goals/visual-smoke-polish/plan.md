## Solution Approach

Treat this as a visual production polish pass. Inspect the existing smoke PNGs first, then fix the SwiftUI layout and snapshot harness where the visual evidence points. Keep privacy disclosures in onboarding/settings/privacy surfaces, while making the menu compact.

## Ordered Steps

1. Inspect current evidence PNGs in `/tmp/scribe-installed-smoke` with image tooling and note the visible failures.
   Verification: open or render the relevant PNGs and compare against the requested end state.

2. Update `TranscriberApp/Scribe/RecordingMenu.swift` so popover height is intrinsic or safely sized, and compress the active privacy/status copy into one compact metadata line.
   Verification: regenerate menu snapshots and confirm starting, recording, stopping, and finalized light images show the action row.

3. Update `TranscriberApp/Scribe/PrivacyAcknowledgementSheet.swift` so light and dark snapshots force the intended color scheme and the light surface has readable text/background contrast.
   Verification: regenerate `installed-smoke-privacy-acknowledgement-light.png` and inspect readability.

4. Update `TranscriberApp/Scribe/SettingsWindow.swift` so the ElevenLabs key editor uses a normal secure text field appearance and clear Save/Clear states, and add missing onboarding key-entry and Skip-to-Local visual snapshots.
   Verification: inspect `installed-smoke-settings-engine-key-entry-light.png` and the new onboarding PNGs.

5. Investigate installed snapshot invocation through `open`; either fix bundle metadata/registration or update the documented smoke command to use the direct executable path.
   Verification: run the documented installed snapshot command successfully.

6. Investigate `scripts/dev-install.sh --build` and XcodeGen project generation to stop path-dependent `.pbxproj` churn.
   Verification: run the relevant generation/build path and confirm `git status` does not show project churn from checkout path changes.

7. Run targeted Swift tests and an installed smoke snapshot run.
   Verification: targeted tests pass and the regenerated PNGs have been inspected visually.

## Risks

- Some existing dirty changes in the previous mission worktree may represent parallel work; this worktree starts from committed `mission/dc740869` to avoid collisions.
- macOS `open`/LaunchServices behavior can depend on bundle registration state; the reliable fallback may be documentation/script normalization rather than forcing `open`.
