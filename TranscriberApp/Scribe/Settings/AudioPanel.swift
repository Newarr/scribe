import SwiftUI
import TranscriberCore

/// Display-name ↔ BCP-47 mapping for the transcription Language dropdown.
/// Membership comes from `CohereMLXBackend.supportedLanguageCodes` so the
/// picker can't drift from what the tokenizer accepts; this table only
/// supplies stable display names. The cloud engine always auto-detects and
/// ignores this setting.
enum TranscriptionLanguageOption {
  static let autoLabel = "Auto (detect)"
  private static let displayNames: [String: String] = [
    "ar": "Arabic", "zh": "Chinese", "nl": "Dutch", "en": "English",
    "fr": "French", "de": "German", "el": "Greek", "it": "Italian",
    "ja": "Japanese", "ko": "Korean", "pl": "Polish", "pt": "Portuguese",
    "es": "Spanish", "vi": "Vietnamese",
  ]
  static let named: [(label: String, code: String)] =
    CohereMLXBackend.supportedLanguageCodes
      .map { code in
        (
          label: displayNames[code]
            ?? Locale.current.localizedString(forLanguageCode: code) ?? code,
          code: code
        )
      }
      .sorted { $0.label < $1.label }
  static var labels: [String] { [autoLabel] + named.map(\.label) }
  static func code(forLabel label: String) -> String? {
    named.first { $0.label == label }?.code
  }
  static func label(forCode code: String?) -> String {
    guard let code else { return autoLabel }
    return named.first { $0.code == code }?.label ?? autoLabel
  }
}

struct FidelityAudioPanel: View {
  @ObservedObject var model: SettingsFormModel
  let onSettingsChange: @MainActor (SessionSettings) async -> Void
  let focusedEngineCard: EngineSettingsCardFocus?
  @State private var inputDevice = "MacBook Pro Microphone"
  @State private var speakerLabels = true

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      FidelityPanelIntro(
        title: "Audio",
        subtitle: "Configure how Scribe captures and transcribes voice."
      )

      FidelitySection(title: "Engine") {
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
              FidelityEngineCard(
                title: "ElevenLabs (cloud)",
                status: model.engineViewState.cloud.statusText,
                detail: model.engineViewState.cloud.detailText,
                selected: model.engineMode == .cloud,
                enabled: model.engineViewState.cloud.isSelectionEnabled,
                actions: [],
                focused: focusedEngineCard == .cloud
              ) { selectEngine(.cloud) }
              FidelityCloudAPIKeyEditor(
                model: model,
                focused: focusedEngineCard == .cloud,
                onCommitSettings: onSettingsChange
              )
            }

            FidelityEngineCard(
              title: "Cohere (local)",
              status: model.engineViewState.local.statusText,
              detail:
                "\(model.engineViewState.local.modelName) · \(model.engineViewState.local.diskUsageText)\n\(model.engineViewState.local.privacyCopy)",
              selected: model.engineMode == .local,
              enabled: model.engineViewState.local.isSelectionEnabled,
              actions: model.engineViewState.local.availableActions,
              focused: focusedEngineCard == .local
            ) {
              selectEngine(.local)
            } actionHandler: { action in
              Task {
                switch action {
                case .retry: _ = await model.handleEngineAction(.retryLocalSetup)
                case .remove: _ = await model.handleEngineAction(.requestRemoveLocalModel)
                }
              }
            }
          }
          if case .confirmRemoveLocalModel(let modelName) = model.pendingLocalModelRemoval {
            FidelityInlineConfirmation(
              title: "Remove \(modelName)?",
              message:
                "Local transcription will be unavailable until the Cohere model is downloaded and verified again.",
              confirmTitle: "Remove",
              onCancel: { Task { _ = await model.handleEngineAction(.cancelRemoveLocalModel) } },
              onConfirm: { Task { _ = await model.handleEngineAction(.confirmRemoveLocalModel) } }
            )
          }
        }
        .padding(14)
        .task { await model.refreshEngineViewState() }
      }
      .padding(.bottom, 22)

      FidelitySection(title: "Recording") {
        FidelityRow(label: "Input device") {
          HStack(spacing: 12) {
            FidelitySelectLike(
              selection: $inputDevice,
              options: [
                "MacBook Pro Microphone", "AirPods Pro", "External USB-C Mic", "System default",
              ],
              minWidth: 240
            )
            FidelityMeter()
          }
        }
        FidelityRowDivider()
        FidelityRow(label: "Language") {
          HStack(spacing: 10) {
            FidelitySelectLike(
              selection: Binding(
                get: { TranscriptionLanguageOption.label(forCode: model.transcriptionLanguage) },
                set: { label in
                  let code = TranscriptionLanguageOption.code(forLabel: label)
                  guard model.transcriptionLanguage != code else { return }
                  model.transcriptionLanguage = code
                  persistSettings()
                }
              ),
              options: TranscriptionLanguageOption.labels,
              minWidth: 240
            )
            FidelityHelpText("Applies to Cohere (local). ElevenLabs always auto-detects.")
          }
        }
        FidelityRowDivider()
        FidelityRow(label: "Speaker labels") {
          HStack(spacing: 10) {
            FidelityToggle(isOn: $speakerLabels)
            FidelityHelpText("Diarize speakers when more than one voice is detected.")
          }
        }
      }
    }
  }

  private func selectEngine(_ mode: EngineMode) {
    Task {
      let attempt = await model.attemptEngineSelection(mode)
      if attempt.accepted {
        await onSettingsChange(model.currentSettings)
      }
    }
  }

  private func persistSettings() {
    Task { await onSettingsChange(model.currentSettings) }
  }
}

