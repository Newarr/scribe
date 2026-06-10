import AVFoundation
import Foundation

/// Produces the V1 spec's user-facing `audio.m4a` (mono AAC, 48kHz) from the
/// per-channel `mic.m4a` + `system.m4a` files.
///
/// Phase ε: streaming pipeline. v0 read both files entirely into memory
/// (~700MB per stream at 60 minutes); the streaming version reads + mixes +
/// writes one ~100ms chunk at a time with `expectsMediaDataInRealTime =
/// false` and `isReadyForMoreMediaData` backpressure polling, keeping
/// peak resident memory proportional to chunk size, not file size.
///
/// Mix recipe: power-preserving — single-active side passes through at its
/// original amplitude, dual-active sides are scaled by 1/√2 each (so two
/// uncorrelated full-scale signals don't clip the sum). Per-sample peak
/// limit at 0.891 ≈ -1 dBFS gives true-peak headroom per spec § Audio
/// normalization.
///
/// LUFS normalization (spec § Audio normalization, target -16 LUFS /
/// true peak ≤ -1 dBTP) is approximated as power-preserving RMS-style
/// scaling per the D3 plan decision — shipping rc1 with documented
/// spec deviation; real BS.1770 lands in V1.1. See docs/spec/SPEC.md
/// "Audio normalization" for the contract and the intentional gap.
public enum AudioFinalizer {
  public enum FinalizeError: Error, Equatable {
    case readFailed(URL)
    case writerSetupFailed
    case writerFailed(String?)
    case converterCreationFailed
    case backpressureTimeout
    case writerStatusFailed
    case invalidPTSLog
  }

  /// Knobs are surfaced so tests can drive partial-chunk EOF boundaries
  /// and short backpressure timeouts without 30-second wall-clock waits.
  public struct Options: Sendable {
    /// Target frames produced per pull. 4800 @ 48kHz = 100ms — small
    /// enough to bound memory, large enough to keep the AAC encoder fed.
    public var chunkFrames: AVAudioFrameCount

    /// Backpressure poll interval when the AVAssetWriter input is full.
    public var backpressureSleep: TimeInterval

    /// Maximum continuous time we'll wait for the writer to drain
    /// before giving up. Prevents an indefinite hang when the disk is
    /// full or the encoder has wedged.
    public var backpressureTimeout: TimeInterval

    /// Test seam for deterministic writer backpressure coverage. Production
    /// uses the real AVAssetWriterInput readiness; tests can force a
    /// permanently not-ready input without relying on encoder timing.
    var forceWriterInputNotReady: Bool

    /// Test seam for deterministic writer/output failure coverage after
    /// inflight output creation. Production leaves this nil and uses the
    /// real AVAssetWriter behavior; tests force the shared failure handling
    /// paths without relying on disk-full, timing, or encoder flakiness.
    var forcedWriterFailure: ForcedWriterFailure?

    public init(
      chunkFrames: AVAudioFrameCount = 4800,
      backpressureSleep: TimeInterval = 0.01,
      backpressureTimeout: TimeInterval = 30,
      forceWriterInputNotReady: Bool = false,
      forcedWriterFailure: ForcedWriterFailure? = nil
    ) {
      self.chunkFrames = chunkFrames
      self.backpressureSleep = backpressureSleep
      self.backpressureTimeout = backpressureTimeout
      self.forceWriterInputNotReady = forceWriterInputNotReady
      self.forcedWriterFailure = forcedWriterFailure
    }

    public static let `default` = Options()
  }

  public enum ForcedWriterFailure: Sendable {
    case append
    case statusDuringReadinessPolling
    case finishWriting
  }

