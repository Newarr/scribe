import SwiftUI
import TranscriberCore

@MainActor
final class SettingsFormModel: ObservableObject {
  @Published var outputRoot: URL
  @Published var engineMode: EngineMode
  @Published var keepRawStreams: Bool
  @Published var aecEnabled: Bool
  @Published var appearanceTheme: AppearanceTheme
  @Published var launchAtLogin: Bool
  @Published var showInMenuBar: Bool
  @Published var startStopShortcut: KeyboardShortcutSetting
  @Published var transcriptionLanguage: String?
  @Published var apiKey: String
  @Published var isSavingCloudAPIKey: Bool = false
  @Published var saveError: String?
  @Published var engineViewState: EngineSettingsViewState
  @Published var pendingLocalModelRemoval: EngineSettingsEffect?

  let initialSnapshot: SessionSettings
  private let keychain: any KeychainPersisting
  private var initialAPIKey: String
  private let engineReadiness: EngineReadinessProbing
  private let onRetryLocalModel: @MainActor () async -> LocalModelCacheStatus
  private let onClearLocalModelCache: @MainActor () async throws -> Void

  init(
    initial: SessionSettings,
    keychainService: String,
    keychainAccount: String,
    engineReadiness: EngineReadinessProbing,
    keychain: (any KeychainPersisting)? = nil,
    onRetryLocalModel: @escaping @MainActor () async -> LocalModelCacheStatus = {
      .notDownloaded(modelID: CohereMLXBackend.modelID)
    },
    onClearLocalModelCache: @escaping @MainActor () async throws -> Void = {}
  ) {
    self.initialSnapshot = initial
    self.outputRoot = initial.outputRoot
    self.engineMode = initial.engineMode
    self.keepRawStreams = initial.keepRawStreams
    self.aecEnabled = initial.aecEnabled
    self.appearanceTheme = initial.appearanceTheme
    self.launchAtLogin = LaunchAtLoginController.isEnabled
    self.showInMenuBar = initial.showInMenuBar
    self.startStopShortcut = initial.startStopShortcut
    self.transcriptionLanguage = initial.transcriptionLanguage
    let keychain = keychain ?? KeychainStore(service: keychainService, account: keychainAccount)
    self.keychain = keychain
    self.engineReadiness = engineReadiness
    self.onRetryLocalModel = onRetryLocalModel
    self.onClearLocalModelCache = onClearLocalModelCache

    let stored = (try? keychain.read()) ?? ""
    self.initialAPIKey = stored
    self.apiKey = stored
    self.engineViewState = EngineSettingsViewState.make(
      selectedEngine: initial.engineMode,
      cloudKeyAvailable: stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
      localStatus: .notDownloaded(modelID: engineReadiness.localModelID()),
      modelID: engineReadiness.localModelID()
    )
    Task { await refreshEngineViewState() }
  }

  var currentSettings: SessionSettings {
    SessionSettings(
      outputRoot: outputRoot,
      engineMode: engineMode,
      keepRawStreams: keepRawStreams,
      aecEnabled: aecEnabled,
      // Privacy ack is one-way; if the user already acked it,
      // preserve. The Settings UI doesn't let them un-ack.
      privacyAcknowledged: initialSnapshot.privacyAcknowledged,
      appearanceTheme: appearanceTheme,
      launchAtLogin: launchAtLogin,
      showInMenuBar: showInMenuBar,
      startStopShortcut: startStopShortcut,
      transcriptionLanguage: transcriptionLanguage
    )
  }

  func refreshEngineViewState() async {
    engineViewState = await EngineSettingsViewState.make(
      selectedEngine: engineMode, readiness: engineReadiness)
  }

  func attemptEngineSelection(_ requestedMode: EngineMode) async -> EngineSelectionAttempt {
    await refreshEngineViewState()
    let attempt = await EngineSelectionPolicy.evaluate(
      requested: requestedMode,
      current: engineMode,
      readiness: engineReadiness
    )
    engineMode = attempt.selectedEngineMode
    await refreshEngineViewState()
    if let reason = attempt.repairReason {
      saveError = SettingsFormModel.repairMessage(for: reason)
    } else {
      saveError = nil
    }
    return attempt
  }

