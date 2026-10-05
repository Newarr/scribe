import AppKit
import TranscriberCore

extension AppDelegate {
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
    guard canStartRecording else { return }
    foregroundTranscription = nil
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
    guard snapshot.privacyAcknowledged || allowPendingPrivacyAcknowledgementForOnboardingTest else {
      Log.lifecycle.info("startRecording blocked: privacy acknowledgement pending")
      presentPrivacyAcknowledgementIfNeeded()
      return
    }
    if allowPendingPrivacyAcknowledgementForOnboardingTest && !snapshot.privacyAcknowledged {
      Log.lifecycle.info(
        "startRecording proceeding for consented onboarding test recording before final privacy acknowledgement"
      )
    }

    self.capturePhase = .starting
    menu?.rebuild(for: status)
    applyTrustIcon()

    // Audit before capture so permission prompts stay inside Scribe UI.
    let report = await preflightDoctor.audit(
      outputRoot: snapshot.outputRoot, engineMode: snapshot.engineMode)
    guard !termination.hasStarted, capturePhase == .starting else { return }
    if let freeBytes = Self.availableDiskBytes(for: snapshot.outputRoot),
      freeBytes < Self.minimumFreeDiskBytes
    {
      denyStartForLowDisk(freeBytes: freeBytes, outputRoot: snapshot.outputRoot)
      return
    }

    guard handleStartPreflightResult(report) else { return }

