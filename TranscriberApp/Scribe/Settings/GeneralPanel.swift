import SwiftUI
import TranscriberCore

struct FidelityGeneralPanel: View {
  @ObservedObject var model: SettingsFormModel
  let onAppearanceThemeChange: @MainActor (AppearanceTheme) -> Void
  let onLaunchAtLoginChange: @MainActor (Bool) -> Void
  let onShowInMenuBarChange: @MainActor (Bool) -> Void
  let onShortcutChange: @MainActor (KeyboardShortcutSetting) -> Void
  let onSettingsChange: @MainActor (SessionSettings) async -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("General")
        .font(FidelitySettings.titleFont)
        .foregroundStyle(FidelitySettings.ink)
        .tracking(-0.55)
        .padding(.bottom, 6)
      Text(
        "Scribe records audio locally and saves transcripts to your Mac. Local (Cohere) transcription keeps everything on-device. Cloud (ElevenLabs) uploads audio to ElevenLabs for transcription."
      )
      .font(FidelitySettings.subtitleFont)
      .foregroundStyle(FidelitySettings.ink2)
      .lineSpacing(4)
      .tracking(-0.08)
      .frame(maxWidth: 520, alignment: .leading)
      .padding(.bottom, 24)

      FidelitySection(title: "Appearance") {
        FidelityRow(label: "Theme") {
          FidelitySegmentedControl(
            selection: Binding(
              get: { model.appearanceTheme },
              set: { theme in
                guard model.appearanceTheme != theme else { return }
                model.appearanceTheme = theme
                onAppearanceThemeChange(theme)
                persistSettings()
              }
            ))
        }
      }
      .padding(.bottom, 22)

      FidelitySection(title: "Shortcut") {
        FidelityRow(label: "Start / stop recording") {
          HStack(spacing: 8) {
            HStack(spacing: 3) {
              ForEach(
                Array(model.startStopShortcut.displayString.map(String.init).enumerated()),
                id: \.offset
              ) { _, part in
                FidelityKey(part)
              }
            }
            FidelityGhostButton("Change…") {
              ShortcutCapturePanel.present(current: model.startStopShortcut) { shortcut in
                model.startStopShortcut = shortcut
                onShortcutChange(shortcut)
                persistSettings()
              }
            }
          }
        }
      }
      .padding(.bottom, 22)

      FidelitySection(title: "App") {
        FidelityRow(label: "Launch at login") {
          FidelityToggle(
            isOn: Binding(
              get: { model.launchAtLogin },
              set: { enabled in
                model.launchAtLogin = enabled
                onLaunchAtLoginChange(enabled)
              }
            ))
        }
        FidelityRowDivider()
        FidelityRow(label: "Show in menu bar") {
          FidelityToggle(
            isOn: Binding(
              get: { model.showInMenuBar },
              set: { visible in
                model.showInMenuBar = visible
                onShowInMenuBarChange(visible)
              }
            ))
        }
      }
    }
  }

  private func persistSettings() {
    Task { await onSettingsChange(model.currentSettings) }
  }
}

private struct FidelitySegmentedControl: View {
  @Binding var selection: AppearanceTheme

  private let segments: [(AppearanceTheme, String, String)] = [
    (.system, "System", "display"),
    (.light, "Light", "sun.max"),
    (.dark, "Dark", "moon"),
  ]

  var body: some View {
    HStack(spacing: 2) {
      ForEach(segments, id: \.0) { segment in
        FidelitySegment(
          title: segment.1,
          symbol: segment.2,
          selected: selection == segment.0
        ) {
          selection = segment.0
        }
      }
    }
    .padding(2)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(FidelitySettings.controlShell)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(FidelitySettings.controlStroke, lineWidth: 1)
    )
  }
}

private struct FidelitySegment: View {
  let title: String
  let symbol: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: symbol)
          .font(.system(size: 12, weight: .medium))
        Text(title)
          .font(FidelitySettings.controlFont)
      }
      .foregroundStyle(selected ? FidelitySettings.ink : FidelitySettings.ink2)
      .padding(.horizontal, 12)
      .frame(height: 30)
      .frame(minWidth: 72)
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(selected ? FidelitySettings.controlSelected : .clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .stroke(selected ? FidelitySettings.controlSelectedStroke : .clear, lineWidth: 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    .buttonStyle(.plain)
    .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
  }
}
