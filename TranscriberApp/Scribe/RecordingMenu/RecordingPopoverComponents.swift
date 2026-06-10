import AppKit
import SwiftUI
import TranscriberCore

struct RecordingPopoverPalette {
  let colorScheme: ColorScheme

  var isDark: Bool { colorScheme == .dark }

  var surfaceBase: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 7 / 255, green: 1 / 255, blue: 3 / 255)
      : SwiftUI.Color(red: 245 / 255, green: 247 / 255, blue: 250 / 255)
  }

  var surfaceCoolTint: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 77 / 255, green: 13 / 255, blue: 26 / 255).opacity(0.50)
      : SwiftUI.Color(red: 220 / 255, green: 234 / 255, blue: 251 / 255).opacity(0.50)
  }

  var surfaceWarmTint: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 92 / 255, green: 28 / 255, blue: 18 / 255).opacity(0.40)
      : SwiftUI.Color(red: 255 / 255, green: 224 / 255, blue: 214 / 255).opacity(0.40)
  }

  var controlFill: SwiftUI.Color {
    isDark
      ? SwiftUI.Color.white.opacity(11 / 255)
      : SwiftUI.Color.white.opacity(102 / 255)
  }

  var controlStroke: SwiftUI.Color {
    isDark
      ? SwiftUI.Color.white.opacity(26 / 255)
      : SwiftUI.Color.black.opacity(16 / 255)
  }

  var badgeFill: SwiftUI.Color {
    isDark
      ? SwiftUI.Color.white.opacity(18 / 255)
      : SwiftUI.Color.black.opacity(8 / 255)
  }

  var hoverFill: SwiftUI.Color {
    isDark
      ? SwiftUI.Color.white.opacity(0.055)
      : SwiftUI.Color.black.opacity(0.055)
  }

  var outerStroke: SwiftUI.Color {
    isDark
      ? SwiftUI.Color.white.opacity(26 / 255)
      : SwiftUI.Color.black.opacity(18 / 255)
  }

  var buttonStroke: SwiftUI.Color {
    isDark
      ? SwiftUI.Color.white.opacity(26 / 255)
      : SwiftUI.Color.black.opacity(31 / 255)
  }

  var dividerLine: SwiftUI.Color {
    isDark
      ? SwiftUI.Color.white.opacity(15 / 255)
      : SwiftUI.Color.black.opacity(10 / 255)
  }

  var line: SwiftUI.Color {
    isDark
      ? SwiftUI.Color.white.opacity(24 / 255)
      : SwiftUI.Color.black.opacity(20 / 255)
  }

  var text: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255)
      : SwiftUI.Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)
  }

  var secondaryText: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 184 / 255, green: 184 / 255, blue: 184 / 255)
      : SwiftUI.Color(red: 71 / 255, green: 71 / 255, blue: 71 / 255)
  }

  var tertiaryText: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 122 / 255, green: 122 / 255, blue: 122 / 255)
      : SwiftUI.Color(red: 107 / 255, green: 107 / 255, blue: 107 / 255)
  }

  var metaText: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 122 / 255, green: 122 / 255, blue: 122 / 255)
      : SwiftUI.Color(red: 140 / 255, green: 135 / 255, blue: 129 / 255)
  }

  var badgeText: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 184 / 255, green: 184 / 255, blue: 184 / 255)
      : SwiftUI.Color(red: 117 / 255, green: 111 / 255, blue: 104 / 255)
  }

  var live: SwiftUI.Color { SwiftUI.Color(red: 235 / 255, green: 94 / 255, blue: 69 / 255) }
  var ready: SwiftUI.Color { SwiftUI.Color(red: 89 / 255, green: 196 / 255, blue: 117 / 255) }
  var warning: SwiftUI.Color { SwiftUI.Color(red: 247 / 255, green: 184 / 255, blue: 61 / 255) }
  var neutralStatus: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 122 / 255, green: 122 / 255, blue: 122 / 255)
      : SwiftUI.Color(red: 128 / 255, green: 122 / 255, blue: 117 / 255)
  }
  var shadow: SwiftUI.Color { SwiftUI.Color.black.opacity(isDark ? 89 / 255 : 20 / 255) }
  var shadowRadius: CGFloat { isDark ? 18 : 16 }
  var shadowYOffset: CGFloat { isDark ? 8 : 6 }
  var waveformBar: SwiftUI.Color { isDark ? SwiftUI.Color.white : SwiftUI.Color.black }
  var primaryButtonFill: SwiftUI.Color { text }
  var primaryButtonText: SwiftUI.Color {
    isDark ? SwiftUI.Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255) : SwiftUI.Color.white
  }
  var activePrimaryButtonText: SwiftUI.Color {
    isDark ? SwiftUI.Color(red: 18 / 255, green: 18 / 255, blue: 19 / 255) : SwiftUI.Color.white
  }
}

