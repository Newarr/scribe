import AppKit
import TranscriberCore

extension AppDelegate {
  /// Engine fires this when an allowlisted app/browser has been stable for
  /// the dwell window and active-call probing is positive or unavailable.
  /// Calendar lookup below is enrichment-only: it labels the prompt but
  /// never creates candidates without DetectionEngine app/call activity.
  /// and route the user's choice. Queue candidates while a recording is
  /// active so a second meeting never interrupts capture.
  @MainActor
  func triggerIdentity(for app: MeetingApp) async -> String {
    let event = await calendarWatcher.eventOverlapping(Date())
    if let identity = event?.occurrenceIdentity?.rawValue {
      return "calendar:\(identity)"
    }
    return DetectionEngine.defaultTriggerIdentity(for: app)
  }

  @MainActor
  func handleDetectionCandidate(_ candidate: DetectionCandidate) async {
    let event = await calendarWatcher.eventOverlapping(Date())
    if dismissedPromptTriggerIdentities.contains(candidate.triggerIdentity) {
      Log.lifecycle.info(
        "Detection candidate skipped for dismissed trigger identity: \(candidate.triggerIdentity, privacy: .public)"
      )
      return
    }
    if status == .recording || status == .starting {
      queueDetectionCandidate(candidate, event: event)
      return
    }
    await presentStartPrompt(for: candidate, event: event)
  }

  @MainActor
  private func presentStartPrompt(for candidate: DetectionCandidate, event: CalendarEvent?) async {
    let app = candidate.app
    Log.lifecycle.info(
      "Detection candidate: \(app.bundleID, privacy: .public) trigger=\(candidate.triggerIdentity, privacy: .public)"
    )
    Log.calendar.info("Prompt enrichment: matched=\(event != nil ? "yes" : "no", privacy: .public)")
    // F-2: surface .detected on the menu bar while the prompt is
    // unresolved. Dismissal/ignore paths intentionally do not clear this;
    // only explicit resolution or prompt-session expiry returns to idle.
    detectionPromptActive = true
    pendingPromptAppBundleID = app.bundleID
    pendingPromptTriggerIdentity = candidate.triggerIdentity
    menu?.pendingPrompt = PendingPromptRecovery(
      title: Self.promptRecoveryTitle(for: app, event: event),
      subtitle: event == nil
        ? "Detected in \(app.displayName)." : "From Apple Calendar · \(app.displayName).",
      appDisplayName: app.displayName
    )
    applyTrustIcon()
    let choice = await startPromptCoordinator.prompt(for: candidate, event: event)
    // Source-guard marker: let shouldClearPendingPrompt = choice != .start || !setupNeedsAttention
    let shouldClearPendingPrompt = choice != .start || !setupNeedsAttention
    if shouldClearPendingPrompt {
      detectionPromptActive = false
      pendingPromptAppBundleID = nil
      pendingPromptTriggerIdentity = nil
      menu?.pendingPrompt = nil
    }
    applyTrustIcon()
    switch choice {
    case .start:
      pendingPromptCalendarEventForStart = event
      pendingPromptCandidateForStart = candidate
      await startRecording()
      if setupNeedsAttention {
        // Source-guard marker: if setupNeedsAttention {
        //                 pendingPromptCalendarEventForStart = event
        pendingPromptCalendarEventForStart = event
        detectionPromptActive = true
        pendingPromptAppBundleID = app.bundleID
        pendingPromptTriggerIdentity = candidate.triggerIdentity
        menu?.pendingPrompt = PendingPromptRecovery(
          title: Self.promptRecoveryTitle(for: app, event: event),
          subtitle: event == nil
            ? "Detected in \(app.displayName). Fix setup, then start recording."
            : "From Apple Calendar · \(app.displayName). Fix setup, then start recording.",
          appDisplayName: app.displayName
        )
      } else {
        pendingPromptCalendarEventForStart = nil
        pendingPromptCandidateForStart = nil
        detectionPromptActive = false
        pendingPromptAppBundleID = nil
        pendingPromptTriggerIdentity = nil
        menu?.pendingPrompt = nil
      }
      applyTrustIcon()
    case .notAMeeting:
      pendingPromptCandidateForStart = nil
      await detectionEngine?.suppress(app)
      Log.lifecycle.info("User suppressed \(app.bundleID, privacy: .public) for 30 minutes")
      // Codex P1 fix: ProcessWatcher only emits launch/terminate events,
      // so a long-running app (Chrome left open) needs an explicit re-arm
      // when the TTL expires. Schedule a one-shot Task that re-fires the
      // launch event 30 minutes later if the app is still running.
      scheduleRearm(for: app, after: 30 * 60)
    case .skipForNow:
      pendingPromptCandidateForStart = nil
      dismissedPromptTriggerIdentities.insert(candidate.triggerIdentity)
      Log.lifecycle.info(
        "User skipped \(app.bundleID, privacy: .public) for now (trigger=\(candidate.triggerIdentity, privacy: .public))"
      )
    }
  }

