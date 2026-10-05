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
    case .stop: await stopRecording()
    case .quit: NSApp.terminate(nil)
    case .openSettings:
      settingsWindowController?.show()
    case .openSetupRequired:
      await presentSetupRequiredPopover()
    case .openDiagnostics:
      diagnosticsWindowController?.show()
    case .promptStartRecording:
      if startPromptCoordinator.hasActivePrompt {
        startPromptCoordinator.chooseStartFromRecovery()
      } else if detectionPromptActive {
        let event = pendingPromptCalendarEventForStart
        if pendingPromptCandidateForStart == nil,
          let bundleID = pendingPromptAppBundleID,
          let triggerIdentity = pendingPromptTriggerIdentity,
          let app = MeetingApps.appFor(bundleID: bundleID)
        {
          pendingPromptCandidateForStart = DetectionCandidate(
            app: app, triggerIdentity: triggerIdentity)
        }
        await startRecording()
        if setupNeedsAttention {
          pendingPromptCalendarEventForStart = event
          applyTrustIcon()
        } else {
          clearPendingRecordingPrompt()
          applyTrustIcon()
        }
      }
    case .promptNotNow:
      if startPromptCoordinator.hasActivePrompt {
        startPromptCoordinator.chooseNotNowFromRecovery()
      } else {
        clearPendingRecordingPrompt()
        applyTrustIcon()
      }
    case .promptSuppressApp:
      if startPromptCoordinator.hasActivePrompt {
        startPromptCoordinator.chooseSuppressAppFromRecovery()
      } else {
        clearPendingRecordingPrompt()
        applyTrustIcon()
      }
    case .endPromptKeepRecording(let generation):
      await keepRecordingFromEndPrompt(generation: generation)
    case .endPromptStopNow(let generation):
      await stopRecordingFromEndPrompt(generation: generation)
    }
  }
}