private struct FidelityCloudAPIKeyEditor: View {
  @ObservedObject var model: SettingsFormModel
  let focused: Bool
  /// Called after a successful Save key or Clear key to commit any
  /// concurrent non-secret Settings edits via the shared save path.
  /// Keychain persistence always completes first; this is only invoked
  /// on success so Settings remains open on Keychain failure.
  let onCommitSettings: @MainActor (SessionSettings) async -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("ElevenLabs API key")
        .font(FidelitySettings.controlFont)
        .foregroundStyle(FidelitySettings.ink)
      apiKeyField
        .font(FidelitySettings.rowValueFont)
        .foregroundStyle(FidelitySettings.ink)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(FidelitySettings.fieldFill)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(
              focused ? FidelitySettings.accentFocus : FidelitySettings.controlStroke,
              lineWidth: focused ? 2 : 1)
        )
        .accessibilityLabel("ElevenLabs API key")
        .accessibilityHint(
          "Secure field. The key is saved only in macOS Keychain and is never shown in labels."
        )
        .accessibilityValue(
          model.cloudAPIKeyHasChanges ? "Unsaved changes" : model.cloudAPIKeyStatusText)

      Text("Save or clear the key explicitly. Scribe stores it only in macOS Keychain.")
        .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11.5))
        .foregroundStyle(FidelitySettings.ink3)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("ElevenLabs key storage help")

      HStack(spacing: 8) {
        FidelitySecondaryButton(model.isSavingCloudAPIKey ? "Saving…" : "Save key") {
          Task {
            // Keychain-first: persist key before committing
            // non-secret settings. On failure, stay open.
            let ok = await model.persistAPIKeyIfChanged()
            if ok { await onCommitSettings(model.currentSettings) }
          }
        }
        .disabled(model.isSavingCloudAPIKey || !model.cloudAPIKeyHasChanges)
        .accessibilityLabel("Save ElevenLabs API key")
        .accessibilityHint(
          "Saves the typed key to macOS Keychain before Cloud readiness refreshes.")

        FidelityDangerButton("Clear key") {
          Task {
            // Keychain-first: delete key before committing
            // non-secret settings. On failure, stay open.
            let ok = await model.clearCloudAPIKey()
            if ok { await onCommitSettings(model.currentSettings) }
          }
        }
        .disabled(model.isSavingCloudAPIKey || model.apiKey.isEmpty)
        .accessibilityLabel("Clear ElevenLabs API key")
        .accessibilityHint("Deletes the saved ElevenLabs API key from macOS Keychain.")

        Text(model.cloudAPIKeyStatusText)
          .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11.5))
          .foregroundStyle(
            model.cloudAPIKeyHasChanges ? FidelitySettings.amber : FidelitySettings.ink3
          )
          .accessibilityLabel("ElevenLabs API key status")
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(FidelitySettings.fieldFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(
          focused ? FidelitySettings.accentFocus : FidelitySettings.controlStroke,
          lineWidth: focused ? 2 : 1)
    )
  }

  @ViewBuilder
  private var apiKeyField: some View {
    #if DEBUG
      if ProcessInfo.processInfo.environment["SCRIBE_VISUAL_SNAPSHOT_DIR"] != nil {
        HStack {
          Text("Paste API key")
            .foregroundStyle(FidelitySettings.ink3)
          Spacer(minLength: 0)
        }
      } else {
        secureAPIKeyField
      }
    #else
      secureAPIKeyField
    #endif
  }

  private var secureAPIKeyField: some View {
    SecureField(
      "Paste API key",
      text: Binding(
        get: { model.apiKey },
        set: { value in
          model.apiKey = value
          model.apiKeyEditedFromInitial = true
        }
      )
    )
    .textFieldStyle(.plain)
  }
}

