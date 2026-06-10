import AppKit
import TranscriberCore

extension AppDelegate {
  /// Phase η P0.2 helper: kicks the orphan-session supervisor scan in
  /// the background. Tracked in `inflightTasks` so applicationShouldTerminate's
  /// drain loop will await it. Must only be called after the user has
  /// acknowledged the privacy notice (cloud-mode uploads start as soon
  /// as the supervisor dispatches a worker).
  @MainActor
  func scheduleSupervisorRecovery() {
    let snap = settings
    let outputRoot = snap.outputRoot
    let keepRaw = snap.keepRawStreams
    let mode = snap.engineMode
    let language = snap.transcriptionLanguage
    let resumeId = UUID()
    let resumeTask = Task { [weak self] in
      let result = await Self.runSupervisor(
        under: outputRoot,
        keepRawStreams: keepRaw,
        engineMode: mode,
        transcriptionLanguage: language,
        localModelStatus: { [weak self] in
          guard let manager = await MainActor.run(body: { self?.localModelManager }) else {
            return .notDownloaded(modelID: CohereMLXBackend.modelID)
          }
          return await manager.status()
        }
      )
      // Codex PM-review UX-31: surface a recovery notice so the
      // user knows a previously-interrupted session is being
      // re-transcribed. Silent recovery feels like the app is
      // ignoring their data.
      await self?.showRecoveryNoticeIfNeeded(result: result)
      if result.localSetupRequired > 0 || result.missingEngineProvenance > 0 {
        await self?.markRecoverySetupRequired(
          payload: result.localSetupRequiredSessions.first.map {
            SessionRepairRouting.LocalRepairPayload(
              sessionDirectory: $0,
              reason:
                "Cohere setup is required before this recovered Local session can be transcribed."
            )
          })
      }
      await self?.removeTask(id: resumeId)
    }
    inflightTasks[resumeId] = resumeTask
  }

  @MainActor
  func markRecoverySetupRequired(payload: SessionRepairRouting.LocalRepairPayload? = nil) {
    status = .idle
    setupNeedsAttention = true
    sessionRepairPayload = payload
    menu?.setupNeedsAttention = true
    menu?.outcomeFolderURL = payload?.sessionDirectory
    menu?.rebuild(for: status)
    applyTrustIcon()
  }

  @MainActor
  private func showRecoveryNoticeIfNeeded(result: SessionSupervisor.ScanResult) {
    guard let notice = SessionRepairRouting.recoveryNotice(for: result) else { return }
    if let payload = notice.localRepairPayloads.first {
      sessionRepairPayload = payload
      menu?.outcomeFolderURL = payload.sessionDirectory
    }
    let title = notice.transcribingStarted ? "Transcription is resuming" : notice.title
    let message = notice.transcribingStarted ? notice.title : notice.message
    let decision = PromptModalWindow.run(
      model: PromptModalWindow.Model(
        badge: notice.transcribingStarted ? "Resuming" : "Recovered",
        title: title,
        message: message,
        secondaryTitle: "Open Scribe folder",
        primaryTitle: "OK"
      ),
      place: { window in window.center() }
    )
    if decision == .secondary {
      NSWorkspace.shared.open(settings.outputRoot)
    }
  }

  @MainActor
  func retryFailedSession() async {
    guard let sessionURL = menu?.outcomeFolderURL ?? mostRecentFailedSessionURL() else {
      Log.engine.error("Failed-session retry unavailable: no failed session with saved audio")
      status = .failed
      menu?.outcomeFolderURL = nil
      menu?.rebuild(for: status)
      return
    }
    await retryFailedSession(at: sessionURL)
  }

  @MainActor
  func retryFailedSession(at sessionURL: URL) async {
    // Same usability predicate FailedSessionRetryCoordinator enforces one
    // call later, so this routing pre-check can't disagree with it.
    guard CanonicalAudio.isUsable(in: sessionURL) else {
      Log.engine.error(
        "Failed-session retry unavailable: saved audio missing for selected failed session")
      if let frontmatter = TranscriptFrontmatterReader.read(
        at: sessionURL.appendingPathComponent("transcript.md")),
        EngineMode(persistedIdentifier: frontmatter.context.engine) == .local
      {
        markRecoverySetupRequired(
          payload: SessionRepairRouting.LocalRepairPayload(
            sessionDirectory: sessionURL,
            reason: "Saved audio is missing; repair this Local session before retrying."
          ))
      } else {
        status = .failed
        menu?.outcomeFolderURL = nil
        menu?.rebuild(for: status)
      }
      return
    }
    menu?.outcomeFolderURL = sessionURL
    status = .starting
    menu?.rebuild(for: status)
    let localStatus = await currentLocalModelStatus()
    do {
      let final = try await Self.retryFailedSession(
        at: sessionURL,
        localModelStatus: localStatus
      )
      switch final {
      case .complete:
        status = .idle
        resetMenuAfterWorker(status: status)
        markSavedFlash()
      case .failed, .cancelled:
        status = .failed
      }
    } catch let error as FailedSessionRetryCoordinator.RetryError {
      Log.engine.error(
        "Failed-session retry could not start: \(String(describing: error), privacy: .public)")
      if case .localSetupRequired = error {
        markRecoverySetupRequired(
          payload: SessionRepairRouting.LocalRepairPayload(
            sessionDirectory: sessionURL,
            reason: "Cohere setup is required before retrying this Local session."
          ))
      } else {
        status = .failed
      }
    } catch {
      Log.engine.error(
        "Failed-session retry could not start: \(String(describing: error), privacy: .public)")
      status = .failed
    }
    menu?.rebuild(for: status)
  }

  @MainActor
  private func mostRecentFailedSessionURL() -> URL? {
    SessionFolderEnumerator.recents(under: outputRoot, limit: RecordingMenuModel.recentsLimit)
      .first { $0.status == .failed && $0.hasSavedAudio }?
      .directory
  }

  @MainActor
  private func currentLocalModelStatus() async -> LocalModelCacheStatus {
    await localModelManager.status()
  }

  nonisolated static func retryFailedSession(
    at sessionURL: URL,
    localModelStatus: LocalModelCacheStatus,
    engineFactory: (@Sendable (EngineMode) -> TranscriptionEngine)? = nil
  ) async throws -> TranscriptionWorker.FinalState {
    try await FailedSessionRetryCoordinator.retry(
      sessionDirectory: sessionURL,
      engineFactory: { mode in
        if let engine = engineFactory?(mode) { return engine }
        return EngineSelector.makeEngine(
          for: mode,
          cloudAPIKey: {
            (try? KeychainStore(service: keychainService, account: keychainAccount).read()) ?? ""
          }
        )
      },
      localModelStatus: localModelStatus
    )
  }
}
