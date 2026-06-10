import TranscriberCore

/// Onboarding's download seam reports the PRIMARY (Cohere) status — that's
/// what gates local readiness. The aux models (VAD/LID) are staged as a
/// side effect and degrade gracefully when missing, so their status never
/// blocks the flow.
struct CompositeLocalModelDownloadStarter: LocalModelDownloadStarting {
  let primary: LocalModelManager
  let auxiliaries: [LocalModelManager]

  @discardableResult
  func startDownload() async -> LocalModelCacheStatus {
    stageAuxiliaries()
    return await primary.startDownload()
  }

  @discardableResult
  func retryDownload() async -> LocalModelCacheStatus {
    stageAuxiliaries()
    return await primary.retryDownload()
  }

  private func stageAuxiliaries() {
    let managers = auxiliaries
    Task.detached(priority: .utility) {
      for manager in managers {
        if await manager.status().isReady { continue }
        _ = await manager.startDownload()
      }
    }
  }
}
