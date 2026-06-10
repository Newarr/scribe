import AppKit
import SwiftUI

/// Design system primitives mirroring `scribe-design-system/colors_and_type.css`.
///
/// Source of truth for colors, typography, spacing, radii, and the
/// indicator + button primitives the design calls "global". The aesthetic
/// chosen by the designer (chat1, "Mac native + Liquid Glass + Vercel
/// soul") is monochrome glass with one slate-ink accent and one warm rust
/// signal for live recording. No emoji, no pills (always dot + mono
/// label), sentence case throughout.
///
/// Color values are translated from the design's OKLCH definitions to
/// sRGB via Apple's display-p3 color space which preserves perceptual
/// alignment closely enough for UI surfaces. Light + dark adapts via
/// `Color(NSColor(name:dynamicProvider:))`.
enum DS {

    // MARK: - Colors

    /// Token namespace. Values are precise OKLCH-to-sRGB translations of
    /// `Downloads/index.html` (the locked design reference). Dark is
    /// the canonical mode; the app forces dark at launch via
    /// `NSApp.appearance`. Light fallbacks are kept for tokens that
    /// might render in a light system context (e.g. via Quick Look).
    enum Color {
        /// Page background. Dark = pure black; light fallback white.
        static let background = adaptive(light: NSColor.white, dark: NSColor.black)

        /// `--ink (0.98 0 0)` is the design's primary white. Off-pure
        /// to avoid the harsh look of #fff on dark glass.
        static let foreground = adaptive(
            light: srgb(0.039, 0.039, 0.039),
            dark: srgb(0.974, 0.974, 0.974)
        )

        /// `--ink-2 (0.78 0 0)`.
        static let foregroundSecondary = adaptive(
            light: srgb(0.250, 0.250, 0.250),
            dark: srgb(0.718, 0.718, 0.718)
        )

        /// `--ink-3 (0.58 0 0)`.
        static let foregroundTertiary = adaptive(
            light: srgb(0.452, 0.452, 0.452),
            dark: srgb(0.479, 0.479, 0.479)
        )

        /// `--ink-4 (0.42 0 0)`. Quaternary, disabled / off states.
        static let foregroundQuaternary = adaptive(
            light: srgb(0.580, 0.580, 0.580),
            dark: srgb(0.302, 0.302, 0.302)
        )

        /// `oklch(1 0 0 / 0.025)` over the dark window. Sidebar fill,
        /// soft surfaces. Translucent white the way the design does it.
        static let backgroundSubtle = adaptive(
            light: srgbC(0.980, 0.980, 0.980),
            dark: SwiftUI.Color.white.opacity(0.025)
        )

        /// `oklch(1 0 0 / 0.06)`. Selected sidebar row, hover fills.
        static let backgroundMuted = adaptive(
            light: srgbC(0.961, 0.961, 0.961),
            dark: SwiftUI.Color.white.opacity(0.06)
        )

        /// Hover overlay, `oklch(1 0 0 / 0.04)`.
        static let backgroundOverlay = adaptive(
            light: SwiftUI.Color.black.opacity(0.04),
            dark: SwiftUI.Color.white.opacity(0.04)
        )

        /// Input/code-block fill, `oklch(0 0 0 / 0.30)`. A darker
        /// pocket inside the window's translucent shell.
        static let backgroundDeep = adaptive(
            light: srgbC(0.961, 0.961, 0.961),
            dark: SwiftUI.Color.black.opacity(0.30)
        )

        /// `oklch(0 0 0 / 0.20)`. Slightly lighter than `backgroundDeep`
        /// for the integration-list / section-card surface in the
        /// reference's `.integ-list` recipe.
        static let backgroundCard = adaptive(
            light: srgbC(0.961, 0.961, 0.961),
            dark: SwiftUI.Color.black.opacity(0.20)
        )

        /// `--line (0.08)`. Primary hairline used for borders +
        /// section separators.
        static let border = adaptive(
            light: srgbC(0.898, 0.898, 0.898),
            dark: SwiftUI.Color.white.opacity(0.08)
        )

