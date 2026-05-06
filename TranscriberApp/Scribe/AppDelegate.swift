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
    private var statusItem: NSStatusItem?
    private var menu: RecordingMenu?
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
    private var settingsWindowController: SettingsWindowController?
    private var setupPopover: PermissionRecoveryPopoverController?
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

    /// Synchronous current settings (no actor hop). Reads the same
    /// single JSON blob the actor writes, so a Settings UI commit is
    /// observably consistent here.
    private var settings: SessionSettings {
        SettingsSnapshotReader.read(fallback: Self.defaultSettingsFallback())
    }

    private var outputRoot: URL { settings.outputRoot }

    /// Phase α preflight. Engine mode is now read from settings (so a
    /// later flip to local-mode lands the local-binary readiness check
    /// without touching this property).
    private var preflightDoctor: PermissionDoctor {
        let keychain = KeychainStore(service: Self.keychainService, account: Self.keychainAccount)
        return PermissionDoctor(
            permissions: DefaultPermissionStatusProbe(permissions: permissions),
            engine: DefaultEngineReadinessProbe(keychain: keychain)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.lifecycle.info("App launched, version=\(BuildInfo.version, privacy: .public)")
        // scribe-design-system: dark is the canonical default per
        // `colors_and_type.css` ("the default vibe for menu bar app +
        // landing hero"). Light mode is supported by the token set
        // but every reference visual is rendered dark, so we force
        // dark here regardless of the user's system appearance.
        NSApp.appearance = NSAppearance(named: .darkAqua)
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

        let m = RecordingMenu { [weak self] action in
            Task { @MainActor in await self?.handle(action) }
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // scribe-design-system: replace the placeholder "T" with the
        // 5-bar wave mark. Both variants are rendered as template images
        // so AppKit tints them with the menu bar's adaptive vibrancy.
        // The recording variant has the same bars plus a small filled
        // circle at the top-right; shape, not color, signals state.
        if let icon = NSImage(named: "MenuBarIcon") {
            icon.isTemplate = true
            icon.accessibilityDescription = "Scribe"
            item.button?.image = icon
            item.button?.imagePosition = .imageOnly
        } else {
            // Fallback if the asset catalog is missing for any reason.
            item.button?.title = "S"
        }
        // F-6: status-item click opens our custom popover instead of
        // an NSMenu. The system click-and-drag-to-highlight behavior is
        // sacrificed in exchange for the design's recents layout +
        // live MIC/SYS meters.
        item.button?.target = StatusItemClickTarget.shared
        item.button?.action = #selector(StatusItemClickTarget.statusItemClicked(_:))
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
        self.statusItem = item
        self.menu = m
        applyTrustIcon()

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
            keychainAccount: Self.keychainAccount
        )
        self.setupPopover = PermissionRecoveryPopoverController()
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

    /// Spec line 348: first-launch privacy modal. Shown only when
    /// `privacyAcknowledged == false`; recording AND supervisor
    /// recovery stay gated until the user dismisses the sheet.
    @MainActor
    private func presentPrivacyAcknowledgementIfNeeded() {
        guard !settings.privacyAcknowledged else { return }
        let controller = PrivacyAcknowledgementController { [weak self] in
            guard let self else { return }
            Task {
                await self.settingsStore.setPrivacyAcknowledged(true)
                Log.lifecycle.info("Privacy acknowledgement recorded; releasing deferred supervisor scan")
                await MainActor.run {
                    self.scheduleSupervisorRecovery()
                }
            }
            self.privacyController = nil
        }
        self.privacyController = controller
        controller.present()
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
            let result = await Self.runSupervisor(under: outputRoot, keepRawStreams: keepRaw, engineMode: mode)
            // Codex PM-review UX-31: surface a recovery notice so the
            // user knows a previously-interrupted session is being
            // re-transcribed. Silent recovery feels like the app is
            // ignoring their data.
            await self?.showRecoveryNoticeIfNeeded(result: result)
            await self?.removeTask(id: resumeId)
        }
        inflightTasks[resumeId] = resumeTask
    }

    @MainActor
    private func showRecoveryNoticeIfNeeded(result: SessionSupervisor.ScanResult) {
        // Only notify when there's actual recovery action; not on
        // every launch.
        let recovered = result.resumed + result.rescued
        guard recovered > 0 else { return }
        let alert = NSAlert()
        if recovered == 1 {
            alert.messageText = "Recovered 1 recording from before the last quit"
            alert.informativeText = result.rescued > 0
                ? "Audio was rescued and is being transcribed now."
                : "Transcription is resuming now."
        } else {
            alert.messageText = "Recovered \(recovered) recordings from before the last quit"
            alert.informativeText = "They're being transcribed in the background."
        }
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

        // Drive the animations on the button's layer so the SVG asset
        // itself stays static + template-clean. .detected pulses
        // opacity (1.0 → 0.4 → 1.0) on a 1.6s loop; .finalizing spins
        // the dashed arc on a 1s loop. Other states clear any prior
        // animations so we don't leak motion across transitions.
        button.wantsLayer = true
        button.layer?.removeAllAnimations()
        switch trust {
        case .detected:
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.4
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            button.layer?.add(pulse, forKey: "trust.detected.pulse")
        case .finalizing:
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0.0
            spin.toValue = Double.pi * 2
            spin.duration = 1.0
            spin.repeatCount = .infinity
            // Rotate around the button's centre, not its origin.
            button.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            button.layer?.add(spin, forKey: "trust.finalizing.spin")
        default:
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

    /// User-triggered Setup Required popover. Re-runs the audit so the
    /// UI reflects whichever permissions have been fixed since the last
    /// record attempt.
    @MainActor
    private func presentSetupRequiredPopover() async {
        let snap = settings
        let report = await preflightDoctor.audit(outputRoot: snap.outputRoot, engineMode: snap.engineMode)
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
                    let didShowPrompt = await self.permissions.requestScreenRecording()
                    let status = await self.permissions.screenRecordingStatus()
                    if !didShowPrompt,
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
                self.settingsWindowController?.show()
            }
        )
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
    private func startRecording() async {
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
        guard settings.privacyAcknowledged else {
            Log.lifecycle.info("startRecording blocked: privacy acknowledgement pending")
            presentPrivacyAcknowledgementIfNeeded()
            return
        }

        self.status = .starting
        menu?.rebuild(for: status)
        applyTrustIcon()

        // Codex PM-review UX-1: lazily request Calendar on first
        // record attempt. The user is now in context (they know
        // they're trying to record a meeting), so a calendar prompt
        // makes sense. We don't BLOCK on the result; calendar denial
        // is allowed-with-warning per spec line 88.
        Task { _ = await self.calendar.requestAccess() }

        // First-launch prompt: if mic is undecided, fire the system prompt
        // so the user can grant before we re-audit. Calendar is optional, so
        // we never wait on it here.
        if permissions.microphoneStatus() == .notDetermined {
            _ = await permissions.requestMicrophone()
        }

        // Phase α preflight gate. Any blocker → abort and surface the
        // Setup Required popover (Phase η) so the user has a 1-click
        // fix path for each unmet permission.
        let snapshot = settings
        let report = await preflightDoctor.audit(outputRoot: snapshot.outputRoot, engineMode: snapshot.engineMode)
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
            let steps = PermissionRemediation.steps(from: report)
            if let anchor = statusItem?.button, let popover = setupPopover {
                popover.show(
                    steps: steps,
                    anchor: anchor,
                    actions: makePopoverActions()
                ) { [weak self] in
                    Task { await self?.presentSetupRequiredPopover() }
                }
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
            let session = try CaptureSession(directory: dir, mic: mic, system: sys, sampleRate: 48000, channelCount: 1)
            self.session = session
            self.currentSessionDirectory = dir
            self.currentSessionStartedAt = Date()

            // Slice 6: prefer the watcher cache (already populated, no
            // EventKit round-trip on the start path). Fall back to the
            // direct lookup if the cache hasn't been refreshed yet.
            let event = await calendarWatcher.eventOverlapping(Date())
                ?? calendar.eventOverlapping(Date())
            self.currentCalendarEvent = event
            Log.calendar.info("Calendar lookup at session start: matched=\(event != nil ? "yes" : "no", privacy: .public)")

            try await session.start()
            self.status = .recording
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
            menu?.rebuild(for: status)
            applyTrustIcon()
        }
    }

    @MainActor
    private func stopRecording() async {
        guard let session, let dir = currentSessionDirectory else { return }
        let endedAt = Date()
        let started = currentSessionStartedAt ?? endedAt
        let event = currentCalendarEvent

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

        let context = Self.makeContext(dir: dir, startedAt: started, endedAt: endedAt, event: event)
        do {
            try TranscriptWriter.writePending(at: dir.transcript, context: context)
        } catch {
            Log.engine.error("Failed to write pending transcript: \(String(describing: error), privacy: .public)")
        }

        let worker = Self.makeWorker(dir: dir, context: context, event: event, keepRawStreams: settings.keepRawStreams, engineMode: settings.engineMode)
        let id = UUID()
        let durationSeconds = Int(endedAt.timeIntervalSince(started))
        let engineLabel = settings.engineMode == .cloud ? "ElevenLabs" : "Local"
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
                    self.markSavedFlash()
                    self.presentSavedNotification(
                        dir: dir,
                        event: event,
                        durationSeconds: durationSeconds,
                        engineLabel: engineLabel
                    )
                case .failed(let reason):
                    Log.engine.error("Worker terminated with failure: \(reason, privacy: .public)")
                    self.markFailureFlash()
                case .cancelled:
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
            title: title,
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
        // truth (DefaultPermissionStatusProbe / DefaultEngineReadinessProbe /
        // DefaultOutputFolderProbe), so what the user sees in
        // Diagnostics is what the gate at record-time will see.
        let permProbe = DefaultPermissionStatusProbe(permissions: permissions)
        let folderProbe = DefaultOutputFolderProbe()
        let keychain = KeychainStore(service: Self.keychainService, account: Self.keychainAccount)
        let engineProbe = DefaultEngineReadinessProbe(keychain: keychain)
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

        return await DiagnosticsSnapshot(
            appVersion: BuildInfo.version,
            exportedAt: isoFmt.string(from: Date()),
            settings: .init(
                engineMode: snap.engineMode.rawValue,
                keepRawStreams: snap.keepRawStreams,
                aecEnabled: snap.aecEnabled,
                privacyAcknowledged: snap.privacyAcknowledged,
                outputRootHash: outputRootHash,
                outputRootIsWritable: outputWritable
            ),
            permissions: permsView,
            engine: engineView,
            sessions: DiagnosticsCollector.collectSessions(under: snap.outputRoot),
            liveLevels: nil  // wired in Phase ξ once AEC pipeline lands
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
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            settings: .init(engineMode: "cloud", keepRawStreams: false, aecEnabled: true, privacyAcknowledged: false, outputRootHash: "", outputRootIsWritable: false),
            permissions: .init(microphone: "unknown", screenRecording: "unknown", calendar: "unknown"),
            engine: .init(cloudKey: "missing"),
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
        event: CalendarEvent?
    ) -> TranscriptContext {
        let isoFmt = ISO8601DateFormatter()
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        let title = event?.title ?? "Manual recording \(dir.url.lastPathComponent)"
        let attendees = (event?.attendees ?? []).map { "[[\($0.name)]]" }
        return TranscriptContext(
            title: title,
            date: dayFmt.string(from: startedAt),
            engine: "elevenlabs",
            audioRelativePaths: ["mic.m4a", "system.m4a"],
            startedAt: isoFmt.string(from: startedAt),
            endedAt: isoFmt.string(from: endedAt),
            attendees: attendees,
            language: nil
        )
    }

    nonisolated static func makeWorker(
        dir: SessionDirectory,
        context: TranscriptContext,
        event: CalendarEvent?,
        keepRawStreams: Bool = false,
        engineMode: EngineMode = .cloud
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
        let backend = EngineSelector.makeEngine(
            for: engineMode,
            cloudAPIKey: { (try? keychain.read()) ?? "" }
        )
        let keyterms = event?.keyterms ?? []
        let request = EngineRequest(
            audioURL: canonicalAudioURL,
            mode: .singleChannelDiarized(numSpeakers: 2),
            languageCode: nil,
            keyterms: keyterms
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
    nonisolated static func runSupervisor(under root: URL, keepRawStreams: Bool = false, engineMode: EngineMode = .cloud) async -> SessionSupervisor.ScanResult {
        let supervisor = SessionSupervisor()
        let result = await supervisor.scanAndResume(
            under: root,
            keepRawStreams: keepRawStreams,
            contextFactory: { dir in
                let isoFmt = ISO8601DateFormatter()
                let dayFmt = DateFormatter()
                dayFmt.dateFormat = "yyyy-MM-dd"
                return TranscriptContext(
                    title: "Resumed session \(dir.url.lastPathComponent)",
                    date: dayFmt.string(from: Date()),
                    engine: "elevenlabs",
                    audioRelativePaths: ["mic.m4a", "system.m4a"],
                    startedAt: isoFmt.string(from: Date()),
                    endedAt: isoFmt.string(from: Date()),
                    attendees: [],
                    language: nil
                )
            },
            workerFactory: { dir, ctx in
                makeWorker(dir: dir, context: ctx, event: nil, keepRawStreams: keepRawStreams, engineMode: engineMode)
            }
        )
        // Codex Phase ζ P1.2: include partialAudioMarkedFailed +
        // recoveryDeferred so launch logs reflect the full ScanResult,
        // not just the v0 fields.
        Log.lifecycle.info("Supervisor scan: resumed=\(result.resumed, privacy: .public), rescued=\(result.rescued, privacy: .public), markedFailed=\(result.markedFailed, privacy: .public), partialAudioMarkedFailed=\(result.partialAudioMarkedFailed, privacy: .public), recoveryDeferred=\(result.recoveryDeferred, privacy: .public), totalFailed=\(result.totalFailed, privacy: .public), skipped=\(result.skipped, privacy: .public)")
        return result
    }
}
