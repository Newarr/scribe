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

// MARK: - Indicator (dot + mono uppercase label)

/// The design's canonical status primitive. A small filled dot plus a
/// short uppercase monospace label. Replaces every "filled SF Symbol" or
/// pill across the app.
struct Indicator: View {
    enum State {
        case idle
        case ready
        case live          // recording, warm rust with pulse
        case transcribing  // neutral, static
        case sent          // success, calm green with pulse
        case warning       // amber, static
        case failed        // danger, static
    }

    let state: State
    let label: String

    @SwiftUI.State private var pulse: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(pulses && pulse ? 0.55 : 1.0)
                .animation(animation, value: pulse)
                .onAppear { pulse = true }
            Text(label.uppercased())
                .font(DS.Font.eyebrow)
                .tracking(0.44)
                .foregroundStyle(color)
        }
    }

    private var color: SwiftUI.Color {
        switch state {
        case .idle:          return DS.Color.foregroundQuaternary
        case .ready:         return DS.Color.success
        case .live:          return DS.Color.recording
        case .transcribing:  return DS.Color.foregroundSecondary
        case .sent:          return DS.Color.success
        case .warning:       return DS.Color.warning
        case .failed:        return DS.Color.danger
        }
    }

    /// States that pulse the dot between full and 0.55 opacity over
    /// 1.6s. The reference `.ind-on` rule applies to RUNNING /
    /// VERIFIED / CONNECTED only, mapped to `.live` (rust), `.ready`
    /// (active green), and `.sent` (sent green). Transcribing / off /
    /// failed / warning all stay solid for legibility.
    private var pulses: Bool {
        switch state {
        case .live, .ready, .sent: return true
        default: return false
        }
    }

    private var animation: Animation? {
        guard pulses else { return nil }
        return .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
    }
}

// MARK: - Brand views

/// The 5-bar wave mark, monochrome, sized to the supplied edge length.
/// Loaded from the asset catalog's BrandMark imageset (template SVG).
struct BrandMark: View {
    let size: CGFloat
    init(size: CGFloat = 32) { self.size = size }
    var body: some View {
        Image("BrandMark")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

/// The mark + "scribe" wordmark, scaled to the supplied height.
struct BrandWordmark: View {
    let height: CGFloat
    init(height: CGFloat = 28) { self.height = height }
    var body: some View {
        Image("BrandWordmark")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(height: height)
    }
}

// MARK: - Button styles

/// Primary action. `.btn-primary` from index.html: white bg, dark
/// text. 28pt height, 11pt horizontal padding, 6pt radius.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.button)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .foregroundStyle(SwiftUI.Color(red: 0.04, green: 0.04, blue: 0.04))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(SwiftUI.Color.white)
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary. `.btn-secondary` from index.html: translucent white
/// fill `oklch(1 0 0 / 0.04)` with `oklch(1 0 0 / 0.10)` border.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.button)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .foregroundStyle(DS.Color.foreground)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(SwiftUI.Color.white.opacity(configuration.isPressed ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(SwiftUI.Color.white.opacity(configuration.isPressed ? 0.18 : 0.10), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Rust accent action button. Used for primary "do it" moments
/// (Connect a new integration, an alert's affirmative). White text on
/// rust fill.
struct RustButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.button)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .foregroundStyle(SwiftUI.Color.white)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(DS.Color.recording)
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Ghost. `.btn-ghost`: transparent, ink-2 color until hover.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.button)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .foregroundStyle(configuration.isPressed ? DS.Color.foreground : DS.Color.foregroundSecondary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(SwiftUI.Color.white.opacity(configuration.isPressed ? 0.04 : 0.0))
            )
    }
}

/// Link, text-only action with the rust-2 color, underline on press.
struct DSLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.button)
            .foregroundStyle(DS.Color.recordingLight)
            .underline(configuration.isPressed)
    }
}

/// Form input. `.txt` from index.html: 30pt height, dark transparent
/// fill `oklch(0 0 0 / 0.30)`, 1px white-alpha border, mono 12pt
/// content. Focus border switches to rust.
struct DSTextFieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .focused($focused)
            .font(DS.Font.monoBody)
            .textFieldStyle(.plain)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(SwiftUI.Color.black.opacity(0.30))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(focused ? DS.Color.recording : SwiftUI.Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

/// Danger, destructive action. Same dimensions as Primary, swap the
/// fill for `DS.Color.danger`.
struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.button)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .foregroundStyle(SwiftUI.Color.white)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(DS.Color.danger)
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Section header helper

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

// MARK: - Hover sheen (F-11)