  @discardableResult
  func handleEngineAction(_ action: EngineSettingsAction) async -> EngineSettingsEffect {
    var reducer = EngineSettingsActionReducer(selectedEngine: engineMode)
    let effect = reducer.handle(action)
    engineMode = reducer.selectedEngine
    switch effect {
    case .confirmRemoveLocalModel:
      pendingLocalModelRemoval = effect
    case .startLocalRetry:
      _ = await onRetryLocalModel()
      await refreshEngineViewState()
      saveError = "Cohere model download is retrying."
    case .clearLocalModelCache:
      do {
        try await onClearLocalModelCache()
        pendingLocalModelRemoval = nil
        if engineMode == .local {
          saveError =
            "Cohere model removed. Local remains selected and will show Setup Required until repaired."
        } else {
          saveError = "Cohere model removed. Local will be unavailable until repaired."
        }
        await refreshEngineViewState()
      } catch {
        saveError = "Failed to remove Cohere model: \(error.localizedDescription)"
      }
    case .none:
      pendingLocalModelRemoval = nil
    }
    return effect
  }

  static func repairMessage(for reason: PreflightReason) -> String {
    switch reason {
    case .missingCloudAPIKey:
      return "Add an ElevenLabs API key before selecting Cloud."
    case .localRuntimeUnavailable:
      return "Cohere (local) is not supported on this Mac."
    case .localModelNotVerified:
      return "Cohere (local) is unavailable until the model is downloaded and verified."
    default:
      return "This engine is not ready yet. Fix setup before selecting it."
    }
  }

  var cloudAPIKeyHasChanges: Bool {
    apiKey != initialAPIKey
  }

  var cloudAPIKeyStatusText: String {
    if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "No key saved"
    }
    return cloudAPIKeyHasChanges ? "Unsaved key edit" : "Key saved in Keychain"
  }

  @discardableResult
  func persistAPIKeyIfChanged(
    onCommitSettings: @MainActor (SessionSettings) async -> Void
  ) async -> Bool {
    guard apiKey != initialAPIKey else { return true }
    isSavingCloudAPIKey = true
    defer { isSavingCloudAPIKey = false }
    let candidate = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      if candidate.isEmpty {
        try keychain.delete()
        apiKey = ""
        initialAPIKey = ""
        saveError =
          "ElevenLabs API key cleared. Cloud will show Setup Required until a key is saved."
      } else {
        try keychain.write(candidate)
        apiKey = candidate
        initialAPIKey = candidate
        saveError = "ElevenLabs API key saved to Keychain."
      }
      await refreshEngineViewState()
      await onCommitSettings(currentSettings)
      return true
    } catch {
      saveError =
        "Could not update the ElevenLabs API key in Keychain. The key was not saved; try again from Settings."
      return false
    }
  }

  @discardableResult
  func clearCloudAPIKey(
    onCommitSettings: @MainActor (SessionSettings) async -> Void
  ) async -> Bool {
    apiKey = ""
    return await persistAPIKeyIfChanged(onCommitSettings: onCommitSettings)
  }

  func canCloseOrSurfaceUnsavedCloudKeyWarning() -> Bool {
    guard cloudAPIKeyHasChanges else { return true }
    saveError =
      "Save or clear the ElevenLabs API key before closing Settings. Unsaved key edits stay only in this secure field."
    return false
  }

  var outputRootSyncedStorageProviderHint: String? {
    DefaultOutputFolderProbe().syncedStorageHint(outputRoot)
  }

  var outputRootIsInICloudDrive: Bool {
    outputRootSyncedStorageProviderHint == "iCloud Drive"
  }

  var outputRootIsInSyncedStorage: Bool {
    outputRootSyncedStorageProviderHint != nil
  }
}