        /// `--line ramped (0.18)`. Focus / hover stronger border.
        static let borderStrong = adaptive(
            light: srgbC(0.831, 0.831, 0.831),
            dark: SwiftUI.Color.white.opacity(0.18)
        )

        /// `--line-2 (0.04)`. Softer separator between sub-sections.
        static let borderSubtle = adaptive(
            light: srgbC(0.949, 0.949, 0.949),
            dark: SwiftUI.Color.white.opacity(0.04)
        )

        /// `oklch(1 0 0 / 0.06)`. Card border (`.integ-list` border).
        static let borderCard = adaptive(
            light: srgbC(0.929, 0.929, 0.929),
            dark: SwiftUI.Color.white.opacity(0.06)
        )

        /// `--rust (0.66 0.18 32)`. Brighter, warmer than the previous
        /// recording color. Reserved for live recording, primary
        /// accent moments (selected sidebar row), and on-toggles.
        static let recording = adaptive(
            light: srgb(0.923, 0.369, 0.272),
            dark: srgb(0.923, 0.369, 0.272)
        )

        /// `--rust-2 (0.78 0.16 32)`. Lighter rust for mono URL text
        /// and hover-on-rust accents.
        static let recordingLight = adaptive(
            light: srgb(1.000, 0.551, 0.456),
            dark: srgb(1.000, 0.551, 0.456)
        )

        /// `--green (0.74 0.15 150)`. The design's running / verified /
        /// connected status color. Brighter than typical "success".
        static let success = adaptive(
            light: srgb(0.353, 0.771, 0.464),
            dark: srgb(0.353, 0.771, 0.464)
        )

        /// `--amber (0.82 0.15 80)`.
        static let warning = adaptive(
            light: srgb(0.967, 0.721, 0.241),
            dark: srgb(0.967, 0.721, 0.241)
        )

        /// `--danger`. Kept from the previous palette. The new design
        /// reference uses warning / off colors for failure states, but
        /// destructive actions still need a true red.
        static let danger = adaptive(
            light: srgb(0.874, 0.127, 0.180),
            dark: srgb(0.874, 0.127, 0.180)
        )

        /// Slate-ink accent kept as `accent` so existing callers
        /// compile. New designs route most accents through `recording`
        /// (rust). Use `accent` for non-recording info states only.
        static let accent = adaptive(
            light: srgb(0.244, 0.395, 0.587),
            dark: srgb(0.547, 0.731, 0.967)
        )

        // Helpers for building dynamic NSColors from sRGB tuples.
        private static func srgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
            NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
        }

        /// SwiftUI.Color flavor of `srgb`. Used in adaptive() pairs
        /// where the dark side wants `Color.white.opacity(...)`.
        private static func srgbC(_ r: Double, _ g: Double, _ b: Double) -> SwiftUI.Color {
            SwiftUI.Color(red: r, green: g, blue: b)
        }

