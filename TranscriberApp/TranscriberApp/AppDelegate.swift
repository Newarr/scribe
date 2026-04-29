import AppKit
import TranscriberCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var menu: RecordingMenu?
    private var session: CaptureSession?
    private var status: SessionStatus = .idle
    private let permissions = PermissionsService()

    private var currentSessionDirectory: SessionDirectory?
    private var currentSessionStartedAt: Date?

    private var outputRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Transcriber", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.lifecycle.info("App launched, version=\(BuildInfo.version, privacy: .public)")
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

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
            try await session.start()
            self.status = .recording
            menu?.rebuild(for: status)
        } catch {
            Log.lifecycle.error("Start failed: \(String(describing: error), privacy: .public)")
            self.status = .failed
            menu?.rebuild(for: status)
        }
    }

    @MainActor
    private func stopRecording() async {
        guard let session, let dir = currentSessionDirectory else { return }
        let endedAt = Date()
        let started = currentSessionStartedAt ?? endedAt

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
        menu?.rebuild(for: status)

        // Only run transcription if capture finalized cleanly. If session.stop() threw,
        // mic.m4a / system.m4a may be missing or partial, and the AudioMixer would crash
        // or produce garbage. The transcript stub from CaptureSession was never written
        // in that case either, so the failed-stop session has no transcript on disk.
        // Slice 7's recovery layer can rescue these by detecting orphaned .partial files.
        guard stopSucceeded else { return }

        // Fire-and-forget transcription. Slice 7 will add proper queueing + retry.
        Task { [weak self] in
            await self?.transcribe(directory: dir, startedAt: started, endedAt: endedAt)
        }
    }
}

extension AppDelegate {
    @MainActor
    func transcribe(directory dir: SessionDirectory, startedAt: Date, endedAt: Date) async {
        let mixedURL = dir.url.appendingPathComponent("mixed.wav")
        let transcriptURL = dir.transcript
        let isoFmt = ISO8601DateFormatter()
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        let context = TranscriptContext(
            title: "Manual recording \(dir.url.lastPathComponent)",
            date: dayFmt.string(from: startedAt),
            engine: "elevenlabs",
            audioRelativePaths: ["mic.m4a", "system.m4a"],
            startedAt: isoFmt.string(from: startedAt),
            endedAt: isoFmt.string(from: endedAt),
            attendees: [],
            language: nil
        )
        do {
            try TranscriptWriter.writePending(at: transcriptURL, context: context)
        } catch {
            Log.engine.error("Failed to write pending transcript: \(String(describing: error), privacy: .public)")
        }

        do {
            try await AudioMixer.mix(
                mic: dir.micFinal,
                system: dir.systemFinal,
                output: mixedURL,
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
            let req = EngineRequest(
                audioURL: mixedURL,
                mode: .singleChannelDiarized(numSpeakers: 2),
                languageCode: nil,
                keyterms: []
            )
            let size = (try? mixedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            Log.engine.info("Uploading to ElevenLabs, bytes=\(size, privacy: .public)")
            let response = try await backend.transcribe(req)

            // CDX-S2-CHAL.6: empty utterance list typically means silent / corrupt audio
            // or an API edge response. Don't write `status: complete` with a blank body
            // — it looks like the transcript ran when nothing was actually transcribed.
            if response.utterances.isEmpty {
                Log.engine.error("ElevenLabs returned no utterances")
                try TranscriptWriter.writeFailed(
                    at: transcriptURL,
                    context: context,
                    errorMessage: "No speech detected in mixed audio. The mic and system tracks may be silent, corrupt, or below ElevenLabs' detection threshold."
                )
                return
            }

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
                speakerMapping: [:]
            )
            Log.engine.info("Transcript complete, utterances=\(response.utterances.count, privacy: .public)")
        } catch {
            Log.engine.error("Transcription failed: \(String(describing: error), privacy: .public)")
            do {
                try TranscriptWriter.writeFailed(at: transcriptURL, context: context, errorMessage: String(describing: error))
            } catch {
                // If the failed-transcript write itself fails (disk full, permissions),
                // log it loudly. The user has lost the durable status record but the
                // audio files are still on disk.
                Log.engine.error("Failed to write failed-transcript marker: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
