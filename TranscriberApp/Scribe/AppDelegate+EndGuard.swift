import Foundation
import TranscriberCore

extension AppDelegate {
  @MainActor
  func startEndGuard(startedAt: Date) async {
    endGuardTickTimer?.invalidate()
    endCountdownController.dismiss()
    activeEndPromptGeneration = nil
    activeEndPromptID = nil
    menu?.endPrompt = nil

    let guardInstance = EndGuard(
      onPrompt: { [weak self] reason in
        Task { @MainActor [weak self] in
          await self?.handleEndGuardPrompt(reason: reason)
        }
      },
      onCountdownTick: { [weak self] remaining in
        Task { @MainActor [weak self] in
          self?.handleEndGuardCountdownTick(remaining: remaining)
        }
      },
      onAutoStop: { [weak self] reason in
        Task { @MainActor [weak self] in
          await self?.handleEndGuardAutoStop(reason: reason)
        }
      },
      onCancel: { [weak self] in
        Task { @MainActor [weak self] in
          self?.cancelEndGuardPrompt()
        }
      }
    )
    endGuard = guardInstance
    await guardInstance.start(at: startedAt)
    startEndGuardTickTimer()
  }

  @MainActor
  private func startEndGuardTickTimer() {
    endGuardTickTimer?.invalidate()
    endGuardTickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
      [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, let endGuard = self.endGuard else { return }
        await endGuard.tick(now: Date())
      }
    }
  }

  @MainActor
  func tearDownEndGuard(reset: Bool = true) async {
    endGuardTickTimer?.invalidate()
    endGuardTickTimer = nil
    clearEndGuardPromptSurface()
    let guardToReset = endGuard
    endGuard = nil
    if reset {
      await guardToReset?.reset()
    }
  }

  @MainActor
  private func handleEndGuardPrompt(reason: EndGuard.Reason) async {
    guard session != nil, status == .recording else { return }
    guard let endGuard else { return }
    // Sub-threshold auto-recorded sessions stay fully silent: the stop
    // countdown panel AND its notification would interrupt for a
    // recording that is about to trash itself anyway. Test the
    // PROJECTED duration: the countdown adds ~10s after this point, so
    // suppressing on elapsed alone would let a session hide the panel
    // at 115s and then get kept at 125s.
    let elapsed = currentSessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    let projectedSeconds = elapsed + EndGuard.Config.default.countdownDuration
    if AutoRecordPolicy.shouldAutoDiscard(
      durationSeconds: projectedSeconds,
      origin: currentSessionOrigin,
      initiator: .endGuard,
      thresholdSeconds: TimeInterval(settings.autoDiscardThresholdSeconds)
    ) {
      Log.lifecycle.info(
        "End guard prompt suppressed: projected duration under auto-discard threshold"
      )
      return
    }
    let generation = await endGuard.promptGeneration
    let promptID = UUID().uuidString
    activeEndPromptGeneration = generation
    activeEndPromptID = promptID
    let initialSeconds = Int(EndGuard.Config.default.countdownDuration)
    menu?.endPrompt = RecordingMenuEndPrompt(
      generation: generation,
      reason: Self.endGuardReasonCopy(reason),
      secondsRemaining: initialSeconds
    )
    menu?.rebuild(for: status)
    applyTrustIcon()
    endCountdownController.present(
      reason: reason,
      secondsRemaining: initialSeconds,
      onKeep: { [weak self, generation] in
        Task { @MainActor [weak self] in
          await self?.keepRecordingFromEndPrompt(generation: generation)
        }
      },
      onStopNow: { [weak self, generation] in
        Task { @MainActor [weak self] in
          await self?.stopRecordingFromEndPrompt(generation: generation)
        }
      },
      onDiscard: { [weak self, generation] in
        Task { @MainActor [weak self] in
          await self?.discardFromEndPrompt(generation: generation)
        }
      }
    )
    Task { @MainActor [weak self] in
      guard let self else { return }
      guard self.activeEndPromptID == promptID, self.activeEndPromptGeneration == generation else {
        return
      }
      await self.startPromptCoordinator.postEndPromptNotificationIfPossible(
        promptID: promptID,
        generation: generation,
        reason: reason,
        secondsRemaining: initialSeconds,
        onKeep: { [weak self] generation in
          await self?.keepRecordingFromEndPrompt(generation: generation)
        },
        onStopNow: { [weak self] generation in
          await self?.stopRecordingFromEndPrompt(generation: generation)
        }
      )
    }
    Log.lifecycle.info(
      "End guard prompt shown: \(Self.endGuardReasonLabel(reason), privacy: .public)")
  }

  @MainActor
  private func handleEndGuardCountdownTick(remaining: TimeInterval) {
    guard activeEndPromptGeneration != nil else { return }
    let seconds = max(0, Int(ceil(remaining)))
    endCountdownController.update(secondsRemaining: seconds)
    if let endPrompt = menu?.endPrompt {
      menu?.endPrompt = RecordingMenuEndPrompt(
        generation: endPrompt.generation,
        reason: endPrompt.reason,
        secondsRemaining: seconds
      )
    }
  }

  @MainActor
  private func handleEndGuardAutoStop(reason: EndGuard.Reason) async {
    guard session != nil else { return }
    Log.lifecycle.info(
      "End guard auto-stop firing: \(Self.endGuardReasonLabel(reason), privacy: .public)")
    clearEndGuardPromptSurface()
    await stopRecording(initiator: .endGuard)
  }

  @MainActor
  func keepRecordingFromEndPrompt(generation: Int) async {
    guard let endGuard else {
      clearEndGuardPromptSurface()
      return
    }
    let accepted = await endGuard.keepRecording(now: Date(), generation: generation)
    guard accepted else {
      Log.lifecycle.info("Ignoring stale end guard Keep Recording action")
      return
    }
    Log.lifecycle.info("End guard prompt dismissed: keep recording")
    cancelEndGuardPrompt()
  }

  @MainActor
  func stopRecordingFromEndPrompt(generation: Int) async {
    guard let endGuard else {
      clearEndGuardPromptSurface()
      return
    }
    let accepted = await endGuard.stopNow(generation: generation)
    guard accepted else {
      Log.lifecycle.info("Ignoring stale end guard Stop now action")
      return
    }
    Log.lifecycle.info("End guard prompt accepted: stop now")
    await stopRecording()
  }

  /// Discard from the stop countdown panel: stop the capture and trash
  /// the folder. An explicit click overrides the threshold and origin:
  /// any session, any duration, manual included.
  @MainActor
  func discardFromEndPrompt(generation: Int) async {
    guard let endGuard else {
      clearEndGuardPromptSurface()
      return
    }
    let accepted = await endGuard.stopNow(generation: generation)
    guard accepted else {
      Log.lifecycle.info("Ignoring stale end guard Discard action")
      return
    }
    Log.lifecycle.info("End prompt accepted: discard")
    await stopRecording(discardRequested: true)
  }

  @MainActor
  private func cancelEndGuardPrompt() {
    guard activeEndPromptGeneration != nil else { return }
    clearEndGuardPromptSurface()
    menu?.rebuild(for: status)
    applyTrustIcon()
  }

  @MainActor
  private func clearEndGuardPromptSurface() {
    if let promptID = activeEndPromptID {
      startPromptCoordinator.clearEndPromptNotification(promptID: promptID)
    }
    activeEndPromptGeneration = nil
    activeEndPromptID = nil
    endCountdownController.dismiss()
    menu?.endPrompt = nil
  }

  private static func endGuardReasonLabel(_ reason: EndGuard.Reason) -> String {
    switch reason {
    case .bidirectionalSilence: return "bidirectional_silence"
    case .callEnded: return "call_ended"
    case .maxSessionDurationReached: return "max_session_duration"
    }
  }

  private static func endGuardReasonCopy(_ reason: EndGuard.Reason) -> String {
    switch reason {
    case .bidirectionalSilence: return "audio has been quiet"
    case .callEnded: return "call ended"
    case .maxSessionDurationReached: return "session reached 4 hours"
    }
  }
}