struct PopoverSurfaceBackground: View {
  let palette: RecordingPopoverPalette

  var body: some View {
    ZStack {
      palette.surfaceBase
      RadialGradient(
        colors: [palette.surfaceCoolTint, SwiftUI.Color.clear],
        center: UnitPoint(x: 0.75, y: 0.06),
        startRadius: 0,
        endRadius: 440
      )
      RadialGradient(
        colors: [palette.surfaceWarmTint, SwiftUI.Color.clear],
        center: UnitPoint(x: 0.03, y: 0.01),
        startRadius: 0,
        endRadius: 380
      )
    }
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

struct StatusBadge: View {
  let text: String
  let color: SwiftUI.Color
  var body: some View {
    HStack(spacing: 7) {
      Circle().fill(color).frame(width: 8, height: 8)
      Text(text)
        .font(SwiftUI.Font.custom(DS.monoFamily, size: 13).weight(.medium))
        .tracking(1.5)
        .foregroundStyle(color)
    }
  }
}

struct MenuHeaderMark: Shape {
  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / 18
    let xOffset = rect.midX - 9 * scale
    let yOffset = rect.midY - 9 * scale

    func scaledRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
      CGRect(
        x: xOffset + x * scale,
        y: yOffset + y * scale,
        width: width * scale,
        height: height * scale
      )
    }

    var path = Path()
    let corner = CGSize(width: 0.8 * scale, height: 0.8 * scale)
    path.addRoundedRect(in: scaledRect(x: 3.0, y: 6.0, width: 2.0, height: 6.0), cornerSize: corner)
    path.addRoundedRect(
      in: scaledRect(x: 6.5, y: 3.0, width: 2.0, height: 12.0), cornerSize: corner)
    path.addRoundedRect(
      in: scaledRect(x: 10.0, y: 5.0, width: 2.0, height: 8.0), cornerSize: corner)
    path.addRoundedRect(
      in: scaledRect(x: 13.0, y: 7.0, width: 2.0, height: 4.0), cornerSize: corner)
    return path
  }
}

struct CompactAudioActivity: View {
  let micLevel: Float
  let systemLevel: Float
  let palette: RecordingPopoverPalette

  var body: some View {
    HStack(spacing: 8) {
      ChannelActivityMark(
        label: "MIC",
        accessibilityLabel: "Microphone level",
        level: micLevel,
        palette: palette
      )
      ChannelActivityMark(
        label: "SYS",
        accessibilityLabel: "System audio level",
        level: systemLevel,
        palette: palette
      )
    }
    .padding(.horizontal, 9)
    .frame(height: 28)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(palette.controlFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(palette.controlStroke, lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
  }
}

private struct ChannelActivityMark: View {
  let label: String
  let accessibilityLabel: String
  let level: Float
  let palette: RecordingPopoverPalette

  private var normalizedLevel: Double {
    min(1, max(0, Double(level)))
  }

  private var isSilent: Bool {
    normalizedLevel <= 0.01
  }

  private var stateText: String {
    isSilent ? "silent" : "active"
  }

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(isSilent ? palette.warning : palette.ready)
        .frame(width: 6, height: 6)
      Text(label)
        .font(SwiftUI.Font.custom(DS.monoFamily, size: 10).weight(.semibold))
        .tracking(1.0)
        .foregroundStyle(isSilent ? palette.warning : palette.metaText)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue("\(stateText), \(Int((normalizedLevel * 100).rounded())) percent")
    .help("\(label) \(stateText)")
  }
}

struct AnimatedWaveform: View {
  let palette: RecordingPopoverPalette
  let isAnimating: Bool
  let isActive: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let barHeights: [CGFloat] = [
    18, 22, 28, 24, 34, 46, 58, 66, 54, 88,
    108, 78, 68, 76, 56, 38, 34, 38, 54, 46,
    32, 36, 46, 60, 78, 58, 74, 64, 60, 66,
    96, 88, 80, 56, 48, 42, 34, 30, 24, 18,
  ]

