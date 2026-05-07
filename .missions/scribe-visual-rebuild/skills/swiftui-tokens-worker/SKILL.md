---
name: swiftui-tokens-worker
description: Audits and gap-fills the DesignSystem.swift token layer against the official Scribe Design System CSS reference. Adds Inter font registration verification, missing tokens, and unit tests for token resolution.
---

# Worker procedure: swiftui-tokens-worker

You are a Swift / SwiftUI worker. You work in `/Users/szymonsypniewicz/Documents/code/scribe`.

## Read first

1. `.missions/scribe-visual-rebuild/AGENTS.md` — boundaries, voice, conventions.
2. `.missions/scribe-visual-rebuild/library/architecture.md` — surface inventory.
3. `.missions/scribe-visual-rebuild/library/design-tokens.md` — token reference summary.
4. `.missions/scribe-visual-rebuild/design-reference/colors_and_type.css` — authoritative source.
5. `TranscriberApp/Scribe/DesignSystem.swift` — the existing 1012-line token layer.
6. `TranscriberApp/Scribe/Fonts/` — bundled fonts.

## Procedure

### Step 1: Audit existing tokens

Cross-reference every token in `colors_and_type.css` against `DesignSystem.swift`. Produce a gap list (write it to `.missions/scribe-visual-rebuild/contract-work/tokens-gap-list.md` if helpful for your own bookkeeping). Categories:

- Colors: `--bg`, `--bg-subtle`, `--fg-1` through `--fg-4`, `--border`, `--border-strong`, `--accent`, `--live-dot`, `--live-dot-glow`, `--recording`, `--success`, `--warning`, `--danger`, plus indicator-state colors.
- Type: font registration, type scale (2xs through 8xl), weights, line heights, letter spacings.
- Spacing: 0 through 15.
- Radii: xs through 2xl, full.
- Shadows: xs, sm, md, lg, xl, menu, inset.
- Motion: ease-out, ease-in-out, ease-spring, durations (instant, fast, base, slow, slower).

### Step 2: Add missing tokens

For any token missing from `DS.*`, ADD it. Do NOT rename existing tokens unless they're clearly wrong. OKLCH→sRGB conversion uses the same approach the existing file uses (display-p3 colorspace; check `DS.adaptive` and `DS.Color` helpers).

### Step 3: Verify Inter font registration

Open `DesignSystem.swift` and find `FontRegistration` (line ~499). Verify it registers `InterVariable.ttf` and `InterVariable-Italic.ttf` at app launch. If it doesn't, add it. The registration must happen before any view that uses Inter is rendered.

Verify that `DS.Typography.body`, `DS.Typography.h1`, etc., return Font instances backed by Inter. If any return `.system(...)`, fix them to use `Font.custom("Inter", size: ...)` or the variable-axis equivalent.

### Step 4: Add unit tests

Add tests under `Tests/TranscriberCoreTests/` (or a new `Tests/ScribeAppTests/` if you wire one up). At minimum:

```swift
// Example shape — adapt to the existing test conventions in the repo
final class DesignSystemTokenTests: XCTestCase {
    func testLiveDotColorMatchesDesignReference() {
        // Reference: oklch(0.55 0.14 35) ≈ sRGB(186, 92, 64) (rough)
        // Allow ΔE<2 in the comparison
    }
    func testAccentColorMatchesDesignReference() {
        // Reference: oklch(0.50 0.09 255)
    }
    func testInterIsRegistered() {
        XCTAssertNotNil(NSFont(name: "Inter", size: 14))
    }
}
```

ΔE<2 comparison: convert both to LAB and compute Euclidean distance. Use `NSColor.usingColorSpace(.deviceRGB)` to extract components, then run a simple LAB conversion. If you don't want to write a LAB converter, accept `XCTAssertEqual(red, expectedRed, accuracy: 0.02)` per channel — that's a reasonable proxy.

### Step 5: Verify

Run:
```
swift test --package-path /Users/szymonsypniewicz/Documents/code/scribe
xcodebuild -project /Users/szymonsypniewicz/Documents/code/scribe/TranscriberApp/Scribe.xcodeproj -scheme Scribe -destination 'platform=macOS' -configuration Debug build
```

Both must pass. Total tests must be ≥253 + however many you added.

### Step 6: Commit

Commit your changes. Include the commit ID in your handoff.

## Handoff requirements

Return:
- `successState`: `success` / `partial` / `failure`
- `featureId`: `tokens-foundation`
- `commitId`, `repoPath`
- `summary`: 2-3 sentences of what changed
- `tokensAdded`: list of new `DS.*` token names
- `testsAdded`: list of new XCTest case names
- `discoveredIssues`: any spec ambiguities or pre-existing bugs you noticed
- `whatWasLeftUndone`: tasks you couldn't complete and why

Do NOT begin downstream work (popover, panes, etc.) — that's other workers' jobs.
