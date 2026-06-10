import AppKit
import SwiftUI

enum FidelitySettings {
  static let windowWidth: CGFloat = 880
  static let windowHeight: CGFloat = 600
  static let sideWidth: CGFloat = 200
  static let mainWidth: CGFloat = windowWidth - sideWidth - 1
  static let headerHeight: CGFloat = 38
  static let rowLabelWidth: CGFloat = 160
  static let rowGap: CGFloat = 18

  static let font = "Inter Variable"
  static let rust = SwiftUI.Color(red: 235 / 255, green: 94 / 255, blue: 69 / 255)
  static let green = SwiftUI.Color(red: 89 / 255, green: 196 / 255, blue: 117 / 255)
  static let amber = SwiftUI.Color(red: 247 / 255, green: 184 / 255, blue: 61 / 255)
  static let surfaceWarmTint = adaptive(
    dark: NSColor(calibratedRed: 92 / 255, green: 28 / 255, blue: 18 / 255, alpha: 1.0),
    light: NSColor(calibratedRed: 255 / 255, green: 224 / 255, blue: 214 / 255, alpha: 1.0)
  )
  static let ink = adaptive(
    dark: NSColor(calibratedWhite: 250 / 255, alpha: 1.0),
    light: NSColor(calibratedWhite: 20 / 255, alpha: 1.0)
  )
  static let inkInverse = adaptive(
    dark: NSColor(calibratedWhite: 20 / 255, alpha: 1.0),
    light: NSColor(calibratedWhite: 250 / 255, alpha: 1.0)
  )
  static let ink2 = adaptive(
    dark: NSColor(calibratedWhite: 184 / 255, alpha: 1.0),
    light: NSColor(calibratedWhite: 71 / 255, alpha: 1.0)
  )
  static let ink3 = adaptive(
    dark: NSColor(calibratedWhite: 122 / 255, alpha: 1.0),
    light: NSColor(calibratedWhite: 107 / 255, alpha: 1.0)
  )
  static let line = adaptive(
    dark: NSColor(calibratedWhite: 1.0, alpha: 15 / 255),
    light: NSColor(calibratedWhite: 0.0, alpha: 20 / 255)
  )
  static let lineRow = adaptive(
    dark: NSColor(calibratedWhite: 1.0, alpha: 13 / 255),
    light: NSColor(calibratedWhite: 0.0, alpha: 18 / 255)
  )
  static let lineStrong = adaptive(
    dark: NSColor(calibratedWhite: 1.0, alpha: 26 / 255),
    light: NSColor(calibratedWhite: 0.0, alpha: 31 / 255)
  )
  static let groupFill = adaptive(
    dark: NSColor(calibratedWhite: 1.0, alpha: 6 / 255),
    light: NSColor(calibratedWhite: 1.0, alpha: 158 / 255)
  )
  static let iconFill = adaptive(
    dark: NSColor(calibratedWhite: 1.0, alpha: 0.05),
    light: NSColor(calibratedWhite: 0.0, alpha: 0.055)
  )
  static let sidebarFill = adaptive(
    dark: NSColor(calibratedWhite: 1.0, alpha: 0.025),
    light: NSColor(calibratedWhite: 0.0, alpha: 0.035)
  )
  static let selectedSidebarFill = adaptive(
    dark: NSColor(calibratedWhite: 1.0, alpha: 0.06),
    light: NSColor(calibratedWhite: 0.0, alpha: 0.075)
  )
  static let controlShell = adaptive(
    dark: NSColor(calibratedWhite: 0.0, alpha: 0.30),
    light: NSColor(calibratedWhite: 0.88, alpha: 1.0)
  )
  static let controlStroke = adaptive(
    dark: NSColor(calibratedWhite: 1.0, alpha: 0.08),
    light: NSColor(calibratedWhite: 0.0, alpha: 0.10)
  )
  static let controlSelected = adaptive(
    dark: NSColor(calibratedWhite: 1.0, alpha: 0.10),
    light: NSColor(calibratedWhite: 1.0, alpha: 0.82)
  )
  static let controlSelectedStroke = adaptive(
    dark: NSColor(calibratedWhite: 1.0, alpha: 0.08),
    light: NSColor(calibratedRed: 0.02, green: 0.39, blue: 0.78, alpha: 1.0)
  )
  static let fieldFill = adaptive(
    dark: NSColor(calibratedWhite: 0.0, alpha: 0.24),
    light: NSColor(calibratedWhite: 1.0, alpha: 0.76)
  )
  static let pathFieldFill = adaptive(
    dark: NSColor(calibratedWhite: 0.0, alpha: 0.30),
    light: NSColor(calibratedWhite: 1.0, alpha: 0.76)
  )
  static let meterFill = adaptive(
    dark: NSColor(calibratedWhite: 0.0, alpha: 0.35),
    light: NSColor(calibratedWhite: 0.0, alpha: 0.10)
  )
  static let codeFill = adaptive(
    dark: NSColor(calibratedWhite: 0.0, alpha: 0.34),
    light: NSColor(calibratedWhite: 1.0, alpha: 0.68)
  )
  static let offToggleFill = adaptive(
    dark: NSColor(calibratedWhite: 1.0, alpha: 0.10),
    light: NSColor(calibratedWhite: 0.0, alpha: 0.10)
  )
  static let keyFill = adaptive(
    dark: NSColor(calibratedWhite: 1.0, alpha: 0.06),
    light: NSColor(calibratedWhite: 1.0, alpha: 0.88)
  )
  static let keyStroke = adaptive(
    dark: NSColor(calibratedWhite: 1.0, alpha: 0.10),
    light: NSColor(calibratedWhite: 0.0, alpha: 0.12)
  )
  static let ghostButtonFill = adaptive(
    dark: NSColor(calibratedWhite: 1.0, alpha: 0.0),
    light: NSColor(calibratedWhite: 1.0, alpha: 0.50)
  )
  static let ghostButtonStroke = adaptive(
    dark: NSColor(calibratedWhite: 1.0, alpha: 0.0),
    light: NSColor(calibratedWhite: 0.0, alpha: 0.08)
  )
  static let secondaryButtonFill = adaptive(
    dark: NSColor(calibratedWhite: 1.0, alpha: 10 / 255),
    light: NSColor(calibratedWhite: 1.0, alpha: 179 / 255)
  )
  static let secondaryButtonStroke = adaptive(
    dark: NSColor(calibratedWhite: 1.0, alpha: 0.10),
    light: NSColor(calibratedWhite: 0.0, alpha: 0.10)
  )
  static let accentFocus = SwiftUI.Color(red: 0.02, green: 0.39, blue: 0.78)

