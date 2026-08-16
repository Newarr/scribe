import AppKit
import TranscriberCore

extension AppDelegate {
  /// Trigger identity for a detection candidate: calendar occurrence
  /// when one overlaps, else the plain app signature.
  @MainActor
  func triggerIdentity(for app: MeetingApp) async -> String {
    let event = await calendarWatcher.eventOverlapping(Date())
    if let identity = event?.occurrenceIdentity?.rawValue {
      return "calendar:\(identity)"
    }
    return DetectionEngine.defaultTriggerIdentity(for: app)
  }

  /// Engine fires this when a candidate passed the AutoRecordPolicy
  /// gates inside DetectionEngine. Calendar lookup is enrichment-only.
  /// A recording already live queues the candidate; otherwise the
  /// candidate either auto-starts a silent recording or parks in the
  /// passive "Meeting detected" state when auto-record is off.
  @MainActor
  func handleDetectionCandidate(_ candidate: DetectionCandidate) async {
    let event = await calendarWatcher.eventOverlapping(Date())
    if status == .recording || status == .starting {
      queueDetectionCandidate(candidate, event: event)
      return
    }
    guard settings.autoRecordEnabled else {
      Log.lifecycle.info(
        "Detection candidate parked (auto-record off): \(candidate.app.bundleID, privacy: .public) trigger=\(candidate.triggerIdentity, privacy: .public)"
      )
      // The parked hold keeps the candidate staged so a manual Record
      // Now attaches its identity (ended-call routing keeps working)
      // and the trust icon shows the pulse.
      parkedCandidate = (candidate: candidate, event: event)
      applyTrustIcon()
      return
    }
    Log.lifecycle.info(
      "Auto-record candidate: \(candidate.app.bundleID, privacy: .public) trigger=\(candidate.triggerIdentity, privacy: .public)"
    )
    Log.calendar.info("Start enrichment: matched=\(event != nil ? "yes" : "no", privacy: .public)")
    // Park first: a failed silent start (privacy, disk, preflight)
    // restores the hold, and a successful start consumes it.
    parkedCandidate = (candidate: candidate, event: event)
    let outcome = await performStart(origin: .detected, staged: (candidate, event))
    if case .failed(let reason) = outcome {
      // Silent path never opens a window; the Setup Required trust
      // state and this log are the whole report. The candidate stays
      // parked so ended-call recognition can clear it and a manual
      // Record Now can attach it.
      Log.lifecycle.info(
        "Auto-record start declined: \(reason, privacy: .public)")
    }
  }

  /// Recognition proved a call ended. Routes the stop when the ended
  /// call is the one being recorded; otherwise clears the parked hold
  /// if it belonged to this candidate.
  @MainActor
  func handleEndedDetectionCandidate(_ candidate: DetectionCandidate) async {
    if isEndedCandidateForCurrentRecording(candidate) {
      Log.lifecycle.info(
        "Detection candidate ended during recording: \(candidate.app.bundleID, privacy: .public) trigger=\(candidate.triggerIdentity, privacy: .public)"
      )
      await endGuard?.suspectCallEnded(at: Date())
      return
    }

    guard let parked = parkedCandidate,
      DetectionTriggerIdentity.matchesEndedCandidate(
        pendingTriggerIdentity: parked.candidate.triggerIdentity,
        pendingBundleID: parked.candidate.bundleID,
        endedCandidate: candidate
      )
    else { return }
    Log.lifecycle.info(
      "Detection candidate ended without recording: \(candidate.app.bundleID, privacy: .public) trigger=\(candidate.triggerIdentity, privacy: .public)"
    )
    parkedCandidate = nil
    applyTrustIcon()
  }

  @MainActor
  private func isEndedCandidateForCurrentRecording(_ candidate: DetectionCandidate) -> Bool {
    guard session != nil else { return false }
    return currentRecordingTriggerIdentity == candidate.triggerIdentity
  }
}
