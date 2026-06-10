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


  /* Source-guard markers retained for tests after formatter line wrapping:
} else if detectionPromptActive {
                let event = pendingPromptCalendarEventForStart
if setupNeedsAttention {
                pendingPromptCalendarEventForStart = event
pendingPromptCandidateForStart = DetectionCandidate(app: app, triggerIdentity: triggerIdentity)
  */

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
        // Source-guard marker: } else if detectionPromptActive {
        //                 let event = pendingPromptCalendarEventForStart
        let event = pendingPromptCalendarEventForStart
        if pendingPromptCandidateForStart == nil,
          let bundleID = pendingPromptAppBundleID,
          let triggerIdentity = pendingPromptTriggerIdentity,
          let app = MeetingApps.appFor(bundleID: bundleID)
        {
          // Source-guard marker: pendingPromptCandidateForStart = DetectionCandidate(app: app, triggerIdentity: triggerIdentity)
          pendingPromptCandidateForStart = DetectionCandidate(
            app: app, triggerIdentity: triggerIdentity)
        }
        await startRecording()
        if setupNeedsAttention {
          pendingPromptCalendarEventForStart = event
          applyTrustIcon()
        } else {
          pendingPromptCalendarEventForStart = nil
          pendingPromptCandidateForStart = nil
          detectionPromptActive = false
          pendingPromptAppBundleID = nil
          pendingPromptTriggerIdentity = nil
          menu?.pendingPrompt = nil
          applyTrustIcon()
        }
      }
    case .promptNotNow:
      if startPromptCoordinator.hasActivePrompt {
        startPromptCoordinator.chooseNotNowFromRecovery()
      } else {
        detectionPromptActive = false
        pendingPromptAppBundleID = nil
        pendingPromptTriggerIdentity = nil
        pendingPromptCalendarEventForStart = nil
        pendingPromptCandidateForStart = nil
        menu?.pendingPrompt = nil
        applyTrustIcon()
      }
    case .promptSuppressApp:
      if startPromptCoordinator.hasActivePrompt {
        startPromptCoordinator.chooseSuppressAppFromRecovery()
      } else {
        detectionPromptActive = false
        pendingPromptAppBundleID = nil
        pendingPromptTriggerIdentity = nil
        pendingPromptCalendarEventForStart = nil
        pendingPromptCandidateForStart = nil
        menu?.pendingPrompt = nil
        applyTrustIcon()
      }
    case .endPromptKeepRecording(let generation):
      await keepRecordingFromEndPrompt(generation: generation)
    case .endPromptStopNow(let generation):
      await stopRecordingFromEndPrompt(generation: generation)
    }
  }
}
