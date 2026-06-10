import AppKit
import SwiftUI
import TranscriberCore

struct FidelityVaultPanel: View {
  @ObservedObject var model: SettingsFormModel
  let onSettingsChange: @MainActor (SessionSettings) async -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      FidelityPanelIntro(
        title: "Vault",
        subtitle: "Where your transcripts and audio live on disk."
      )

      FidelitySection(title: "Location") {
        FidelityRow(label: "Save transcripts to") {
          HStack(spacing: 8) {
            FidelityPathField(path: shortenedPath)
              .frame(maxWidth: .infinity)
            FidelitySecondaryButton("Choose…") { pickFolder() }
            FidelityGhostButton("Reveal") { revealFolder(model.outputRoot) }
          }
        }
        if let warning = syncedStorageWarning {
          FidelityRowDivider()
          FidelityVaultWarning(message: warning)
        }
        FidelityRowDivider()
        FidelityRow(label: "On disk") {
          FidelityStorageStat(url: model.outputRoot)
        }
      }
    }
  }

  private var shortenedPath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return model.outputRoot.path.replacingOccurrences(of: home, with: "~")
  }

  private var syncedStorageWarning: String? {
    guard model.outputRootIsInSyncedStorage else { return nil }
    let provider = model.outputRootSyncedStorageProviderHint ?? "synced storage"
    // Permission Doctor will show the same non-blocking warning before recording.
    return
      "Sync races can corrupt durable meeting audio in \(provider). Use a local folder like ~/Scribe while recording."
  }

  private func pickFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.directoryURL = model.outputRoot
    if panel.runModal() == .OK, let url = panel.url {
      model.outputRoot = url
      Task { await onSettingsChange(model.currentSettings) }
    }
  }

  private func revealFolder(_ url: URL) {
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      NSWorkspace.shared.open(url)
      model.saveError = nil
    } catch {
      model.saveError = "Failed to open folder: \(error.localizedDescription)"
    }
  }
}

private struct FidelityVaultWarning: View {
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(FidelitySettings.amber)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 3) {
        Text("Synced folder warning")
          .font(FidelitySettings.controlFont)
          .foregroundStyle(FidelitySettings.ink)
        Text(message)
          .font(SwiftUI.Font.custom(FidelitySettings.font, size: 12))
          .foregroundStyle(FidelitySettings.ink2)
          .lineSpacing(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(FidelitySettings.amber.opacity(0.10))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(FidelitySettings.amber.opacity(0.24), lineWidth: 1)
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Vault synced-storage warning")
    .accessibilityValue(message)
  }
}

private struct FidelityPathField: View {
  let path: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "folder")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(FidelitySettings.ink3)
      Text(attributedPath)
        .font(FidelitySettings.controlFont)
        .foregroundStyle(FidelitySettings.ink2)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 11)
    .frame(height: 28)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(FidelitySettings.pathFieldFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(FidelitySettings.line, lineWidth: 1)
    )
  }

  private var attributedPath: AttributedString {
    var value = AttributedString(path)
    if let range = value.range(of: "Scribe") {
      value[range].foregroundColor = FidelitySettings.ink
      value[range].font = FidelitySettings.controlFont.weight(.medium)
    }
    return value
  }
}

private struct FidelityStorageStat: View {
  let url: URL
  // The recursive output-folder walk stats thousands of files; running it
  // inside body blocked the main actor on every render of the storage tab.
  // Compute once per output root off the main thread instead.
  @State private var stat: (transcriptCount: Int, byteCount: String) = (0, "0 KB")

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("\(stat.transcriptCount)")
        .font(SwiftUI.Font.custom(FidelitySettings.font, size: 15).weight(.semibold))
        .foregroundStyle(FidelitySettings.ink)
        .monospacedDigit()
      Text("transcripts")
        .font(FidelitySettings.rowValueFont)
        .foregroundStyle(FidelitySettings.ink2)
      Text("·")
        .font(FidelitySettings.rowValueFont)
        .foregroundStyle(FidelitySettings.ink3)
      Text(stat.byteCount)
        .font(SwiftUI.Font.custom(FidelitySettings.font, size: 15).weight(.semibold))
        .foregroundStyle(FidelitySettings.ink)
        .monospacedDigit()
    }
    .task(id: url) {
      let target = url
      stat = await Task.detached(priority: .utility) {
        Self.computeStorageStat(at: target)
      }.value
    }
  }

  private nonisolated static func computeStorageStat(at url: URL) -> (transcriptCount: Int, byteCount: String) {
    let manager = FileManager.default
    guard
      let enumerator = manager.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return (0, "0 KB")
    }

    var count = 0
    var bytes: Int64 = 0
    for case let fileURL as URL in enumerator {
      let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values?.isRegularFile == true else { continue }
      if fileURL.pathExtension.lowercased() == "md" {
        count += 1
      }
      bytes += Int64(values?.fileSize ?? 0)
    }

    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = bytes < 1_000_000 ? [.useKB] : [.useMB, .useGB]
    return (count, formatter.string(fromByteCount: bytes))
  }
}
