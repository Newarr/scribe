import SwiftUI
import TranscriberCore

@MainActor
private struct InstalledAppSmokeSettingsFrame<Content: View>: View {
  let title: String
  let content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        HStack(spacing: 9) {
          Circle().fill(SwiftUI.Color(red: 1.0, green: 0.31, blue: 0.29)).frame(
            width: 12, height: 12)
          Circle().fill(SwiftUI.Color(red: 1.0, green: 0.75, blue: 0.13)).frame(
            width: 12, height: 12)
          Circle().fill(SwiftUI.Color(red: 0.19, green: 0.80, blue: 0.30)).frame(
            width: 12, height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: FidelitySettings.headerHeight)
        .padding(.leading, 15)
        Spacer(minLength: 0)
      }
      .frame(width: FidelitySettings.sideWidth)
      .background(FidelitySettings.sidebarFill)
      FidelityDivider()
      VStack(spacing: 0) {
        FidelityHeader(title: title)
        content
          .padding(.top, 28)
          .padding(.horizontal, 36)
          .padding(.bottom, 36)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
  }
}

#if DEBUG
  @MainActor
  enum SettingsInstalledAppSmokeSnapshotRenderer {
    static func renderAll(to directory: URL) throws {
      let audioModel = smokeModel(
        outputRoot: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Scribe")
      )
      let audioView = InstalledAppSmokeSettingsFrame(title: "Audio") {
        FidelityAudioPanel(
          model: audioModel,
          onSettingsChange: { _ in },
          focusedEngineCard: nil
        )
      }
      .environment(\.colorScheme, ColorScheme.light)
      .preferredColorScheme(.light)
      try DebugVisualSnapshotWriter.write(
        audioView,
        named: "installed-smoke-settings-engine-key-entry-light",
        to: directory
      )

      let vaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/CloudStorage/Dropbox/ScribeInstalledSmoke")
      let vaultModel = smokeModel(outputRoot: vaultRoot)
      let vaultView = InstalledAppSmokeSettingsFrame(title: "Vault") {
        FidelityVaultPanel(model: vaultModel, onSettingsChange: { _ in })
      }
      .environment(\.colorScheme, ColorScheme.light)
      .preferredColorScheme(.light)
      try DebugVisualSnapshotWriter.write(
        vaultView,
        named: "installed-smoke-settings-vault-warning-light",
        to: directory
      )
    }

    private static func smokeModel(outputRoot: URL) -> SettingsFormModel {
      SettingsFormModel(
        initial: SessionSettings(
          outputRoot: outputRoot,
          engineMode: .cloud,
          keepRawStreams: false,
          aecEnabled: true,
          privacyAcknowledged: false,
          appearanceTheme: .light,
          launchAtLogin: false,
          showInMenuBar: true,
          startStopShortcut: .defaultStartStop
        ),
        keychainService: "com.szymonsypniewicz.transcriber.installed-smoke",
        keychainAccount: "redacted-ui-only-key",
        engineReadiness: InstalledAppSmokeEngineReadiness()
      )
    }
  }

  private struct InstalledAppSmokeEngineReadiness: EngineReadinessProbing {
    func cloudKeyAvailable() async -> Bool { false }
    func localModelStatus() async -> LocalModelCacheStatus {
      .verified(
        LocalModelCacheInfo(
          modelID: CohereMLXBackend.modelID,
          cacheURL: FileManager.default.temporaryDirectory,
          diskUsageBytes: 0
        ))
    }
    func localModelID() -> String { CohereMLXBackend.modelID }
    func mlxAvailable() -> Bool { true }
  }
#endif
