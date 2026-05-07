# Environment

What workers need to know about the build/run environment.

## Required

- macOS 15+ (the Package.swift targets `.macOS(.v15)`).
- Xcode 16+ with the matching command-line tools.
- Swift 6 toolchain (`swift-tools-version:6.0`).
- The repo at `/Users/szymonsypniewicz/Documents/code/scribe`.

## What does NOT belong here

Service ports/commands → `services.yaml`. Token values → `library/design-tokens.md`. Architecture → `library/architecture.md`.

## Pre-existing on disk

- Fonts: `TranscriberApp/Scribe/Fonts/InterVariable.ttf`, `InterVariable-Italic.ttf`, `GeistVariable.ttf`, `GeistVariable-Italic.ttf`, `GeistMonoVariable.ttf`, `GeistMonoVariable-Italic.ttf`, `JetBrainsMonoVariable.ttf`, `JetBrainsMonoVariable-Italic.ttf`.
- `DesignSystem.swift` is at 1012 lines with substantial token + typography work already done.
- 253 unit tests pass at baseline (per the previous Droid's verification).
- The `.dd-release/` directory under `TranscriberApp/` is left over from a release build and is gitignored. Workers should leave it alone.

## Privileges & permissions

- The app uses Microphone, Screen Recording, and EventKit (Calendar) entitlements (see `Scribe.entitlements`).
- Visual rebuild workers do NOT need to request or modify any entitlements.

## Test data

Sample transcript fixtures live at `Tests/TranscriberCoreTests/Engines/Fixtures/` and `Tests/TranscriberCoreTests/Storage/Fixtures/`. Workers may use these for unit-test assertions on rendering paths.

## Things workers commonly forget

- The Xcode project is at `TranscriberApp/Scribe.xcodeproj`, NOT at the repo root. The repo root has `Package.swift` for the core library only.
- `swift test` from the repo root only runs core-library tests. App-target tests (if any are added) require `xcodebuild test`.
- Do not commit `.dd-release/` artifacts.
- The `nonisolated(unsafe)` warnings in `AppDelegate.swift` are pre-existing and should not be "fixed" as part of a visual feature unless the orchestrator schedules it.