/// Mirrors `docs/spec/design-system/btn-sheen.js`: a 120pt radial gradient
/// that follows the cursor across button surfaces. SwiftUI doesn't
/// have a CSS-variable equivalent, so the implementation tracks the
/// mouse position via `NSTrackingArea` (wrapped in
/// `NSViewRepresentable`) and feeds it into the SwiftUI overlay.
private struct MouseLocationReader: NSViewRepresentable {
    @Binding var location: CGPoint?

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.onUpdate = { location = $0 }
        return view
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {}

    final class TrackingNSView: NSView {
        var onUpdate: ((CGPoint?) -> Void)?
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseMoved(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            // Flip Y so SwiftUI overlay coordinates (origin top-left)
            // match what the gradient expects.
            onUpdate?(CGPoint(x: p.x, y: bounds.height - p.y))
        }

        override func mouseExited(with event: NSEvent) {
            onUpdate?(nil)
        }
    }
}

private struct HoverSheen: ViewModifier {
    @State private var location: CGPoint?

    func body(content: Content) -> some View {
        content
            .background(
                MouseLocationReader(location: $location)
                    .allowsHitTesting(false)
            )
            .overlay(
                Group {
                    if let p = location {
                        RadialGradient(
                            colors: [SwiftUI.Color.white.opacity(0.18), SwiftUI.Color.clear],
                            center: UnitPoint(x: 0, y: 0),
                            startRadius: 0,
                            endRadius: 120
                        )
                        .offset(x: p.x - 120, y: p.y - 120)
                        .frame(width: 240, height: 240)
                        .allowsHitTesting(false)
                        .blendMode(.plusLighter)
                    }
                }
                .clipped()
            )
    }
}

extension View {
    /// Adds the radial-cursor hover sheen the design specifies for
    /// `.btn-primary` and `.btn-secondary`. No-op on touch / non-mouse
    /// surfaces because `NSTrackingArea` only fires on hover events.
    func hoverSheen() -> some View {
        modifier(HoverSheen())
    }
}

// MARK: - Switch toggle style

/// scribe-design-system switch. `.toggle` from index.html: 30x18
/// track, 14pt white knob, rust fill when on, translucent white when
/// off, 1px hairline border, ease-out 120ms transition.
struct ScribeSwitchStyle: ToggleStyle {
    private let trackWidth: CGFloat = 30
    private let trackHeight: CGFloat = 18
    private let knobSize: CGFloat = 14
    private let inset: CGFloat = 1

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: DS.Spacing.ml) {
            configuration.label
                .layoutPriority(1)
            Spacer(minLength: DS.Spacing.s)
            switchView(isOn: configuration.isOn)
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.12)) {
                        configuration.isOn.toggle()
                    }
                }
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(configuration.isOn ? "on" : "off")
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func switchView(isOn: Bool) -> some View {
        let travel = trackWidth - knobSize - inset * 2
        ZStack(alignment: .leading) {
            Capsule()
                .fill(isOn ? DS.Color.recording : SwiftUI.Color.white.opacity(0.10))
                .frame(width: trackWidth, height: trackHeight)
                .overlay(
                    Capsule()
                        .stroke(isOn ? DS.Color.recording : SwiftUI.Color.white.opacity(0.06), lineWidth: 1)
                )
            Circle()
                .fill(SwiftUI.Color.white)
                .frame(width: knobSize, height: knobSize)
                .shadow(color: SwiftUI.Color.black.opacity(0.25), radius: 1, x: 0, y: 1)
                .offset(x: inset + (isOn ? travel : 0))
        }
        .frame(width: trackWidth, height: trackHeight)
    }
}

// MARK: - Confidential UI sharing type

/// `NSWindow.sharingType` per codex UX-4 (confidential UI must not
/// appear in screen-shared video). Release builds return `.none`;
/// DEBUG builds return `.readWrite` so screenshots and screen
/// recordings still work during development. Every Scribe-owned
/// window/popover/panel reads from here.
@MainActor
enum WindowChromeSharing {
    static var confidential: NSWindow.SharingType {
        #if DEBUG
        return .readWrite
        #else
        return .none
        #endif
    }
}

// MARK: - Liquid Glass window chrome

/// Wraps an `NSWindow`'s contents in an `NSVisualEffectView` so the
/// surface picks up system vibrancy, then strips the title bar so the
/// glass extends edge-to-edge. The SwiftUI content this hosts must use
/// `Color.clear` (or the `.glassBackground()` modifier below) for its
/// outermost background, otherwise the blur is occluded.
///
/// `material` defaults to `.windowBackground` for full windows;
/// menu-bar popovers should pass `.hudWindow` for the tighter HUD
/// vibrancy the design specifies.
@MainActor
enum WindowChrome {
    static func installGlass(
        on window: NSWindow,
        material: NSVisualEffectView.Material = .windowBackground
    ) {
        // Codex UX-4 stays satisfied: NSVisualEffectView does not
        // bypass the window's `sharingType`; the wrapper inherits the
        // window's exclusion from screen capture.
        guard let host = window.contentView else { return }

        let blur = NSVisualEffectView(frame: host.bounds)
        blur.material = material
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false

        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor)
        ])

        window.contentView = blur

        // Titlebar transparent + hidden title so glass reaches the top
        // edge. Spec requires the SwiftUI body to carry any title text
        // (the brand wordmark in PrivacyAcknowledgement, content
        // headings in Settings/Diagnostics).
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
    }
}

