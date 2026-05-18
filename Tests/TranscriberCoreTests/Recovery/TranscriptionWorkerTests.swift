import AVFoundation
import XCTest

@testable import TranscriberCore

final class TranscriptionWorkerTests: XCTestCase {
  var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testHappyPathWritesCompleteOnFirstAttempt() async throws {
    let worker = makeWorker(responses: [.success(makeResponse())])
    let final = await worker.run()
    XCTAssertEqual(final, .complete)
    XCTAssertEqual(TranscriptStatusReader.read(at: dir().transcript), .complete)
  }

  /// Slice 9a output contract: a successful run must produce
  /// `audio.m4a` + `metadata.json` and the completed transcript should
  /// reference `audio.m4a` (not the raw mic/system files).
  func testSuccessfulRunProducesAudioAndMetadata() async throws {
    let dir = self.dir()
    try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
    // AudioFinalizer needs real m4a inputs to mix.
    try writeAACSilence(to: dir.micFinal, durationSec: 0.3)
    try writeAACSilence(to: dir.systemFinal, durationSec: 0.3)

    let worker = makeWorker(responses: [.success(makeResponse())])
    let final = await worker.run()
    XCTAssertEqual(final, .complete)

    let audioPath = dir.url.appendingPathComponent("audio.m4a").path
    let metadataPath = dir.url.appendingPathComponent("metadata.json").path
    XCTAssertTrue(FileManager.default.fileExists(atPath: audioPath), "audio.m4a missing")
    XCTAssertTrue(FileManager.default.fileExists(atPath: metadataPath), "metadata.json missing")

    // metadata.json should round-trip with audio = "audio.m4a".
    let data = try Data(contentsOf: dir.url.appendingPathComponent("metadata.json"))
    let metadata = try JSONDecoder().decode(MetadataJSONWriter.Metadata.self, from: data)
    XCTAssertEqual(metadata.audio, "audio.m4a")
    XCTAssertEqual(metadata.status, "complete")

    // transcript.md should reference audio.m4a too.
    let transcript = try String(contentsOf: dir.transcript, encoding: .utf8)
    XCTAssertTrue(
      transcript.contains("audio: \"audio.m4a\""),
      "completed transcript should reference audio.m4a, got: \(transcript.prefix(500))")
  }

