import SwiftUI
import TranscriberCore

struct SettingsForm: View {
  @ObservedObject var model: SettingsFormModel
  let onAppearanceThemeChange: @MainActor (AppearanceTheme) -> Void
  let onLaunchAtLoginChange: @MainActor (Bool) -> Void
  let onShowInMenuBarChange: @MainActor (Bool) -> Void
  let onShortcutChange: @MainActor (KeyboardShortcutSetting) -> Void
  let onSettingsChange: @MainActor (SessionSettings) async -> Void
  let onSave: @MainActor (SessionSettings) async -> Void
  let onCancel: @MainActor () -> Void
  let initialEngineFocus: EngineSettingsCardFocus?
  @State private var selectedPage: SettingsPage = .general
  @State private var focusedEngineCard: EngineSettingsCardFocus?

  var body: some View {
    HStack(spacing: 0) {
      FidelitySidebar(selection: $selectedPage, onClose: onCancel)
        .frame(width: FidelitySettings.sideWidth)
      FidelityDivider()
      VStack(spacing: 0) {
        FidelityHeader(title: selectedPage.title)
        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 16) {
            if let saveError = model.saveError {
              FidelityErrorBanner(message: saveError) {
                model.saveError = nil
              }
            }
            activePanel
          }
          .padding(.top, 28)
          .padding(.horizontal, 36)
          .padding(.bottom, 36)
        }
      }
      .frame(width: FidelitySettings.mainWidth)
    }
    .frame(width: FidelitySettings.windowWidth, height: FidelitySettings.windowHeight)
    .background(FidelityWindowSurface())
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(FidelitySettings.lineStrong, lineWidth: 1)
    )
    .preferredColorScheme(model.appearanceTheme.preferredColorScheme)
    .onAppear {
      if let initialEngineFocus {
        selectedPage = .audio
        focusedEngineCard = initialEngineFocus
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .settingsEngineFocusRequested)) {
      notification in
      selectedPage = .audio
      if let raw = notification.object as? String {
        focusedEngineCard = EngineSettingsCardFocus(rawValue: raw)
      }
    }
  }

  @ViewBuilder
  private var activePanel: some View {
    switch selectedPage {
    case .general:
      FidelityGeneralPanel(
        model: model,
        onAppearanceThemeChange: onAppearanceThemeChange,
        onLaunchAtLoginChange: onLaunchAtLoginChange,
        onShowInMenuBarChange: onShowInMenuBarChange,
        onShortcutChange: onShortcutChange,
        onSettingsChange: onSettingsChange
      )
    case .audio:
      FidelityAudioPanel(
        model: model, onSettingsChange: onSettingsChange, focusedEngineCard: focusedEngineCard)
    case .shortcuts:
      FidelityShortcutsPanel(
        model: model,
        onShortcutChange: onShortcutChange,
        onSettingsChange: onSettingsChange
      )
    case .vault:
      FidelityVaultPanel(model: model, onSettingsChange: onSettingsChange)
    case .privacy:
      FidelityPrivacyPanel(model: model)
    case .permissions:
      FidelityPermissionsPanel()
    case .about:
      FidelityAboutPanel()
    }
  }
}

extension Notification.Name {
  static let settingsEngineFocusRequested = Notification.Name(
    "ScribeSettingsEngineFocusRequested")
}

enum SettingsPage: String, CaseIterable, Identifiable {
  case general
  case audio
  case shortcuts
  case vault
  case privacy
  case permissions
  case about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: return "General"
    case .audio: return "Audio"
    case .shortcuts: return "Shortcuts"
    case .vault: return "Vault"
    case .privacy: return "Privacy"
    case .permissions: return "Permissions"
    case .about: return "About"
    }
  }

  var symbol: String {
    switch self {
    case .general: return "target"
    case .audio: return "waveform"
    case .shortcuts: return "keyboard"
    case .vault: return "cube"
    case .privacy: return "lock"
    case .permissions: return "checkmark.shield"
    case .about: return "info.circle"
    }
  }
}

private struct FidelityErrorBanner: View {
  let message: String
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(FidelitySettings.rust)
      Text(message)
        .font(FidelitySettings.rowValueFont)
        .foregroundStyle(FidelitySettings.ink2)
        .lineLimit(2)
      Spacer(minLength: 0)
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(FidelitySettings.ink3)
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 12)
    .frame(minHeight: 42)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(FidelitySettings.rust.opacity(0.10))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(FidelitySettings.rust.opacity(0.22), lineWidth: 1)
    )
  }
}
