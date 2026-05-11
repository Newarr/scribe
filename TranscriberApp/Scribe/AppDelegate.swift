import AppKit
import Carbon.HIToolbox
import EventKit  // .EKEventStoreChanged notification name (codex slice-6 final-review P1)
import ServiceManagement
import UserNotifications
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
    private var statusItem: NSStatusItem?
    private var menu: RecordingMenu?
    private var hotKeyRegistrar: StartStopHotKeyRegistrar?
    private var session: CaptureSession?
    private var status: SessionStatus = .idle
    private let permissions = PermissionsService()
    private let calendar = CalendarLookup()
    private let calendarWatcher = CalendarWatcher()
    private var wakeObserver: NSObjectProtocol?
    private var calendarChangeObserver: NSObjectProtocol?

    private var currentSessionDirectory: SessionDirectory?
    private var currentSessionStartedAt: Date?
    private var currentCalendarEvent: CalendarEvent?
    private var currentSessionEngineMode: EngineMode?
    private var currentDiagnosticsLiveLevels: DiagnosticsSnapshot.LiveLevels?

    /// Drives the popover's elapsed-time field while a session is
    /// active. Fires once per second; the popover formats the value
    /// as `M:SS` / `H:MM:SS`. Timer instead of a `Task.sleep` loop
    /// because the popover is the only consumer and `RunLoop.main`
    /// suspension semantics are simpler under tests.
    private var elapsedTickTimer: Timer?

    private var inflightTasks: [UUID: Task<Void, Never>] = [:]

    // Detection layer (slice 5 light)
    private var detectionEngine: DetectionEngine?
    private var processWatcher: ProcessWatcher?
    private let startPromptCoordinator = StartPromptCoordinator()

    // F-2: trust-language flags. The menu bar icon is the design's
    // primary trust surface, so its shape encodes more than just
    // SessionStatus. These fields capture the pieces of state the
    // status enum doesn't carry: setup blockers (PermissionDoctor),
    // an in-flight detection prompt, and the most recent terminal
    // outcome (saved / failed) so the icon can transiently flash a
    // confirmation glyph after a session lands.
    private var setupNeedsAttention: Bool = false
    private var sessionRepairPayload: SessionRepairRouting.LocalRepairPayload?
    private var setupEngineFocus: EngineSettingsCardFocus?
    private var detectionPromptActive: Bool = false
    private var lastSavedAt: Date?
    private var lastFailureAt: Date?
    private var savedFlashTimer: Timer?
    /// Window during which `.saved` shows on the menu bar before
    /// reverting to `.idle`. Spec F-2 calls for ~3s.
    private static let savedFlashDuration: TimeInterval = 3.0

    // Codex rc2-audit STATE-2: these are immutable constants, so
    // nonisolated to allow access from `nonisolated static func makeWorker`
    // even with the class @MainActor-annotated.
    //
    // Rename note (Transcriber → Scribe): the keychain service string
    // intentionally keeps the original `com.szymonsypniewicz.transcriber`
    // identifier so existing dev builds don't lose their stored
    // ElevenLabs API key. Migration would require a fallback-read
    // pattern, which we're deferring until there's a user-visible win.
    nonisolated(unsafe) private static let keychainService = "com.szymonsypniewicz.transcriber"
    nonisolated(unsafe) private static let keychainAccount = "elevenlabs-api-key"

    // Phase η: SwiftUI surfaces for first-run privacy ack, Settings,
    // and the Setup Required popover. Initialized in
    // applicationDidFinishLaunching (which runs on @MainActor); the
    // controllers themselves are @MainActor-isolated.
    private var privacyController: PrivacyAcknowledgementController?
    private var onboardingController: OnboardingWindowController?
    private var onboardingFlowController: OnboardingFlowController?
    private var settingsWindowController: SettingsWindowController?
    private var setupPopover: PermissionRecoveryPopoverController?
    private var permissionsOnboarding: PermissionsOnboardingWindowController?
    private var diagnosticsWindowController: DiagnosticsWindowController?
    private let savedNotification = SavedNotificationWindowController()

    // Rename note (Transcriber to Scribe): kept as `transcriber` so the
    // diagnostics instance ID stays stable across the rename; see the
    // keychainService comment above.
    private static let diagnosticsInstanceService = "com.szymonsypniewicz.transcriber"
    private static let diagnosticsInstanceAccount = "diagnostics-instance-id"
    private let diagnosticsInstanceID = DiagnosticsInstanceID(
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
            engineMode: .cloud,         // rc1: only working engine until Phase ο
            keepRawStreams: false,      // spec line 102
            aecEnabled: true            // D2
        )
    }

    private let settingsStore: SettingsStore = SettingsStore(
        defaults: .standard,
        fallback: AppDelegate.defaultSettingsFallback()
    )

    private lazy var localModelManager = LocalModelManager(
        cacheRoot: CohereMLXBackend.defaultModelCacheRoot,
        downloader: HuggingFaceLocalModelDownloader()
    )

    private func engineReadinessProbe() -> EngineReadinessProbing {
        let keychain = KeychainStore(service: Self.keychainService, account: Self.keychainAccount)
        return LocalModelEngineReadinessProbe(
            cloudKeyProbe: { Self.probeCloudKey(keychain: keychain) == .configured },
            localModel: localModelManager
        )
    }

    /// Synchronous current settings (no actor hop). Reads the same
    /// single JSON blob the actor writes, so a Settings UI commit is
    /// observably consistent here.
    private var settings: SessionSettings {
        SettingsSnapshotReader.read(fallback: Self.defaultSettingsFallback())
    }

    private var outputRoot: URL { settings.outputRoot }
    private static let minimumFreeDiskBytes: Int64 = 1_000_000_000

    /// Phase α preflight. Engine mode is read from settings; Local readiness
    /// comes from the app-owned LocalModelManager so removed/failed/unsupported
    /// caches block production recording instead of using placeholder readiness.
    private var preflightDoctor: PermissionDoctor {
        PermissionDoctor(
            permissions: DefaultPermissionStatusProbe(permissions: permissions),
            engine: engineReadinessProbe()
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.lifecycle.info("App launched, version=\(BuildInfo.version, privacy: .public)")
        applyAppearanceTheme(settings.appearanceTheme)
        FontRegistration.assertLoaded()
        #if DEBUG
        FontRegistration.writeDebugSentinel()
        #endif
        // Codex Phase ζ P1.5: don't silently `try?` the mkdir. If the
        // user has pointed outputRoot at an unmounted volume or a path
        // they don't own, log it loudly so the eventual failed-to-record
        // / empty-recovery-scan symptoms have a breadcrumb.
        do {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        } catch {
            Log.lifecycle.error("Failed to create outputRoot at \(self.outputRoot.path, privacy: .private): \(String(describing: error), privacy: .public). Recovery scan will skip this scan; please fix the path or grant permission and relaunch.")
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
            Task { [weak self] in
                Log.calendar.info("Wake-from-sleep: forcing calendar refresh")
                await self?.calendarWatcher.refreshNow()
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
            Task { [weak self] in
                Log.calendar.info("Calendar store changed: forcing refresh")
                await self?.calendarWatcher.refreshNow()
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
        m.outputRoot = outputRoot
        m.appearanceTheme = settings.appearanceTheme
        self.menu = m
        if settings.showInMenuBar {
            installStatusItemIfNeeded()
        }

        let hotKeyRegistrar = StartStopHotKeyRegistrar { [weak self] in
            Task { await self?.toggleRecordingFromShortcut() }
        }
        hotKeyRegistrar.register(settings.startStopShortcut)
        self.hotKeyRegistrar = hotKeyRegistrar

        // Codex Phase η P0.2: orphaned-session supervisor scan can
        // dispatch a worker that uploads audio to ElevenLabs (cloud
        // mode), so it MUST NOT run before the user has acknowledged
        // the privacy notice. If the flag is already set (returning
        // user), kick off recovery now; otherwise the ack callback
        // below schedules it after the user clicks "I understand".
        if settings.privacyAcknowledged {
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
            probe: CoreAudioInputProbe()
        ) { [weak self] app in
            await self?.handleDetectionCandidate(app)
        }
        self.detectionEngine = engine
        let watcher = ProcessWatcher(
            onLaunch: { app in
                Task { await engine.handleLaunch(of: app) }
            },
            onQuit: { app in
                Task { await engine.handleQuit(of: app) }
            }
        )
        self.processWatcher = watcher
        watcher.start()
        Log.lifecycle.info("Detection layer started (allowlist size=\(MeetingApps.allowlist.count, privacy: .public), dwellTime=30s)")

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

    /// Spec line 348: first-launch privacy modal. Shown only when
    /// `privacyAcknowledged == false`; recording AND supervisor
    /// recovery stay gated until the user dismisses the sheet.
    @MainActor
    private func presentPrivacyAcknowledgementIfNeeded() {
        guard !settings.privacyAcknowledged else { return }
        let flowController = OnboardingFlowController(downloadStarter: localModelManager)
        self.onboardingFlowController = flowController
        let controller = OnboardingWindowController(
            flowController: flowController,
            snapshotProvider: { [weak self] in
                guard let self else { return await Self.emptyOnboardingSnapshot() }
                return await self.makeOnboardingResumeSnapshot()
            },
            cloudKeyAvailable: { [weak self] in
                guard let self else { return false }
                let keychain = KeychainStore(service: Self.keychainService, account: Self.keychainAccount)
                return Self.probeCloudKey(keychain: keychain) == .configured
            },
            requestMicrophone: { [weak self] in
                guard let self else { return .notDetermined }
                _ = await self.permissions.requestMicrophone()
                return self.permissions.microphoneStatus()
            },
            requestCalendar: { [weak self] in
                guard let self else { return .notDetermined }
                _ = await self.permissions.requestCalendar()
                return await DefaultPermissionStatusProbe(permissions: self.permissions).calendar()
            },
            requestNotifications: {
                do {
                    let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    return granted ? .granted : .denied
                } catch {
                    return .denied
                }
            },
            requestScreenRecording: { [weak self] in
                guard let self else { return .notDetermined }
                _ = await self.permissions.requestScreenRecording()
                return await self.permissions.screenRecordingStatus()
            },
            selectEngine: { [weak self] engine in
                guard let self else { return }
                await self.settingsStore.setEngineModeIfReady(engine, readiness: self.engineReadinessProbe())
            },
            saveOutputFolder: { [weak self] url in
                guard let self else { return }
                await self.settingsStore.setOutputRoot(url)
            },
            runTestRecording: { [weak self] in
                guard let self else { return false }
                return await self.runOnboardingTestRecording()
            },
            onAcknowledged: { [weak self] in
                guard let self else { return }
                Task {
                    await self.settingsStore.setPrivacyAcknowledged(true)
                    Log.lifecycle.info("Onboarding completed; releasing deferred supervisor scan")
                    await MainActor.run {
                        self.scheduleSupervisorRecovery()
                    }
                }
                self.privacyController = nil
                self.onboardingController = nil
                self.onboardingFlowController = nil
            }
        )
        self.privacyController = controller
        self.onboardingController = controller
        controller.present()
    }


    private static func emptyOnboardingSnapshot() async -> OnboardingResumeSnapshot {
        OnboardingResumeSnapshot(
            microphone: .notDetermined,
            calendar: .notDetermined,
            notifications: .notDetermined,
            screenRecording: .notDetermined,
            cloudKeyAvailable: false,
            localModelStatus: .notDownloaded(modelID: CohereMLXBackend.modelID),
            selectedEngine: .cloud,
            outputFolderReady: false,
            testRecordingComplete: false
        )
    }

    @MainActor
    private func makeOnboardingResumeSnapshot() async -> OnboardingResumeSnapshot {
        let snap = settings
        let permissionProbe = DefaultPermissionStatusProbe(permissions: permissions)
        let keychain = KeychainStore(service: Self.keychainService, account: Self.keychainAccount)
        return OnboardingResumeSnapshot(
            microphone: await permissionProbe.microphone(),
            calendar: await permissionProbe.calendar(),
            notifications: await permissionProbe.notifications(),
            screenRecording: await permissionProbe.screenRecording(),
            cloudKeyAvailable: Self.probeCloudKey(keychain: keychain) == .configured,
            localModelStatus: await localModelManager.status(),
            selectedEngine: snap.engineMode,
            outputFolderReady: await DefaultOutputFolderProbe().isWritable(snap.outputRoot),
            testRecordingComplete: false
        )
    }

    /// Phase η P0.2 helper: kicks the orphan-session supervisor scan in
    /// the background. Tracked in `inflightTasks` so applicationShouldTerminate's
    /// drain loop will await it. Must only be called after the user has
    /// acknowledged the privacy notice (cloud-mode uploads start as soon
    /// as the supervisor dispatches a worker).
    @MainActor
    private func scheduleSupervisorRecovery() {
        let snap = settings
        let outputRoot = snap.outputRoot
        let keepRaw = snap.keepRawStreams
        let mode = snap.engineMode
        let resumeId = UUID()
        let resumeTask = Task { [weak self] in
            let result = await Self.runSupervisor(
                under: outputRoot,
                keepRawStreams: keepRaw,
                engineMode: mode,
                localModelStatus: { [weak self] in
                    guard let manager = await MainActor.run(body: { self?.localModelManager }) else {
                        return .notDownloaded(modelID: CohereMLXBackend.modelID)
                    }
                    return await manager.status()
                }
            )
            // Codex PM-review UX-31: surface a recovery notice so the
            // user knows a previously-interrupted session is being
            // re-transcribed. Silent recovery feels like the app is
            // ignoring their data.
            await self?.showRecoveryNoticeIfNeeded(result: result)
            if result.localSetupRequired > 0 || result.missingEngineProvenance > 0 {
                await self?.markRecoverySetupRequired(payload: result.localSetupRequiredSessions.first.map {
                    SessionRepairRouting.LocalRepairPayload(
                        sessionDirectory: $0,
                        reason: "Cohere setup is required before this recovered Local session can be transcribed."
                    )
                })
            }
            await self?.removeTask(id: resumeId)
        }
        inflightTasks[resumeId] = resumeTask
    }

    @MainActor
    private func markRecoverySetupRequired(payload: SessionRepairRouting.LocalRepairPayload? = nil) {
        status = .idle
        setupNeedsAttention = true
        sessionRepairPayload = payload
        menu?.setupNeedsAttention = true
        menu?.outcomeFolderURL = payload?.sessionDirectory
        menu?.rebuild(for: status)
        applyTrustIcon()
    }

    @MainActor
    private func showRecoveryNoticeIfNeeded(result: SessionSupervisor.ScanResult) {
        guard let notice = SessionRepairRouting.recoveryNotice(for: result) else { return }
        if let payload = notice.localRepairPayloads.first {
            sessionRepairPayload = payload
            menu?.outcomeFolderURL = payload.sessionDirectory
        }
        let alert = NSAlert()
        alert.messageText = notice.title
        alert.informativeText = notice.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Scribe folder")
        alert.window.sharingType = WindowChromeSharing.confidential  // UX-4
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSWorkspace.shared.open(settings.outputRoot)
        }
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

        // Codex extensive-review P1.1 fix: a live CaptureSession isn't tracked
        // in inflightTasks, so a Quit during recording previously exited
        // immediately with the SCStream + AVAssetWriter still live, leaving
        // .partial files and no transcript. Finalize the capture first.
        if !hasLiveCapture && inflight.isEmpty { return .terminateNow }

        // Codex PM-review UX-20: confirm before quitting during
        // recording. The user might have hit Cmd-Q by accident, or
        // be unaware a recording is running. Default action is "stop
        // and quit" (saves their work); secondary keeps recording.
        if hasLiveCapture {
            let alert = NSAlert()
            alert.messageText = "Stop recording before quitting?"
            alert.informativeText = "Scribe is recording. Quitting now will save the audio and finalize the transcript before exit."
            alert.addButton(withTitle: "Stop and quit")
            alert.addButton(withTitle: "Keep recording")
            alert.window.sharingType = WindowChromeSharing.confidential  // UX-4
            let choice = alert.runModal()
            if choice == .alertSecondButtonReturn {
                Log.lifecycle.info("Quit cancelled by user; recording continues")
                return .terminateCancel
            }
        }

        Log.lifecycle.info("Quit requested: capture=\(hasLiveCapture, privacy: .public), in-flight tasks=\(inflight.count, privacy: .public); finalizing up to 10s")
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
                    group.addTask { try? await Task.sleep(nanoseconds: UInt64(max(0, remaining) * 1_000_000_000)) }
                    await group.next()
                    group.cancelAll()
                }
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @MainActor
    private func removeTask(id: UUID) {
        inflightTasks.removeValue(forKey: id)
    }

    @MainActor
    private func installStatusItemIfNeeded() {
        guard statusItem == nil else {
            applyTrustIcon()
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let icon = NSImage(named: "MenuBarIcon") {
            icon.isTemplate = true
            icon.accessibilityDescription = "Scribe"
            item.button?.image = icon
            item.button?.imagePosition = .imageOnly
        } else {
            item.button?.title = "S"
        }
        item.button?.target = StatusItemClickTarget.shared
        item.button?.action = #selector(StatusItemClickTarget.statusItemClicked(_:))
        statusItem = item
        menu?.outputRoot = outputRoot
        applyTrustIcon()
    }

    @MainActor
    private func setMenuBarVisible(_ visible: Bool) {
        if visible {
            installStatusItemIfNeeded()
        } else if let item = statusItem {
            menu?.close()
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// scribe-design-system: full 8-state trust language on the menu
    /// bar. The shape encodes status (`SessionStatus`), setup blockers,
    /// in-flight detection prompts, and recent saved/failed outcomes;
    /// `TrustState.resolve` is the single source of truth. CALayer
    /// animations supply the pulse + spin for the two motion states.
    @MainActor
    private func applyTrustIcon() {
        guard let button = statusItem?.button else { return }
        let trust = TrustState.resolve(currentTrustInputs())

        guard let icon = NSImage(named: trust.assetName) else {
            // Defensive: if a new trust state lands without a matching
            // asset the bare mark is the safe fallback.
            button.image = NSImage(named: "MenuBarIcon")
            return
        }
        icon.isTemplate = true
        icon.accessibilityDescription = trust.accessibilityLabel
        button.image = icon

        // Menu-bar animations are intentionally disabled. The previous
        // CABasicAnimation pulse (.detected) + rotation (.finalizing)
        // left the button's CALayer presentation in a stuck/clipped
        // state on transition (visible bug: a small frozen glyph
        // remained at the menu bar after a session finalized). Static
        // icon swaps still communicate the active state. A proper
        // animation system is a deferred design task — see vault note
        // `01-projects/scribe/menu-bar-animations.md`.
        button.wantsLayer = true
        button.layer?.removeAllAnimations()
        button.layer?.transform = CATransform3DIdentity
        button.layer?.opacity = 1.0
    }

    @MainActor
    private func toggleRecordingFromShortcut() async {
        switch status {
        case .recording:
            await stopRecording()
        case .idle, .failed, .finalized:
            await startRecording()
        case .starting, .stopping:
            break
        }
    }

    /// Snapshots the inputs `TrustState.resolve` needs. Centralized so
    /// every call site (status flips, flag flips, the saved-flash
    /// timer firing) goes through the same builder.
    @MainActor
    private func currentTrustInputs() -> TrustState.Inputs {
        TrustState.Inputs(
            status: status,
            setupNeedsAttention: setupNeedsAttention,
            detectionPromptActive: detectionPromptActive,
            lastSavedAt: lastSavedAt,
            lastFailureAt: lastFailureAt,
            now: Date(),
            savedFlashDuration: AppDelegate.savedFlashDuration
        )
    }

    /// Records a successful save and starts the 3s saved-flash window.
    /// Called from the stopRecording() success path.
    @MainActor
    private func markSavedFlash() {
        lastSavedAt = Date()
        lastFailureAt = nil
        savedFlashTimer?.invalidate()
        savedFlashTimer = Timer.scheduledTimer(
            withTimeInterval: AppDelegate.savedFlashDuration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.applyTrustIcon() }
        }
        applyTrustIcon()
    }

    /// Records a terminal failure. The icon stays in `.failed` until
    /// the next record attempt or recovery flow clears it.
    @MainActor
    private func markFailureFlash() {
        lastFailureAt = Date()
        lastSavedAt = nil
        savedFlashTimer?.invalidate()
        applyTrustIcon()
    }

    /// Clears terminal-outcome flags. Called when the user triggers a
    /// new record attempt so a stale `.failed` doesn't survive past the
    /// next session start.
    @MainActor
    private func clearTerminalFlash() {
        lastSavedAt = nil
        lastFailureAt = nil
        savedFlashTimer?.invalidate()
        applyTrustIcon()
    }

    @MainActor
    private func handle(_ action: RecordingMenu.Action) async {
        switch action {
        case .record: await startRecording()
        case .retryFailedSession: await retryFailedSession()
        case .retryRecentFailedSession(let sessionURL): await retryFailedSession(at: sessionURL)
        case .repairRecentFailedSession(let sessionURL):
            markRecoverySetupRequired(payload: SessionRepairRouting.LocalRepairPayload(
                sessionDirectory: sessionURL,
                reason: "Saved audio is missing; open setup to repair this failed session before retrying."
            ))
            await presentSetupRequiredPopover()
        case .stop:   await stopRecording()
        case .quit:   NSApp.terminate(nil)
        case .openSettings:
            settingsWindowController?.show()
        case .openSetupRequired:
            await presentSetupRequiredPopover()
        case .openDiagnostics:
            diagnosticsWindowController?.show()
        }
    }


    @MainActor
    private func retryFailedSession() async {
        guard let sessionURL = menu?.outcomeFolderURL ?? mostRecentFailedSessionURL() else {
            Log.engine.error("Failed-session retry unavailable: no failed session with saved audio")
            status = .failed
            menu?.outcomeFolderURL = nil
            menu?.rebuild(for: status)
            return
        }
        await retryFailedSession(at: sessionURL)
    }

    @MainActor
    private func retryFailedSession(at sessionURL: URL) async {
        let savedAudioURL = sessionURL.appendingPathComponent("audio.m4a")
        guard FileManager.default.fileExists(atPath: savedAudioURL.path) else {
            Log.engine.error("Failed-session retry unavailable: saved audio missing for selected failed session")
            if let frontmatter = TranscriptFrontmatterReader.read(at: sessionURL.appendingPathComponent("transcript.md")),
               frontmatter.context.engine.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased() == "cohere" {
                markRecoverySetupRequired(payload: SessionRepairRouting.LocalRepairPayload(
                    sessionDirectory: sessionURL,
                    reason: "Saved audio is missing; repair this Local session before retrying."
                ))
            } else {
                status = .failed
                menu?.outcomeFolderURL = nil
                menu?.rebuild(for: status)
            }
            return
        }
        menu?.outcomeFolderURL = sessionURL
        status = .starting
        menu?.rebuild(for: status)
        let localStatus = await currentLocalModelStatus()
        do {
            let final = try await Self.retryFailedSession(
                at: sessionURL,
                localModelStatus: localStatus
            )
            switch final {
            case .complete:
                status = .finalized
                markSavedFlash()
            case .failed, .cancelled:
                status = .failed
            }
        } catch let error as FailedSessionRetryCoordinator.RetryError {
            Log.engine.error("Failed-session retry could not start: \(String(describing: error), privacy: .public)")
            if case .localSetupRequired = error {
                markRecoverySetupRequired(payload: SessionRepairRouting.LocalRepairPayload(
                    sessionDirectory: sessionURL,
                    reason: "Cohere setup is required before retrying this Local session."
                ))
            } else {
                status = .failed
            }
        } catch {
            Log.engine.error("Failed-session retry could not start: \(String(describing: error), privacy: .public)")
            status = .failed
        }
        menu?.rebuild(for: status)
    }

    @MainActor
    private func mostRecentFailedSessionURL() -> URL? {
        SessionFolderEnumerator.recents(under: outputRoot, limit: 5)
            .first { entry in
                entry.status == .failed
                    && FileManager.default.fileExists(atPath: entry.directory.appendingPathComponent("audio.m4a").path)
            }?
            .directory
    }

    @MainActor
    private func currentLocalModelStatus() async -> LocalModelCacheStatus {
        await localModelManager.status()
    }

    nonisolated static func retryFailedSession(
        at sessionURL: URL,
        localModelStatus: LocalModelCacheStatus,
        engineFactory: (@Sendable (EngineMode) -> TranscriptionEngine)? = nil
    ) async throws -> TranscriptionWorker.FinalState {
        try await FailedSessionRetryCoordinator.retry(
            sessionDirectory: sessionURL,
            engineFactory: { mode in
                if let engine = engineFactory?(mode) { return engine }
                return EngineSelector.makeEngine(
                    for: mode,
                    cloudAPIKey: {
                        (try? KeychainStore(service: keychainService, account: keychainAccount).read()) ?? ""
                    }
                )
            },
            localModelStatus: localModelStatus
        )
    }

    /// User-triggered Setup Required popover. Re-runs the audit so the
    /// UI reflects whichever permissions have been fixed since the last
    /// record attempt.
    @MainActor
    private func presentSetupRequiredPopover() async {
        let report: PreflightReport
        let payload = sessionRepairPayload
        if let payload {
            report = SessionRepairRouting.setupReport(for: payload)
        } else {
            let snap = settings
            report = await preflightDoctor.audit(outputRoot: snap.outputRoot, engineMode: snap.engineMode)
        }
        // Route permission-only blockers to the polished onboarding
        // window. Session-repair payloads and engine/output blockers
        // stay on the deprecated popover path (it still handles those
        // remediation surfaces; replacement is out of scope for this
        // iteration).
        if payload == nil, Self.allBlockersArePermissions(report) {
            setupPopover?.close()
            permissionsOnboarding?.present()
            return
        }
        showSetupRequiredPopover(report: report, sessionRepairPayload: payload)
    }

    /// True only when every blocker is a permission-related reason.
    /// Used to decide whether the polished onboarding window can fully
    /// cover the remediation surface, or whether we need to fall back
    /// to the popover (engine config, output folder, etc.).
    private static func allBlockersArePermissions(_ report: PreflightReport) -> Bool {
        guard !report.blockers.isEmpty else { return false }
        return report.blockers.allSatisfy { isPermissionReason($0) }
    }

    private static func isPermissionReason(_ reason: PreflightReason) -> Bool {
        switch reason {
        case .microphoneDenied, .microphoneNotDetermined,
             .screenRecordingDenied,
             .calendarDeniedOptional, .calendarNotDetermined,
             .notificationsDeniedOptional, .notificationsNotDetermined:
            return true
        case .outputFolderUnwritable, .outputFolderInSyncedStorage,
             .missingCloudAPIKey,
             .localModelNotVerified, .localRuntimeUnavailable:
            return false
        }
    }

    @MainActor
    private func showSetupRequiredPopover(
        report: PreflightReport,
        sessionRepairPayload payload: SessionRepairRouting.LocalRepairPayload?
    ) {
        setupEngineFocus = setupRequiredEngineFocus(report: report, sessionRepairPayload: payload)
        let steps = PermissionRemediation.steps(from: report)
        guard let anchor = statusItem?.button, let popover = setupPopover else { return }
        popover.show(
            steps: steps,
            anchor: anchor,
            actions: makePopoverActions()
        ) { [weak self] in
            Task { await self?.presentSetupRequiredPopover() }
        }
    }

    @MainActor
    private func setupRequiredEngineFocus(
        report: PreflightReport,
        sessionRepairPayload payload: SessionRepairRouting.LocalRepairPayload?
    ) -> EngineSettingsCardFocus? {
        SessionRepairRouting.engineSettingsFocus(for: payload)
            ?? report.blockers.compactMap { EngineSettingsNavigation.focus(for: $0) }.first
    }

    /// Builds the inline-action handler set the popover hands to its
    /// step rows. Each handler closes the popover before invoking the
    /// system-prompt API so the macOS sheet appears alone (the popover
    /// would otherwise occlude it on the menu bar anchor); the
    /// auto-recheck observers reopen it with refreshed state once the
    /// user responds.
    @MainActor
    private func makePopoverActions() -> PermissionRecoveryActions {
        PermissionRecoveryActions(
            onRequestMicrophone: { [weak self] in
                guard let self else { return }
                self.setupPopover?.close()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.permissions.requestMicrophone()
                    await self.presentSetupRequiredPopover()
                }
            },
            onRequestScreenRecording: { [weak self] in
                guard let self else { return }
                self.setupPopover?.close()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // CGRequestScreenCaptureAccess returns whether the
                    // current process has access, not whether a prompt
                    // was shown. CGPreflightScreenCaptureAccess can
                    // disagree: after a fresh grant, the running process
                    // may still see denied until relaunch. When that
                    // happens, polling is futile — surface a restart
                    // alert instead of reopening the popover forever.
                    let requestGrant = await self.permissions.requestScreenRecording()
                    let status = await self.permissions.screenRecordingStatus()
                    if requestGrant, status == .denied {
                        self.presentScreenRecordingRestartRequiredAlert()
                        return
                    }
                    if !requestGrant,
                       status == .denied,
                       let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                    await self.presentSetupRequiredPopover()
                }
            },
            onRequestCalendar: { [weak self] in
                guard let self else { return }
                self.setupPopover?.close()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.permissions.requestCalendar()
                    await self.presentSetupRequiredPopover()
                }
            },
            onOpenInAppSettings: { [weak self] in
                guard let self else { return }
                self.setupPopover?.close()
                self.settingsWindowController?.show(focus: self.setupEngineFocus)
            }
        )
    }

    /// Shown when the user has granted screen recording in System Settings
    /// (or this process's TCC bit has flipped to granted) but the running
    /// process's CGPreflightScreenCaptureAccess still reports denied. This
    /// is a macOS quirk: the grant doesn't propagate to a running process
    /// for screen recording — only relaunch picks it up. Loop-prompting
    /// the user is what produced the "popover flashing and can't close"
    /// failure mode.
    @MainActor
    private func presentScreenRecordingRestartRequiredAlert() {
        setupPopover?.close()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restart Scribe to finish enabling Screen Recording"
        alert.informativeText = "macOS has approved Screen & System Audio Recording in System Settings, but the running Scribe process can't see the new grant until it relaunches."
        alert.addButton(withTitle: "Quit & Reopen Scribe")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            Self.relaunchAndTerminate()
        }
    }

    /// Spawns a detached `open -n` against our own bundle, then terminates
    /// ourselves. The child launches as a new instance immediately; the
    /// brief two-process overlap is harmless because the new instance's
    /// status item replaces ours after the old one exits.
    ///
    /// `NSApp.terminate(nil)` on its own does NOT relaunch — macOS only
    /// re-spawns crashed apps marked for relaunch, not normal quits. We
    /// need an external spawn so the user doesn't have to manually
    /// reopen Scribe after granting Screen Recording.
    nonisolated static func relaunchAndTerminate() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", Bundle.main.bundlePath]
        do {
            try task.run()
        } catch {
            Log.lifecycle.error("Relaunch spawn failed: \(String(describing: error), privacy: .public). Quitting without relaunch; user must reopen manually.")
        }
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    /// Engine fires this when an allowlisted app has been running for the
    /// dwell window without being skipped or quitting. Show the start prompt
    /// and route the user's choice. Ignore if a recording is already active.
    @MainActor
    func handleDetectionCandidate(_ app: MeetingApp) async {
        guard status != .recording, status != .starting else {
            Log.lifecycle.info("Detection candidate \(app.bundleID, privacy: .public) ignored: already \(self.status.rawValue, privacy: .public)")
            return
        }
        Log.lifecycle.info("Detection candidate: \(app.bundleID, privacy: .public)")
        // Enrich the prompt with the overlapping calendar event title if one
        // is in cache. Spec line 167: "Start recording 'Acme Weekly'?".
        let event = await calendarWatcher.eventOverlapping(Date())
        Log.calendar.info("Prompt enrichment: matched=\(event != nil ? "yes" : "no", privacy: .public)")
        // F-2: surface .detected on the menu bar while the user is
        // deciding. Cleared in defer so any exit path (start, suppress,
        // skip, auto-dismiss) reverts the icon.
        detectionPromptActive = true
        applyTrustIcon()
        defer {
            detectionPromptActive = false
            applyTrustIcon()
        }
        let choice = await startPromptCoordinator.prompt(for: app, event: event)
        switch choice {
        case .start:
            await startRecording()
        case .notAMeeting:
            await detectionEngine?.suppress(app)
            Log.lifecycle.info("User suppressed \(app.bundleID, privacy: .public) for 30 minutes")
            // Codex P1 fix: ProcessWatcher only emits launch/terminate events,
            // so a long-running app (Chrome left open) needs an explicit re-arm
            // when the TTL expires. Schedule a one-shot Task that re-fires the
            // launch event 30 minutes later if the app is still running.
            scheduleRearm(for: app, after: 30 * 60)
        case .skipForNow:
            Log.lifecycle.info("User skipped \(app.bundleID, privacy: .public) for now")
        }
    }

    @MainActor
    private func presentLowDiskAlert(freeBytes: Int64, outputRoot: URL) {
        let alert = NSAlert()
        alert.messageText = "Not enough disk space to record"
        alert.informativeText = "Scribe needs at least 1 GB free before starting a recording. \(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) is available in the selected folder."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open folder")
        alert.addButton(withTitle: "Cancel")
        alert.window.sharingType = WindowChromeSharing.confidential
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(outputRoot)
        }
    }

    private static func availableDiskBytes(for url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage {
            return important
        }
        if let capacity = values?.volumeAvailableCapacity {
            return Int64(capacity)
        }
        return nil
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

    @MainActor
    private func runOnboardingTestRecording() async -> Bool {
        let route = OnboardingTestRecordingRoute(
            snapshot: { [weak self] in
                guard let self else { return await Self.emptyOnboardingSnapshot() }
                return await self.makeOnboardingResumeSnapshot()
            },
            starter: AppOnboardingTestRecordingStarter(start: { [weak self] allowPendingPrivacyAcknowledgementForOnboardingTest in
                guard let self else { return false }
                await self.startRecording(allowPendingPrivacyAcknowledgementForOnboardingTest: allowPendingPrivacyAcknowledgementForOnboardingTest)
                guard self.status == .recording else { return false }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.stopRecording()
                return true
            })
        )
        return await route.run()
    }

    @MainActor
    private func startRecording(allowPendingPrivacyAcknowledgementForOnboardingTest: Bool = false) async {
        // Codex P2 fix: claim .starting before any await so concurrent
        // detection candidates (or a menu Record + a candidate firing
        // simultaneously) can't pass the handleDetectionCandidate guard
        // and create two CaptureSessions.
        guard status != .recording, status != .starting else {
            Log.lifecycle.info("startRecording skipped: already \(self.status.rawValue, privacy: .public)")
            return
        }
        // F-2: a new attempt clears any leftover saved/failed flash so
        // the icon doesn't keep mourning the previous session.
        clearTerminalFlash()

        // Phase η spec line 348: recording is gated on privacy ack.
        // If the sheet was dismissed via cmd-q without acknowledging,
        // re-present it instead of starting the engine.
        guard settings.privacyAcknowledged || allowPendingPrivacyAcknowledgementForOnboardingTest else {
            Log.lifecycle.info("startRecording blocked: privacy acknowledgement pending")
            presentPrivacyAcknowledgementIfNeeded()
            return
        }
        if allowPendingPrivacyAcknowledgementForOnboardingTest && !settings.privacyAcknowledged {
            Log.lifecycle.info("startRecording proceeding for consented onboarding test recording before final privacy acknowledgement")
        }

        self.status = .starting
        menu?.rebuild(for: status)
        applyTrustIcon()

        // Eager mic and calendar prompts removed. The previous
        // pattern (auto-fire CGRequest / EKEventStore before the audit)
        // caused a surprise system dialog to appear BEFORE any Scribe
        // UI surfaced — violating the "one clean window for all
        // permissions" UX. The audit below catches .notDetermined as a
        // blocker and routes to the Permissions onboarding window
        // (`PermissionsOnboardingWindowController`); the user clicks
        // Allow… in-window, which fires the system prompt from a
        // context they understand.

        // Phase α preflight gate. Any blocker → abort and route to the
        // Permissions onboarding window so the user has a single,
        // explained surface for granting each unmet permission.
        let snapshot = settings
        let report = await preflightDoctor.audit(outputRoot: snapshot.outputRoot, engineMode: snapshot.engineMode)
        if let freeBytes = Self.availableDiskBytes(for: snapshot.outputRoot), freeBytes < Self.minimumFreeDiskBytes {
            Log.lifecycle.error("startRecording denied: low disk space (\(freeBytes, privacy: .public) bytes free)")
            self.status = .idle
            menu?.rebuild(for: status)
            applyTrustIcon()
            presentLowDiskAlert(freeBytes: freeBytes, outputRoot: snapshot.outputRoot)
            return
        }

        switch RecordRequestGate().verdict(from: report) {
        case .deny(let reasons):
            // Codex rc2-audit P0 (privacy): String(describing: reasons)
            // expands the associated URL values, which carry
            // `/Users/<name>/...` paths. Use the safe `publicLabels`
            // accessor for .public; full reasons at .private.
            Log.lifecycle.error("startRecording denied by preflight: \(reasons.publicLabels, privacy: .public) [\(String(describing: reasons), privacy: .private)]")
            self.status = .idle
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
            return
        case .allowWithWarnings(let reasons):
            Log.lifecycle.info("startRecording proceeding with warnings: \(reasons.publicLabels, privacy: .public) [\(String(describing: reasons), privacy: .private)]")
            // UX-7: warnings don't need to scream "Setup Required";
            // recording is happening.
            menu?.setupNeedsAttention = false
            self.setupNeedsAttention = false
        case .allow:
            menu?.setupNeedsAttention = false
            self.setupNeedsAttention = false
        }

        let id = SessionID(from: Date())
        do {
            let dir = try SessionDirectory.create(under: outputRoot, id: id)
            // Phase β: one SCStream with both .audio + .microphone outputs
            // so mic and system share a sync clock. AEC (Phase ξ) and
            // streaming finalize (Phase ε) both depend on this.
            let stream = SCKDualOutputStream(sampleRate: 48000, channelCount: 1)
            let mic = SCKAudioCaptureSource(kind: .microphone, stream: stream)
            let sys = SCKAudioCaptureSource(kind: .system, stream: stream)
            let sessionEngineMode = snapshot.engineMode
            let session = try CaptureSession(
                directory: dir,
                mic: mic,
                system: sys,
                sampleRate: 48000,
                channelCount: 1,
                sessionEngineIdentifier: sessionEngineMode.sessionEngineIdentifier,
                liveLevelHandler: { [weak self] stream, rms in
                    Task { @MainActor [weak self] in
                        self?.recordLiveAudioLevel(stream: stream, rms: rms)
                    }
                }
            )
            self.session = session
            self.currentSessionDirectory = dir
            self.currentSessionStartedAt = Date()
            self.currentSessionEngineMode = sessionEngineMode
            menu?.sessionEngineMode = sessionEngineMode
            self.currentDiagnosticsLiveLevels = nil

            // Slice 6: prefer the watcher cache (already populated, no
            // EventKit round-trip on the start path). Fall back to the
            // direct lookup if the cache hasn't been refreshed yet.
            let event = await calendarWatcher.eventOverlapping(Date())
                ?? calendar.eventOverlapping(Date())
            self.currentCalendarEvent = event
            Log.calendar.info("Calendar lookup at session start: matched=\(event != nil ? "yes" : "no", privacy: .public)")

            try await session.start()
            self.status = .recording
            // Wire the popover's live trust-surface readouts so the
            // user sees a ticking timer + the matched meeting title
            // the moment they open the menu bar. Without this, the
            // popover read `0:00 · Recording` for the entire session.
            menu?.recordingSourceLabel = Self.recordingSourceLabel(for: event)
            menu?.outcomeFolderName = dir.url.lastPathComponent
            menu?.outcomeFolderURL = dir.url
            menu?.elapsedSeconds = 0
            startElapsedTickTimer()
            menu?.rebuild(for: status)
            applyTrustIcon()
        } catch {
            Log.lifecycle.error("Start failed: \(String(describing: error), privacy: .public)")
            // Codex rc2-audit STATE-3: a failed start would leave
            // self.session / currentSessionDirectory / currentSessionStartedAt
            // populated. A subsequent Stop or Quit would then write a
            // pending transcript for a never-started session. Clear
            // ALL session state on the catch path so the app is in a
            // well-defined idle.
            self.status = .failed
            self.session = nil
            self.currentSessionDirectory = nil
            self.currentSessionStartedAt = nil
            self.currentCalendarEvent = nil
            self.currentSessionEngineMode = nil
            self.currentDiagnosticsLiveLevels = nil
            stopElapsedTickTimer()
            menu?.outcomeFolderName = nil
            menu?.outcomeFolderURL = nil
            menu?.sessionEngineMode = .cloud
            menu?.recordingSourceLabel = "Recording"
            menu?.elapsedSeconds = 0
            menu?.rebuild(for: status)
            applyTrustIcon()
        }
    }

    @MainActor
    private func recordLiveAudioLevel(stream: PTSCollector.StreamID, rms: Float) {
        let safeRMS = Double(min(max(rms, 0), 1))
        let existing = currentDiagnosticsLiveLevels
        switch stream {
        case .mic:
            currentDiagnosticsLiveLevels = .init(micRMS: safeRMS, systemRMS: existing?.systemRMS)
            menu?.micLevel = Float(safeRMS)
        case .system:
            currentDiagnosticsLiveLevels = .init(micRMS: existing?.micRMS, systemRMS: safeRMS)
            menu?.systemLevel = Float(safeRMS)
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

    @MainActor
    private func stopRecording() async {
        guard let session, let dir = currentSessionDirectory else { return }
        let endedAt = Date()
        let started = currentSessionStartedAt ?? endedAt
        let event = currentCalendarEvent
        let sessionEngineMode = currentSessionEngineMode ?? settings.engineMode

        var stopSucceeded = false
        do {
            try await session.stop()
            self.status = .finalized
            stopSucceeded = true
        } catch {
            Log.lifecycle.error("Stop failed: \(String(describing: error), privacy: .public)")
            self.status = .failed
        }
        self.session = nil
        self.currentSessionDirectory = nil
        self.currentSessionStartedAt = nil
        self.currentCalendarEvent = nil
        self.currentSessionEngineMode = nil
        self.currentDiagnosticsLiveLevels = nil
        stopElapsedTickTimer()
        menu?.outcomeFolderName = nil
        menu?.outcomeFolderURL = nil
        menu?.sessionEngineMode = sessionEngineMode
        menu?.recordingSourceLabel = "Recording"
        menu?.elapsedSeconds = 0
        menu?.rebuild(for: status)
        applyTrustIcon()

        // session.stop() failure is a terminal failure (audio commit
        // broke). Flash the failed glyph and bail before spawning the
        // transcript worker.
        if !stopSucceeded {
            self.status = .idle
            menu?.rebuild(for: status)
            markFailureFlash()
            return
        }

        let context = Self.makeContext(dir: dir, startedAt: started, endedAt: endedAt, event: event, engineMode: sessionEngineMode)
        do {
            try TranscriptWriter.writePending(at: dir.transcript, context: context)
        } catch {
            Log.engine.error("Failed to write pending transcript: \(String(describing: error), privacy: .public)")
        }

        let worker = Self.makeWorker(dir: dir, context: context, event: event, keepRawStreams: settings.keepRawStreams, engineMode: sessionEngineMode)
        let id = UUID()
        let durationSeconds = Int(endedAt.timeIntervalSince(started))
        let engineLabel = sessionEngineMode == .cloud ? "ElevenLabs" : "Cohere"
        let task = Task { [weak self] in
            let outcome = await worker.run()
            await MainActor.run {
                guard let self else { return }
                // F-2: spinner ran while the worker was in flight. Now
                // that it's done, revert status to .idle and either
                // flash .saved (3s) or surface the sticky .failed.
                self.status = .idle
                self.menu?.rebuild(for: self.status)
                switch outcome {
                case .complete:
                    self.menu?.sessionEngineMode = .cloud
                    self.markSavedFlash()
                    self.presentSavedNotification(
                        dir: dir,
                        event: event,
                        durationSeconds: durationSeconds,
                        engineLabel: engineLabel
                    )
                case .failed(let reason):
                    self.menu?.sessionEngineMode = .cloud
                    Log.engine.error("Worker terminated with failure: \(reason, privacy: .public)")
                    self.markFailureFlash()
                case .cancelled:
                    self.menu?.sessionEngineMode = .cloud
                    // App was quit / session forcibly aborted. Don't
                    // flash either success or failure; just settle
                    // back to idle.
                    self.applyTrustIcon()
                }
            }
            await self?.removeTask(id: id)
        }
        inflightTasks[id] = task
    }

    @MainActor
    private func presentSavedNotification(
        dir: SessionDirectory,
        event: CalendarEvent?,
        durationSeconds: Int,
        engineLabel: String
    ) {
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

    /// Sums the byte sizes of the canonical mic + system audio files
    /// for the saved notification's MB caption. Best-effort: errors
    /// fall back to 0 (the notification still shows, just without an
    /// accurate size).
    private nonisolated func totalAudioBytes(in dir: SessionDirectory) -> Int64 {
        let candidates = [dir.micFinal, dir.systemFinal]
        var total: Int64 = 0
        for url in candidates {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }
}

private struct AppOnboardingTestRecordingStarter: OnboardingRecordingRouteStarting {
    let start: @MainActor @Sendable (Bool) async -> Bool

    func startRecording(allowPendingPrivacyAcknowledgementForOnboardingTest: Bool) async -> Bool {
        await start(allowPendingPrivacyAcknowledgementForOnboardingTest)
    }
}

@MainActor
enum AppearanceApplier {
    static func apply(_ theme: AppearanceTheme) {
        NSApp.appearance = theme.nsAppearance
    }
}

@MainActor
enum LaunchAtLoginController {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
final class StartStopHotKeyRegistrar {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onFire: @MainActor () -> Void

    init(onFire: @escaping @MainActor () -> Void) {
        self.onFire = onFire
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            StartStopHotKeyRegistrar.handleEvent,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    deinit {
        MainActor.assumeIsolated {
            if let hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
            }
            if let eventHandler {
                RemoveEventHandler(eventHandler)
            }
        }
    }

    func register(_ shortcut: KeyboardShortcutSetting) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        var ref: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.fourCC("Scrb"), id: 1)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifierFlags,
            identifier,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        }
    }

    private func fire() {
        onFire()
    }

    private static let handleEvent: EventHandlerUPP = { _, _, userData in
        guard let userData else { return noErr }
        let registrar = Unmanaged<StartStopHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in registrar.fire() }
        return noErr
    }

    private static func fourCC(_ string: String) -> OSType {
        var result: OSType = 0
        for scalar in string.unicodeScalars.prefix(4) {
            result = (result << 8) + OSType(scalar.value)
        }
        return result
    }
}

extension KeyboardShortcutSetting {
    var carbonModifierFlags: UInt32 {
        modifiers.reduce(UInt32(0)) { flags, modifier in
            switch modifier {
            case .command:
                return flags | UInt32(cmdKey)
            case .shift:
                return flags | UInt32(shiftKey)
            case .option:
                return flags | UInt32(optionKey)
            case .control:
                return flags | UInt32(controlKey)
            }
        }
    }

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.control) { parts.append("⌃") }
        parts.append(key.uppercased())
        return parts.joined()
    }
}