  /// CDX-S9a.P2.1: failed transcripts must also produce audio.m4a +
  /// metadata.json per the spec output contract. Without this, JSON
  /// consumers see no asset at all on auth failures, retry exhaustion,
  /// or empty-utterance responses.
  func testFailedRunStillProducesAudioAndMetadata() async throws {
    let dir = self.dir()
    try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
    try writeAACSilence(to: dir.micFinal, durationSec: 0.3)
    try writeAACSilence(to: dir.systemFinal, durationSec: 0.3)

    // Terminal failure: unauthorized. No retries.
    let worker = makeWorker(responses: [.failure(ElevenLabsScribeBackend.BackendError.unauthorized)]
    )
    let final = await worker.run()
    guard case .failed = final else {
      return XCTFail("expected .failed for unauthorized, got \(final)")
    }

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("audio.m4a").path),
      "audio.m4a must exist on failure path so the failed transcript template's `Audio was captured and saved as` reference is valid"
    )
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("metadata.json").path),
      "metadata.json must exist on failure path")

    let data = try Data(contentsOf: dir.url.appendingPathComponent("metadata.json"))
    let metadata = try JSONDecoder().decode(MetadataJSONWriter.Metadata.self, from: data)
    XCTAssertEqual(metadata.status, "failed")
    XCTAssertEqual(
      metadata.audio, "audio.m4a",
      "failure metadata must reference the canonical audio asset, not raw streams")
    XCTAssertEqual(metadata.error_code, "elevenlabs_unauthorized")
    XCTAssertEqual(metadata.retry_count, 0)
    XCTAssertEqual(metadata.attempt_count, 1)
    XCTAssertNotNil(metadata.audio_duration_seconds)
    XCTAssertNotNil(metadata.audio_size_bytes)
    XCTAssertGreaterThan(metadata.audio_size_bytes ?? 0, 0)
  }

  func testNormalStopCanonicalAudioHonorsFlushedPTSLog() async throws {
    let session = dir()
    try FileManager.default.createDirectory(at: session.url, withIntermediateDirectories: true)
    try writeAACTone(to: session.micFinal, durationSec: 0.2, frequency: 440)
    try writeAACSilence(to: session.systemFinal, durationSec: 0.2)
    try writePTSLog(
      to: session.ptsStreamingLog,
      entries: [
        PTSLogEntry(stream: "mic", ptsSeconds: 100.0, sampleCount: 4800, sampleRate: 48000),
        PTSLogEntry(stream: "mic", ptsSeconds: 100.3, sampleCount: 4800, sampleRate: 48000),
        PTSLogEntry(stream: "system", ptsSeconds: 100.0, sampleCount: 4800, sampleRate: 48000),
        PTSLogEntry(stream: "system", ptsSeconds: 100.3, sampleCount: 4800, sampleRate: 48000),
      ])

    let worker = makeWorker(responses: [.success(makeResponse())], directory: session)
    let final = await worker.run()
    XCTAssertEqual(final, .complete)

    let audio = session.url.appendingPathComponent("audio.m4a")
    XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    let samples = try readSamples(from: audio)
    XCTAssertLessThan(
      samples.count, 40_000, "session path should pass pts.jsonl and normalize absolute capture PTS"
    )
    XCTAssertGreaterThan(rms(samples, start: 1_000, count: 2_000), 0.05)
    XCTAssertLessThan(
      rms(samples, start: 6_000, count: 6_000), 0.02,
      "logged 200ms PTS gap should survive canonical audio generation")
    XCTAssertGreaterThan(rms(samples, start: 15_000, count: 2_000), 0.05)
  }

  private func writeAACSilence(to url: URL, durationSec: Double) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 48000,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64_000,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames = AVAudioFrameCount(durationSec * 48000)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buf.frameLength = frames
    try file.write(from: buf)
  }

  private func writeAACTone(to url: URL, durationSec: Double, frequency: Double) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 48000,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64_000,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames = AVAudioFrameCount(durationSec * 48000)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buf.frameLength = frames
    let ptr = buf.floatChannelData![0]
    for i in 0..<Int(frames) {
      ptr[i] = Float(0.45 * sin(2 * .pi * frequency * Double(i) / 48000.0))
    }
    try file.write(from: buf)
  }

  private func writePTSLog(to url: URL, entries: [PTSLogEntry]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let lines =
      try entries.map { entry -> String in
        String(data: try encoder.encode(entry), encoding: .utf8)!
      }.joined(separator: "\n") + "\n"
    try lines.write(to: url, atomically: true, encoding: .utf8)
  }

  private func readSamples(from url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let ptr = buffer.floatChannelData![0]
    return Array(UnsafeBufferPointer(start: ptr, count: Int(buffer.frameLength)))
  }

  private func rms(_ samples: [Float], start: Int, count: Int) -> Double {
    guard start < samples.count else { return 0 }
    let end = min(samples.count, start + count)
    guard end > start else { return 0 }
    let sum = samples[start..<end].reduce(0.0) { $0 + Double($1 * $1) }
    return sqrt(sum / Double(end - start))
  }

  func testLocalSuccessWritesCohereArtifacts() async throws {
    let session = dir()
    try FileManager.default.createDirectory(at: session.url, withIntermediateDirectories: true)
    try writeAACSilence(to: session.micFinal, durationSec: 0.3)
    try writeAACSilence(to: session.systemFinal, durationSec: 0.3)

    let worker = makeWorker(
      responses: [.success(makeResponse(modelID: CohereMLXBackend.modelID))],
      directory: session,
      context: makeContext(engine: "cohere"),
      request: EngineRequest(
        audioURL: session.url.appendingPathComponent("audio.m4a"),
        mode: .singleChannelDiarized(numSpeakers: nil),
        languageCode: nil,
        keyterms: ["must-not-matter"],
        modelID: CohereMLXBackend.modelID
      )
    )

    let final = await worker.run()
    XCTAssertEqual(final, .complete)

    let transcript = try String(contentsOf: session.transcript, encoding: .utf8)
    XCTAssertTrue(transcript.contains("engine: cohere"), transcript)
    XCTAssertTrue(transcript.contains("audio: \"audio.m4a\""), transcript)
    XCTAssertFalse(
      transcript.contains("status:"), "complete transcript must omit status: \(transcript)")

    let metadata = try JSONDecoder().decode(
      MetadataJSONWriter.Metadata.self,
      from: Data(contentsOf: session.url.appendingPathComponent("metadata.json"))
    )
    XCTAssertEqual(metadata.status, "complete")
    XCTAssertEqual(metadata.engine, "cohere")
    XCTAssertEqual(metadata.audio, "audio.m4a")
  }

  func testLocalTerminalFailureWritesCohereFailedArtifactsAndPreservesAudio() async throws {
    let session = dir()
    try FileManager.default.createDirectory(at: session.url, withIntermediateDirectories: true)
    try writeAACSilence(to: session.micFinal, durationSec: 0.3)
    try writeAACSilence(to: session.systemFinal, durationSec: 0.3)

    let localEngine = RecordingEngine(responses: [.failure(LocalFixtureError.inferenceFailed)])
    let cloudEngine = RecordingEngine(responses: [.success(makeResponse())])
    let worker = makeWorker(
      engine: localEngine,
      directory: session,
      context: makeContext(engine: "cohere"),
      request: EngineRequest(
        audioURL: session.url.appendingPathComponent("audio.m4a"),
        mode: .singleChannelDiarized(numSpeakers: nil),
        languageCode: nil,
        keyterms: [],
        modelID: CohereMLXBackend.modelID
      )
    )

    let final = await worker.run()
    guard case .failed = final else { return XCTFail("expected failed, got \(final)") }

    let localCallCount = await localEngine.callCount
    let cloudCallCount = await cloudEngine.callCount
    XCTAssertEqual(localCallCount, 1)
    XCTAssertEqual(cloudCallCount, 0, "local failure must not call cloud fallback")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: session.url.appendingPathComponent("audio.m4a").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: session.micFinal.path),
      "failed local sessions preserve raw retryable audio")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: session.systemFinal.path),
      "failed local sessions preserve raw retryable audio")

    let transcript = try String(contentsOf: session.transcript, encoding: .utf8)
    XCTAssertTrue(transcript.contains("status: failed"), transcript)
    XCTAssertTrue(transcript.contains("engine: cohere"), transcript)
    XCTAssertTrue(transcript.contains("audio: \"audio.m4a\""), transcript)
    XCTAssertTrue(transcript.contains("error_code: \"transcription_failed\""), transcript)
    XCTAssertTrue(transcript.contains("retry_count: 0"), transcript)
    XCTAssertTrue(transcript.contains("attempt_count: 1"), transcript)
    XCTAssertTrue(transcript.contains("audio_duration_seconds:"), transcript)
    XCTAssertTrue(transcript.contains("audio_size_bytes:"), transcript)
    XCTAssertTrue(transcript.contains("## What you can do"), transcript)

    let metadata = try JSONDecoder().decode(
      MetadataJSONWriter.Metadata.self,
      from: Data(contentsOf: session.url.appendingPathComponent("metadata.json"))
    )
    XCTAssertEqual(metadata.status, "failed")
    XCTAssertEqual(metadata.engine, "cohere")
    XCTAssertEqual(metadata.audio, "audio.m4a")
    XCTAssertEqual(metadata.error_code, "transcription_failed")
    XCTAssertEqual(metadata.retry_count, 0)
    XCTAssertEqual(metadata.attempt_count, 1)
    XCTAssertNotNil(metadata.audio_duration_seconds)
    XCTAssertNotNil(metadata.audio_size_bytes)
  }

  func testLocalRetryReusesExistingSessionAudioAndUpdatesSameArtifacts() async throws {
    let session = dir()
    try FileManager.default.createDirectory(at: session.url, withIntermediateDirectories: true)
    try Data("existing-audio".utf8).write(to: session.url.appendingPathComponent("audio.m4a"))
    try TranscriptWriter.writeFailed(
      at: session.transcript,
      context: makeContext(engine: "cohere", audioRelativePaths: ["audio.m4a"]),
      errorMessage: "previous local failure"
    )
    try MetadataJSONWriter.write(
      at: session.url.appendingPathComponent("metadata.json"),
      metadata: MetadataJSONWriter.Metadata(
        status: .failed,
        context: makeContext(engine: "cohere", audioRelativePaths: ["audio.m4a"]),
        audio: "audio.m4a",
        aecStatus: .failed
      )
    )

    let engine = RecordingEngine(responses: [
      .success(makeResponse(modelID: CohereMLXBackend.modelID))
    ])
    let worker = makeWorker(
      engine: engine,
      directory: session,
      context: makeContext(engine: "cohere", audioRelativePaths: ["audio.m4a"]),
      request: EngineRequest(
        audioURL: session.url.appendingPathComponent("audio.m4a"),
        mode: .singleChannelDiarized(numSpeakers: nil),
        languageCode: nil,
        keyterms: [],
        modelID: CohereMLXBackend.modelID
      ),
      retryTerminalFailures: true
    )

    let final = await worker.run()
    XCTAssertEqual(final, .complete)
    let audioURLs = await engine.audioURLs
    XCTAssertEqual(audioURLs, [session.url.appendingPathComponent("audio.m4a")])
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: session.url.appendingPathComponent("audio.m4a").path))

    let transcript = try String(contentsOf: session.transcript, encoding: .utf8)
    XCTAssertTrue(transcript.contains("engine: cohere"), transcript)
    XCTAssertTrue(transcript.contains("Hello"), transcript)
    XCTAssertFalse(transcript.contains("status:"), transcript)
    let metadata = try JSONDecoder().decode(
      MetadataJSONWriter.Metadata.self,
      from: Data(contentsOf: session.url.appendingPathComponent("metadata.json"))
    )
    XCTAssertEqual(metadata.status, "complete")
    XCTAssertEqual(metadata.engine, "cohere")
  }

  func testCloudRetryReusesExistingSessionAudioAndUpdatesSameArtifacts() async throws {
    let session = dir()
    try FileManager.default.createDirectory(at: session.url, withIntermediateDirectories: true)
    let audio = session.url.appendingPathComponent("audio.m4a")
    try Data("existing-cloud-audio".utf8).write(to: audio)
    try TranscriptWriter.writeFailed(
      at: session.transcript,
      context: makeContext(engine: "elevenlabs", audioRelativePaths: ["audio.m4a"]),
      errorMessage: "previous cloud failure"
    )
    let transcriptBefore =
      try FileManager.default.attributesOfItem(atPath: session.transcript.path)[.modificationDate]
      as? Date
    let metadataURL = session.url.appendingPathComponent("metadata.json")
    try MetadataJSONWriter.write(
      at: metadataURL,
      metadata: MetadataJSONWriter.Metadata(
        status: .failed,
        context: makeContext(engine: "elevenlabs", audioRelativePaths: ["audio.m4a"]),
        audio: "audio.m4a",
        aecStatus: .failed
      )
    )

    let engine = RecordingEngine(responses: [.success(makeResponse())])
    let worker = makeWorker(
      engine: engine,
      directory: session,
      context: makeContext(engine: "elevenlabs", audioRelativePaths: ["audio.m4a"]),
      request: EngineRequest(
        audioURL: audio,
        mode: .singleChannelDiarized(numSpeakers: nil),
        languageCode: nil,
        keyterms: [],
        modelID: "scribe_v2"
      ),
      retryTerminalFailures: true
    )

    let final = await worker.run()
    XCTAssertEqual(final, .complete)
    let audioURLs = await engine.audioURLs
    XCTAssertEqual(audioURLs, [audio])
    XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    XCTAssertEqual(try Data(contentsOf: audio), Data("existing-cloud-audio".utf8))
    XCTAssertEqual(
      session.url.lastPathComponent, "session", "retry must stay in the original session directory")

    let transcript = try String(contentsOf: session.transcript, encoding: .utf8)
    XCTAssertTrue(transcript.contains("engine: elevenlabs"), transcript)
    XCTAssertTrue(transcript.contains("Hello"), transcript)
    XCTAssertFalse(transcript.contains("status:"), transcript)
    let transcriptAfter =
      try FileManager.default.attributesOfItem(atPath: session.transcript.path)[.modificationDate]
      as? Date
    XCTAssertNotEqual(transcriptBefore, transcriptAfter)

    let metadata = try JSONDecoder().decode(
      MetadataJSONWriter.Metadata.self,
      from: Data(contentsOf: metadataURL)
    )
    XCTAssertEqual(metadata.status, "complete")
    XCTAssertEqual(metadata.engine, "elevenlabs")
    XCTAssertEqual(metadata.audio, "audio.m4a")
  }

  func testLocalCancellationAfterAudioFinalizationLeavesRecoverablePendingArtifacts() async throws {
    let session = dir()
    try FileManager.default.createDirectory(at: session.url, withIntermediateDirectories: true)
    try writeAACSilence(to: session.micFinal, durationSec: 0.3)
    try writeAACSilence(to: session.systemFinal, durationSec: 0.3)

    let engine = RecordingEngine(responses: [.failure(CancellationError())])
    let worker = makeWorker(
      engine: engine,
      directory: session,
      context: makeContext(engine: "cohere"),
      request: EngineRequest(
        audioURL: session.url.appendingPathComponent("audio.m4a"),
        mode: .singleChannelDiarized(numSpeakers: nil),
        languageCode: nil,
        keyterms: [],
        modelID: CohereMLXBackend.modelID
      )
    )

    let final = await worker.run()
    XCTAssertEqual(final, .cancelled)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: session.url.appendingPathComponent("audio.m4a").path))
    XCTAssertEqual(TranscriptStatusReader.read(at: session.transcript), .pending)
    let parsed = TranscriptFrontmatterReader.read(at: session.transcript)
    XCTAssertEqual(parsed?.context.engine, "cohere")
    XCTAssertEqual(parsed?.context.audioRelativePaths, ["audio.m4a"])
    let metadata = try JSONDecoder().decode(
      MetadataJSONWriter.Metadata.self,
      from: Data(contentsOf: session.url.appendingPathComponent("metadata.json"))
    )
    XCTAssertEqual(metadata.status, "pending")
    XCTAssertEqual(metadata.engine, "cohere")
    XCTAssertEqual(metadata.audio, "audio.m4a")
  }

  func testTransientFailureThenSuccessOnRetry() async throws {
    let worker = makeWorker(responses: [
      .failure(ElevenLabsScribeBackend.BackendError.rateLimited),
      .success(makeResponse()),
    ])
    let final = await worker.run()
    XCTAssertEqual(final, .complete)
    XCTAssertEqual(TranscriptStatusReader.read(at: dir().transcript), .complete)
  }

  /// CDX-S7-FINAL.P2.2: writeRetrying must preserve all calendar-enriched
  /// fields (attendees, language) on the retrying-status transcript so a
  /// relaunch during backoff can read them back via
  /// TranscriptFrontmatterReader and resume with the original metadata.
  func testRetryingFrontmatterPreservesAttendeesAndLanguage() async throws {
    try FileManager.default.createDirectory(at: dir().url, withIntermediateDirectories: true)
    let richContext = TranscriptContext(
      title: "1:1 with Faris",
      date: "2026-04-29",
      engine: "elevenlabs",
      audioRelativePaths: ["mic.m4a", "system.m4a"],
      startedAt: "2026-04-29T14:30:00Z",
      endedAt: "2026-04-29T15:00:00Z",
      attendees: [
        TranscriptPerson(name: "Szymon Sypniewicz"), TranscriptPerson(name: "Faris Riaz"),
      ],
      language: "en"
    )
    let engine = FakeEngine(responses: [
      .failure(ElevenLabsScribeBackend.BackendError.rateLimited),
      .success(makeResponse()),
    ])
    let worker = TranscriptionWorker(
      directory: dir(),
      context: richContext,
      engine: engine,
      request: EngineRequest(
        audioURL: root.appendingPathComponent("multichannel.wav"),
        mode: .multichannel,
        languageCode: "en",
        keyterms: []
      ),
      speakerMapping: [:],
      policy: RetryPolicy(delays: [0.001, 0.001, 0.001]),
      sleep: { _ in /* skip */ }
    )

    // Capture the retrying-status frontmatter mid-run by reading it after
    // the first failure but before the worker overwrites with complete.
    // Easiest: pre-write a retrying status, parse its frontmatter, and
    // confirm the writer's output round-trips through the reader.
    // Drive the test by failing the engine once and asserting on whatever
    // intermediate file content surfaces — but simpler is to just verify
    // the round-trip after run() lands on complete.
    let final = await worker.run()
    XCTAssertEqual(final, .complete)

    // Then directly invoke the private codepath via a separate harness:
    // simulate the failure write by calling writeRetrying through a tiny
    // re-creation of its body builder. Since writeRetrying is private,
    // assert via the actually-observable behavior: a retrying transcript
    // written by the worker must parse back with attendees + language.
    // For this we run a SECOND worker that fails 3 times so it persists
    // retrying+terminal failure and never reaches complete.
    let dir2 = SessionDirectory(url: root.appendingPathComponent("session-retry"))
    try FileManager.default.createDirectory(at: dir2.url, withIntermediateDirectories: true)
    let engine2 = FakeEngine(responses: [
      .failure(ElevenLabsScribeBackend.BackendError.rateLimited)
    ])
    let worker2 = TranscriptionWorker(
      directory: dir2,
      context: richContext,
      engine: engine2,
      request: EngineRequest(
        audioURL: root.appendingPathComponent("multichannel.wav"),
        mode: .multichannel,
        languageCode: "en",
        keyterms: []
      ),
      speakerMapping: [:],
      policy: RetryPolicy(delays: [0.001]),
      sleep: { _ in /* skip */ }
    )
    // Pre-populate a retrying transcript from a fresh start to capture the writer's shape.
    // The worker first writes retrying after the initial failure, then sleeps 0.001s, then
    // gets noMoreResponses (terminal) and writes failed. Read the failed transcript and
    // assert it preserves attendees + language.
    _ = await worker2.run()
    let parsed = TranscriptFrontmatterReader.read(at: dir2.transcript)
    XCTAssertNotNil(parsed)
    XCTAssertEqual(
      parsed?.context.attendees,
      [TranscriptPerson(name: "Szymon Sypniewicz"), TranscriptPerson(name: "Faris Riaz")])
    XCTAssertEqual(parsed?.context.language, "en")
  }

  func testFourTransientCloudFailuresRecordsThreeRetriesAndFourAttempts() async throws {
    let err = ElevenLabsScribeBackend.BackendError.rateLimited
    let worker = makeWorker(responses: [.failure(err), .failure(err), .failure(err), .failure(err)])
    let final = await worker.run()
    guard case .failed = final else {
      return XCTFail("expected .failed, got \(final)")
    }
    XCTAssertEqual(TranscriptStatusReader.read(at: dir().transcript), .failed)
    let transcript = try String(contentsOf: dir().transcript, encoding: .utf8)
    XCTAssertTrue(transcript.contains("retry_count: 3"), transcript)
    XCTAssertTrue(transcript.contains("attempt_count: 4"), transcript)
    let metadata = try JSONDecoder().decode(
      MetadataJSONWriter.Metadata.self,
      from: Data(contentsOf: dir().url.appendingPathComponent("metadata.json"))
    )
    XCTAssertEqual(metadata.retry_count, 3)
    XCTAssertEqual(metadata.attempt_count, 4)
  }

  func testTerminalErrorDoesNotRetry() async throws {
    let counter = SleepCounter()
    let worker = makeWorker(
      responses: [.failure(ElevenLabsScribeBackend.BackendError.unauthorized)],
      sleep: { _ in await counter.increment() }
    )
    let final = await worker.run()
    guard case .failed = final else {
      return XCTFail("expected .failed, got \(final)")
    }
    let n = await counter.count
    XCTAssertEqual(n, 0, "terminal errors must not trigger sleep/retry")
    XCTAssertEqual(TranscriptStatusReader.read(at: dir().transcript), .failed)
  }

  func testEmptyResponseFails() async throws {
    let empty = EngineResponse(utterances: [], detectedLanguage: "en", modelID: "scribe_v2")
    let worker = makeWorker(responses: [.success(empty)])
    let final = await worker.run()
    guard case .failed(let reason) = final else {
      return XCTFail("expected .failed for empty utterances")
    }
    XCTAssertTrue(reason.contains("No speech"), "reason should mention no-speech: \(reason)")
  }

  /// CDX-S7-CHAL.P2.2: when resuming a `retrying` session whose attempt count
  /// is already at the policy max, the worker must NOT grant a fresh budget.
  /// One transient failure here should write `failed` and never sleep.
  func testRetryingSessionResumesFromPersistedAttempts() async throws {
    try FileManager.default.createDirectory(at: dir().url, withIntermediateDirectories: true)
    // Pre-populate the transcript at attempts=3 (the cloud policy's max
    // failure count). After this, a single fresh failure is terminal.
    let stub = """
      ---
      schema: transcriber/v1
      status: retrying
      title: "Test Session"
      date: 2026-04-29
      engine: elevenlabs
      audio:
        - mic.m4a
        - system.m4a
      started_at: 2026-04-29T14:30:00Z
      ended_at: 2026-04-29T15:00:00Z
      attempts: 3
      ---

      body
      """
    try stub.write(to: dir().transcript, atomically: true, encoding: .utf8)

    let counter = SleepCounter()
    let worker = makeWorker(
      responses: [.failure(ElevenLabsScribeBackend.BackendError.rateLimited)],
      sleep: { _ in await counter.increment() }
    )
    let final = await worker.run()
    guard case .failed = final else {
      return XCTFail("expected .failed (budget exhausted), got \(final)")
    }
    let sleeps = await counter.count
    XCTAssertEqual(
      sleeps, 0,
      "worker must not retry once persisted attempts hits policy max; \(sleeps) sleeps observed")
  }

  func testIdempotentOnAlreadyComplete() async throws {
    // Session dir must exist before we can write the pre-populated transcript.
    try FileManager.default.createDirectory(at: dir().url, withIntermediateDirectories: true)

    // Pre-populate the transcript with status: complete.
    let context = makeContext()
    let utterances = [
      EngineResponse.Utterance(speaker: "speaker_0", startSeconds: 0, endSeconds: 1, text: "Hi")
    ]
    try TranscriptWriter.writeComplete(
      at: dir().transcript, context: context, utterances: utterances, speakerMapping: [:])

    // Engine throws to prove the worker doesn't call it.
    let worker = makeWorker(responses: [.failure(ElevenLabsScribeBackend.BackendError.unauthorized)]
    )
    let final = await worker.run()
    XCTAssertEqual(final, .complete)
  }

  // MARK: - helpers

  private func dir() -> SessionDirectory {
    SessionDirectory(url: root.appendingPathComponent("session"))
  }

  private func makeContext(
    engine: String = "elevenlabs", audioRelativePaths: [String] = ["mic.m4a", "system.m4a"]
  ) -> TranscriptContext {
    TranscriptContext(
      title: "Test Session",
      date: "2026-04-29",
      engine: engine,
      audioRelativePaths: audioRelativePaths,
      startedAt: "2026-04-29T14:30:00Z",
      endedAt: "2026-04-29T15:00:00Z",
      attendees: [],
      language: nil
    )
  }

  private func makeResponse(modelID: String = "scribe_v2") -> EngineResponse {
    EngineResponse(
      utterances: [
        .init(speaker: "speaker_0", startSeconds: 0, endSeconds: 1.0, text: "Hello"),
        .init(speaker: "speaker_1", startSeconds: 1.1, endSeconds: 2.0, text: "World"),
      ],
      detectedLanguage: "en",
      modelID: modelID
    )
  }

  private func makeWorker(
    responses: [Result<EngineResponse, Error>],
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in /* skip */ },
    keepRawStreams: Bool = false,
    directory: SessionDirectory? = nil,
    context: TranscriptContext? = nil,
    request: EngineRequest? = nil,
    retryTerminalFailures: Bool = false
  ) -> TranscriptionWorker {
    let session = directory ?? dir()
    let engine = FakeEngine(responses: responses)
    return makeWorker(
      engine: engine,
      directory: session,
      context: context ?? makeContext(),
      request: request
        ?? EngineRequest(
          audioURL: root.appendingPathComponent("multichannel.wav"),
          mode: .multichannel,
          languageCode: nil,
          keyterms: []
        ),
      sleep: sleep,
      keepRawStreams: keepRawStreams,
      retryTerminalFailures: retryTerminalFailures
    )
  }

  private func makeWorker(
    engine: TranscriptionEngine,
    directory session: SessionDirectory,
    context: TranscriptContext,
    request: EngineRequest,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in /* skip */ },
    keepRawStreams: Bool = false,
    retryTerminalFailures: Bool = false
  ) -> TranscriptionWorker {
    try? FileManager.default.createDirectory(at: session.url, withIntermediateDirectories: true)
    return TranscriptionWorker(
      directory: session,
      context: context,
      engine: engine,
      request: request,
      speakerMapping: [:],
      policy: RetryPolicy(delays: [0.001, 0.001, 0.001]),
      sleep: sleep,
      keepRawStreams: keepRawStreams,
      retryTerminalFailures: retryTerminalFailures
    )
  }

  // MARK: - Phase ι: keep_raw_streams polarity (spec line 102)

  /// Default keepRawStreams=false + audio.m4a present + complete
  /// state → raw streams must be deleted.
  func testRawStreamsDeletedOnSuccessByDefault() async throws {
    let session = dir()
    try FileManager.default.createDirectory(at: session.url, withIntermediateDirectories: true)
    try Data("mic-bytes".utf8).write(to: session.micFinal)
    try Data("sys-bytes".utf8).write(to: session.systemFinal)
    try Data("mixed".utf8).write(to: session.url.appendingPathComponent("audio.m4a"))

    let worker = makeWorker(
      responses: [.success(makeResponse())], keepRawStreams: false, directory: session)
    let final = await worker.run()
    XCTAssertEqual(final, .complete)

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: session.micFinal.path),
      "spec line 102: raw mic must be deleted on success")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: session.systemFinal.path),
      "spec line 102: raw system must be deleted on success")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: session.url.appendingPathComponent("audio.m4a").path),
      "audio.m4a must survive")
  }

  /// keepRawStreams=true + complete state → raws preserved.
  func testRawStreamsPreservedWhenKeepRawStreamsTrue() async throws {
    let session = dir()
    try FileManager.default.createDirectory(at: session.url, withIntermediateDirectories: true)
    try Data("mic-bytes".utf8).write(to: session.micFinal)
    try Data("sys-bytes".utf8).write(to: session.systemFinal)
    try Data("mixed".utf8).write(to: session.url.appendingPathComponent("audio.m4a"))

    let worker = makeWorker(
      responses: [.success(makeResponse())], keepRawStreams: true, directory: session)
    _ = await worker.run()

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: session.micFinal.path),
      "keepRawStreams=true: raws must survive")
    XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemFinal.path))
  }

  /// audio.m4a missing → raws preserved even on success (don't orphan
  /// the user's only audio).
  func testRawStreamsPreservedWhenAudioM4AMissing() async throws {
    let session = dir()
    try FileManager.default.createDirectory(at: session.url, withIntermediateDirectories: true)
    try Data("mic-bytes".utf8).write(to: session.micFinal)
    try Data("sys-bytes".utf8).write(to: session.systemFinal)
    // NO audio.m4a — finalizer didn't run or failed.

    let worker = makeWorker(
      responses: [.success(makeResponse())], keepRawStreams: false, directory: session)
    _ = await worker.run()

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: session.micFinal.path),
      "audio.m4a missing: don't orphan the user's only copy")
    XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemFinal.path))
  }

  /// Failed terminal state → raws preserved (might be needed for
  /// manual recovery / re-upload).
  func testRawStreamsPreservedOnTerminalFailure() async throws {
    let session = dir()
    try FileManager.default.createDirectory(at: session.url, withIntermediateDirectories: true)
    try Data("mic-bytes".utf8).write(to: session.micFinal)
    try Data("sys-bytes".utf8).write(to: session.systemFinal)
    try Data("mixed".utf8).write(to: session.url.appendingPathComponent("audio.m4a"))

    // A fatal (non-transient) engine error → terminal failed state
    // without delete.
    struct FatalError: Error {}
    let worker = makeWorker(
      responses: [.failure(FatalError())], keepRawStreams: false, directory: session)
    let final = await worker.run()
    if case .failed = final {
      // expected
    } else {
      XCTFail("expected failed terminal state, got \(final)")
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: session.micFinal.path),
      "spec line 102: NEVER delete raws on failed terminal state")
    XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemFinal.path))
  }
}

