import AppKit
import TranscriberCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var menu: RecordingMenu?
    private var session: CaptureSession?
    private var status: SessionStatus = .idle
    private let permissions = PermissionsService()
    private let calendar = CalendarLookup()

    private var currentSessionDirectory: SessionDirectory?
    private var currentSessionStartedAt: Date?
    private var currentCalendarEvent: CalendarEvent?

    /// In-flight transcription tasks (fresh recordings + resumed sessions). Tracked so
    /// applicationShouldTerminate can cancel them and observe completion before quitting.
    private var inflightTasks: [Task<Void, Never>] = []

    private static let keychainService = "com.szymonsypniewicz.transcriber"
    private static let keychainAccount = "elevenlabs-api-key"

    private var outputRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Transcriber", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.lifecycle.info("App launched, version=\(BuildInfo.version, privacy: .public)")
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        Task { _ = await self.calendar.requestAccess() }

        let m = RecordingMenu { [weak self] action in
            Task { @MainActor in await self?.handle(action) }
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "T"
        item.menu = m.menu
        self.statusItem = item
        self.menu = m

        // Resume any orphaned sessions from a previous launch (mid-transcribe crash,
        // unfinalized stop, retry-pending). Runs in the background so launch is fast.
        let outputRoot = self.outputRoot
        let resumeTask = Task { [weak self] in
            await Self.runSupervisor(under: outputRoot)
            await self?.cleanupFinishedTasks()
        }
        inflightTasks.append(resumeTask)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let inflight = inflightTasks.filter { !$0.isCancelled }
        guard !inflight.isEmpty else { return .terminateNow }

        Log.lifecycle.info("Quit requested with \(inflight.count, privacy: .public) in-flight task(s); cancelling and waiting up to 3s")
        inflight.forEach { $0.cancel() }

        Task { @MainActor in
            // Wait at most 3 seconds for tasks to observe cancellation and exit
            // cleanly. On-disk status: retrying state survives so the next launch
            // resumes from there.
            let deadline = Date().addingTimeInterval(3.0)
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
    private func cleanupFinishedTasks() {
        inflightTasks.removeAll { $0.isCancelled }
    }

    @MainActor
    private func handle(_ action: RecordingMenu.Action) async {
        switch action {
        case .record: await startRecording()
        case .stop:   await stopRecording()
        case .quit:   NSApp.terminate(nil)
        }
    }

    @MainActor
    private func startRecording() async {
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

            let event = self.calendar.eventOverlapping(Date())
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

        // Dispatch a TranscriptionWorker for this session. The worker handles
        // pending->retrying->complete|failed transitions, retry policy, and
        // cancellation on quit. Fire-and-forget Task tracked in inflightTasks
        // so applicationShouldTerminate can cancel cleanly.
        let context = Self.makeContext(dir: dir, startedAt: started, endedAt: endedAt, event: event)
        let worker = Self.makeWorker(dir: dir, context: context, event: event)
        let task = Task { [weak self] in
            _ = await worker.run()
            await self?.cleanupFinishedTasks()
        }
        inflightTasks.append(task)
    }
}

// MARK: - Worker construction shared by fresh + resumed paths

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
        let multichannelURL = dir.url.appendingPathComponent("multichannel.wav")
        let keychain = KeychainStore(service: keychainService, account: keychainAccount)
        let apiKey = (try? keychain.read()) ?? ""
        let backend = ElevenLabsScribeBackend(apiKey: apiKey)
        let keyterms = event?.keyterms ?? []
        let request = EngineRequest(
            audioURL: multichannelURL,
            mode: .multichannel,
            languageCode: nil,
            keyterms: keyterms
        )
        let mapping = SpeakerMappingBuilder.build(event: event, mode: request.mode)

        // prepareAudio: if multichannel.wav is missing (fresh recording or resumed
        // session that crashed pre-mix), build it from mic.m4a + system.m4a.
        let prepareAudio: @Sendable () async throws -> Void = {
            let fm = FileManager.default
            if fm.fileExists(atPath: multichannelURL.path) { return }
            try await MultichannelWAVBuilder.build(
                mic: dir.micFinal,
                system: dir.systemFinal,
                output: multichannelURL,
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
                // Resumed sessions don't have the original calendar event in memory,
                // and the existing transcript on disk already carries title +
                // attendees from when slice 3's writePending ran. Until a full
                // frontmatter reader exists, the resumed context here is minimal —
                // the worker's writeComplete will replace title/attendees with these
                // basic values, so the resumed transcript may lose some enrichment
                // metadata. Slice 6 (calendar enrichment full) can fix this by
                // adding a TranscriptContextReader.
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