  public static func finalize(
    mic: URL,
    system: URL,
    output: URL,
    sampleRate: Double = 48000,
    ptsLogURL: URL? = nil,
    options: Options = .default
  ) async throws {
    let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    let writerSettings = aacMonoSettings(sampleRate: sampleRate)

    if let ptsLogURL, FileManager.default.fileExists(atPath: ptsLogURL.path) {
      let timeline = try readPTSTimeline(at: ptsLogURL, outputSampleRate: sampleRate)
      if !timeline.mic.isEmpty || !timeline.system.isEmpty {
        try await finalizeWithTimeline(
          mic: mic,
          system: system,
          output: output,
          sampleRate: sampleRate,
          monoFormat: monoFormat,
          timeline: timeline,
          options: options,
          writerSettings: writerSettings
        )
        return
      }
    }

    let micPrependFrames: Int = 0
    let systemPrependFrames: Int = 0

    // Write to a sibling temp path so a mid-stream failure (or an
    // attempted retry after a previous run) cannot wipe an existing
    // finalized audio.m4a. Atomic move at the very end.
    let tempName = ".\(output.lastPathComponent).inflight-\(UUID().uuidString.prefix(8))"
    let tempOutput = output.deletingLastPathComponent().appendingPathComponent(tempName)
    try? FileManager.default.removeItem(at: tempOutput)

    let micFile = try AVAudioFile(forReading: mic)
    let sysFile = try AVAudioFile(forReading: system)

    let micReader = try StreamReader(
      file: micFile, target: monoFormat, chunkFrames: options.chunkFrames)
    let sysReader = try StreamReader(
      file: sysFile, target: monoFormat, chunkFrames: options.chunkFrames)

    let writer = try AVAssetWriter(outputURL: tempOutput, fileType: .m4a)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else { throw FinalizeError.writerSetupFailed }
    writer.add(input)

    guard writer.startWriting() else {
      throw FinalizeError.writerFailed(writer.error.map { String(describing: $0) })
    }
    writer.startSession(atSourceTime: .zero)

    let micChunk = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: options.chunkFrames)!
    let sysChunk = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: options.chunkFrames)!
    // Reused across chunks: makeSampleBuffer copies the PCM bytes into its
    // own CMBlockBuffer, so mutating `mixed` on the next iteration is safe.
    let mixed = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: options.chunkFrames)!
    let formatDescription = try makeFormatDescription(for: monoFormat)
    var cumulativeFrames: Int64 = 0

    // Power-preserving mix coefficients. Single active side stays at
    // unity, dual-active is scaled by 1/√2 so two uncorrelated
    // full-scale sources sum to ~ -3 dB (instead of clipping at 6 dB
    // above, or attenuating at 6 dB below as v0's *0.5 averaging did).
    let invSqrt2 = Float(1.0 / 2.0.squareRoot())
    let peakLimit: Float = 0.891  // ~ -1 dBFS true-peak headroom

    // Codex rc2-audit CAP-2: consume the prepend-silence budget
    // before reading from the file. `remainingMicSilence` /
    // `remainingSystemSilence` are decremented as we synthesize
    // zero-filled chunks; once they hit 0 we resume reading from
    // the source files.
    var remainingMicSilence = micPrependFrames
    var remainingSystemSilence = systemPrependFrames

    do {
      while !(micReader.isExhausted && sysReader.isExhausted) || remainingMicSilence > 0
        || remainingSystemSilence > 0
      {
        let micFrames: AVAudioFrameCount
        if remainingMicSilence > 0 {
          let take = min(Int(options.chunkFrames), remainingMicSilence)
          micChunk.frameLength = AVAudioFrameCount(take)
          if let ptr = micChunk.floatChannelData?[0] {
            memset(ptr, 0, take * MemoryLayout<Float>.size)
          }
          remainingMicSilence -= take
          micFrames = AVAudioFrameCount(take)
        } else {
          micFrames = try micReader.produce(into: micChunk, target: options.chunkFrames)
        }
        let sysFrames: AVAudioFrameCount
        if remainingSystemSilence > 0 {
          let take = min(Int(options.chunkFrames), remainingSystemSilence)
          sysChunk.frameLength = AVAudioFrameCount(take)
          if let ptr = sysChunk.floatChannelData?[0] {
            memset(ptr, 0, take * MemoryLayout<Float>.size)
          }
          remainingSystemSilence -= take
          sysFrames = AVAudioFrameCount(take)
        } else {
          sysFrames = try sysReader.produce(into: sysChunk, target: options.chunkFrames)
        }

        let frames = max(micFrames, sysFrames)
        if frames == 0 { break }

        mixed.frameLength = frames
        let mixPtr = mixed.floatChannelData![0]
        let micPtr = micChunk.floatChannelData![0]
        let sysPtr = sysChunk.floatChannelData![0]

        let micCount = Int(micFrames)
        let sysCount = Int(sysFrames)
        for i in 0..<Int(frames) {
          let micActive = i < micCount
          let sysActive = i < sysCount
          let m = micActive ? micPtr[i] : 0
          let s = sysActive ? sysPtr[i] : 0
          let sum: Float
          if micActive && sysActive {
            sum = (m + s) * invSqrt2
          } else {
            sum = m + s  // single-active side preserved at unity
          }
          mixPtr[i] = max(-peakLimit, min(peakLimit, sum))
        }

        let pts = CMTime(value: cumulativeFrames, timescale: Int32(sampleRate))
        cumulativeFrames += Int64(frames)
        let sample = try Self.makeSampleBuffer(
          from: mixed, presentationTimeStamp: pts, format: formatDescription)

        // Bounded backpressure. Without the timeout + writer-status
        // check, a wedged writer (disk full, sandbox revoked,
        // encoder stalled) would loop forever.
        let waitStart = Date()
        while !(options.forceWriterInputNotReady ? false : input.isReadyForMoreMediaData) {
          if Task.isCancelled { throw CancellationError() }
          if options.forcedWriterFailure == .statusDuringReadinessPolling {
            throw FinalizeError.writerStatusFailed
          }
          if writer.status == .failed || writer.status == .cancelled {
            throw FinalizeError.writerStatusFailed
          }
          if Date().timeIntervalSince(waitStart) > options.backpressureTimeout {
            throw FinalizeError.backpressureTimeout
          }
          try await Task.sleep(nanoseconds: UInt64(options.backpressureSleep * 1_000_000_000))
        }

        if options.forcedWriterFailure == .append {
          throw FinalizeError.writerFailed("forced append failure")
        }
        if !input.append(sample) {
          throw FinalizeError.writerFailed(writer.error.map { String(describing: $0) })
        }
      }

      input.markAsFinished()
      await writer.finishWriting()
      if options.forcedWriterFailure == .finishWriting {
        throw FinalizeError.writerFailed("forced finish failure")
      }
      if writer.status == .failed {
        throw FinalizeError.writerFailed(writer.error.map { String(describing: $0) })
      }

      // Codex rc2-audit AUDIO-2: replaceItem is the atomic
      // primitive on macOS — under the hood it uses renameat()
      // with RENAME_SWAP semantics so the existing output is
      // never visibly absent. The v0 path (remove-then-move)
      // had a window where a crash between the two ops would
      // lose the prior good audio.m4a.
      if FileManager.default.fileExists(atPath: output.path) {
        _ = try FileManager.default.replaceItemAt(output, withItemAt: tempOutput)
      } else {
        try FileManager.default.moveItem(at: tempOutput, to: output)
      }
    } catch {
      if writer.status == .writing {
        writer.cancelWriting()
      }
      try? FileManager.default.removeItem(at: tempOutput)
      throw error
    }
  }

  // MARK: - private

  /// Per-source streaming reader that owns its file, optional resampling
  /// converter, scratch read buffer, and EOF state. Each `produce` call
  /// drains the converter (or copies passthrough frames) until either
  /// `target` frames are produced or the source is fully exhausted.
  ///
  /// Replaces the v0 `readMonoChunk` static helper which had a critical
  /// bug: the converter input callback signaled `.endOfStream` after
  /// every single source-buffer pull, so an upsampled input (e.g.
  /// 16kHz → 48kHz) could only ever yield 1x target frames per call,
  /// silently truncating the input to a third of its real length.
  ///
  /// `@unchecked Sendable`: the AVAudioConverter input callback is typed
  /// `@Sendable`, but in practice the converter invokes it synchronously
  /// on the calling thread of `convert(to:error:withInputFrom:)`. Each
  /// StreamReader instance is owned by a single async call to
  /// `finalize(...)` and never escapes — there is no concurrent access
  /// to its mutable state in practice.
  ///
  /// Codex rc2-audit AUDIO-1: the @unchecked Sendable claim relies on
  /// observed converter behavior. A future converter that invokes the
  /// callback concurrently OR a future caller that pulls produce()
  /// from multiple threads against the same instance would race.
  /// A serial DispatchQueue would deadlock the synchronous callback;
  /// instead we use an os_unfair_lock + a re-entry guard counter
  /// that fatalErrors on a real race. This makes the
  /// single-call-site contract enforceable at runtime without
  /// holding a lock during the callback.
  final class StreamReader: @unchecked Sendable {
    let file: AVAudioFile
    let converter: AVAudioConverter?
    let readBuffer: AVAudioPCMBuffer
    private var fileEOF = false
    private var converterEOF = false
    /// Codex rc2-audit AUDIO-1: re-entry guard. produce() bumps
    /// this on entry; if it's already > 0, two threads are
    /// hitting the same reader concurrently — that's a
    /// programming error, not a recoverable runtime condition.
    private var inProduce: Int32 = 0
    private let inProduceLock = NSLock()

    var isExhausted: Bool {
      // Passthrough: no internal converter buffer, so file EOF == done.
      // Converter: must drain the converter's tail too — signalled by
      // `.endOfStream` from the most recent convert call.
      converter == nil ? fileEOF : converterEOF
    }

    private func enterProduce() {
      inProduceLock.lock()
      defer { inProduceLock.unlock() }
      if inProduce > 0 {
        // Concurrent produce() against the same StreamReader is
        // a contract violation. Caller must serialize.
        fatalError(
          "AudioFinalizer.StreamReader: concurrent produce() — single-call-site contract violated")
      }
      inProduce += 1
    }

    private func exitProduce() {
      inProduceLock.lock()
      inProduce -= 1
      inProduceLock.unlock()
    }

    init(file: AVAudioFile, target: AVAudioFormat, chunkFrames: AVAudioFrameCount) throws {
      self.file = file
      let processingFormat = file.processingFormat
      self.readBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: chunkFrames)!
      if processingFormat.isEqual(target) {
        self.converter = nil
      } else {
        guard let conv = AVAudioConverter(from: processingFormat, to: target) else {
          // Don't silently fall through to passthrough — that
          // would memcpy non-Float-mono bytes into a Float-mono
          // buffer and produce garbage with no error.
          throw FinalizeError.converterCreationFailed
        }
        self.converter = conv
      }
    }

    /// Reads one source-format chunk into `readBuffer`. Returns the
    /// frames written, or 0 on real EOF. Throws only on REAL read
    /// errors (corrupt file, truncation), never on EOF.
    ///
    /// AVAudioFile.read(into:) is documented to return frameLength=0
    /// at EOF, but on AAC-decoded m4a inputs it can throw `nilError`
    /// instead. Distinguish via `framePosition` vs `length`: once
    /// we've read every frame the file declares, any further throw is
    /// EOF; before that, a throw is a real failure.
    private func readNextSourceChunk() throws -> AVAudioFrameCount {
      let total = file.length
      if file.framePosition >= total {
        fileEOF = true
        return 0
      }
      readBuffer.frameLength = 0
      do {
        try file.read(into: readBuffer)
      } catch {
        if file.framePosition >= total {
          // Read drained the file; the throw is the AAC decoder's
          // way of signalling EOF. Not a real failure.
          fileEOF = true
          return 0
        }
        throw FinalizeError.readFailed(file.url)
      }
      let frames = readBuffer.frameLength
      if frames == 0 {
        fileEOF = true
      }
      return frames
    }

    func produce(into out: AVAudioPCMBuffer, target: AVAudioFrameCount) throws -> AVAudioFrameCount
    {
      // Codex rc2-audit AUDIO-1: assert single-thread contract.
      enterProduce()
      defer { exitProduce() }
      out.frameLength = 0
      if let converter {
        return try produceConverted(out: out, target: target, converter: converter)
      } else {
        return try producePassthrough(out: out, target: target)
      }
    }

    private func producePassthrough(out: AVAudioPCMBuffer, target: AVAudioFrameCount) throws
      -> AVAudioFrameCount
    {
      if fileEOF { return 0 }
      let frames = try readNextSourceChunk()
      if frames == 0 { return 0 }
      out.frameLength = frames
      if let src = readBuffer.floatChannelData?[0],
        let dst = out.floatChannelData?[0]
      {
        memcpy(dst, src, Int(frames) * MemoryLayout<Float>.size)
      }
      return frames
    }

    private func produceConverted(
      out: AVAudioPCMBuffer,
      target: AVAudioFrameCount,
      converter: AVAudioConverter
    ) throws -> AVAudioFrameCount {
      if converterEOF { return 0 }
      // out.frameCapacity caps the produced target frames.
      // The converter pulls source data via the input callback below
      // as it needs more — we only signal endOfStream when the
      // underlying file is genuinely empty.
      var convertError: NSError?
      let errorBox = ConverterErrorBox()
      let status = converter.convert(to: out, error: &convertError) { _, outStatus in
        if self.fileEOF {
          outStatus.pointee = .endOfStream
          return nil
        }
        let frames: AVAudioFrameCount
        do {
          frames = try self.readNextSourceChunk()
        } catch {
          errorBox.error = error
          outStatus.pointee = .endOfStream
          return nil
        }
        if frames == 0 {
          outStatus.pointee = .endOfStream
          return nil
        }
        outStatus.pointee = .haveData
        return self.readBuffer
      }

      if let hardError = errorBox.error { throw hardError }
      if let err = convertError { throw err }
      switch status {
      case .haveData:
        break  // produced up to target frames; more may follow
      case .endOfStream:
        converterEOF = true
      case .inputRanDry:
        // Shouldn't happen with a synchronous file-pull callback;
        // emit what was produced and let the caller decide.
        break
      case .error:
        throw FinalizeError.readFailed(file.url)
      @unknown default:
        throw FinalizeError.readFailed(file.url)
      }
      return out.frameLength
    }
  }

  /// Reference-typed error sink so the converter input callback can
  /// stash a hard read failure without tripping Swift 6's mutation-
  /// of-captured-var-in-Sendable-closure warning. The callback itself
  /// runs synchronously on the same thread as `convert(...)`, so this
  /// is read-write-safe in practice.
  private final class ConverterErrorBox: @unchecked Sendable {
    var error: Error?
  }
}
