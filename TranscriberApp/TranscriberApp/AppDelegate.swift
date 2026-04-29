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

    private var outputRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Transcriber", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.lifecycle.info("App launched, version=\(BuildInfo.version, privacy: .public)")
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        // Trigger calendar permission prompt early so first-time recording isn't held up.
        // Failure is fine; recording still works without calendar.
        Task { _ = await self.calendar.requestAccess() }

        let m = RecordingMenu { [weak self] action in
            Task { @MainActor in await self?.handle(action) }
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "T"
        item.menu = m.menu
        self.statusItem = item
        self.menu = m
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

            // Snapshot the overlapping calendar event at session start. Slice 6 will add
            // a continuous watcher; slice 3 only needs the value at start time.
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

        // Fire-and-forget transcription. Slice 7 will add proper queueing + retry.
        Task { [weak self] in
            await self?.transcribe(directory: dir, startedAt: started, endedAt: endedAt, event: event)
        }
    }
}

extension AppDelegate {
    @MainActor
    func transcribe(directory dir: SessionDirectory, startedAt: Date, endedAt: Date, event: CalendarEvent?) async {
        let multichannelURL = dir.url.appendingPathComponent("multichannel.wav")
        let transcriptURL = dir.transcript
        let isoFmt = ISO8601DateFormatter()
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"

        let title = event?.title ?? "Manual recording \(dir.url.lastPathComponent)"
        let attendees = (event?.attendees ?? []).map { "[[\($0.name)]]" }

        let context = TranscriptContext(
            title: title,
            date: dayFmt.string(from: startedAt),
            engine: "elevenlabs",
            audioRelativePaths: ["mic.m4a", "system.m4a"],
            startedAt: isoFmt.string(from: startedAt),
            endedAt: isoFmt.string(from: endedAt),
            attendees: attendees,
            language: nil
        )
        do {
            try TranscriptWriter.writePending(at: transcriptURL, context: context)
        } catch {
            Log.engine.error("Failed to write pending transcript: \(String(describing: error), privacy: .public)")
        }

        do {
            try await MultichannelWAVBuilder.build(
                mic: dir.micFinal,
                system: dir.systemFinal,
                output: multichannelURL,
                sampleRate: 16000
            )

            let keychain = KeychainStore(
                service: "com.szymonsypniewicz.transcriber",
                account: "elevenlabs-api-key"
            )
            guard let apiKey = try keychain.read(), !apiKey.isEmpty else {
                let setupHint = "ElevenLabs API key not found in Keychain. Set it with: security add-generic-password -s 'com.szymonsypniewicz.transcriber' -a 'elevenlabs-api-key' -w '<your-key>' -U"
                try TranscriptWriter.writeFailed(at: transcriptURL, context: context, errorMessage: setupHint)
                Log.engine.error("API key missing")
                return
            }

            let backend = ElevenLabsScribeBackend(apiKey: apiKey)
            let keyterms = event?.keyterms ?? []
            let req = EngineRequest(
                audioURL: multichannelURL,
                mode: .multichannel,
                languageCode: nil,
                keyterms: keyterms
            )
            let size = (try? multichannelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            Log.engine.info("Uploading 2-ch to ElevenLabs, bytes=\(size, privacy: .public)")
            let response = try await backend.transcribe(req)

            if response.utterances.isEmpty {
                Log.engine.error("ElevenLabs returned no utterances")
                try TranscriptWriter.writeFailed(
                    at: transcriptURL,
                    context: context,
                    errorMessage: "No speech detected in the 2-channel upload. The mic and system tracks may be silent, corrupt, or below ElevenLabs' detection threshold."
                )
                return
            }

            let mapping = SpeakerMappingBuilder.build(event: event, mode: req.mode)
            let completedContext = TranscriptContext(
                title: context.title,
                date: context.date,
                engine: context.engine,
                audioRelativePaths: context.audioRelativePaths,
                startedAt: context.startedAt,
                endedAt: context.endedAt,
                attendees: context.attendees,
                language: response.detectedLanguage
            )
            try TranscriptWriter.writeComplete(
                at: transcriptURL,
                context: completedContext,
                utterances: response.utterances,
                speakerMapping: mapping
            )
            Log.engine.info("Transcript complete, utterances=\(response.utterances.count, privacy: .public), mapped=\(mapping.count, privacy: .public)")
        } catch {
            Log.engine.error("Transcription failed: \(String(describing: error), privacy: .public)")
            do {
                try TranscriptWriter.writeFailed(at: transcriptURL, context: context, errorMessage: String(describing: error))
            } catch {
                Log.engine.error("Failed to write failed-transcript marker: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
