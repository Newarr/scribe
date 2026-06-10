import Foundation
import TranscriberCore

extension AppDelegate {
  /// Phase θ: builds a diagnostics snapshot from typed sources only.
  /// NEVER reads transcript bodies or session-folder file contents
  /// (the security contract lives in DiagnosticsExporter; this method
  /// is a thin assembly point).
  ///
  /// Codex Phase θ P1.3 / P1.4 / P1.6: real async permission probes,
  /// tri-state cloud key (configured | missing | unreadable), and
  /// real write-probe via DefaultOutputFolderProbe instead of the
  /// metadata-only isWritableFile.
  @MainActor
  func buildDiagnosticsSnapshot() async -> DiagnosticsSnapshot {
    let snap = settings
    let isoFmt = ISO8601DateFormatter()

    // Async probes. These match the preflight audit's source of
    // truth (DefaultPermissionStatusProbe / app-owned LocalModelManager readiness /
    // DefaultOutputFolderProbe), so what the user sees in
    // Diagnostics is what the gate at record-time will see.
    let permProbe = DefaultPermissionStatusProbe(permissions: permissions)
    let folderProbe = DefaultOutputFolderProbe()
    let keychain = KeychainStore(service: Self.keychainService, account: Self.keychainAccount)
    let engineProbe = engineReadinessProbe()
    // Codex rc2-audit PRIVACY-2: distinguish keychain-unreadable
    // from "configured." If unreadable, surface a fixed sentinel
    // in outputRootHash rather than a phantom-keyed hash that
    // varies per session.
    let instanceState = await diagnosticsInstanceID.currentState()
    let outputRootHash: String
    switch instanceState {
    case .configured(let secret):
      outputRootHash = DiagnosticsCollector.hashPath(snap.outputRoot, instanceID: secret)
    case .unreadable:
      outputRootHash = "unreadable"
    }

    async let permsView = DiagnosticsCollector.permissions(probe: permProbe)
    async let outputWritable = folderProbe.isWritable(snap.outputRoot)
    async let engineView = DiagnosticsCollector.engine(
      mode: snap.engineMode,
      cloudProbe: { Self.probeCloudKey(keychain: keychain) },
      engineProbe: engineProbe
    )

    let permissionsView = await permsView

    return await DiagnosticsSnapshot(
      appVersion: BuildInfo.version,
      osVersion: .init(ProcessInfo.processInfo.operatingSystemVersion),
      activeCalendarSource: DiagnosticsCollector.activeCalendarSource(
        calendarPermission: permissionsView.calendar),
      exportedAt: isoFmt.string(from: Date()),
      settings: .init(
        engineMode: snap.engineMode.rawValue,
        keepRawStreams: snap.keepRawStreams,
        aecEnabled: snap.aecEnabled,
        privacyAcknowledged: snap.privacyAcknowledged,
        outputRootHash: outputRootHash,
        outputRootIsWritable: outputWritable
      ),
      permissions: permissionsView,
      engine: engineView,
      sessions: DiagnosticsCollector.collectSessions(under: snap.outputRoot),
      liveLevels: currentDiagnosticsLiveLevels
    )
  }

  /// Codex Phase θ P1.4: probe the keychain and surface
  /// configured / missing / unreadable distinctly. KeychainStore.read
  /// throws KeychainError.notFound for the missing case and other
  /// errors for locked / denied / transient I/O.
  nonisolated static func probeCloudKey(
    keychain: KeychainStore,
    allowingUserInteraction: Bool = false
  ) -> DiagnosticsCollector.CloudKeyState {
    do {
      let value = try keychain.read(allowingUserInteraction: allowingUserInteraction)
      if let value, !value.isEmpty { return .configured }
      return .missing
    } catch {
      // Distinguish "no item" from "read failed for some other
      // reason". Anything that isn't `notFound` is treated as
      // unreadable so support sees the difference.
      return .unreadable
    }
  }

  nonisolated static func emptyDiagnosticsSnapshot() -> DiagnosticsSnapshot {
    DiagnosticsSnapshot(
      appVersion: BuildInfo.version,
      osVersion: .init(ProcessInfo.processInfo.operatingSystemVersion),
      activeCalendarSource: "unknown",
      exportedAt: ISO8601DateFormatter().string(from: Date()),
      settings: .init(
        engineMode: "cloud", keepRawStreams: false, aecEnabled: true, privacyAcknowledged: false,
        outputRootHash: "", outputRootIsWritable: false),
      permissions: .init(microphone: "unknown", screenRecording: "unknown", calendar: "unknown"),
      engine: .init(
        selectedEngine: "cloud",
        selectedEngineReady: false,
        cloudKey: "missing",
        localModelStatus: "notDownloaded",
        localModelID: CohereMLXBackend.modelID,
        localCachePathExists: false,
        mlxAvailable: true,
        localReady: false,
        lastDownloadError: ""
      ),
      sessions: .zero,
      liveLevels: nil
    )
  }

  /// Writes the current diagnostics snapshot to
  /// `~/Library/Logs/Scribe/diagnostics-<timestamp>.json` and
  /// returns the URL on success. Logs (and returns nil) on failure.
  @MainActor
  func exportDiagnosticsToFile() async -> URL? {
    let snapshot = await buildDiagnosticsSnapshot()
    do {
      let data = try DiagnosticsExporter.encode(snapshot)
      let logsDir = try Self.diagnosticsLogsDirectory()
      let fmt = DateFormatter()
      fmt.dateFormat = "yyyyMMdd-HHmmss"
      let url = logsDir.appendingPathComponent("diagnostics-\(fmt.string(from: Date())).json")
      try data.write(to: url, options: [.atomic])
      // Codex Phase θ P2.4: log the path .private so the user's
      // /Users/<name> doesn't leak into shared logs.
      Log.lifecycle.info("Diagnostics exported to \(url.path, privacy: .private)")
      return url
    } catch {
      Log.lifecycle.error(
        "Diagnostics export failed: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  private static func diagnosticsLogsDirectory() throws -> URL {
    let library = try FileManager.default.url(
      for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let logs = library.appendingPathComponent("Logs/Scribe", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    return logs
  }

  @MainActor
  private func permissionStatusName(_ status: PermissionStatus) -> String {
    switch status {
    case .granted: return "granted"
    case .denied: return "denied"
    case .notDetermined: return "notDetermined"
    }
  }
}