@MainActor
extension WindowChrome {
    /// Wraps an `NSHostingController`'s view in an `NSVisualEffectView`
    /// so an `NSPopover` reads with the same Liquid Glass treatment as
    /// the design's menu bar popover. NSPopover supplies its own
    /// system chrome but the SwiftUI host view sits ON TOP of that
    /// chrome; without a vibrancy wrapper the host occludes the blur.
    static func wrapInGlass<V: View>(
        controller: NSHostingController<V>,
        material: NSVisualEffectView.Material = .hudWindow
    ) {
        let host = controller.view
        let blur = NSVisualEffectView(frame: host.bounds)
        blur.material = material
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false

        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor)
        ])
        controller.view = blur
    }
}

/// Adds the design's 1px specular highlight to the very top edge of any
/// SwiftUI surface presented in a glass window. The gradient is
/// `white.opacity(0.08) → clear` confined to a 1pt-tall hairline,
/// matching the design preview's `.surface::before` pseudo-element.
struct GlassSpecularHighlight: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [SwiftUI.Color.white.opacity(0.08), SwiftUI.Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 1)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Backdrop for SwiftUI surfaces hosted by a glass window. Replaces
    /// the previous `.background(DS.Color.background)` calls so the
    /// `NSVisualEffectView` underneath shows through.
    func glassBackground() -> some View {
        background(SwiftUI.Color.clear)
            .overlay(GlassSpecularHighlight(), alignment: .top)
    }
}

/// Legacy: mono uppercase eyebrow above a sentence-case section name.
/// The current reference dropped this pattern in favor of plain
/// `sec h3` + optional `sec-help` (see `DSSection`). Kept available
/// for the welcome window's distinct `WELCOME` eyebrow + wordmark
/// pairing, but new section surfaces should not use it.
struct SectionEyebrow: View {
    let eyebrow: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DSEyebrow(text: eyebrow)
            Text(title)
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.foreground)
        }
    }
}

/// Standalone mono uppercase eyebrow. Same primitive as the eyebrow
/// portion of `SectionEyebrow`, factored out so list / popover surfaces
/// can drop it without forcing a paired heading.
struct DSEyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(DS.Font.eyebrow)
            .tracking(0.8)
            .foregroundStyle(DS.Color.foregroundTertiary)
    }
}

/// `.sec` from index.html. A 13/600 sentence-case heading, an optional
/// 12.5/400 ink-3 help line (capped at ~520pt for legibility), then a
/// vertical stack of rows. The top hairline border + 20pt vertical
/// padding live here so the caller just composes sections back-to-back.
struct DSSection<Content: View>: View {
    let title: String
    let help: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String, help: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.help = help
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(DS.Font.subheading)
                .foregroundStyle(DS.Color.foreground)
            if let help, !help.isEmpty {
                Text(help)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.foregroundTertiary)
                    .lineSpacing(2)
                    .frame(maxWidth: 520, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -2)
                    .padding(.bottom, 8)
            }
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DS.Color.borderSubtle)
                .frame(height: 1)
        }
    }
}

/// scribe-design-system status row. The reference designs use this
/// pattern everywhere a setting maps to a value: sentence-case label
/// on the left, mono value (or status group) right-aligned. Caller
/// supplies the trailing view so it can be plain mono text, an
/// indicator + mono label, a button, etc.
///
/// Reference `.row` is `grid-template-columns: 160px 1fr` with 18pt
/// gap and 13/400 ink-2 label. We use a 160pt minimum-width label
/// column so labels align across consecutive rows.
struct DSStatusRow<Trailing: View>: View {
    let label: String
    @ViewBuilder let trailing: () -> Trailing

