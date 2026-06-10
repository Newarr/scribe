import AppKit
import SwiftUI
import TranscriberCore

struct FidelityAboutPanel: View {
  @State private var microphoneStatus: PermissionStatus = .notDetermined

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      FidelityPanelIntro(
        title: "About",
        subtitle: "Scribe — every call, captured locally."
      )

      FidelitySection(title: "App") {
        FidelityRow(label: "Version") {
          HStack(spacing: 8) {
            Text(BuildInfo.version)
              .font(FidelitySettings.rowValueFont)
              .foregroundStyle(FidelitySettings.ink)
            FidelityGhostButton("Check for updates") {
              if let url = URL(string: "https://github.com/Newarr/scribe/releases") {
                NSWorkspace.shared.open(url)
              }
            }
          }
        }
        FidelityRowDivider()
        FidelityRow(label: "Build") {
          Text("2026.05.07 · macOS 14.4+")
            .font(FidelitySettings.rowValueFont)
            .foregroundStyle(FidelitySettings.ink2)
        }
        FidelityRowDivider()
        FidelityRow(label: "Mic access") {
          Text(microphoneStatus.fidelityLabel)
            .font(FidelitySettings.rowValueFont.weight(.medium))
            .foregroundStyle(microphoneStatus.fidelityColor)
        }
      }
    }
    .task {
      microphoneStatus = PermissionsService().microphoneStatus()
    }
  }
}