  static let headerFont = SwiftUI.Font.custom(font, size: 13).weight(.semibold)
  static let titleFont = SwiftUI.Font.custom(font, size: 22).weight(.semibold)
  static let subtitleFont = SwiftUI.Font.custom(font, size: 13).weight(.regular)
  static let sectionFont = SwiftUI.Font.custom(font, size: 11).weight(.semibold)
  static let rowFont = SwiftUI.Font.custom(font, size: 13).weight(.regular)
  static let rowValueFont = SwiftUI.Font.custom(font, size: 13).weight(.regular)
  static let controlFont = SwiftUI.Font.custom(font, size: 12.5).weight(.medium)
  static let keyFont = SwiftUI.Font.custom(font, size: 12).weight(.medium)

  /// Label-order adapter over the shared dynamic-color helper in
  /// `DS.Color`; this token table reads dark-first.
  private static func adaptive(dark: NSColor, light: NSColor) -> SwiftUI.Color {
    DS.Color.adaptive(light: light, dark: dark)
  }
}

struct FidelityWindowSurface: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      glassTint
      topRightGlow
      topLeftGlow
    }
  }

  private var isLight: Bool { colorScheme == .light }

  private var glassTint: SwiftUI.Color {
    isLight
      ? SwiftUI.Color(red: 245 / 255, green: 247 / 255, blue: 250 / 255)
      : SwiftUI.Color(red: 7 / 255, green: 1 / 255, blue: 3 / 255)
  }

  private var topRightGlow: RadialGradient {
    RadialGradient(
      colors: [
        isLight
          ? SwiftUI.Color(red: 220 / 255, green: 234 / 255, blue: 251 / 255).opacity(0.55)
          : SwiftUI.Color(red: 77 / 255, green: 13 / 255, blue: 26 / 255).opacity(0.55),
        SwiftUI.Color.clear,
      ],
      center: UnitPoint(x: 0.82, y: 0.04),
      startRadius: 0,
      endRadius: 520
    )
  }

  private var topLeftGlow: RadialGradient {
    RadialGradient(
      colors: [
        isLight
          ? SwiftUI.Color(red: 255 / 255, green: 224 / 255, blue: 214 / 255).opacity(0.42)
          : SwiftUI.Color(red: 92 / 255, green: 28 / 255, blue: 18 / 255).opacity(0.42),
        SwiftUI.Color.clear,
      ],
      center: UnitPoint(x: 0.05, y: 0.02),
      startRadius: 0,
      endRadius: 480
    )
  }
}
struct FidelityDivider: View {
  var body: some View {
    Rectangle()
      .fill(FidelitySettings.line)
      .frame(width: 1)
  }
}