  var body: some View {
    if isAnimating && !reduceMotion {
      TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
        bars(time: timeline.date.timeIntervalSinceReferenceDate)
      }
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    } else {
      bars(time: nil)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
  }

  private func bars(time: TimeInterval?) -> some View {
    HStack(alignment: .center, spacing: 3) {
      ForEach(barHeights.indices, id: \.self) { i in
        Capsule()
          .fill(palette.waveformBar.opacity(barOpacity(at: i) * (isActive ? 1 : 0.42)))
          .frame(width: 4, height: barHeight(at: i, time: time))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func barHeight(at index: Int, time: TimeInterval?) -> CGFloat {
    let base = barHeights[index]
    guard let time else { return base }
    let phase = Double(index) * 0.23
    let wave = sin(time * 3.1 + phase)
    let scale = 1.03 + CGFloat(wave) * 0.17
    return min(118, max(10, base * scale))
  }

  private func barOpacity(at index: Int) -> Double {
    let edge = min(index, barHeights.count - 1 - index)
    return edge < 5 ? 0.16 + Double(edge) * 0.10 : 0.68
  }
}

struct PrimaryPopoverButtonStyle: ButtonStyle {
  let palette: RecordingPopoverPalette
  var textColor: SwiftUI.Color?

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(DS.Font.button)
      .foregroundStyle(textColor ?? palette.primaryButtonText)
      .padding(.horizontal, 15)
      .frame(height: 32)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(
          palette.primaryButtonFill.opacity(configuration.isPressed ? 0.82 : 1)))
  }
}

struct SecondaryPopoverButtonStyle: ButtonStyle {
  let palette: RecordingPopoverPalette

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(DS.Font.button)
      .foregroundStyle(palette.text)
      .padding(.horizontal, 15)
      .frame(height: 32)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(
          configuration.isPressed ? palette.hoverFill : SwiftUI.Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(
          palette.buttonStroke, lineWidth: 1))
  }
}

struct GhostPopoverButtonStyle: ButtonStyle {
  let palette: RecordingPopoverPalette

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(DS.Font.button)
      .foregroundStyle(configuration.isPressed ? palette.text : palette.secondaryText)
      .padding(.horizontal, 16)
      .frame(height: 32)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(
          configuration.isPressed ? palette.hoverFill : SwiftUI.Color.clear))
  }
}

struct IconButtonStyle: ButtonStyle {
  let palette: RecordingPopoverPalette

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(configuration.isPressed ? palette.text : palette.tertiaryText)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(configuration.isPressed ? palette.controlFill : SwiftUI.Color.clear)
      )
  }
}

