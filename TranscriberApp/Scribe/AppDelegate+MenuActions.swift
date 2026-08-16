import AppKit
import TranscriberCore

extension AppDelegate {
  @MainActor
  func toggleRecordingFromShortcut() async {
    switch status {
    case .recording:
      await stopRecording()
    case .idle, .failed, .finalized:
      await startRecording()
    case .starting, .stopping:
      break
    }
  }

  @MainActor
  func handle(_ action: RecordingMenu.Action) async {
    switch action {
    case .record: await startRecording()
    case .retryFailedSession: await retryFailedSession()
    case .retryRecentFailedSession(let sessionURL): await retryFailedSession(at: sessionURL)
    case .repairRecentFailedSession(let sessionURL):
      markRecoverySetupRequired(
        payload: SessionRepairRouting.LocalRepairPayload(
          sessionDirectory: sessionURL,
          reason:
            "Saved audio is missing; open setup to repair this failed session before retrying."
        ))
      await presentSetupRequiredPopover()
    case .discardSession(let sessionURL): await discardSession(at: sessionURL)
    case .stop: await stopRecording()
    case .quit: NSApp.terminate(nil)
    case .openSettings:
      settingsWindowController?.show()
    case .openSetupRequired:
      await presentSetupRequiredPopover()
    case .openDiagnostics:
      diagnosticsWindowController?.show()
    case .endPromptKeepRecording(let generation):
      await keepRecordingFromEndPrompt(generation: generation)
    case .endPromptStopNow(let generation):
      await stopRecordingFromEndPrompt(generation: generation)
    case .endPromptDiscard(let generation):
      await discardFromEndPrompt(generation: generation)
    }
  }
}
