# Slice 0 — Project Scaffolding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a working SwiftPM workspace + Xcode app project so every later slice has a tested compiler, a stable bundle identifier (for macOS permissions), and a menu-bar runtime to attach features to.

**Architecture:** Pure SwiftPM library `TranscriberCore` (all business logic, fully unit-tested), separate Xcode project `TranscriberApp.xcodeproj` for the macOS menu-bar app target (links `TranscriberCore` as a local SwiftPM dependency). Unit tests live with the library; the App target stays a thin shell.

**Tech Stack:** Swift 6, macOS 15+, SwiftPM, Xcode 16, XCTest, `os.Logger`. No third-party deps in this slice.

**Why this structure:** Apple's signing/entitlements/permission model is bundle-keyed. Without an Xcode-managed bundle identifier, every `swift run` is a fresh permission prompt. The library-in-SwiftPM, app-in-Xcode split is what Apple's docs recommend for macOS apps that want testable cores; OpenOats and other production apps follow it.

---

## File Structure

After this slice:

```
transcriber/
  Package.swift                                            # SwiftPM manifest
  Sources/
    TranscriberCore/
      BuildInfo.swift                                      # Version sentinel
      Logging.swift                                        # os.Logger categories
  Tests/
    TranscriberCoreTests/
      BuildInfoTests.swift
      LoggingTests.swift
  TranscriberApp/                                          # Xcode project root
    TranscriberApp.xcodeproj/
    TranscriberApp/
      TranscriberApp.swift                                 # @main entry point
      AppDelegate.swift                                    # Menu-bar lifecycle
      Info.plist                                           # LSUIElement, bundle ID
      TranscriberApp.entitlements                          # Mic + screen capture (later slices)
  README.md                                                # Updated with build/run instructions
  .gitignore                                               # Xcode + SwiftPM
```

`TranscriberCore` is the unit of test discipline. `TranscriberApp` exists only to host the runtime and link `TranscriberCore`. The split forces business logic out of the App target.

---

## Task 1: SwiftPM manifest + library target

**Files:**
- Create: `Package.swift`
- Create: `Sources/TranscriberCore/BuildInfo.swift`
- Create: `Tests/TranscriberCoreTests/BuildInfoTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/TranscriberCoreTests/BuildInfoTests.swift`:

```swift
import XCTest
@testable import TranscriberCore

final class BuildInfoTests: XCTestCase {
    func testVersionIsSemver() {
        let v = BuildInfo.version
        let parts = v.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "version must be semver: MAJOR.MINOR.PATCH")
        for part in parts {
            XCTAssertNotNil(Int(part), "each component must be numeric: \(v)")
        }
    }

    func testNameIsTranscriber() {
        XCTAssertEqual(BuildInfo.appName, "Transcriber")
    }
}
```

- [ ] **Step 2: Create Package.swift**