/// Single row in the recents list. Matches the canonical menu-rows
/// preview: 24x24 mono initial badge, sentence-case title, mono
/// sub-label with separator dots, right-aligned mono duration and
/// relative time. Folder and transcript actions are visible inline.
/// Failed sessions expose inline retry/repair controls so recovery
/// stays visible without relying on Finder or a context menu.
struct MenuRow: View {
  let entry: SessionFolderEnumerator.Entry
  let onRetry: (URL) -> Void
  let onRepair: (URL) -> Void
  let localModelReadyForRetry: Bool?
  @State private var hovering: Bool = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let palette = RecordingPopoverPalette(colorScheme: colorScheme)
    HStack(alignment: .center, spacing: 10) {
      badge(palette: palette)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title)
          .font(DS.Font.bodySmall)
          .foregroundStyle(palette.text)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(subline)
          .font(DS.Font.monoSmall)
          .tracking(0.1)
          .foregroundStyle(palette.metaText)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Text(relativeTime)
        .font(DS.Font.monoSmall)
        .tracking(0.25)
        .foregroundStyle(palette.metaText)

      recentIconButton(
        glyph: .folder,
        label: "Open Folder",
        palette: palette,
        action: openFolder
      )
      recentIconButton(
        glyph: .fileText,
        label: "Open Transcript",
        palette: palette,
        action: openTranscript
      )

      recentActionButton(palette: palette)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(hovering ? palette.hoverFill : SwiftUI.Color.clear)
    )
    .onHover { hovering = $0 }
  }

  private func recentIconButton(
    glyph: LucideGlyph,
    label: String,
    palette: RecordingPopoverPalette,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      LucideIcon(glyph: glyph)
        .frame(width: 14, height: 14)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(IconButtonStyle(palette: palette))
    .help(label)
    .accessibilityLabel(label)
  }

  @ViewBuilder
  private func recentActionButton(palette: RecordingPopoverPalette) -> some View {
    switch SessionRepairRouting.recentAction(for: entry, localModelReady: localModelReadyForRetry) {
    case .retry(let sessionDirectory):
      Button("Retry") { onRetry(sessionDirectory) }
        .buttonStyle(SecondaryPopoverButtonStyle(palette: palette))
    case .repair(let payload):
      Button("Repair") { onRepair(payload.sessionDirectory) }
        .buttonStyle(SecondaryPopoverButtonStyle(palette: palette))
    case .loading:
      Button("Checking…") {}
        .buttonStyle(SecondaryPopoverButtonStyle(palette: palette))
        .disabled(true)
    case .none:
      EmptyView()
    }
  }

  private func openTranscript() {
    NSWorkspace.shared.open(entry.transcript)
  }

  private func openFolder() {
    NSWorkspace.shared.open(entry.directory)
  }

  /// 24x24 rounded square with a single mono initial: Z for Zoom,
  /// M for Meet, etc. Inferred from the title's first letter (best
  /// effort; opaque enough for the empty / unknown case). Reference:
  /// `.integ-row .mark` is 24x24, 5pt radius, mono 11/600.
  private func badge(palette: RecordingPopoverPalette) -> some View {
    RoundedRectangle(cornerRadius: 5)
      .fill(palette.badgeFill)
      .overlay(
        Text(initial)
          .font(SwiftUI.Font.custom(DS.monoFamily, size: 11).weight(.semibold))
          .tracking(0.1)
          .foregroundStyle(palette.badgeText)
      )
      .frame(width: 24, height: 24)
  }

  private var initial: String {
    let trimmed = entry.title.trimmingCharacters(in: .whitespaces)
    return String(trimmed.first.map { Character($0.uppercased()) } ?? "S")
  }

  /// Mono sub-label with separator dots: status and duration if
  /// known. The design preview uses this slot for "zoom · 3
  /// speakers" but we don't capture per-meeting speaker counts yet,
  /// so stick to status for now.
  private var subline: String {
    switch entry.status {
    case .complete: return "saved"
    case .pending: return "pending"
    case .retrying: return "retrying"
    case .failed: return entry.hasSavedAudio ? "failed · audio saved" : "failed · repair needed"
    }
  }

  // Formatter construction loads locale data; one shared instance instead
  // of one per row per render of the popover. Only touched from MainActor
  // view bodies.
  private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  private var relativeTime: String {
    Self.relativeTimeFormatter
      .localizedString(for: entry.createdAt, relativeTo: Date())
      .replacingOccurrences(of: ".", with: "")
      .uppercased()
  }
}
