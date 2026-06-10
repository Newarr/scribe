import AppKit
import EventKit  // .EKEventStoreChanged notification name (codex slice-6 final-review P1)
import TranscriberCore

/// Codex rc2-audit STATE-2: was @unchecked Sendable + ad-hoc
/// @MainActor on individual methods, a broader claim than the code
/// proves. Annotating the WHOLE class with @MainActor makes the
/// isolation contract explicit: every stored property and every
/// method is implicitly main-actor-isolated, and Swift's strict
/// concurrency enforces that. NSApplicationDelegate callbacks fire
/// on the main thread by AppKit's contract, so this is also runtime-
/// correct.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private struct QueuedDetectionCandidate {
    let candidate: DetectionCandidate
    let event: CalendarEvent?

    var app: MeetingApp { candidate.app }

    var displayTitle: String {
      let title = event?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return title.isEmpty ? app.displayName : title
    }

    var displayTime: String {
      guard let startDate = event?.startDate else { return "after this recording" }
      let formatter = DateFormatter()
      formatter.dateFormat = "HH:mm"
      return formatter.string(from: startDate)
    }

    func isStillActive(at now: Date) -> Bool {
      guard let event else { return true }
      return event.startDate <= now && now < event.endDate
    }
  }

  var statusItem: NSStatusItem?
  var menu: RecordingMenu?
  private var hotKeyRegistrar: StartStopHotKeyRegistrar?
  var session: CaptureSession?
  var status: SessionStatus = .idle
  let permissions = PermissionsService()
  let calendar = CalendarLookup()
  let calendarWatcher = CalendarWatcher()
  private var wakeObserver: NSObjectProtocol?
  private var calendarChangeObserver: NSObjectProtocol?

  var currentSessionDirectory: SessionDirectory?
  var currentSessionStartedAt: Date?
  var currentCalendarEvent: CalendarEvent?
  var currentSessionEngineMode: EngineMode?
  var currentDiagnosticsLiveLevels: DiagnosticsSnapshot.LiveLevels?
  var currentRecordingTriggerIdentity: String?

  /// Drives the popover's elapsed-time field while a session is
  /// active. Fires once per second; the popover formats the value
  /// as `M:SS` / `H:MM:SS`. Timer instead of a `Task.sleep` loop
  /// because the popover is the only consumer and `RunLoop.main`
  /// suspension semantics are simpler under tests.
  var elapsedTickTimer: Timer?

  var inflightTasks: [UUID: Task<Void, Never>] = [:]

  // Detection layer (slice 5 light)
  var detectionEngine: DetectionEngine?
  private var processWatcher: ProcessWatcher?
  let startPromptCoordinator = StartPromptCoordinator()
  private var queuedDetectionCandidate: QueuedDetectionCandidate?
  var pendingPromptCalendarEventForStart: CalendarEvent?
  var pendingPromptCandidateForStart: DetectionCandidate?
  var pendingPromptAppBundleID: String?
  var pendingPromptTriggerIdentity: String?
  var dismissedPromptTriggerIdentities: Set<String> = []

  // End detection mirrors the start prompt path: the recognition layer
  // proves the call ended, then EndGuard owns the 10s stop prompt / Keep
  // Recording flow. The audio-silence fallback uses the same guard.
  var endGuard: EndGuard?
  var endGuardTickTimer: Timer?
  var activeEndPromptGeneration: Int?
  var activeEndPromptID: String?

  // F-2: trust-language flags. The menu bar icon is the design's
  // primary trust surface, so its shape encodes more than just
  // SessionStatus. These fields capture the pieces of state the
  // status enum doesn't carry: setup blockers (PermissionDoctor),
  // an in-flight detection prompt, and the most recent terminal
  // outcome (saved / failed) so the icon can transiently flash a
  // confirmation glyph after a session lands.
  var setupNeedsAttention: Bool = false
  var sessionRepairPayload: SessionRepairRouting.LocalRepairPayload?
  var setupEngineFocus: EngineSettingsCardFocus?
  var detectionPromptActive: Bool = false
  var lastSavedAt: Date?
  var lastFailureAt: Date?
  var savedFlashTimer: Timer?
  /// Window during which `.saved` shows on the menu bar before
  /// reverting to `.idle`. Spec F-2 calls for ~3s.
  static let savedFlashDuration: TimeInterval = 3.0

  // Codex rc2-audit STATE-2: these are immutable constants, so
  // nonisolated to allow access from `nonisolated static func makeWorker`
  // even with the class @MainActor-annotated.
  //
  // Scribe owns the current Keychain service. Older Transcriber builds
  // used `com.szymonsypniewicz.transcriber`; launch-time migration copies
  // readable legacy items here without showing Keychain prompts.
  nonisolated(unsafe) static let keychainService = "com.szymonsypniewicz.scribe"
  nonisolated(unsafe) private static let legacyKeychainService = "com.szymonsypniewicz.transcriber"
  nonisolated(unsafe) static let keychainAccount = "elevenlabs-api-key"

  // Phase η: SwiftUI surfaces for first-run privacy ack, Settings,
  // and the Setup Required popover. Initialized in
  // applicationDidFinishLaunching (which runs on @MainActor); the
  // controllers themselves are @MainActor-isolated.
  var privacyController: PrivacyAcknowledgementController?
  var onboardingController: OnboardingWindowController?
  var onboardingFlowController: OnboardingFlowController?
  var settingsWindowController: SettingsWindowController?
  var setupPopover: PermissionRecoveryPopoverController?
  var permissionsOnboarding: PermissionsOnboardingWindowController?
  var diagnosticsWindowController: DiagnosticsWindowController?
  let savedNotification = SavedNotificationWindowController()
  let endCountdownController = EndCountdownWindowController()

  // Current diagnostics service. Legacy Transcriber values are migrated
  // silently on launch when macOS allows a noninteractive read.
  private static let diagnosticsInstanceService = "com.szymonsypniewicz.scribe"
  private static let legacyDiagnosticsInstanceService = "com.szymonsypniewicz.transcriber"
  private static let diagnosticsInstanceAccount = "diagnostics-instance-id"
  let diagnosticsInstanceID = DiagnosticsInstanceID(
    service: AppDelegate.diagnosticsInstanceService,
    account: AppDelegate.diagnosticsInstanceAccount
  )

  /// Phase ζ: SettingsStore wires runtime contracts (output folder,
  /// engine selection, raw-stream retention, AEC enable) instead of
  /// hardcoding them. The actor handles writes (Phase η Settings UI);
  /// MainActor-bound reads go through `settings` below, which decodes
  /// the same single JSON blob via `SettingsSnapshotReader`.
  private static func defaultSettingsFallback() -> SettingsStore.Defaults {
    // Codex PM-review UX-14: default to ~/Scribe/ instead of
    // ~/Documents/Scribe/. Documents is iCloud-Drive-synced
    // by default on macOS 13+; recording into a synced folder
    // races the cloud sync (truncated audio mid-write, conflict
    // copies, deleted-by-Drive). The home folder is local-only.
    // Existing users keep whatever folder they configured (this
    // is the FALLBACK for new installs).
    let home = FileManager.default.homeDirectoryForCurrentUser
    let defaultRoot = home.appendingPathComponent("Scribe", isDirectory: true)
    return SettingsStore.Defaults(
      outputRoot: defaultRoot,
      engineMode: .cloud,  // rc1: only working engine until Phase ο
      keepRawStreams: false,  // spec line 102
      aecEnabled: true  // D2
    )
  }

  let settingsStore: SettingsStore = SettingsStore(
    defaults: .standard,
    fallback: AppDelegate.defaultSettingsFallback()
  )

  lazy var localModelManager = LocalModelManager(
    cacheRoot: CohereMLXBackend.defaultModelCacheRoot,
    downloader: HuggingFaceLocalModelDownloader()
  )

  /// Auxiliary local-engine models: Silero VAD (~2 MB, silence gating) and
  /// ECAPA VoxLingua107 (~81 MB, language auto-detect). Staged alongside
  /// the Cohere download; missing aux models degrade gracefully (no VAD
  /// gating / no detection) instead of blocking local readiness.
  lazy var sileroVADModelManager = LocalModelManager(
    cacheRoot: CohereMLXBackend.defaultModelCacheRoot,
    manifest: .sileroVADPinned,
    downloader: HuggingFaceLocalModelDownloader()
  )

  lazy var languageIDModelManager = LocalModelManager(
    cacheRoot: CohereMLXBackend.defaultModelCacheRoot,
    manifest: .ecapaLanguageIDPinned,
    downloader: HuggingFaceLocalModelDownloader()
  )

  /// Fire-and-forget staging of the aux models wherever the Cohere
  /// download is kicked. Verified models are skipped, so this is cheap to
  /// call repeatedly; it also backfills users who set up the local engine
  /// before the aux models existed.
  private func stageAuxiliaryLocalModels() {
    let managers = [sileroVADModelManager, languageIDModelManager]
    Task.detached(priority: .utility) {
      for manager in managers {
        let status = await manager.status()
        if status.isReady { continue }
        let result = await manager.startDownload()
        Log.engine.info("Aux local model staging finished: \(String(describing: result), privacy: .public)")
      }
    }
  }

  func engineReadinessProbe() -> EngineReadinessProbing {
    let keychain = KeychainStore(service: Self.keychainService, account: Self.keychainAccount)
    return LocalModelEngineReadinessProbe(
      cloudKeyProbe: { Self.probeCloudKey(keychain: keychain) == .configured },
      localModel: localModelManager
    )
  }

  /// Synchronous current settings (no actor hop). Reads the same
  /// single JSON blob the actor writes, so a Settings UI commit is
  /// observably consistent here.
  var settings: SessionSettings {
    SettingsSnapshotReader.read(fallback: Self.defaultSettingsFallback())
  }

  var outputRoot: URL { settings.outputRoot }
  static let minimumFreeDiskBytes: Int64 = 1_000_000_000

  /// Set once both legacy migrations reach a definitive state. This runs
  /// synchronously in applicationDidFinishLaunching, so steady-state
  /// launches must skip the securityd round-trips (up to five blocking
  /// SecItem calls) instead of re-confirming a finished migration.
  private static let keychainMigrationSettledKey = "KeychainLegacyMigrationSettled.v1"

  private static func migrateLegacyKeychainItemsIfNeeded() {
    let defaults = UserDefaults.standard
    guard defaults.bool(forKey: keychainMigrationSettledKey) == false else { return }
    let apiKeySettled = migrateLegacyKeychainItem(
      account: keychainAccount,
      currentService: keychainService,
      legacyService: legacyKeychainService,
      label: "ElevenLabs API key"
    )
    let diagnosticsSettled = migrateLegacyKeychainItem(
      account: diagnosticsInstanceAccount,
      currentService: diagnosticsInstanceService,
      legacyService: legacyDiagnosticsInstanceService,
      label: "diagnostics instance ID"
    )
    if apiKeySettled && diagnosticsSettled {
      defaults.set(true, forKey: keychainMigrationSettledKey)
    }
  }

  /// Returns true when the migration reached a definitive state (current
  /// item already present, nothing legacy to migrate, or value migrated).
  /// Returns false when the keychain was not silently readable or the write
  /// failed, so the attempt repeats on the next launch.
  private static func migrateLegacyKeychainItem(
    account: String,
    currentService: String,
    legacyService: String,
    label: String
  ) -> Bool {
    guard currentService != legacyService else { return true }
    let current = KeychainStore(service: currentService, account: account)
    let legacy = KeychainStore(service: legacyService, account: account)

    do {
      if let value = try current.read(allowingUserInteraction: false),
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      {
        return true
      }
    } catch {
      Log.lifecycle.info("Skipping \(label, privacy: .public) Keychain migration because the Scribe item is not silently readable")
      return false
    }

    let legacyValue: String
    do {
      guard let value = try legacy.read(allowingUserInteraction: false),
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      else {
        return true
      }
      legacyValue = value
    } catch {
      Log.lifecycle.info("Legacy \(label, privacy: .public) Keychain item is not silently readable; leaving it untouched")
      return false
    }

    do {
      try current.write(legacyValue)
      Log.lifecycle.info("Migrated \(label, privacy: .public) Keychain item to the Scribe service")
      do {
        try legacy.delete(allowingUserInteraction: false)
      } catch {
        // The current item now exists, so the next launch settles on the
        // early-return path even with the legacy item left behind.
        Log.lifecycle.info("Migrated \(label, privacy: .public), but could not silently delete the legacy Keychain item")
      }
      return true
    } catch {
      Log.lifecycle.error("Failed to migrate \(label, privacy: .public) Keychain item to the Scribe service: \(String(describing: error), privacy: .public)")
      return false
    }
  }

  /// Phase α preflight. Engine mode is read from settings; Local readiness
  /// comes from the app-owned LocalModelManager so removed/failed/unsupported
  /// caches block production recording instead of using placeholder readiness.
  var preflightDoctor: PermissionDoctor {
    PermissionDoctor(
      permissions: DefaultPermissionStatusProbe(permissions: permissions),
      engine: engineReadinessProbe()
    )
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    Log.lifecycle.info("App launched, version=\(BuildInfo.version, privacy: .public)")
    ScreenRecordingRelaunchAssist.disarm()
    Self.migrateLegacyKeychainItemsIfNeeded()
    // One settings read for the whole launch path: every consumer below
    // sees the same snapshot.
    let snap = settings
    applyAppearanceTheme(snap.appearanceTheme)
    // Backfill VAD/LID models for users who completed local-engine setup
    // before aux models existed. No-op unless local mode is selected.
    if snap.engineMode == .local {
      stageAuxiliaryLocalModels()
    }
    FontRegistration.assertLoaded()
    #if DEBUG
      let visualSnapshotDirectory = ProcessInfo.processInfo.environment[
        "SCRIBE_VISUAL_SNAPSHOT_DIR"
      ]
      if ProcessInfo.processInfo.arguments.contains("--visual-snapshots")
        || visualSnapshotDirectory != nil
      {
        let snapshotDirectory =
          visualSnapshotDirectory
          ?? FileManager.default.temporaryDirectory
          .appendingPathComponent(
            "scribe-installed-visual-snapshots.\(UUID().uuidString)"
          )
          .path
        let directory = URL(fileURLWithPath: snapshotDirectory, isDirectory: true)
        do {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          try RecordingMenuVisualSnapshotRenderer.renderAll(to: directory)
          try OnboardingVisualSnapshotRenderer.renderAll(to: directory)
          try SettingsInstalledAppSmokeSnapshotRenderer.renderAll(to: directory)
          try PrivacyAcknowledgementVisualSnapshotRenderer.renderAll(to: directory)
          print("Scribe visual snapshots: \(directory.path)")
          NSApp.terminate(nil)
          return
        } catch {
          fputs("Scribe visual snapshot render failed: \(error)\n", stderr)
          exit(1)
        }
      }
      FontRegistration.writeDebugSentinel()
    #endif
    // Codex Phase ζ P1.5: don't silently `try?` the mkdir. If the
    // user has pointed outputRoot at an unmounted volume or a path
    // they don't own, log it loudly so the eventual failed-to-record
    // / empty-recovery-scan symptoms have a breadcrumb.
    do {
      try FileManager.default.createDirectory(at: snap.outputRoot, withIntermediateDirectories: true)
    } catch {
      Log.lifecycle.error(
        "Failed to create outputRoot at \(snap.outputRoot.path, privacy: .private): \(String(describing: error), privacy: .public). Recovery scan will skip this scan; please fix the path or grant permission and relaunch."
      )
    }

    Task {
      // Codex PM-review UX-1: do NOT request Calendar at launch
      // before the user has any product context. The watcher
      // still runs (sees empty event list until permission is
      // granted); the request happens lazily on first record
      // attempt where the user has the context to understand
      // why we'd want their calendar.
      await self.calendarWatcher.start()
    }

    // Refresh the watcher's cache on wake-from-sleep. Long lid-closed
    // gaps would otherwise leave the cache stale until the next 60s tick.
    let nc = NSWorkspace.shared.notificationCenter
    wakeObserver = nc.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        Log.calendar.info("Wake-from-sleep: forcing calendar refresh and detection re-evaluation")
        await self?.calendarWatcher.refreshNow()
        self?.processWatcher?.reevaluateRunningMeetingApps()
      }
    }

    // Refresh the cache when EventKit posts a store-changed notification
    // (user added/edited/deleted an event in Calendar.app). Without this
    // the prompt path would show stale data until the next 60s tick
    // (codex slice-6 review P2.2).
    calendarChangeObserver = NotificationCenter.default.addObserver(
      forName: .EKEventStoreChanged,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        Log.calendar.info("Calendar store changed: forcing refresh and detection re-evaluation")
        await self?.calendarWatcher.refreshNow()
        self?.processWatcher?.reevaluateRunningMeetingApps()
      }
    }

    let m = RecordingMenu(
      localModelStatusProvider: { [weak self] in
        guard let self else { return .notDownloaded(modelID: CohereMLXBackend.modelID) }
        return await self.localModelManager.status()
      },
      onAction: { [weak self] action in
        Task { @MainActor in await self?.handle(action) }
      }
    )
    StatusItemClickTarget.shared.delegate = m
    // Raise the welcome window before opening the popover when a
    // click lands on the menu bar icon and consent is still pending.
    // The window can get buried under other apps, especially since
    // we use a normal window level (not .floating) per UX-4 P1.5.
    StatusItemClickTarget.shared.priorityHandler = { [weak self] _ in
      guard let self else { return false }
      if let pc = self.privacyController, pc.isPending {
        pc.bringFront()
        return true
      }
      return false
    }
    StatusItemClickTarget.shared.contextMenuProvider = { [weak self] in
      let menu = NSMenu()
      let settingsItem = NSMenuItem(
        title: "Settings…",
        action: #selector(AppDelegate.statusContextOpenSettings),
        keyEquivalent: ",")
      settingsItem.target = self
      menu.addItem(settingsItem)
      let folderItem = NSMenuItem(
        title: "Open Transcripts Folder",
        action: #selector(AppDelegate.statusContextOpenTranscripts),
        keyEquivalent: "")
      folderItem.target = self
      menu.addItem(folderItem)
      menu.addItem(.separator())
      let quitItem = NSMenuItem(
        title: "Quit Scribe",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q")
      quitItem.target = NSApp
      menu.addItem(quitItem)
      return menu
    }
    m.outputRoot = snap.outputRoot
    m.appearanceTheme = snap.appearanceTheme
    self.menu = m
    if snap.showInMenuBar {
      installStatusItemIfNeeded()
    }

    let hotKeyRegistrar = StartStopHotKeyRegistrar { [weak self] in
      Task { await self?.toggleRecordingFromShortcut() }
    }
    hotKeyRegistrar.register(snap.startStopShortcut)
    self.hotKeyRegistrar = hotKeyRegistrar

    // Codex Phase η P0.2: orphaned-session supervisor scan can
    // dispatch a worker that uploads audio to ElevenLabs (cloud
    // mode), so it MUST NOT run before the user has acknowledged
    // the privacy notice. If the flag is already set (returning
    // user), kick off recovery now; otherwise the ack callback
    // below schedules it after the user clicks "I understand".
    if snap.privacyAcknowledged {
      scheduleSupervisorRecovery()
    } else {
      Log.lifecycle.info("Supervisor recovery deferred until privacy ack")
    }

    // Detection layer: process allowlist watcher feeds DetectionEngine,
    // engine fires onCandidate after dwell + per-PID input-device
    // check, app shows the start prompt. The probe closes the
    // Signal-opens-for-messaging and Chrome-opens-for-anything-else
    // false positives that dwell-on-launch alone produced.
    let engine = DetectionEngine(
      dwellTime: 30,
      probe: CoreAudioInputProbe(),
      triggerIdentity: { [weak self] app in
        await self?.triggerIdentity(for: app) ?? DetectionEngine.defaultTriggerIdentity(for: app)
      },
      onCandidateEnded: { [weak self] candidate in
        await self?.handleEndedDetectionCandidate(candidate)
      }
    ) { [weak self] candidate in
      await self?.handleDetectionCandidate(candidate)
    }
    self.detectionEngine = engine
    let watcher = ProcessWatcher(
      onLaunch: { app in
        Task { await engine.handleLaunch(of: app) }
      },
      onQuit: { app in
        Task { await engine.handleQuit(of: app) }
      },
      onReevaluate: { app in
        Task { await engine.reevaluate(app) }
      }
    )
    self.processWatcher = watcher
    watcher.start()
    Log.lifecycle.info(
      "Detection layer started (allowlist size=\(MeetingApps.allowlist.count, privacy: .public), dwellTime=30s)"
    )

    // Phase η controllers (MainActor-isolated; safe to construct here
    // because applicationDidFinishLaunching runs on the main thread).
    self.settingsWindowController = SettingsWindowController(
      store: settingsStore,
      fallback: Self.defaultSettingsFallback(),
      keychainService: Self.keychainService,
      keychainAccount: Self.keychainAccount,
      engineReadiness: engineReadinessProbe(),
      onRetryLocalModel: { [weak self] in
        guard let self else { return .notDownloaded(modelID: CohereMLXBackend.modelID) }
        self.stageAuxiliaryLocalModels()
        return await self.localModelManager.retryDownload()
      },
      onClearLocalModelCache: { [weak self] in
        guard let self else { return }
        try await self.localModelManager.clearCache()
      },
      onShowInMenuBarChange: { [weak self] visible in
        self?.setMenuBarVisible(visible)
      },
      onShortcutChange: { [weak self] shortcut in
        self?.hotKeyRegistrar?.register(shortcut)
      },
      onAppearanceThemeChange: { [weak self] theme in
        self?.applyAppearanceTheme(theme)
        self?.menu?.appearanceTheme = theme
      }
    )
    self.setupPopover = PermissionRecoveryPopoverController()
    // Polished permissions onboarding window (replaces the popover
    // for permission-only blockers). The model inside fires
    // `onScreenRecordingRestartRequired` when CGRequest reports
    // granted but the running process can't see it yet — same
    // restart alert + relaunch path as the popover used to invoke.
    self.permissionsOnboarding = PermissionsOnboardingWindowController(
      onScreenRecordingRestartRequired: { [weak self] in
        self?.presentScreenRecordingRestartRequiredAlert()
      }
    )
    self.diagnosticsWindowController = DiagnosticsWindowController(
      snapshotProvider: { [weak self] in
        guard let self else { return Self.emptyDiagnosticsSnapshot() }
        return await self.buildDiagnosticsSnapshot()
      },
      exportHandler: { [weak self] in
        await self?.exportDiagnosticsToFile()
      }
    )

    presentPrivacyAcknowledgementIfNeeded()
  }

  private func applyAppearanceTheme(_ theme: AppearanceTheme) {
    NSApp.appearance = theme.nsAppearance
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    processWatcher?.stop()
    if let wakeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
      self.wakeObserver = nil
    }
    if let calendarChangeObserver {
      NotificationCenter.default.removeObserver(calendarChangeObserver)
      self.calendarChangeObserver = nil
    }
    Task { await self.calendarWatcher.stop() }
    let inflight = Array(inflightTasks.values)
    let hasLiveCapture = (session != nil)
    let relaunchAfterTermination = ScreenRecordingRelaunchAssist.isArmed()

    // Codex extensive-review P1.1 fix: a live CaptureSession isn't tracked
    // in inflightTasks, so a Quit during recording previously exited
    // immediately with the SCStream + AVAssetWriter still live, leaving
    // .partial files and no transcript. Finalize the capture first.
    if !hasLiveCapture && inflight.isEmpty {
      if relaunchAfterTermination {
        ScreenRecordingRelaunchAssist.disarm()
        Self.spawnDelayedRelaunch()
      }
      return .terminateNow
    }

    // Codex PM-review UX-20: confirm before quitting during
    // recording. The user might have hit Cmd-Q by accident, or
    // be unaware a recording is running. Default action is "stop
    // and quit" (saves their work); secondary keeps recording.
    if hasLiveCapture {
      let alert = NSAlert()
      alert.messageText = "Stop recording before quitting?"
      alert.informativeText =
        "Scribe is recording. Quitting now will save the audio and finalize the transcript before exit."
      alert.addButton(withTitle: "Stop and quit")
      alert.addButton(withTitle: "Keep recording")
      alert.window.sharingType = WindowChromeSharing.confidential  // UX-4
      let choice = alert.runModal()
      if choice == .alertSecondButtonReturn {
        Log.lifecycle.info("Quit cancelled by user; recording continues")
        if relaunchAfterTermination {
          ScreenRecordingRelaunchAssist.disarm()
        }
        return .terminateCancel
      }
    }

    Log.lifecycle.info(
      "Quit requested: capture=\(hasLiveCapture, privacy: .public), in-flight tasks=\(inflight.count, privacy: .public); finalizing up to 10s"
    )
    inflight.forEach { $0.cancel() }

    Task { @MainActor in
      // First, finalize any active recording. This produces mic.m4a +
      // system.m4a + transcript.md so the next launch's supervisor can
      // pick up the rest of the pipeline.
      if hasLiveCapture {
        await self.stopRecording()
      }

      // Then wait briefly for in-flight transcription tasks to observe
      // cancellation. status: retrying on disk survives, so the next
      // launch resumes them.
      let deadline = Date().addingTimeInterval(10.0)
      for task in inflight {
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { break }
        _ = await withTaskGroup(of: Void.self) { group in
          group.addTask { _ = await task.value }
          group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(max(0, remaining) * 1_000_000_000))
          }
          await group.next()
          group.cancelAll()
        }
      }
      if relaunchAfterTermination {
        ScreenRecordingRelaunchAssist.disarm()
        Self.spawnDelayedRelaunch()
      }
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  @MainActor
  func removeTask(id: UUID) {
    inflightTasks.removeValue(forKey: id)
  }

  @MainActor
  func queueDetectionCandidate(_ candidate: DetectionCandidate, event: CalendarEvent?) {
    let queued = QueuedDetectionCandidate(candidate: candidate, event: event)
    queuedDetectionCandidate = queued
    menu?.queuedNextMeeting = RecordingMenuQueuedMeeting(
      title: queued.displayTitle, time: queued.displayTime)
    Log.lifecycle.info(
      "Detection candidate \(candidate.app.bundleID, privacy: .public) queued: already \(self.status.rawValue, privacy: .public)"
    )
  }

  @MainActor
  func clearQueuedDetectionCandidate() {
    queuedDetectionCandidate = nil
    menu?.queuedNextMeeting = nil
  }

  @MainActor
  func reevaluateQueuedDetectionCandidateAfterStop() {
    guard let queued = queuedDetectionCandidate else { return }
    clearQueuedDetectionCandidate()
    let now = Date()
    guard queued.isStillActive(at: now) else {
      Log.lifecycle.info(
        "Queued detection candidate \(queued.app.bundleID, privacy: .public) dropped: expired before stop"
      )
      return
    }
    Log.lifecycle.info(
      "Queued detection candidate \(queued.app.bundleID, privacy: .public) re-evaluating after stop"
    )
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.detectionEngine?.releaseActiveCandidate(queued.candidate)
      await self.detectionEngine?.reevaluate(queued.app)
    }
  }
}