    init(_ label: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.label = label
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(label)
                .font(DS.Font.bodySmall)
                .foregroundStyle(DS.Color.foregroundSecondary)
                .frame(minWidth: 160, alignment: .leading)
            trailing()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

extension DSStatusRow where Trailing == DSMonoValue {
    /// Convenience that renders a mono-text value on the right.
    /// Matches the canonical "System audio · 48 kHz" pattern.
    init(_ label: String, value: String) {
        self.label = label
        self.trailing = { DSMonoValue(value) }
    }
}

/// Right-side mono value for `DSStatusRow`. Use a `·` separator for
/// compound values: `"on · 48 kHz"`, `"3 attempts · exponential backoff"`,
/// `"since launch · 2 clients connected"`. Mono 12pt ink-3 per the
/// reference's `.sub-meta` recipe.
struct DSMonoValue: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(DS.Font.monoBody)
            .foregroundStyle(DS.Color.foregroundTertiary)
    }
}

/// `.code-block` from index.html: a dark transparent pocket holding
/// mono rust-2 text and a trailing ghost button slot. Used for URLs
/// like `scribe://localhost:7421` that the user might want to copy.
struct DSCodeBlock<Trailing: View>: View {
    let text: String
    @ViewBuilder let trailing: () -> Trailing

    init(_ text: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(DS.Font.monoBody)
                .foregroundStyle(DS.Color.recordingLight)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(SwiftUI.Color.black.opacity(0.40))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(SwiftUI.Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

extension DSCodeBlock where Trailing == EmptyView {
    init(_ text: String) {
        self.text = text
        self.trailing = { EmptyView() }
    }
}

/// scribe-design-system waveform. Decorative live indicator that sits
/// under the source label in the recording surface. Animated bars with
/// staggered heights and opacities. Not a true audio meter; for that,
/// use `LevelBar` (in `RecordingMenu.swift`).
struct DSWaveform: View {
    /// Number of bars. The reference design fits ~24 in the card.
    var bars: Int = 24
    /// Color of the bars. Defaults to the design's recording rust.
    var color: SwiftUI.Color = DS.Color.recording
    /// Track height. The bars scale within this.
    var height: CGFloat = 36

    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    bar(index: i, time: t)
                }
            }
            .frame(height: height)
        }
    }

    private func bar(index: Int, time: Double) -> some View {
        // Pseudo-random phase per bar so the waveform doesn't read as
        // a uniform sine. The combination of two cosines at different
        // frequencies gives a plausible "audio energy" look.
        let p = Double(index) * 0.37
        let h1 = (cos(time * 2.4 + p) + 1) / 2          // 0…1
        let h2 = (cos(time * 6.1 + p * 1.7) + 1) / 2    // 0…1
        let blended = (h1 * 0.65 + h2 * 0.35)
        let amplitude = 0.25 + blended * 0.75           // 0.25…1
        let alpha = 0.35 + blended * 0.65               // 0.35…1
        return Capsule()
            .fill(color.opacity(alpha))
            .frame(width: 3, height: height * CGFloat(amplitude))
    }
}

enum LucideGlyph: String {
    case alertTriangle
    case arrowUpRight
    case check
    case calendar
    case fileText
    case folder
    case info
    case settings

    var paths: String {
        switch self {
        case .alertTriangle:
            return #"<path d="M12 3l10 17H2L12 3z"/><path d="M12 10v4M12 17h0"/>"#
        case .arrowUpRight:
            return #"<path d="M7 7h10v10"/><path d="M7 17L17 7"/>"#
        case .check:
            return #"<path d="M5 12l5 5L20 7"/>"#
        case .calendar:
            return #"<path d="M8 2v4"/><path d="M16 2v4"/><rect x="3" y="4" width="18" height="18" rx="2"/><path d="M3 10h18"/>"#
        case .fileText:
            return #"<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="M16 13H8"/><path d="M16 17H8"/><path d="M10 9H8"/>"#
        case .folder:
            return #"<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7z"/>"#
        case .info:
            return #"<circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>"#
        case .settings:
            return #"<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1A1.7 1.7 0 0 0 4.6 9a1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>"#
        }
    }
}

struct LucideIcon: View {
    let glyph: LucideGlyph
    var strokeWidth: Double = 1.5

    var body: some View {
        Image(nsImage: nsImage)
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
    }

    private var nsImage: NSImage {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="\(strokeWidth)" stroke-linecap="round" stroke-linejoin="round">
        \(glyph.paths)
        </svg>
        """
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage(size: NSSize(width: 24, height: 24))
        image.isTemplate = true
        return image
    }
}

#if DEBUG
enum DebugVisualSnapshotWriter {
    enum SnapshotError: LocalizedError {
        case renderFailed(String)

        var errorDescription: String? {
            switch self {
            case .renderFailed(let name): return "Failed to render \(name)"
            }
        }
    }

    @MainActor
    static func write<V: View>(
        _ view: V,
        named name: String,
        to directory: URL,
        scale: CGFloat = 2
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.nsImage else {
            throw SnapshotError.renderFailed(name)
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.renderFailed(name)
        }
        try png.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }
}
#endif
