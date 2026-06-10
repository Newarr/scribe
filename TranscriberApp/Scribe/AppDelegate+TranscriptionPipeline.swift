import Foundation
import TranscriberCore

extension AppDelegate {
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
      engine: engineMode.persistedIdentifier,
      audioRelativePaths: ["mic.m4a", "system.m4a"],
      scheduledStart: event.map { isoFmt.string(from: $0.startDate) },
      scheduledEnd: event.map { isoFmt.string(from: $0.endDate) },
      actualStart: isoFmt.string(from: startedAt),
      actualEnd: isoFmt.string(from: endedAt),
      calendarEventID: event?.calendarEventID,
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
    transcriptionLanguage: String? = nil,
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
    let canonicalAudioURL = dir.audioFinal
    let keychain = KeychainStore(service: keychainService, account: keychainAccount)
    // Codex rc1-final P1.4: dispatch through EngineSelector so a
    // future flip to local mode lands the Cohere subprocess
    // backend without touching this site. Cloud mode reads the API
    // key lazily; local mode ignores it.
    let backend =
      engineOverride
      ?? EngineSelector.makeEngine(
        for: engineMode,
        cloudAPIKey: { (try? keychain.read()) ?? "" }
      )
    let keyterms = event?.keyterms ?? []
    // The Settings language governs the LOCAL engine only: a non-nil
    // languageCode short-circuits the worker's language detector and is
    // forced onto the Cohere tokenizer. ElevenLabs auto-detects, so the
    // cloud path always passes nil regardless of the setting.
    let request = EngineRequest(
      audioURL: canonicalAudioURL,
      mode: .singleChannelDiarized(numSpeakers: 2),
      languageCode: engineMode == .local ? transcriptionLanguage : nil,
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
    let prepareAudio: @Sendable () async throws -> Void = { /* no-op */  }

    // Phase ν landed as ECAPA VoxLingua107 (MLXAudioLID) instead of the
    // originally planned WhisperKit. Local engine only: the Cohere
    // tokenizer needs an explicit language token (its nil-fallback to
    // "en" is the gibberish bug), while ElevenLabs auto-detects best
    // when left alone. An explicit Settings language short-circuits the
    // detector inside the worker.
    return TranscriptionWorker(
      directory: dir,
      context: context,
      engine: backend,
      request: request,
      speakerMapping: mapping,
      policy: .cloud,
      prepareAudio: prepareAudio,
      keepRawStreams: keepRawStreams,
      languageDetector: engineMode == .local ? EcapaLanguageDetector() : nil
    )
  }

  @discardableResult
  nonisolated static func runSupervisor(
    under root: URL,
    keepRawStreams: Bool = false,
    engineMode: EngineMode = .cloud,
    transcriptionLanguage: String? = nil,
    workerFactory overrideWorkerFactory: SessionSupervisor.WorkerFactory? = nil,
    engineFactory: (@Sendable (EngineMode) -> TranscriptionEngine)? = nil,
    localModelStatus: (@Sendable () async -> LocalModelCacheStatus)? = nil
  ) async -> SessionSupervisor.ScanResult {
    let localStatusProvider: @Sendable () async -> LocalModelCacheStatus =
      localModelStatus ?? {
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
            Log.engine.warning(
              "supervisor: local session \(dir.url.lastPathComponent, privacy: .public) requires Cohere setup before recovery; leaving pending"
            )
          case .missingOrInvalid:
            Log.engine.error(
              "supervisor: session \(dir.url.lastPathComponent, privacy: .public) has missing engine provenance; leaving recoverable for repair"
            )
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
          transcriptionLanguage: transcriptionLanguage,
          engineOverride: engineFactory?(persistedEngineMode)
        )
      }
    )
    // Codex Phase ζ P1.2: include partialAudioMarkedFailed +
    // recoveryDeferred so launch logs reflect the full ScanResult,
    // not just the v0 fields.
    Log.lifecycle.info(
      "Supervisor scan: resumed=\(result.resumed, privacy: .public), rescued=\(result.rescued, privacy: .public), markedFailed=\(result.markedFailed, privacy: .public), partialAudioMarkedFailed=\(result.partialAudioMarkedFailed, privacy: .public), recoveryDeferred=\(result.recoveryDeferred, privacy: .public), totalFailed=\(result.totalFailed, privacy: .public), skipped=\(result.skipped, privacy: .public)"
    )
    return result
  }
}