struct FidelityHeader: View {
  let title: String

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(title)
          .font(FidelitySettings.headerFont)
          .foregroundStyle(FidelitySettings.ink)
          .tracking(-0.13)
        Spacer()
      }
      .padding(.horizontal, 18)
      .frame(height: FidelitySettings.headerHeight)
      Rectangle()
        .fill(FidelitySettings.line)
        .frame(height: 1)
    }
  }
}

struct FidelitySidebar: View {
  @Binding var selection: SettingsPage
  let onClose: @MainActor () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 9) {
        FidelityTrafficButton(color: SwiftUI.Color(red: 1.0, green: 0.31, blue: 0.29)) {
          onClose()
        }
        FidelityTrafficButton(color: SwiftUI.Color(red: 1.0, green: 0.75, blue: 0.13)) {
          NSApp.keyWindow?.miniaturize(nil)
        }
        FidelityTrafficButton(color: SwiftUI.Color(red: 0.19, green: 0.80, blue: 0.30)) {
          NSApp.keyWindow?.zoom(nil)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: FidelitySettings.headerHeight)
      .padding(.leading, 15)

      VStack(spacing: 1) {
        ForEach(SettingsPage.allCases) { page in
          FidelitySidebarItem(
            symbol: page.symbol,
            title: page.title,
            selected: selection == page
          ) {
            selection = page
          }
        }
      }
      .padding(8)
      Spacer(minLength: 0)
    }
    .background(FidelitySettings.sidebarFill)
  }
}

private struct FidelityTrafficButton: View {
  let color: SwiftUI.Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Circle()
        .fill(color)
        .frame(width: 12, height: 12)
        .overlay(
          Circle()
            .stroke(SwiftUI.Color.black.opacity(0.22), lineWidth: 0.5)
        )
    }
    .buttonStyle(.plain)
  }
}

private struct FidelitySidebarItem: View {
  let symbol: String
  let title: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        ZStack {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? FidelitySettings.rust : FidelitySettings.iconFill)
          Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(selected ? SwiftUI.Color.white : FidelitySettings.ink3)
        }
        .frame(width: 22, height: 22)
        Text(title)
          .font(FidelitySettings.rowFont)
          .foregroundStyle(selected ? FidelitySettings.ink : FidelitySettings.ink2)
          .tracking(-0.13)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: 36)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(selected ? FidelitySettings.selectedSidebarFill : .clear)
      )
      .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}
