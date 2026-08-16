import AppKit
import TranscriberCore

extension AppDelegate {
  /// Typed outcome of a start attempt so the silent (detection-driven)
  /// path can fail without ever opening a window.
  enum StartOutcome: Equatable {
    case started
    case alreadyBusy
    case failed(reason: String)
  }

  /// The staged start: the detection candidate (and its calendar event)
  /// behind the next start, whether that start is an auto-record or a
  /// manual Record Now while a candidate is parked. One value, so the
  /// parked state can never disagree with itself.
  typealias StagedStart = (candidate: DetectionCandidate, event: CalendarEvent?)

  @MainActor
  private func presentLowDiskAlert(freeBytes: Int64, outputRoot: URL) {
    let alert = NSAlert()
    alert.messageText = "Not enough disk space to record"
    alert.informativeText =
      "Scribe needs at least 1 GB free before starting a recording. \(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) is available in the selected folder."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Open folder")
    alert.addButton(withTitle: "Cancel")
    alert.window.sharingType = WindowChromeSharing.confidential
    if alert.runModal() == .alertFirstButtonReturn {
      NSWorkspace.shared.open(outputRoot)
    }
  }

  private static func availableDiskBytes(for url: URL) -> Int64? {
    let values = try? url.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
    ])
    if let important = values?.volumeAvailableCapacityForImportantUsage {
      return important
    }
    if let capacity = values?.volumeAvailableCapacity {
      return Int64(capacity)
    }
    return nil
  }

  @MainActor
  func startRecording(allowPendingPrivacyAcknowledgementForOnboardingTest: Bool = false) async {
    _ = await performStart(
      origin: .manual,
      staged: parkedCandidate,
      allowPendingPrivacyAcknowledgementForOnboardingTest:
        allowPendingPrivacyAcknowledgementForOnboardingTest
    )
  }

  /// Single start path for manual and detection-driven starts. The
  /// preflight (privacy gate, disk space, permission audit) is identical
  /// for both; only the failure presentation differs, and that is
  /// derived from the origin: manual starts keep today's windows
  /// (low-disk alert, consent sheet, setup popover), detected starts
  /// fail typed and surface only through the Setup Required trust
  /// state and lifecycle logs.
  @MainActor
  func performStart(
    origin: AutoRecordPolicy.SessionOrigin,
    staged: StagedStart?,
    allowPendingPrivacyAcknowledgementForOnboardingTest: Bool = false
  ) async -> StartOutcome {
    let interactive = origin == .manual
    // Codex P2 fix: claim .starting before any await so concurrent
    // detection candidates (or a menu Record + a candidate firing
    // simultaneously) can't pass the handleDetectionCandidate guard
    // and create two CaptureSessions.
    guard status != .recording, status != .starting else {
      Log.lifecycle.info(
        "startRecording skipped: already \(self.status.rawValue, privacy: .public)")
      return .alreadyBusy
    }
    // F-2: a new attempt clears any leftover saved/failed flash so
    // the icon doesn't keep mourning the previous session.
    clearTerminalFlash()

    // Phase η spec line 348: recording is gated on privacy ack.
    // If the sheet was dismissed via cmd-q without acknowledging,
    // re-present it instead of starting the engine.
    // One settings read for the whole start path: the privacy gate, the
    // preflight audit, and the session-directory creation below must not
    // see different snapshots (the audit await is a commit window).
    let snapshot = settings
    guard snapshot.privacyAcknowledged || allowPendingPrivacyAcknowledgementForOnboardingTest
    else {
      Log.lifecycle.info(
        "startRecording blocked: privacy acknowledgement pending (\(interactive ? "interactive" : "silent", privacy: .public))")
      if interactive {
        presentPrivacyAcknowledgementIfNeeded()
      }
      return .failed(reason: "privacy acknowledgement pending")
    }
    if allowPendingPrivacyAcknowledgementForOnboardingTest && !snapshot.privacyAcknowledged {
      Log.lifecycle.info(
        "startRecording proceeding for consented onboarding test recording before final privacy acknowledgement"
      )
    }

    self.status = .starting
    menu?.rebuild(for: status)
    applyTrustIcon()

    // Audit before capture so permission prompts stay inside Scribe UI.
    let report = await preflightDoctor.audit(
      outputRoot: snapshot.outputRoot, engineMode: snapshot.engineMode)
    if let freeBytes = Self.availableDiskBytes(for: snapshot.outputRoot),
      freeBytes < Self.minimumFreeDiskBytes
    {
      if interactive {
        denyStartForLowDisk(freeBytes: freeBytes, outputRoot: snapshot.outputRoot)
      } else {
        Log.lifecycle.error(
          "Silent start denied: low disk space (\(freeBytes, privacy: .public) bytes free)")
        status = .idle
        menu?.rebuild(for: status)
        applyTrustIcon()
      }
      return .failed(reason: "low disk")
    }

    guard await handleStartPreflightResult(report, interactive: interactive) else {
      return .failed(reason: "preflight denied")
    }

    let id = SessionID(from: Date())
    do {
      let dir = try SessionDirectory.create(under: snapshot.outputRoot, id: id)
      let sessionEngineMode = snapshot.engineMode
      let session = try makeCaptureSession(directory: dir, engineMode: sessionEngineMode)
      installStartingSession(
        session, directory: dir, engineMode: sessionEngineMode, origin: origin, staged: staged)

      // Slice 6: prefer the staged event, then the watcher cache
      // (already populated, no EventKit round-trip on the start path),
      // then the direct lookup.
      let cachedEvent = staged?.event == nil ? await calendarWatcher.eventOverlapping(Date()) : nil
      let event = staged?.event ?? cachedEvent ?? calendar.eventOverlapping(Date())
      self.currentCalendarEvent = event
      Log.calendar.info(
        "Calendar lookup at session start: matched=\(event != nil ? "yes" : "no", privacy: .public)"
      )

      try await session.start()
      await finishSuccessfulStart(directory: dir, event: event)
      return .started
    } catch {
      handleStartFailure(error)
      return .failed(reason: "capture start failed")
    }
  }

  @MainActor
  private func handleStartPreflightResult(
    _ report: PreflightReport, interactive: Bool
  ) async -> Bool {
    switch RecordRequestGate().verdict(from: report) {
    case .deny(let reasons):
      // Codex rc2-audit P0 (privacy): String(describing: reasons)
      // expands the associated URL values, which carry
      // `/Users/<name>/...` paths. Use the safe `publicLabels`
      // accessor for .public; full reasons at .private.
      Log.lifecycle.error(
        "startRecording denied by preflight: \(reasons.publicLabels, privacy: .public) [\(String(describing: reasons), privacy: .private)]"
      )
      status = .idle
      // Codex PM-review UX-7: flag the menu so "Setup Required…"
      // appears (instead of the neutral "Check setup…") until
      // the next successful start.
      menu?.setupNeedsAttention = true
      self.setupNeedsAttention = true
      menu?.rebuild(for: status)
      applyTrustIcon()
      self.sessionRepairPayload = nil
      // The silent path never opens a window; the Setup Required trust
      // state is the only surface. The interactive path keeps the
      // polished blockers UI.
      if interactive {
        // Permission-only blockers → polished onboarding window;
        // engine/output blockers stay on the popover path.
        if Self.allBlockersArePermissions(report) {
          setupPopover?.close()
          permissionsOnboarding?.present()
        } else {
          showSetupRequiredPopover(report: report, sessionRepairPayload: nil)
        }
      }
      return false
    case .allowWithWarnings(let reasons):
      Log.lifecycle.info(
        "startRecording proceeding with warnings: \(reasons.publicLabels, privacy: .public) [\(String(describing: reasons), privacy: .private)]"
      )
      // UX-7: warnings don't need to scream "Setup Required";
      // recording is happening.
      menu?.setupNeedsAttention = false
      self.setupNeedsAttention = false
      return true
    case .allow:
      menu?.setupNeedsAttention = false
      self.setupNeedsAttention = false
      return true
    }
  }

  @MainActor
  private func makeCaptureSession(directory: SessionDirectory, engineMode: EngineMode) throws
    -> CaptureSession
  {
    // Phase beta: one SCStream with both .audio and .microphone outputs
    // keeps mic and system audio on a shared sync clock.
    let stream = SCKDualOutputStream(sampleRate: 48000, channelCount: 1)
    let mic = SCKAudioCaptureSource(kind: .microphone, stream: stream)
    let sys = SCKAudioCaptureSource(kind: .system, stream: stream)
    return try CaptureSession(
      directory: directory,
      mic: mic,
      system: sys,
      sampleRate: 48000,
      channelCount: 1,
      sessionEngineIdentifier: engineMode.persistedIdentifier,
      liveLevelHandler: { [weak self] stream, rms in
        Task { @MainActor [weak self] in
          self?.recordLiveAudioLevel(stream: stream, rms: rms)
        }
      }
    )
  }

  @MainActor
  private func installStartingSession(
    _ session: CaptureSession,
    directory: SessionDirectory,
    engineMode: EngineMode,
    origin: AutoRecordPolicy.SessionOrigin,
    staged: StagedStart?
  ) {
    self.session = session
    currentSessionDirectory = directory
    currentSessionStartedAt = Date()
    currentSessionEngineMode = engineMode
    currentSessionOrigin = origin
    currentRecordingTriggerIdentity = staged?.candidate.triggerIdentity
    currentRecordingCandidate = staged?.candidate
    menu?.sessionEngineMode = engineMode
    currentDiagnosticsLiveLevels = nil
  }

  @MainActor
  private func denyStartForLowDisk(freeBytes: Int64, outputRoot: URL) {
    Log.lifecycle.error(
      "startRecording denied: low disk space (\(freeBytes, privacy: .public) bytes free)")
    status = .idle
    menu?.rebuild(for: status)
    applyTrustIcon()
    presentLowDiskAlert(freeBytes: freeBytes, outputRoot: outputRoot)
  }

  @MainActor
  private func finishSuccessfulStart(directory: SessionDirectory, event: CalendarEvent?) async {
    status = .recording
    // The staged candidate now belongs to the recording; the parked
    // hold is consumed either way (auto-start or manual attach).
    parkedCandidate = nil
    await startEndGuard(startedAt: currentSessionStartedAt ?? Date())
    // Wire the popover's live trust-surface readouts so the user sees
    // a ticking timer and the matched meeting title the moment they
    // open the menu bar.
    menu?.recordingSourceLabel = Self.recordingSourceLabel(for: event)
    menu?.outcomeFolderName = directory.url.lastPathComponent
    menu?.outcomeFolderURL = directory.url
    menu?.elapsedSeconds = 0
    startElapsedTickTimer()
    menu?.rebuild(for: status)
    applyTrustIcon()
  }

  /// Clears every piece of live-session state. Used by the stop path
  /// and the failed-start path so both leave the app well-defined.
  /// Does not touch the parked candidate: a failed start restores it
  /// (the meeting is still live) and only the ended-candidate signal
  /// clears it.
  @MainActor
  private func clearLiveSessionState() {
    session = nil
    currentSessionDirectory = nil
    currentSessionStartedAt = nil
    currentCalendarEvent = nil
    currentSessionEngineMode = nil
    currentDiagnosticsLiveLevels = nil
    currentRecordingTriggerIdentity = nil
    currentRecordingCandidate = nil
    currentSessionOrigin = .manual
    stopElapsedTickTimer()
  }

  @MainActor
  private func handleStartFailure(_ error: Error) {
    Log.lifecycle.error("Start failed: \(String(describing: error), privacy: .public)")
    // Codex rc2-audit STATE-3: a failed start would leave
    // self.session / currentSessionDirectory / currentSessionStartedAt
    // populated. A subsequent Stop or Quit would then write a
    // pending transcript for a never-started session. Clear all
    // session state on the catch path so the app is well-defined.
    status = .failed
    clearLiveSessionState()
    menu?.outcomeFolderName = nil
    menu?.outcomeFolderURL = nil
    menu?.sessionEngineMode = .cloud
    menu?.recordingSourceLabel = "Recording"
    menu?.queuedNextMeeting = nil
    menu?.elapsedSeconds = 0
    menu?.rebuild(for: status)
    applyTrustIcon()
  }

  @MainActor
  private func recordLiveAudioLevel(stream: PTSCollector.StreamID, rms: Float) {
    let safeRMS = Double(min(max(rms, 0), 1))
    let existing = currentDiagnosticsLiveLevels
    let guardStream: EndGuard.AudioStream
    switch stream {
    case .mic:
      currentDiagnosticsLiveLevels = .init(micRMS: safeRMS, systemRMS: existing?.systemRMS)
      menu?.micLevel = Float(safeRMS)
      guardStream = .mic
    case .system:
      currentDiagnosticsLiveLevels = .init(micRMS: existing?.micRMS, systemRMS: safeRMS)
      menu?.systemLevel = Float(safeRMS)
      guardStream = .system
    }
    if let endGuard {
      Task {
        await endGuard.observeAudioLevel(stream: guardStream, rms: Float(safeRMS), at: Date())
      }
    }
  }

  /// Maps a matched calendar event to a short, sentence-case label
  /// the popover shows alongside the LIVE indicator. Falls back to
  /// `Recording` when there's no calendar match (the user
  /// triggered Record manually).
  private static func recordingSourceLabel(for event: CalendarEvent?) -> String {
    let title = event?.title.trimmingCharacters(in: .whitespaces) ?? ""
    return title.isEmpty ? "Recording" : title
  }

  /// Stand up the per-second tick that drives the popover's
  /// elapsed-time field. Runs on `RunLoop.main` so the popover
  /// observes the change immediately without dispatching across
  /// actors.
  @MainActor
  private func startElapsedTickTimer() {
    elapsedTickTimer?.invalidate()
    let started = currentSessionStartedAt ?? Date()
    elapsedTickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(started)))
        self.menu?.elapsedSeconds = elapsed
      }
    }
  }

  @MainActor
  private func stopElapsedTickTimer() {
    elapsedTickTimer?.invalidate()
    elapsedTickTimer = nil
  }

  private nonisolated static func captureFinalizationIsDurable(in dir: SessionDirectory) -> Bool {
    let fm = FileManager.default
    for url in [dir.micFinal, dir.systemFinal] {
      var isDirectory: ObjCBool = false
      guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
        fm.isReadableFile(atPath: url.path)
      else {
        return false
      }
    }
    // Parse the frontmatter with the same reader recovery uses instead of
    // substring-matching raw transcript bytes; a core serialization change
    // (quoting, key order) must not turn every stop into noDurableAudio.
    guard let frontmatter = TranscriptFrontmatterReader.read(at: dir.transcript),
      frontmatter.status == .pending
    else {
      return false
    }
    let audio = frontmatter.context.audioRelativePaths
    return audio.contains(dir.micFinal.lastPathComponent)
      && audio.contains(dir.systemFinal.lastPathComponent)
  }

  @MainActor
  func stopRecording(
    initiator: AutoRecordPolicy.StopInitiator = .user, discardRequested: Bool = false
  ) async {
    guard let session, let dir = currentSessionDirectory else { return }
    await tearDownEndGuard()
    self.status = .stopping
    menu?.rebuild(for: status)
    applyTrustIcon()
    let endedAt = Date()
    let started = currentSessionStartedAt ?? endedAt
    let event = currentCalendarEvent
    let origin = currentSessionOrigin
    let recordingCandidate = currentRecordingCandidate
    // One settings read for the whole stop path: session.stop() below is
    // a commit window, and the worker must not mix engineMode from one
    // snapshot with keepRawStreams/transcriptionLanguage from another.
    let snap = settings
    let sessionEngineMode = currentSessionEngineMode ?? snap.engineMode
    let durationSeconds = endedAt.timeIntervalSince(started)
    // An explicit Discard click is a user decision and always trashes.
    // Otherwise only EndGuard-initiated stops of detected sessions
    // under the threshold auto-discard.
    let shouldDiscard =
      discardRequested
      || AutoRecordPolicy.shouldAutoDiscard(
        durationSeconds: durationSeconds,
        origin: origin,
        initiator: initiator,
        thresholdSeconds: TimeInterval(snap.autoDiscardThresholdSeconds)
      )

    var stopSucceeded = false
    do {
      try await session.stop()
      guard Self.captureFinalizationIsDurable(in: dir) else {
        throw CaptureSession.CaptureError.noDurableAudio
      }
      self.status = .finalized
      stopSucceeded = true
    } catch {
      Log.lifecycle.error("Stop failed: \(String(describing: error), privacy: .public)")
      self.status = .failed
    }
    clearLiveSessionState()
    parkedCandidate = nil
    menu?.outcomeFolderName = dir.url.lastPathComponent
    menu?.outcomeFolderURL = dir.url
    menu?.sessionEngineMode = sessionEngineMode
    menu?.recordingSourceLabel = Self.recordingSourceLabel(for: event)
    menu?.elapsedSeconds = max(0, Int(durationSeconds))
    menu?.rebuild(for: status)
    applyTrustIcon()

    // session.stop() failure is a terminal failure (audio commit
    // broke). Flash the failed glyph and bail before spawning the
    // transcript worker.
    if !stopSucceeded {
      self.status = .failed
      clearQueuedDetectionCandidate()
      menu?.rebuild(for: status)
      markFailureFlash()
      return
    }

    if shouldDiscard {
      await discardStoppedSession(
        dir: dir,
        candidate: recordingCandidate,
        origin: origin,
        started: started,
        endedAt: endedAt,
        event: event,
        engineMode: sessionEngineMode,
        keepRawStreams: snap.keepRawStreams,
        transcriptionLanguage: snap.transcriptionLanguage)
      return
    }

    keepStoppedSession(
      dir: dir,
      started: started,
      endedAt: endedAt,
      event: event,
      origin: origin,
      engineMode: sessionEngineMode,
      keepRawStreams: snap.keepRawStreams,
      transcriptionLanguage: snap.transcriptionLanguage,
      durationSeconds: Int(durationSeconds))
  }

  /// The keep tail: pending transcript, worker dispatch, then queued-
  /// candidate re-evaluation. Shared by the normal stop and the
  /// failed-discard fallback so both paths stay identical.
  @MainActor
  private func keepStoppedSession(
    dir: SessionDirectory,
    started: Date,
    endedAt: Date,
    event: CalendarEvent?,
    origin: AutoRecordPolicy.SessionOrigin,
    engineMode: EngineMode,
    keepRawStreams: Bool,
    transcriptionLanguage: String?,
    durationSeconds: Int
  ) {
    let context = Self.makeContext(
      dir: dir, startedAt: started, endedAt: endedAt, event: event, engineMode: engineMode)
    do {
      try TranscriptWriter.writePending(at: dir.transcript, context: context)
    } catch {
      Log.engine.error(
        "Failed to write pending transcript: \(String(describing: error), privacy: .public)")
    }
    // Source-order guard: worker dispatch below precedes the queue
    // re-evaluation so the stopped session has a durable worker path
    // before a queued candidate can start a new recording.
    dispatchWorker(
      dir: dir,
      context: context,
      event: event,
      origin: origin,
      keepRawStreams: keepRawStreams,
      engineMode: engineMode,
      transcriptionLanguage: transcriptionLanguage,
      durationSeconds: durationSeconds)
    reevaluateQueuedDetectionCandidateAfterStop()
  }

  /// Shared tail for every discard: trash the folder, release the
  /// detection candidate so a quiet-start call can re-fire, re-evaluate
  /// a queued candidate, and settle to idle with no notification. A
  /// failed trash keeps the session (never a `failed` transcript for a
  /// discard problem) and runs the exact keep tail.
  @MainActor
  private func discardStoppedSession(
    dir: SessionDirectory,
    candidate: DetectionCandidate?,
    origin: AutoRecordPolicy.SessionOrigin,
    started: Date,
    endedAt: Date,
    event: CalendarEvent?,
    engineMode: EngineMode,
    keepRawStreams: Bool,
    transcriptionLanguage: String?
  ) async {
    do {
      try dir.moveToTrash()
    } catch {
      Log.lifecycle.error(
        "Discard failed; session kept at its current status: \(String(describing: error), privacy: .public)"
      )
      keepStoppedSession(
        dir: dir,
        started: started,
        endedAt: endedAt,
        event: event,
        origin: origin,
        engineMode: engineMode,
        keepRawStreams: keepRawStreams,
        transcriptionLanguage: transcriptionLanguage,
        durationSeconds: 0)
      return
    }
    Log.lifecycle.info(
      "Session discarded to Trash: \(dir.url.lastPathComponent, privacy: .public)")
    // Rule: auto-discard must release its candidate. Without the
    // release, engine coalescing blocks re-detection while the probe
    // still reads active, and a meeting that started quiet records
    // nothing for its whole length.
    if let candidate {
      await detectionEngine?.releaseActiveCandidate(candidate)
    }
    parkedCandidate = nil
    status = .idle
    menu?.outcomeFolderName = nil
    menu?.outcomeFolderURL = nil
    menu?.recordingSourceLabel = "Recording"
    menu?.elapsedSeconds = 0
    menu?.rebuild(for: status)
    applyTrustIcon()
    reevaluateQueuedDetectionCandidateAfterStop()
  }

  /// Dispatches a transcription worker for a session and tracks it in
  /// the inflight table (keyed by directory) so Recents Discard can
  /// cancel it. Auto-recorded (detected) sessions transcribe silently:
  /// the saved window after every call of the day would be a larger new
  /// surface than the capture itself. Manual recordings keep the
  /// confirmation.
  @MainActor
  private func dispatchWorker(
    dir: SessionDirectory,
    context: TranscriptContext,
    event: CalendarEvent?,
    origin: AutoRecordPolicy.SessionOrigin,
    keepRawStreams: Bool,
    engineMode: EngineMode,
    transcriptionLanguage: String?,
    durationSeconds: Int
  ) {
    let worker = Self.makeWorker(
      dir: dir, context: context, event: event, keepRawStreams: keepRawStreams,
      engineMode: engineMode, transcriptionLanguage: transcriptionLanguage)
    let id = UUID()
    let engineLabel = engineMode.displayName
    let task = Task { [weak self] in
      let outcome = await worker.run()
      await MainActor.run {
        guard let self else { return }
        // F-2: spinner ran while the worker was in flight. On
        // success, revert to idle and flash saved. On failure,
        // keep the failed popover actionable against the saved
        // audio folder so Retry has a concrete target.
        switch outcome {
        case .complete:
          self.status = .idle
          self.resetMenuAfterWorker(status: self.status)
          self.markSavedFlash()
          if origin == .manual {
            self.presentSavedNotification(
              dir: dir,
              event: event,
              durationSeconds: durationSeconds,
              engineLabel: engineLabel
            )
          }
        case .failed(let reason):
          self.status = .failed
          self.menu?.sessionEngineMode = engineMode
          self.menu?.outcomeFolderName = dir.url.lastPathComponent
          self.menu?.outcomeFolderURL = dir.url
          self.menu?.recordingSourceLabel = Self.recordingSourceLabel(for: event)
          self.menu?.rebuild(for: self.status)
          Log.engine.error("Worker terminated with failure: \(reason, privacy: .public)")
          self.markFailureFlash()
        case .cancelled:
          self.status = .idle
          self.resetMenuAfterWorker(status: self.status)
          // App was quit / session forcibly aborted / discarded from
          // Recents. Don't flash either success or failure; just
          // settle back to idle.
          self.applyTrustIcon()
        }
      }
      await self?.removeTask(id: id)
    }
    inflightSessions[id] = (task: task, directory: dir.url)
  }

  /// Recents Discard: cancel any live or retrying worker for the
  /// session, then trash the folder. Off-main cancellation wait so the
  /// menu never blocks on an MLX inference step.
  @MainActor
  func discardSession(at url: URL) async {
    Log.lifecycle.info("Recents discard requested: \(url.lastPathComponent, privacy: .public)")
    let workerTasks = inflightSessions
      .filter { $0.value.directory == url }
      .map(\.value.task)
    let dir = SessionDirectory.existing(at: url)
    Task.detached(priority: .userInitiated) { [weak self] in
      for task in workerTasks {
        task.cancel()
        _ = await task.value
      }
      let trashed: URL?
      do {
        trashed = try dir.moveToTrash()
      } catch {
        Log.lifecycle.error(
          "Recents discard failed (kept in place): \(String(describing: error), privacy: .public)"
        )
        trashed = nil
      }
      await MainActor.run { [weak self] in
        for (id, entry) in self?.inflightSessions ?? [:] where entry.directory == url {
          self?.removeTask(id: id)
        }
        self?.menu?.refreshRecents()
        if trashed != nil {
          Log.lifecycle.info(
            "Session discarded to Trash: \(url.lastPathComponent, privacy: .public)")
        }
      }
    }
  }

  @MainActor
  func resetMenuAfterWorker(status: SessionStatus) {
    menu?.outcomeFolderName = nil
    menu?.outcomeFolderURL = nil
    menu?.recordingSourceLabel = "Recording"
    menu?.elapsedSeconds = 0
    menu?.rebuild(for: status)
    menu?.sessionEngineMode = .cloud
  }

  @MainActor
  private func presentSavedNotification(
    dir: SessionDirectory,
    event: CalendarEvent?,
    durationSeconds: Int,
    engineLabel: String
  ) {
    guard FileManager.default.fileExists(atPath: dir.url.path),
      FileManager.default.fileExists(atPath: dir.transcript.path)
    else {
      Log.engine.error(
        "Saved notification suppressed because durable transcript or folder is missing")
      return
    }
    let title = event?.title ?? "Manual recording"
    let sizeBytes = totalAudioBytes(in: dir)
    let summary = SavedNotificationWindowController.Summary(
      title: "\(title) · transcript saved",
      durationSeconds: durationSeconds,
      sizeBytes: sizeBytes,
      engineLabel: engineLabel,
      folderURL: dir.url,
      transcriptURL: dir.transcript
    )
    savedNotification.present(summary)
  }

  /// Uses canonical `audio.m4a` for the saved notification's MB
  /// caption when present. Raw mic/system streams are only a fallback
  /// for legacy or partially recovered sessions where canonical audio
  /// has not been published.
  private nonisolated func totalAudioBytes(in dir: SessionDirectory) -> Int64 {
    if let canonicalSize = audioByteSize(at: dir.audioFinal) {
      return canonicalSize
    }
    return [dir.micFinal, dir.systemFinal].compactMap(audioByteSize(at:)).reduce(0, +)
  }

  private nonisolated func audioByteSize(at url: URL) -> Int64? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attrs[.size] as? NSNumber
    else {
      return nil
    }
    return size.int64Value
  }
}