    let id = SessionID(from: Date())
    do {
      let dir = try SessionDirectory.create(under: snapshot.outputRoot, id: id)
      let sessionEngineMode = snapshot.engineMode
      let session = try makeCaptureSession(directory: dir, engineMode: sessionEngineMode)
      installStartingSession(session, directory: dir, engineMode: sessionEngineMode)

      // Slice 6: prefer the watcher cache (already populated, no
      // EventKit round-trip on the start path). Fall back to the
      // direct lookup if the cache hasn't been refreshed yet.
      let promptedEvent = pendingPromptCalendarEventForStart
      let cachedEvent = promptedEvent == nil ? await calendarWatcher.eventOverlapping(Date()) : nil
      let event = promptedEvent ?? cachedEvent ?? calendar.eventOverlapping(Date())
      Log.calendar.info(
        "Calendar lookup at session start: matched=\(event != nil ? "yes" : "no", privacy: .public)"
      )

      guard !termination.hasStarted, self.session === session, capturePhase == .starting else { return }
      self.currentCalendarEvent = event
      do {
        try await session.start()
        guard self.session === session, capturePhase == .starting else { return }
        await finishSuccessfulStart(directory: dir, event: event)
      } catch {
        guard self.session === session else { return }
        await handleStartFailure(error, session: session)
      }
    } catch {
      await handleStartFailure(error, session: nil)
    }
  }

  @MainActor
  func handleStartPreflightResult(_ report: PreflightReport) -> Bool {
    switch RecordRequestGate().verdict(from: report) {
    case .deny(let reasons):
      // Codex rc2-audit P0 (privacy): String(describing: reasons)
      // expands the associated URL values, which carry
      // `/Users/<name>/...` paths. Use the safe `publicLabels`
      // accessor for .public; full reasons at .private.
      Log.lifecycle.error(
        "startRecording denied by preflight: \(reasons.publicLabels, privacy: .public) [\(String(describing: reasons), privacy: .private)]"
      )
      capturePhase = .idle
      // Codex PM-review UX-7: flag the menu so "Setup Required…"
      // appears (instead of the neutral "Check setup…") until
      // the next successful start.
      menu?.setupNeedsAttention = true
      self.setupNeedsAttention = true
      menu?.rebuild(for: status)
      applyTrustIcon()
      self.sessionRepairPayload = nil
      // Permission-only blockers → polished onboarding window;
      // engine/output blockers stay on the popover path.
      if Self.allBlockersArePermissions(report) {
        setupPopover?.close()
        permissionsOnboarding?.present()
      } else {
        showSetupRequiredPopover(report: report, sessionRepairPayload: nil)
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
    _ session: CaptureSession, directory: SessionDirectory, engineMode: EngineMode
  ) {
    self.session = session
    currentSessionDirectory = directory
    currentSessionStartedAt = Date()
    currentSessionEngineMode = engineMode
    currentRecordingTriggerIdentity = pendingPromptCandidateForStart?.triggerIdentity
    menu?.sessionEngineMode = engineMode
    currentDiagnosticsLiveLevels = nil
  }

  @MainActor
  private func denyStartForLowDisk(freeBytes: Int64, outputRoot: URL) {
    Log.lifecycle.error(
      "startRecording denied: low disk space (\(freeBytes, privacy: .public) bytes free)")
    capturePhase = .idle
    menu?.rebuild(for: status)
    applyTrustIcon()
    presentLowDiskAlert(freeBytes: freeBytes, outputRoot: outputRoot)
  }

  @MainActor
  private func finishSuccessfulStart(directory: SessionDirectory, event: CalendarEvent?) async {
    capturePhase = .recording
    pendingPromptCandidateForStart = nil
    await startEndGuard(startedAt: currentSessionStartedAt ?? Date())
    guard currentSessionDirectory == directory, capturePhase == .recording else { return }
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

  @MainActor
  func handleStartFailure(_ error: Error, session failedSession: CaptureSession?) async {
    let needsStopRetry = await failedSession?.needsStopRetry ?? false
    guard session === failedSession else { return }
    if needsStopRetry {
      showCaptureStopFailure()
      return
    }
    Log.lifecycle.error("Start failed: \(String(describing: error), privacy: .public)")
    // Codex rc2-audit STATE-3: a failed start would leave
    // self.session / currentSessionDirectory / currentSessionStartedAt
    // populated. A subsequent Stop or Quit would then write a
    // pending transcript for a never-started session. Clear all
    // session state on the catch path so the app is well-defined.
    capturePhase = .failed
    session = nil
    currentSessionDirectory = nil
    currentSessionStartedAt = nil
    currentCalendarEvent = nil
    currentSessionEngineMode = nil
    currentDiagnosticsLiveLevels = nil
    currentRecordingTriggerIdentity = nil
    pendingPromptCandidateForStart = nil
    stopElapsedTickTimer()
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
  func stopRecording() async {
    if let captureStopTask {
      await captureStopTask.value
      return
    }
    guard let session, let dir = currentSessionDirectory else { return }
    capturePhase = .stopping
    menu?.rebuild(for: status)
    applyTrustIcon()
    let task = Task { await finishRecording(session: session, directory: dir) }
    captureStopTask = task
    await task.value
    captureStopTask = nil
    if capturePhase == .idle, !termination.hasStarted {
      reevaluateQueuedDetectionCandidateAfterStop()
    }
  }

  private func finishRecording(session: CaptureSession, directory dir: SessionDirectory) async {
    let endedAt = Date()
    let started = currentSessionStartedAt ?? endedAt
    let event = currentCalendarEvent
    let snap = settings
    let sessionEngineMode = currentSessionEngineMode ?? snap.engineMode
    await tearDownEndGuard()

    do {
      try await session.stop()
      guard Self.captureFinalizationIsDurable(in: dir) else {
        throw CaptureSession.CaptureError.noDurableAudio
      }
    } catch {
      Log.engine.error("Stop failed: \(String(describing: error), privacy: .public)")
      if await session.needsStopRetry {
        showCaptureStopFailure()
      } else {
        releaseCapture()
        capturePhase = .failed
        clearQueuedDetectionCandidate()
        menu?.outcomeFolderName = dir.url.lastPathComponent
        menu?.outcomeFolderURL = dir.url
        menu?.rebuild(for: status)
        markFailureFlash()
      }
      return
    }

    releaseCapture()
    capturePhase = .idle
    let context = Self.makeContext(
      dir: dir, startedAt: started, endedAt: endedAt, event: event, engineMode: sessionEngineMode)
    do {
      try TranscriptWriter.writePending(at: dir.transcript, context: context)
    } catch {
      Log.engine.error("Failed to write pending transcript: \(String(describing: error), privacy: .public)")
    }
    guard !termination.hasStarted else { return }

    beginTranscription(at: dir.url, engineMode: sessionEngineMode, sourceLabel: Self.recordingSourceLabel(for: event))
    let worker = Self.makeWorker(
      dir: dir, context: context, event: event, keepRawStreams: snap.keepRawStreams,
      engineMode: sessionEngineMode, transcriptionLanguage: snap.transcriptionLanguage)
    let task = Task { [weak self] in
      let outcome = await worker.run()
      guard let self else { return }
      self.finishTranscription(outcome, at: dir.url)
      self.transcriptionTasks.removeValue(forKey: dir.url)
      if case .complete = outcome, self.session == nil, !self.termination.hasStarted {
        self.presentSavedNotification(
          dir: dir, event: event, durationSeconds: Int(endedAt.timeIntervalSince(started)),
          engineLabel: sessionEngineMode.displayName)
      }
    }
    transcriptionTasks[dir.url] = task
  }

  private func releaseCapture() {
    session = nil
    currentSessionDirectory = nil
    currentSessionStartedAt = nil
    currentCalendarEvent = nil
    currentSessionEngineMode = nil
    currentDiagnosticsLiveLevels = nil
    currentRecordingTriggerIdentity = nil
    pendingPromptCandidateForStart = nil
    stopElapsedTickTimer()
  }

  private func showCaptureStopFailure() {
    capturePhase = .recording
    menu?.recordingSourceLabel = "Could not stop recording. Try Stop again."
    menu?.rebuild(for: status)
    applyTrustIcon()
  }

  func beginTranscription(at directory: URL, engineMode: EngineMode, sourceLabel: String) {
    if capturePhase == .idle || (capturePhase == .failed && session == nil) {
      capturePhase = .idle
      foregroundTranscription = .init(directory: directory, engineMode: engineMode, sourceLabel: sourceLabel)
      menu?.outcomeFolderName = directory.lastPathComponent
      menu?.outcomeFolderURL = directory
      menu?.sessionEngineMode = engineMode
      menu?.recordingSourceLabel = sourceLabel
      menu?.rebuild(for: status)
      applyTrustIcon()
    }
  }

  func finishTranscription(_ outcome: TranscriptionWorker.FinalState, at directory: URL) {
    guard foregroundTranscription?.directory == directory else { return }
    foregroundTranscription?.state = .finished(outcome)
    guard capturePhase == .idle else { return }
    switch outcome {
    case .complete:
      resetMenuAfterWorker()
      markSavedFlash()
    case .failed:
      menu?.rebuild(for: status)
      markFailureFlash()
    case .cancelled:
      resetMenuAfterWorker()
      applyTrustIcon()
    }
  }

  func resetMenuAfterWorker() {
    menu?.outcomeFolderName = nil
    menu?.outcomeFolderURL = nil
    menu?.recordingSourceLabel = "Recording"
    menu?.elapsedSeconds = 0
    menu?.sessionEngineMode = .cloud
    menu?.rebuild(for: status)
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
