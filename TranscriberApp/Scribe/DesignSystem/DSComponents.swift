import AppKit
import SwiftUI

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

// MARK: - Section header helper

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
