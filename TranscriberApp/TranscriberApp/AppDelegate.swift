import AppKit
import TranscriberCore

// @unchecked Sendable: all mutable state on this class is accessed through
// @MainActor methods, so it's effectively single-threaded. The @MainActor
// guard is enforced at compile time on the methods themselves; the Sendable
// promise here just lets us pass `self` into @Sendable closures (e.g.
// DetectionEngine.OnCandidate) without the compiler losing track of that
// MainActor invariant. Required for CI's Xcode 16 strict-concurrency mode.
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var statusItem: NSStatusItem?
    private var menu: RecordingMenu?
    private var session: CaptureSession?
    private var status: SessionStatus = .idle
    private let permissions = PermissionsService()
    private let calendar = CalendarLookup()
    private let calendarWatcher = CalendarWatcher()
    private var wakeObserver: NSObjectProtocol?

    private var currentSessionDirectory: SessionDirectory?
    private var currentSessionStartedAt: Date?
    private var currentCalendarEvent: CalendarEvent?

    private var inflightTasks: [UUID: Task<Void, Never>] = [:]

    // Detection layer (slice 5 light)
    private var detectionEngine: DetectionEngine?
    private var processWatcher: ProcessWatcher?
    private let startPromptCoordinator = StartPromptCoordinator()

    private static let keychainService = "com.szymonsypniewicz.transcriber"
    private static let keychainAccount = "elevenlabs-api-key"

    private var outputRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Transcriber", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.lifecycle.info("App launched, version=\(BuildInfo.version, privacy: .public)")
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        Task {
            _ = await self.calendar.requestAccess()
            // Kick the watcher after permission resolves so its first refresh
            // hits a permission-granted EKEventStore. If permission was
            // denied, the watcher still runs but every refresh sees an empty
            // event list — by spec calendar never blocks recording.
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

        let m = RecordingMenu { [weak self] action in
            Task { @MainActor in await self?.handle(action) }
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "T"
        item.menu = m.menu
        self.statusItem = item
        self.menu = m

        // Resume orphaned sessions in the background.
        let outputRoot = self.outputRoot
        let resumeId = UUID()
        let resumeTask = Task { [weak self] in
            await Self.runSupervisor(under: outputRoot)
            await self?.removeTask(id: resumeId)
        }
        inflightTasks[resumeId] = resumeTask

        // Detection layer: process allowlist watcher feeds DetectionEngine,
        // engine fires onCandidate after dwell, app shows the start prompt.
        let engine = DetectionEngine(dwellTime: 30) { [weak self] app in
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
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        processWatcher?.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        Task { await self.calendarWatcher.stop() }
        let inflight = Array(inflightTasks.values)
        let hasLiveCapture = (session != nil)

        // Codex extensive-review P1.1 fix: a live CaptureSession isn't tracked
        // in inflightTasks, so a Quit during recording previously exited
        // immediately with the SCStream + AVAssetWriter still live, leaving
        // .partial files and no transcript. Finalize the capture first.
        if !hasLiveCapture && inflight.isEmpty { return .terminateNow }

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
    private func handle(_ action: RecordingMenu.Action) async {
        switch action {
        case .record: await startRecording()
        case .stop:   await stopRecording()
        case .quit:   NSApp.terminate(nil)
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
        self.status = .starting
        menu?.rebuild(for: status)

        if permissions.microphoneStatus() != .granted {
            _ = await permissions.requestMicrophone()
        }
        _ = await permissions.screenRecordingStatus()

        let id = SessionID(from: Date())
        do {
            let dir = try SessionDirectory.create(under: outputRoot, id: id)
            let mic = SCKAudioCaptureSource(kind: .microphone)
            let sys = SCKAudioCaptureSource(kind: .system)
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
        } catch {
            Log.lifecycle.error("Start failed: \(String(describing: error), privacy: .public)")
            self.status = .failed
            self.currentCalendarEvent = nil
            menu?.rebuild(for: status)
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

        guard stopSucceeded else { return }

        let context = Self.makeContext(dir: dir, startedAt: started, endedAt: endedAt, event: event)
        do {
            try TranscriptWriter.writePending(at: dir.transcript, context: context)
        } catch {
            Log.engine.error("Failed to write pending transcript: \(String(describing: error), privacy: .public)")
        }

        let worker = Self.makeWorker(dir: dir, context: context, event: event)
        let id = UUID()
        let task = Task { [weak self] in
            _ = await worker.run()
            await self?.removeTask(id: id)
        }
        inflightTasks[id] = task
    }
}

extension AppDelegate {
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
        event: CalendarEvent?
    ) -> TranscriptionWorker {
        // Pre-AEC default: single-channel diarized (slice 2 path).
        //
        // Spec line 117 (`decision_engine_payload_multichannel`) requires the mic
        // channel to be AEC-cleaned before multichannel upload. Spec line 119
        // explicitly forbids "dirty 2-channel uploads" as a fallback because they
        // reproduce a known failure mode where the remote speaker is decoded
        // twice. Slice 4 ships AEC + flips this back to multichannel with
        // mic.cleaned.wav. Until then, mix to mono and rely on diarize=true.
        let mixedURL = dir.url.appendingPathComponent("mixed.wav")
        let keychain = KeychainStore(service: keychainService, account: keychainAccount)
        let apiKey = (try? keychain.read()) ?? ""
        let backend = ElevenLabsScribeBackend(apiKey: apiKey)
        let keyterms = event?.keyterms ?? []
        let request = EngineRequest(
            audioURL: mixedURL,
            mode: .singleChannelDiarized(numSpeakers: 2),
            languageCode: nil,
            keyterms: keyterms
        )
        // SpeakerMappingBuilder returns empty for single-channel diarized
        // because diarization clusters voices by acoustic features, not by
        // channel — speaker_0/_1 don't reliably correspond to mic vs system.
        let mapping = SpeakerMappingBuilder.build(event: event, mode: request.mode)

        let prepareAudio: @Sendable () async throws -> Void = {
            let fm = FileManager.default
            if fm.fileExists(atPath: mixedURL.path) { return }
            try await AudioMixer.mix(
                mic: dir.micFinal,
                system: dir.systemFinal,
                output: mixedURL,
                sampleRate: 16000
            )
        }

        return TranscriptionWorker(
            directory: dir,
            context: context,
            engine: backend,
            request: request,
            speakerMapping: mapping,
            policy: .cloud,
            prepareAudio: prepareAudio
        )
    }

    nonisolated static func runSupervisor(under root: URL) async {
        let supervisor = SessionSupervisor()
        let result = await supervisor.scanAndResume(
            under: root,
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
                makeWorker(dir: dir, context: ctx, event: nil)
            }
        )
        Log.lifecycle.info("Supervisor scan: resumed=\(result.resumed, privacy: .public), rescued=\(result.rescued, privacy: .public), markedFailed=\(result.markedFailed, privacy: .public), skipped=\(result.skipped, privacy: .public)")
    }
}