`Package.swift`:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TranscriberCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TranscriberCore", targets: ["TranscriberCore"])
    ],
    targets: [
        .target(name: "TranscriberCore", path: "Sources/TranscriberCore"),
        .testTarget(
            name: "TranscriberCoreTests",
            dependencies: ["TranscriberCore"],
            path: "Tests/TranscriberCoreTests"
        )
    ]
)
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter BuildInfoTests`
Expected: FAIL with "cannot find 'BuildInfo' in scope" (file doesn't exist yet).

- [ ] **Step 4: Write minimal implementation**

`Sources/TranscriberCore/BuildInfo.swift`:

```swift
public enum BuildInfo {
    public static let appName = "Transcriber"
    public static let version = "0.0.1"
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter BuildInfoTests`
Expected: PASS, both test methods green.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/TranscriberCore/BuildInfo.swift Tests/TranscriberCoreTests/BuildInfoTests.swift
git commit -m "scaffold: SwiftPM TranscriberCore library + BuildInfo sentinel"
```

---

## Task 2: Logging primitives

**Files:**
- Create: `Sources/TranscriberCore/Logging.swift`
- Create: `Tests/TranscriberCoreTests/LoggingTests.swift`

The spec requires "lifecycle events only (prompted, started, stopped, failed, provider used). No transcript, audio, or calendar content in logs." We need a single source of truth for log categories so individual subsystems can't accidentally log into a category that exports content.

- [ ] **Step 1: Write the failing test**

`Tests/TranscriberCoreTests/LoggingTests.swift`:

```swift
import XCTest
import os
@testable import TranscriberCore

final class LoggingTests: XCTestCase {
    func testSubsystemIsBundleStyle() {
        XCTAssertEqual(Log.subsystem, "com.szymonsypniewicz.transcriber")
    }

    func testCategoriesEnumerated() {
        let expected: Set<String> = [
            "lifecycle", "capture", "engine", "calendar",
            "permissions", "storage", "diagnostics"
        ]
        XCTAssertEqual(Set(Log.categories), expected)
    }

    func testEachCategoryHasLogger() {
        XCTAssertNotNil(Log.lifecycle)
        XCTAssertNotNil(Log.capture)
        XCTAssertNotNil(Log.engine)
        XCTAssertNotNil(Log.calendar)
        XCTAssertNotNil(Log.permissions)
        XCTAssertNotNil(Log.storage)
        XCTAssertNotNil(Log.diagnostics)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LoggingTests`
Expected: FAIL — `Log` type undefined.

- [ ] **Step 3: Write implementation**

`Sources/TranscriberCore/Logging.swift`:

```swift
import os

public enum Log {
    public static let subsystem = "com.szymonsypniewicz.transcriber"

    public static let lifecycle    = Logger(subsystem: subsystem, category: "lifecycle")
    public static let capture      = Logger(subsystem: subsystem, category: "capture")
    public static let engine       = Logger(subsystem: subsystem, category: "engine")
    public static let calendar     = Logger(subsystem: subsystem, category: "calendar")
    public static let permissions  = Logger(subsystem: subsystem, category: "permissions")
    public static let storage      = Logger(subsystem: subsystem, category: "storage")
    public static let diagnostics  = Logger(subsystem: subsystem, category: "diagnostics")

    public static let categories: [String] = [
        "lifecycle", "capture", "engine", "calendar",
        "permissions", "storage", "diagnostics"
    ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LoggingTests`
Expected: PASS, all three test methods green.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriberCore/Logging.swift Tests/TranscriberCoreTests/LoggingTests.swift
git commit -m "scaffold: Log primitives with enumerated categories"
```

---

## Task 3: .gitignore

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Write `.gitignore`**

```gitignore
# SwiftPM
.build/
Package.resolved
.swiftpm/

# Xcode
*.xcuserdata/
*.xcuserdatad/
xcuserdata/
*.xcworkspace/xcuserdata/
DerivedData/

# macOS
.DS_Store
```

- [ ] **Step 2: Verify nothing critical is now ignored**

Run: `git status --ignored | head -30`
Expected: Confirms `.build/`, `.swiftpm/`, `Package.resolved` would be ignored if present, but `Package.swift`, `Sources/`, `Tests/` are not affected.

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "scaffold: gitignore for SwiftPM and Xcode"
```

---

## Task 4: Xcode project for app target

**Files:**
- Create: `TranscriberApp/TranscriberApp.xcodeproj/...` (generated by Xcode)
- Create: `TranscriberApp/TranscriberApp/TranscriberApp.swift`
- Create: `TranscriberApp/TranscriberApp/AppDelegate.swift`
- Create: `TranscriberApp/TranscriberApp/Info.plist`
- Create: `TranscriberApp/TranscriberApp/TranscriberApp.entitlements`

This task is partly UI-driven in Xcode. Capture the manual steps with explicit Xcode menu paths so they're reproducible.

- [ ] **Step 1: Create the Xcode project via the IDE**

In Xcode → File → New → Project → macOS → App.
- Product Name: `TranscriberApp`
- Team: select your developer team (or "None" for now)
- Organization Identifier: `com.szymonsypniewicz`
- Bundle Identifier (auto-derived): `com.szymonsypniewicz.transcriber`
  - **Important:** Must match `Log.subsystem` from Task 2.
- Interface: SwiftUI
- Language: Swift
- Storage: None
- Tests: unchecked (we already have an XCTest target via SwiftPM)

Save inside `transcriber/TranscriberApp/`. The resulting layout:
```
TranscriberApp/
  TranscriberApp.xcodeproj/
  TranscriberApp/
    TranscriberApp.swift
    ContentView.swift
    Assets.xcassets/
    Preview Content/
    TranscriberApp.entitlements
```

- [ ] **Step 2: Set the bundle identifier**

In Xcode → TranscriberApp target → Signing & Capabilities tab.
- Bundle Identifier: `com.szymonsypniewicz.transcriber` (must match `Log.subsystem`).
- Team: your developer team.
- Signing Certificate: Development.

- [ ] **Step 3: Add LSUIElement to Info.plist**

In Xcode → TranscriberApp target → Info tab → Custom macOS Application Target Properties → add row:
- Key: `Application is agent (UIElement)` (raw key: `LSUIElement`)
- Type: Boolean
- Value: YES

This makes the app menu-bar-only (no Dock icon, no menu bar app menu).

- [ ] **Step 4: Link TranscriberCore as local SwiftPM package**

In Xcode → File → Add Package Dependencies → Add Local… → select the parent `transcriber/` folder.
Add `TranscriberCore` library to the TranscriberApp target.

Verify in `Package.swift`-derived dependencies that the link is resolved (Xcode left sidebar shows "Package Dependencies → TranscriberCore").

- [ ] **Step 5: Replace `ContentView.swift` with a minimal menu-bar runtime**

Delete `ContentView.swift`. Replace `TranscriberApp.swift` with:

```swift
import SwiftUI
import TranscriberCore

@main
struct TranscriberAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }   // App with no windows; menu bar is the UI
    }
}
```

Create `AppDelegate.swift`:

```swift
import AppKit
import TranscriberCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.lifecycle.info("App launched, version=\(BuildInfo.version, privacy: .public)")

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "T"
        item.menu = makeMenu()
        statusItem = item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "\(BuildInfo.appName) \(BuildInfo.version)",
            action: nil,
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        return menu
    }
}
```

- [ ] **Step 6: Build and run**

In Xcode → Product → Run (⌘R).
Expected:
- No window appears.
- Menu bar shows "T" status item.
- Click → dropdown shows "Transcriber 0.0.1" and "Quit".
- Console (View → Debug Area → Activate Console) shows: `App launched, version=0.0.1`.

- [ ] **Step 7: Verify logs flow into the unified log**

Open Console.app (in /Applications/Utilities/) → search for `subsystem:com.szymonsypniewicz.transcriber`.
Expected: `App launched, version=0.0.1` from the lifecycle category visible.

- [ ] **Step 8: Commit**

```bash
git add TranscriberApp/
git commit -m "scaffold: TranscriberApp Xcode project with menu-bar status item"
```

---

## Task 5: README

**Files:**
- Modify: `README.md` (full rewrite — current content is the spec workspace overview, which is now in `docs/`)

- [ ] **Step 1: Update README**

`README.md`:

```markdown
# Transcriber

Menu-bar macOS app that captures meeting audio (mic + system) and produces high-fidelity markdown transcripts via ElevenLabs Scribe v2 or Cohere Transcribe (local).

> Spec: `docs/SPEC.md` · Open questions: `docs/QUESTIONS.md` · Implementation roadmap: `docs/superpowers/plans/2026-04-29-MASTER-ROADMAP.md`

## Build

Requires macOS 15+, Xcode 16, Swift 6.

### Library + tests

\`\`\`bash
swift build
swift test
\`\`\`

### App

Open `TranscriberApp/TranscriberApp.xcodeproj` in Xcode and Product → Run.

The first launch will prompt for microphone and screen-recording permissions on later slices once capture is wired up. Bundle identifier is `com.szymonsypniewicz.transcriber`.

## Architecture

- `TranscriberCore` — pure-Swift library, no AppKit. All business logic, all unit-tested.
- `TranscriberApp` — Xcode app target. Thin shell: lifecycle, menu bar, permission flows.

Slices ship from `docs/superpowers/plans/`. See `MASTER-ROADMAP.md` for the slice list.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "scaffold: README with build instructions and architecture notes"
```

---

## Task 6: GitHub Actions CI

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the workflow**

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.app
      - name: Build core
        run: swift build
      - name: Test core
        run: swift test --enable-code-coverage
      - name: Build app
        run: |
          xcodebuild \
            -project TranscriberApp/TranscriberApp.xcodeproj \
            -scheme TranscriberApp \
            -configuration Debug \
            -destination 'platform=macOS' \
            build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```

- [ ] **Step 2: Commit and push**

```bash
git add .github/workflows/ci.yml
git commit -m "scaffold: GitHub Actions CI for swift test + xcodebuild"
git push origin main
```

- [ ] **Step 3: Verify CI runs green**

Check `https://github.com/Newarr/transcriber/actions`. Expected: green checkmark on the latest commit.

If red: fix and push again. Do not move to Slice 1 with red CI.

---

## Task 7: Slice acceptance check

- [ ] **Step 1: Local acceptance**

```bash
swift test
```
Expected: 5+ tests pass (BuildInfo: 2, Logging: 3, plus any added).

In Xcode: ⌘R, menu bar shows "T", click → "Transcriber 0.0.1" and "Quit" visible.

- [ ] **Step 2: Update master roadmap status**

Edit `docs/superpowers/plans/2026-04-29-MASTER-ROADMAP.md`:
- Change Slice 0 status row to: `0 | ✅ ... | — | shipped YYYY-MM-DD`

- [ ] **Step 3: Commit and push**

```bash
git add docs/superpowers/plans/2026-04-29-MASTER-ROADMAP.md
git commit -m "roadmap: Slice 0 shipped"
git push origin main
```

- [ ] **Step 4: Tag a build**

```bash
git tag -a v0.0.1-slice-0 -m "Slice 0: scaffolding"
git push origin v0.0.1-slice-0
```

---

## Definition of done for Slice 0

- [ ] `swift test` passes locally with at least 5 green tests.
- [ ] `xcodebuild` builds the app target without code signing.
- [ ] CI passes on push to main.
- [ ] Running the app shows a menu-bar item, click reveals "Transcriber 0.0.1" and "Quit".
- [ ] Console.app shows the launch log under `subsystem:com.szymonsypniewicz.transcriber`.
- [ ] README explains how to build and run.
- [ ] `MASTER-ROADMAP.md` Slice 0 row marked shipped.

When all checked, this slice is done. Start Slice 1.