private struct FidelityEngineCard: View {
  let title: String
  let status: String
  let detail: String
  let selected: Bool
  let enabled: Bool
  let actions: [EngineSettingsLocalAction]
  let focused: Bool
  let select: () -> Void
  let actionHandler: (EngineSettingsLocalAction) -> Void

  init(
    title: String,
    status: String,
    detail: String,
    selected: Bool,
    enabled: Bool,
    actions: [EngineSettingsLocalAction],
    focused: Bool = false,
    select: @escaping () -> Void,
    actionHandler: @escaping (EngineSettingsLocalAction) -> Void = { _ in }
  ) {
    self.title = title
    self.status = status
    self.detail = detail
    self.selected = selected
    self.enabled = enabled
    self.actions = actions
    self.focused = focused
    self.select = select
    self.actionHandler = actionHandler
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button(action: select) {
        VStack(alignment: .leading, spacing: 7) {
          HStack(spacing: 8) {
            FidelityStatusDot(
              color: selected
                ? FidelitySettings.green
                : (enabled ? FidelitySettings.amber : FidelitySettings.ink3))
            Text(title)
              .font(FidelitySettings.controlFont)
              .foregroundStyle(selected ? FidelitySettings.ink : FidelitySettings.ink2)
            Spacer(minLength: 0)
            Text(status)
              .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11).weight(.medium))
              .foregroundStyle(enabled ? FidelitySettings.green : FidelitySettings.amber)
          }
          Text(detail)
            .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11.5))
            .foregroundStyle(FidelitySettings.ink3)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(selected ? FidelitySettings.controlSelected : FidelitySettings.fieldFill)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(
              focused
                ? FidelitySettings.accentFocus
                : (selected
                  ? FidelitySettings.controlSelectedStroke : FidelitySettings.controlStroke),
              lineWidth: focused ? 2 : 1)
        )
        .opacity(enabled || selected ? 1 : 0.70)
      }
      .buttonStyle(.plain)
      .disabled(!enabled)

      if actions.isEmpty == false {
        HStack(spacing: 8) {
          ForEach(actions, id: \.self) { action in
            switch action {
            case .remove:
              FidelityDangerButton(Self.title(for: action)) { actionHandler(action) }
            case .retry:
              FidelitySecondaryButton(Self.title(for: action)) { actionHandler(action) }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private static func title(for action: EngineSettingsLocalAction) -> String {
    switch action {
    case .retry: return "Retry"
    case .remove: return "Remove"
    }
  }
}

private struct FidelityInlineConfirmation: View {
  let title: String
  let message: String
  let confirmTitle: String
  let onCancel: () -> Void
  let onConfirm: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(FidelitySettings.rowFont.weight(.medium))
          .foregroundStyle(FidelitySettings.ink)
        Text(message)
          .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11.5))
          .foregroundStyle(FidelitySettings.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 10)
      FidelityGhostButton("Cancel", action: onCancel)
      FidelityDangerButton(confirmTitle, action: onConfirm)
    }
    .padding(12)
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

private struct FidelityStatusDot: View {
  let color: SwiftUI.Color

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 6, height: 6)
  }
}

private struct FidelitySelectLike: View {
  @Binding var selection: String
  let options: [String]
  let minWidth: CGFloat

  var body: some View {
    Menu {
      ForEach(options, id: \.self) { option in
        Button(option) {
          selection = option
        }
      }
    } label: {
      HStack(spacing: 8) {
        Text(selection)
          .font(FidelitySettings.controlFont)
          .foregroundStyle(FidelitySettings.ink)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 12)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(FidelitySettings.ink3)
      }
      .padding(.horizontal, 11)
      .frame(minWidth: minWidth, minHeight: 28)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(FidelitySettings.fieldFill)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(FidelitySettings.line, lineWidth: 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}

private struct FidelityMeter: View {
  @State private var high = false

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(FidelitySettings.meterFill)
          .overlay(Capsule().stroke(FidelitySettings.line, lineWidth: 1))
        Capsule()
          .fill(
            LinearGradient(
              colors: [
                FidelitySettings.green, FidelitySettings.green, FidelitySettings.amber,
                FidelitySettings.rust,
              ],
              startPoint: .leading,
              endPoint: .trailing
            )
          )
          .frame(width: proxy.size.width * (high ? 0.72 : 0.38))
      }
    }
    .frame(width: 200, height: 6)
    .clipShape(Capsule())
    .onAppear {
      withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
        high = true
      }
    }
  }
}

private struct FidelityDangerButton: View {
  let title: String
  let action: () -> Void

  init(_ title: String, action: @escaping () -> Void = {}) {
    self.title = title
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(FidelitySettings.controlFont)
        .foregroundStyle(SwiftUI.Color.white)
        .frame(height: 28)
        .padding(.horizontal, 11)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(FidelitySettings.rust)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}