extension AppDelegate {
    /// Phase θ: builds a diagnostics snapshot from typed sources only.
    /// NEVER reads transcript bodies or session-folder file contents
    /// (the security contract lives in DiagnosticsExporter; this method
    /// is a thin assembly point).
    ///
    /// Codex Phase θ P1.3 / P1.4 / P1.6: real async permission probes,
    /// tri-state cloud key (configured | missing | unreadable), and
    /// real write-probe via DefaultOutputFolderProbe instead of the
    /// metadata-only isWritableFile.
    @MainActor
    func buildDiagnosticsSnapshot() async -> DiagnosticsSnapshot {
        let snap = settings
        let isoFmt = ISO8601DateFormatter()

        // Async probes. These match the preflight audit's source of
        // truth (DefaultPermissionStatusProbe / app-owned LocalModelManager readiness /
        // DefaultOutputFolderProbe), so what the user sees in
        // Diagnostics is what the gate at record-time will see.
        let permProbe = DefaultPermissionStatusProbe(permissions: permissions)
        let folderProbe = DefaultOutputFolderProbe()
        let keychain = KeychainStore(service: Self.keychainService, account: Self.keychainAccount)
        let engineProbe = engineReadinessProbe()
        // Codex rc2-audit PRIVACY-2: distinguish keychain-unreadable
        // from "configured." If unreadable, surface a fixed sentinel
        // in outputRootHash rather than a phantom-keyed hash that
        // varies per session.
        let instanceState = await diagnosticsInstanceID.currentState()
        let outputRootHash: String
        switch instanceState {
        case .configured(let secret):
            outputRootHash = DiagnosticsCollector.hashPath(snap.outputRoot, instanceID: secret)
        case .unreadable:
            outputRootHash = "unreadable"
        }

        async let permsView = DiagnosticsCollector.permissions(probe: permProbe)
        async let outputWritable = folderProbe.isWritable(snap.outputRoot)
        async let engineView = DiagnosticsCollector.engine(
            mode: snap.engineMode,
            cloudProbe: { Self.probeCloudKey(keychain: keychain) },
            engineProbe: engineProbe
        )

        let permissionsView = await permsView

        return await DiagnosticsSnapshot(
            appVersion: BuildInfo.version,
            osVersion: .init(ProcessInfo.processInfo.operatingSystemVersion),
            activeCalendarSource: DiagnosticsCollector.activeCalendarSource(calendarPermission: permissionsView.calendar),
            exportedAt: isoFmt.string(from: Date()),
            settings: .init(
                engineMode: snap.engineMode.rawValue,
                keepRawStreams: snap.keepRawStreams,
                aecEnabled: snap.aecEnabled,
                privacyAcknowledged: snap.privacyAcknowledged,
                outputRootHash: outputRootHash,
                outputRootIsWritable: outputWritable
            ),
            permissions: permissionsView,
            engine: engineView,
            sessions: DiagnosticsCollector.collectSessions(under: snap.outputRoot),
            liveLevels: currentDiagnosticsLiveLevels
        )
    }

