import Foundation
import CoreMedia

/// Per-buffer PTS log entry. The streaming finalize pipeline (Phase ε) and
/// the AEC pre-pass (Phase ξ) both need per-buffer timing to detect gaps and
/// align mic / system streams to a coherent timeline. AEC3 specifically can't
/// recover from dropped buffers without per-chunk PTS, which is why this
/// landed in Phase β rather than later (codex pass 2 P1 #17).
struct PTSLogEntry: Codable, Equatable, Sendable {
    let stream: String
    let ptsSeconds: Double
    let sampleCount: Int
    let sampleRate: Int

    init(stream: String, ptsSeconds: Double, sampleCount: Int, sampleRate: Int) {
        self.stream = stream
        self.ptsSeconds = ptsSeconds
        self.sampleCount = sampleCount
        self.sampleRate = sampleRate
    }
}

public final class PTSCollector: @unchecked Sendable {
    public enum StreamID: String, Sendable { case mic, system }

    private let lock = NSLock()
    private var micFirstPTS: Double?
    private var sysFirstPTS: Double?
    private var micRate: Int = 0
    private var sysRate: Int = 0
    private var micChannels: Int = 0
    private var sysChannels: Int = 0
    private var micFrames: Int64 = 0
    private var sysFrames: Int64 = 0

    /// Optional per-buffer log URL. When set, every `observe()` appends one
    /// JSONL line. nil disables the log entirely (used by tests that only
    /// care about the snapshot summary).
    private let streamingLogURL: URL?
    private let logQueue = DispatchQueue(label: "pts.collector.log", qos: .utility)
    private var logHandle: FileHandle?
    private var logOpenAttempted = false
    private var logTerminallyClosed = false

    init(streamingLogURL: URL? = nil) {
        self.streamingLogURL = streamingLogURL
    }

    deinit {
        try? logHandle?.close()
    }

    public func observe(_ stream: StreamID, buffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(buffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }
        let asbd = asbdPointer.pointee
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
        let frames = Int64(CMSampleBufferGetNumSamples(buffer))
        let rate = Int(asbd.mSampleRate)
        let channels = Int(asbd.mChannelsPerFrame)

        lock.lock()
        switch stream {
        case .mic:
            if micFirstPTS == nil { micFirstPTS = pts; micRate = rate; micChannels = channels }
            micFrames += frames
        case .system:
            if sysFirstPTS == nil { sysFirstPTS = pts; sysRate = rate; sysChannels = channels }
            sysFrames += frames
        }
        lock.unlock()

        appendLogEntry(PTSLogEntry(
            stream: stream.rawValue,
            ptsSeconds: pts,
            sampleCount: Int(frames),
            sampleRate: rate
        ))
    }

    public func snapshot() -> PTSMetadata {
        lock.lock(); defer { lock.unlock() }
        return PTSMetadata(
            mic: .init(
                firstPTSSeconds: micFirstPTS ?? 0,
                sampleRate: micRate,
                channelCount: micChannels,
                frameCount: micFrames
            ),
            system: .init(
                firstPTSSeconds: sysFirstPTS ?? 0,
                sampleRate: sysRate,
                channelCount: sysChannels,
                frameCount: sysFrames
            )
        )
    }

    func writeSidecar(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot())
        try data.write(to: url, options: .atomic)
    }

    /// Blocks until every queued log entry has hit disk and closes the
    /// underlying file handle. This is the terminal stop/finalize flush; it
    /// is safe to call repeatedly after capture has stopped. Mid-session
    /// readers use `synchronizeLogForRead()` instead so observing the log
    /// cannot disable future writes.
    func flushLog() {
        logQueue.sync {
            self.synchronizeAndCloseLog(markTerminal: true)
        }
    }

    /// Returns the entries written so far. Walks the on-disk log to keep the
    /// API independent of whatever in-memory buffering grows later.
    /// Tolerates a malformed trailing line (process kill mid-write left a
    /// partial JSONL line) — codex Phase β review P1.6: the recovery path
    /// must not throw on the survivable case.
    func loggedEntries() throws -> [PTSLogEntry] {
        guard let url = streamingLogURL else { return [] }
        synchronizeLogForRead()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var entries: [PTSLogEntry] = []
        entries.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            do {
                entries.append(try decoder.decode(PTSLogEntry.self, from: Data(line.utf8)))
            } catch {
                // Tolerate ONLY a malformed trailing line (the kill-during-
                // write case). A malformed line in the middle is real
                // corruption and should still throw.
                if index == lines.count - 1 {
                    Log.capture.info("PTS log: discarding malformed trailing line (likely crash mid-write)")
                    break
                }
                throw error
            }
        }
        return entries
    }

    // MARK: - private

    private func appendLogEntry(_ entry: PTSLogEntry) {
        guard let url = streamingLogURL else { return }
        // Encode on the caller (cheap, no I/O), dispatch the write so SCK
        // output queues don't block on disk. Errors log + drop — losing a
        // log line is preferable to deadlocking capture.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entry) else { return }
        var encodedLine = data
        encodedLine.append(0x0A) // '\n'
        let line = encodedLine

        logQueue.async { [self] in
            guard self.logTerminallyClosed == false else { return }
            self.openLogIfNeeded(at: url)
            guard let handle = self.logHandle else { return }
            do {
                try handle.write(contentsOf: line)
            } catch {
                Log.capture.error("PTS log write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func synchronizeLogForRead() {
        logQueue.sync {
            do {
                try self.logHandle?.synchronize()
            } catch {
                Log.capture.error("PTS log sync failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func synchronizeAndCloseLog(markTerminal: Bool) {
        do {
            try self.logHandle?.synchronize()
            try self.logHandle?.close()
        } catch {
            Log.capture.error("PTS log close failed: \(String(describing: error), privacy: .public)")
        }
        self.logHandle = nil
        if markTerminal {
            self.logTerminallyClosed = true
        }
    }

    private func openLogIfNeeded(at url: URL) {
        if logTerminallyClosed || logHandle != nil { return }
        if logOpenAttempted == false { logOpenAttempted = true }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) == false {
            fm.createFile(atPath: url.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            logHandle = handle
        } catch {
            Log.capture.error("PTS log open failed: \(String(describing: error), privacy: .public)")
        }
    }
}