        private static func adaptive(light: NSColor, dark: NSColor) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
                return isDark ? dark : light
            })
        }

        private static func adaptive(light: SwiftUI.Color, dark: SwiftUI.Color) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
                return NSColor(isDark ? dark : light)
            })
        }
    }

    // MARK: - Typography

    /// Bundled font family names registered via `Info.plist`
    /// `ATSApplicationFontsPath`. The product spec and Pencil v1
    /// surfaces use Inter for sans text and JetBrains Mono for status,
    /// paths, timestamps, and indicators.
    static let sansFamily = "Inter Variable"
    static let monoFamily = "JetBrains Mono"
    /// Legacy alias. Points at `sansFamily` so existing `DS.interFamily`
    /// references keep compiling. Remove in a future cleanup pass.
    static let interFamily = sansFamily

    /// Type scale. Values come from `Downloads/index.html`:
    /// - panel-h1 24/600 -0.025em, panel-sub 14/400 line-height 1.55
    /// - sec h3 13/600, sec-help 12.5/400
    /// - row label 13/400, button 12.5/500
    /// - input 12/400 mono, indicator 11/500 mono tracked
    enum Font {
        /// 24/600. Section page title (the design's `panel-h1`).
        static let title = SwiftUI.Font.custom(DS.sansFamily, size: 24).weight(.semibold).leading(.tight)
        /// Legacy alias.
        static let displayDisplay = title
        /// 18/600. Kept for callers that wanted a heading between
        /// title and subheading. The design uses `subheading` at 13.
        static let heading = SwiftUI.Font.custom(DS.sansFamily, size: 18).weight(.semibold).leading(.tight)

        /// 13/600. Sub-section heading inside a section (`sec h3`).
        static let subheading = SwiftUI.Font.custom(DS.sansFamily, size: 13).weight(.semibold).leading(.tight)

        /// 14/400. Default body / description (`panel-sub`).
        static let body = SwiftUI.Font.custom(DS.sansFamily, size: 14).weight(.regular).leading(.standard)
        /// 13/500. Emphasized inline body, integration row name.
        static let bodyEmphasis = SwiftUI.Font.custom(DS.sansFamily, size: 13).weight(.medium).leading(.standard)
        /// 13/400. Row label.
        static let bodySmall = SwiftUI.Font.custom(DS.sansFamily, size: 13).weight(.regular).leading(.standard)
        /// 12.5/400. Sub-section help text (`sec-help`).
        static let caption = SwiftUI.Font.custom(DS.sansFamily, size: 12.5).weight(.regular).leading(.standard)
        /// 12/500.
        static let captionEmphasis = SwiftUI.Font.custom(DS.sansFamily, size: 12).weight(.medium).leading(.standard)

        /// 12.5/500. Button label.
        static let button = SwiftUI.Font.custom(DS.sansFamily, size: 12.5).weight(.medium)

        /// 11/500 mono. Indicator label, sub-meta, sidebar foot.
        static let eyebrow = SwiftUI.Font.custom(DS.monoFamily, size: 11).weight(.medium)
        static let monoSmall = SwiftUI.Font.custom(DS.monoFamily, size: 11).weight(.medium)
        /// 12/400 mono. Input / code-block / mono row value.
        static let monoBody = SwiftUI.Font.custom(DS.monoFamily, size: 12).weight(.regular)
    }

    // MARK: - Spacing

    /// 15-step scale matching `--space-*` tokens, in pt.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let ml: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
        static let huge: CGFloat = 40
    }

    // MARK: - Radii

    enum Radius {
        static let xs: CGFloat = 2
        static let sm: CGFloat = 4
        static let md: CGFloat = 6
        static let lg: CGFloat = 8
        static let xl: CGFloat = 12
    }
}

// MARK: - Font registration sanity check

/// Verifies the bundled fonts loaded. Call once at app launch from
/// `AppDelegate.applicationDidFinishLaunching`. The `ATSApplicationFontsPath`
/// key in `Info.plist` triggers Core Text to register fonts in `Fonts/`
/// at process start, but a missing or mistyped resource would silently
/// fall back to SF Pro, which looks "almost right" and is exactly the
/// failure mode this check exists to prevent.
enum FontRegistration {
    /// Returns the list of expected family names that did NOT register.
    /// Empty array means everything is wired up.
    static func missingFamilies() -> [String] {
        let expected = [DS.interFamily, DS.monoFamily]
        let registered = NSFontManager.shared.availableFontFamilies
        return expected.filter { !registered.contains($0) }
    }

    /// Logs a warning for each missing family. Call at launch.
    static func assertLoaded() {
        let missing = missingFamilies()
        guard !missing.isEmpty else { return }
        for family in missing {
            NSLog("[FontRegistration] family '\(family)' did not register; verify Fonts/ resources and ATSApplicationFontsPath")
        }
    }

    #if DEBUG
    /// Debug-only hook: writes a one-line JSON sentinel describing the
    /// font-registration outcome to `~/Library/Caches/com.szymonsypniewicz.transcriber/font-registration.json`.
    /// Used by build scripts and the F-1 acceptance check to confirm the
    /// bundled fonts loaded at launch without relying on log-stream parsing.
    static func writeDebugSentinel() {
        let missing = missingFamilies()
        let payload: [String: Any] = [
            "missing": missing,
            "ok": missing.isEmpty,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        guard
            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return }
        let dir = cacheDir.appendingPathComponent("com.szymonsypniewicz.transcriber", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("font-registration.json")
        try? data.write(to: url, options: [.atomic])
    }
    #endif
}
