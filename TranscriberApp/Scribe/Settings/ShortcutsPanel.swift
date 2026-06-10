import SwiftUI
import TranscriberCore

struct FidelityShortcutsPanel: View {
  @ObservedObject var model: SettingsFormModel
  let onShortcutChange: @MainActor (KeyboardShortcutSetting) -> Void
  let onSettingsChange: @MainActor (SessionSettings) async -> Void
  @State private var menuShortcut = KeyboardShortcutSetting(
    key: "S", keyCode: 1, modifiers: [.control, .command])

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      FidelityPanelIntro(
        title: "Shortcuts",
        subtitle: "Keyboard shortcuts for quick capture."
      )

      FidelitySection(title: "Global") {
        FidelityRow(label: "Start / stop recording") {
          HStack(spacing: 8) {
            FidelityKeyboardShortcutDisplay(shortcut: model.startStopShortcut)
            FidelityGhostButton("Change…") {
              ShortcutCapturePanel.present(current: model.startStopShortcut) { shortcut in
                model.startStopShortcut = shortcut
                onShortcutChange(shortcut)
                Task { await onSettingsChange(model.currentSettings) }
              }
            }
          }
        }
        FidelityRowDivider()
        FidelityRow(label: "Open menu bar popover") {
          HStack(spacing: 8) {
            FidelityKeyboardShortcutDisplay(shortcut: menuShortcut)
            FidelityGhostButton("Change…") {
              ShortcutCapturePanel.present(current: menuShortcut) { shortcut in
                menuShortcut = shortcut
              }
            }
          }
        }
      }
    }
  }
}

private struct FidelityKeyboardShortcutDisplay: View {
  let shortcut: KeyboardShortcutSetting

  var body: some View {
    HStack(spacing: 3) {
      ForEach(Array(shortcut.displayString.map(String.init).enumerated()), id: \.offset) {
        _, part in
        FidelityKey(part)
      }
    }
  }
}