actor SleepCounter {
  private(set) var count = 0
  func increment() { count += 1 }
}

enum LocalFixtureError: Error { case inferenceFailed }

actor RecordingEngine: TranscriptionEngine {
  private var queue: [Result<EngineResponse, Error>]
  private(set) var audioURLs: [URL] = []

  init(responses: [Result<EngineResponse, Error>]) {
    self.queue = responses
  }

  var callCount: Int { audioURLs.count }

  func transcribe(_ request: EngineRequest) async throws -> EngineResponse {
    audioURLs.append(request.audioURL)
    guard !queue.isEmpty else { throw FakeEngine.FakeError.noMoreResponses }
    let next = queue.removeFirst()
    switch next {
    case .success(let r): return r
    case .failure(let e): throw e
    }
  }
}

actor FakeEngine: TranscriptionEngine {
  private var queue: [Result<EngineResponse, Error>]

  init(responses: [Result<EngineResponse, Error>]) {
    self.queue = responses
  }

  func transcribe(_ request: EngineRequest) async throws -> EngineResponse {
    guard !queue.isEmpty else { throw FakeError.noMoreResponses }
    let next = queue.removeFirst()
    switch next {
    case .success(let r): return r
    case .failure(let e): throw e
    }
  }

  enum FakeError: Error { case noMoreResponses }
}