    /// Codex Phase θ P1.4: probe the keychain and surface
    /// configured / missing / unreadable distinctly. KeychainStore.read
    /// throws KeychainError.notFound for the missing case and other
    /// errors for locked / denied / transient I/O.
    nonisolated static func probeCloudKey(keychain: KeychainStore) -> DiagnosticsCollector.CloudKeyState {
        do {
            let value = try keychain.read()
            if let value, !value.isEmpty { return .configured }
            return .missing
        } catch {
            // Distinguish "no item" from "read failed for some other
            // reason". Anything that isn't `notFound` is treated as
            // unreadable so support sees the difference.
            return .unreadable
        }
    }

    nonisolated static func emptyDiagnosticsSnapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: BuildInfo.version,
            osVersion: .init(ProcessInfo.processInfo.operatingSystemVersion),
            activeCalendarSource: "unknown",
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            settings: .init(engineMode: "cloud", keepRawStreams: false, aecEnabled: true, privacyAcknowledged: false, outputRootHash: "", outputRootIsWritable: false),
            permissions: .init(microphone: "unknown", screenRecording: "unknown", calendar: "unknown"),
            engine: .init(
                selectedEngine: "cloud",
                selectedEngineReady: false,
                cloudKey: "missing",
                localModelStatus: "notDownloaded",
                localModelID: CohereMLXBackend.modelID,
                localCachePathExists: false,
                mlxAvailable: true,
                localReady: false,
                lastDownloadError: ""
            ),
            sessions: .zero,
            liveLevels: nil
        )
    }

    /// Writes the current diagnostics snapshot to
    /// `~/Library/Logs/Scribe/diagnostics-<timestamp>.json` and
    /// returns the URL on success. Logs (and returns nil) on failure.
    @MainActor
    func exportDiagnosticsToFile() async -> URL? {
        let snapshot = await buildDiagnosticsSnapshot()
        do {
            let data = try DiagnosticsExporter.encode(snapshot)
            let logsDir = try Self.diagnosticsLogsDirectory()
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let url = logsDir.appendingPathComponent("diagnostics-\(fmt.string(from: Date())).json")
            try data.write(to: url, options: [.atomic])
            // Codex Phase θ P2.4: log the path .private so the user's
            // /Users/<name> doesn't leak into shared logs.
            Log.lifecycle.info("Diagnostics exported to \(url.path, privacy: .private)")
            return url
        } catch {
            Log.lifecycle.error("Diagnostics export failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func diagnosticsLogsDirectory() throws -> URL {
        let library = try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let logs = library.appendingPathComponent("Logs/Scribe", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs
    }

    @MainActor
    private func permissionStatusName(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: return "granted"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        }
    }

    nonisolated static func makeContext(
        dir: SessionDirectory,
        startedAt: Date,
        endedAt: Date,
        event: CalendarEvent?,
        engineMode: EngineMode = .cloud
    ) -> TranscriptContext {
        let isoFmt = ISO8601DateFormatter()
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        let title = event?.title ?? "Manual recording \(dir.url.lastPathComponent)"
        let elapsed = event.map { max(0, Int(startedAt.timeIntervalSince($0.startDate))) }
        let joinedLate = elapsed.map { $0 > 60 }
        return TranscriptContext(
            title: title,
            date: dayFmt.string(from: startedAt),
            engine: engineMode.sessionEngineIdentifier,
            audioRelativePaths: ["mic.m4a", "system.m4a"],
            scheduledStart: event.map { isoFmt.string(from: $0.startDate) },
            scheduledEnd: event.map { isoFmt.string(from: $0.endDate) },
            actualStart: isoFmt.string(from: startedAt),
            actualEnd: isoFmt.string(from: endedAt),
            joinedLate: joinedLate,
            elapsedAtStartSeconds: joinedLate == true ? elapsed : nil,
            attendees: (event?.attendees ?? []).map(\.transcriptPerson),
            language: nil
        )
    }

    nonisolated static func makeWorker(
        dir: SessionDirectory,
        context: TranscriptContext,
        event: CalendarEvent?,
        keepRawStreams: Bool = false,
        engineMode: EngineMode = .cloud,
        engineOverride: TranscriptionEngine? = nil
    ) -> TranscriptionWorker {
        // Pre-AEC default: single-channel diarized (slice 2 path).
        //
        // Spec line 117 (`decision_engine_payload_multichannel`) requires the mic
        // channel to be AEC-cleaned before multichannel upload. Spec line 119
        // explicitly forbids "dirty 2-channel uploads" as a fallback because they
        // reproduce a known failure mode where the remote speaker is decoded
        // twice. Slice 4 ships AEC + flips this back to multichannel with
        // mic.cleaned.wav. Until then, upload audio.m4a (the streaming-mixed
        // mono output produced by AudioFinalizer) and rely on diarize=true.
        //
        // Codex rc1-final P0.1 + P0.2: previously prepareAudio called
        // AudioMixer.mix to write mixed.wav as a SECOND copy of the mix,
        // which (a) buffered the whole file in memory (defeats Phase ε
        // streaming) and (b) was never deleted on .complete. Phase ε
        // already produces audio.m4a streaming, so use that directly as
        // the upload artifact.
        let canonicalAudioURL = dir.url.appendingPathComponent("audio.m4a")
        let keychain = KeychainStore(service: keychainService, account: keychainAccount)
        // Codex rc1-final P1.4: dispatch through EngineSelector so a
        // future flip to local mode lands the Cohere subprocess
        // backend without touching this site. Cloud mode reads the API
        // key lazily; local mode ignores it.
        let backend = engineOverride ?? EngineSelector.makeEngine(
            for: engineMode,
            cloudAPIKey: { (try? keychain.read()) ?? "" }
        )
        let keyterms = event?.keyterms ?? []
        let request = EngineRequest(
            audioURL: canonicalAudioURL,
            mode: .singleChannelDiarized(numSpeakers: 2),
            languageCode: nil,
            keyterms: keyterms,
            modelID: engineMode == .local ? CohereMLXBackend.modelID : "scribe_v2"
        )
        // SpeakerMappingBuilder returns empty for single-channel diarized
        // because diarization clusters voices by acoustic features, not by
        // channel; speaker_0/_1 don't reliably correspond to mic vs system.
        let mapping = SpeakerMappingBuilder.build(event: event, mode: request.mode)

        // prepareAudio is a no-op now: audio.m4a is produced by
        // TranscriptionWorker.prepareCanonicalAudio (which calls the
        // streaming AudioFinalizer) BEFORE the retry loop runs. The
        // worker's prepareAudio hook stays for callers that need
        // additional pre-upload preparation.
        let prepareAudio: @Sendable () async throws -> Void = { /* no-op */ }

        // Phase ν: WhisperKitLanguageDetector is a placeholder until the
        // spike integrates the model. It returns nil today (engine
        // auto-detects); the architectural seam is here so swapping in
        // the real WhisperKit-backed detector is a one-line change.
        return TranscriptionWorker(
            directory: dir,
            context: context,
            engine: backend,
            request: request,
            speakerMapping: mapping,
            policy: .cloud,
            prepareAudio: prepareAudio,
            keepRawStreams: keepRawStreams,
            languageDetector: WhisperKitLanguageDetector()
        )
    }

    @discardableResult
    nonisolated static func runSupervisor(
        under root: URL,
        keepRawStreams: Bool = false,
        engineMode: EngineMode = .cloud,
        workerFactory overrideWorkerFactory: SessionSupervisor.WorkerFactory? = nil,
        engineFactory: (@Sendable (EngineMode) -> TranscriptionEngine)? = nil,
        localModelStatus: (@Sendable () async -> LocalModelCacheStatus)? = nil
    ) async -> SessionSupervisor.ScanResult {
        let localStatusProvider: @Sendable () async -> LocalModelCacheStatus = localModelStatus ?? {
            let manager = LocalModelManager(
                cacheRoot: CohereMLXBackend.defaultModelCacheRoot,
                downloader: HuggingFaceLocalModelDownloader()
            )
            return await manager.status()
        }
        let localStatus = await localStatusProvider()
        let supervisor = SessionSupervisor()
        let result = await supervisor.scanAndResume(
            under: root,
            keepRawStreams: keepRawStreams,
            contextFactory: { dir in
                let isoFmt = ISO8601DateFormatter()
                let dayFmt = DateFormatter()
                dayFmt.dateFormat = "yyyy-MM-dd"
                let now = Date()
                return TranscriptContext(
                    title: "Resumed session \(dir.url.lastPathComponent)",
                    date: dayFmt.string(from: now),
                    engine: "unknown",
                    audioRelativePaths: ["mic.m4a", "system.m4a"],
                    actualStart: isoFmt.string(from: now),
                    actualEnd: isoFmt.string(from: now),
                    attendees: [],
                    language: nil
                )
            },
            workerFactory: { dir, ctx in
                if let overrideWorkerFactory {
                    return overrideWorkerFactory(dir, ctx)
                }
                let provenance = RecoveryEngineProvenance.resolve(
                    sessionEngineIdentifier: ctx.engine,
                    localModelStatus: localStatus
                )
                guard let persistedEngineMode = provenance.engineMode else {
                    switch provenance {
                    case .localSetupRequired:
                        Log.engine.warning("supervisor: local session \(dir.url.lastPathComponent, privacy: .public) requires Cohere setup before recovery; leaving pending")
                    case .missingOrInvalid:
                        Log.engine.error("supervisor: session \(dir.url.lastPathComponent, privacy: .public) has missing engine provenance; leaving recoverable for repair")
                    case .cloud, .localReady:
                        break
                    }
                    return nil
                }
                return makeWorker(
                    dir: dir,
                    context: ctx,
                    event: nil,
                    keepRawStreams: keepRawStreams,
                    engineMode: persistedEngineMode,
                    engineOverride: engineFactory?(persistedEngineMode)
                )
            }
        )
        // Codex Phase ζ P1.2: include partialAudioMarkedFailed +
        // recoveryDeferred so launch logs reflect the full ScanResult,
        // not just the v0 fields.
        Log.lifecycle.info("Supervisor scan: resumed=\(result.resumed, privacy: .public), rescued=\(result.rescued, privacy: .public), markedFailed=\(result.markedFailed, privacy: .public), partialAudioMarkedFailed=\(result.partialAudioMarkedFailed, privacy: .public), recoveryDeferred=\(result.recoveryDeferred, privacy: .public), totalFailed=\(result.totalFailed, privacy: .public), skipped=\(result.skipped, privacy: .public)")
        return result
    }
}


private extension EngineMode {
    var sessionEngineIdentifier: String {
        switch self {
        case .cloud: return "elevenlabs"
        case .local: return "cohere"
        }
    }

    init?(sessionEngineIdentifier: String) {
        switch sessionEngineIdentifier.lowercased() {
        case "elevenlabs": self = .cloud
        case "cohere": self = .local
        default: return nil
        }
    }
}