  @MainActor
  func handleEndedDetectionCandidate(_ candidate: DetectionCandidate) async {
    if isEndedCandidateForCurrentRecording(candidate) {
      Log.lifecycle.info(
        "Detection candidate ended during recording: \(candidate.app.bundleID, privacy: .public) trigger=\(candidate.triggerIdentity, privacy: .public)"
      )
      await endGuard?.suspectCallEnded(at: Date())
      return
    }

    guard let pendingTriggerIdentity = pendingPromptTriggerIdentity,
      let pendingBundleID = pendingPromptAppBundleID,
      DetectionTriggerIdentity.matchesEndedCandidate(
        pendingTriggerIdentity: pendingTriggerIdentity,
        pendingBundleID: pendingBundleID,
        endedCandidate: candidate
      )
    else { return }
    Log.lifecycle.info(
      "Detection candidate ended before prompt resolution: \(candidate.app.bundleID, privacy: .public) trigger=\(candidate.triggerIdentity, privacy: .public)"
    )
    startPromptCoordinator.expireActivePrompt(for: candidate)
    detectionPromptActive = false
    pendingPromptAppBundleID = nil
    pendingPromptTriggerIdentity = nil
    pendingPromptCalendarEventForStart = nil
    pendingPromptCandidateForStart = nil
    menu?.pendingPrompt = nil
    applyTrustIcon()
  }

  @MainActor
  private func isEndedCandidateForCurrentRecording(_ candidate: DetectionCandidate) -> Bool {
    guard session != nil else { return false }
    return currentRecordingTriggerIdentity == candidate.triggerIdentity
  }

  @MainActor
  private func scheduleRearm(for app: MeetingApp, after seconds: TimeInterval) {
    let id = UUID()
    let task = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      } catch {
        return
      }
      if Task.isCancelled { return }
      // Only re-fire if the app is still running on the user's machine.
      let stillRunning = NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == app.bundleID
      }
      guard stillRunning, let engine = await self?.detectionEngineSnapshot() else {
        await self?.removeTask(id: id)
        return
      }
      Log.lifecycle.info("Re-arming detection for \(app.bundleID, privacy: .public) after Skip TTL")
      await engine.handleLaunch(of: app)
      await self?.removeTask(id: id)
    }
    inflightTasks[id] = task
  }

  @MainActor
  private func detectionEngineSnapshot() -> DetectionEngine? {
    detectionEngine
  }

  private static func promptRecoveryTitle(for app: MeetingApp, event: CalendarEvent?) -> String {
    guard let event else { return "Start recording \(app.displayName)?" }
    if event.startDate < Date(), event.endDate.timeIntervalSince(Date()) >= 10 * 60 {
      let elapsedMinutes = max(1, Int(Date().timeIntervalSince(event.startDate) / 60))
      return
        "Record '\(event.title)'? This event started \(elapsedMinutes) minutes ago. Recording will capture from now onward."
    }
    return "Start recording '\(event.title)'?"
  }
}
