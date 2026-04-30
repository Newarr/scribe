import Darwin
import Foundation

/// Cross-process atomic claim on a session directory. Two processes (e.g. the
/// running app + a relaunched supervisor scan) must not run a
/// `TranscriptionWorker` against the same session simultaneously — the second
/// run would race file writes and could clobber the first one's transcript
/// or metadata.
///
/// The lock file uses POSIX `O_CREAT | O_EXCL` for actual cross-process
/// atomicity (codex pass 2 P0 #6 — Foundation `.withoutOverwriting` doesn't
/// give that guarantee on every filesystem). The claim payload stores
/// `{pid, boot_time, started_at, heartbeat_at}`. A claim is reclaimable if:
/// - the file is missing entirely (no claim), OR
/// - `kill(pid, 0)` returns ESRCH (the claiming process is dead), OR
/// - the recorded `boot_time` differs from the current boot time (the
///   claiming process belonged to a previous boot; PID may have been
///   reused), OR
/// - `heartbeat_at` is older than `staleAfter` seconds (the worker died
///   without releasing the file).
///
/// The worker writes a heartbeat every `heartbeatInterval` so a still-alive
/// long-running worker on the same boot keeps its claim valid.
public enum SessionClaim {
    public struct Token: Sendable, Equatable {
        public let url: URL
        public let pid: Int32
        public let bootTime: Int64
        public let startedAt: Date

        public init(url: URL, pid: Int32, bootTime: Int64, startedAt: Date) {
            self.url = url
            self.pid = pid
            self.bootTime = bootTime
            self.startedAt = startedAt
        }
    }

    public struct Payload: Codable, Equatable {
        public let pid: Int32
        public let bootTime: Int64
        public let startedAt: Date
        public let heartbeatAt: Date
    }

    public enum ClaimError: Error, Equatable {
        case alreadyClaimed
        case writeFailed(Int32)  // errno
    }

    public static let defaultStaleAfter: TimeInterval = 30
    public static let defaultHeartbeatInterval: TimeInterval = 15

    /// Returns the kernel boot time as a Unix timestamp (seconds).
    /// `kern.boottime` is the canonical macOS source for "this boot started
    /// at." The PID identity check (`{pid, boot_time}`) survives PID reuse:
    /// a recycled PID after reboot doesn't match the recorded boot time so
    /// the new worker reclaims.
    public static func currentBootTime() -> Int64 {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib = [CTL_KERN, KERN_BOOTTIME]
        let result = mib.withUnsafeMutableBufferPointer { mibPtr in
            sysctl(mibPtr.baseAddress, 2, &bootTime, &size, nil, 0)
        }
        guard result == 0 else { return 0 }
        return Int64(bootTime.tv_sec)
    }

    /// Attempts to atomically create the claim file. Returns nil if the file
    /// already exists AND the existing claim is still valid; returns a Token
    /// after a fresh claim or a successful reclaim of a stale one.
    public static func acquire(
        at url: URL,
        pid: Int32 = getpid(),
        now: Date = Date(),
        staleAfter: TimeInterval = defaultStaleAfter
    ) -> Token? {
        // Read whatever's there (if anything). If it's stale, remove it and
        // fall through to the create path. The remove-then-create has an
        // intentional race window: two processes may both decide a claim
        // is stale and both call remove. The O_CREAT|O_EXCL on create is
        // what serializes them — only one creates successfully.
        if let existing = readPayload(at: url) {
            if isStale(existing, currentBootTime: currentBootTime(), now: now, staleAfter: staleAfter) {
                try? FileManager.default.removeItem(at: url)
            } else {
                return nil
            }
        }

        let bootTime = currentBootTime()
        let payload = Payload(pid: pid, bootTime: bootTime, startedAt: now, heartbeatAt: now)
        guard atomicCreate(payload, at: url) else { return nil }
        return Token(url: url, pid: pid, bootTime: bootTime, startedAt: now)
    }

    /// Updates the heartbeat timestamp on an existing claim. Worker calls
    /// this every `heartbeatInterval` so peer scans see the claim is alive.
    public static func heartbeat(_ token: Token, now: Date = Date()) {
        guard let existing = readPayload(at: token.url) else { return }
        // Only update if WE own the claim (defensive — protects against
        // someone else's reclaim having raced past us).
        guard existing.pid == token.pid && existing.bootTime == token.bootTime else { return }
        let updated = Payload(pid: existing.pid, bootTime: existing.bootTime, startedAt: existing.startedAt, heartbeatAt: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(updated) else { return }
        try? data.write(to: token.url, options: .atomic)
    }

    /// Removes the claim file. Worker calls this on every exit path.
    public static func release(_ token: Token) {
        // Defensive: only remove if the file still belongs to us. A reclaim
        // already removed it if heartbeat lapsed; deleting somebody else's
        // claim would let two workers run concurrently.
        guard let existing = readPayload(at: token.url) else { return }
        guard existing.pid == token.pid && existing.bootTime == token.bootTime else { return }
        try? FileManager.default.removeItem(at: token.url)
    }

    /// Test-only: surfaced so unit tests can assert the staleness logic
    /// without scheduling a real heartbeat.
    static func isStale(
        _ payload: Payload,
        currentBootTime: Int64,
        now: Date = Date(),
        staleAfter: TimeInterval = defaultStaleAfter
    ) -> Bool {
        // PID-reuse defense: if the recorded boot_time differs from the
        // current boot, the PID slot has been recycled. Always stale.
        if payload.bootTime != currentBootTime { return true }
        // Process-death defense: if the recorded PID has no live process,
        // the claim is stale. kill(pid, 0) returns -1/ESRCH for missing.
        if kill(payload.pid, 0) != 0 && errno == ESRCH { return true }
        // Heartbeat-death defense: process is alive but the worker thread
        // hung. Reclaim if the last heartbeat is older than staleAfter.
        if now.timeIntervalSince(payload.heartbeatAt) > staleAfter { return true }
        return false
    }

    // MARK: - private

    private static func readPayload(at url: URL) -> Payload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Payload.self, from: data)
    }

    private static func atomicCreate(_ payload: Payload, at url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return false }

        // O_CREAT | O_EXCL gives cross-process atomicity. If another process
        // creates the file between our existence-check and this open, the
        // open returns -1 with errno=EEXIST; we lose the race cleanly.
        let path = url.path
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        if fd == -1 {
            return false
        }
        defer { close(fd) }

        let written = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int in
            guard let base = bytes.baseAddress else { return -1 }
            return Darwin.write(fd, base, data.count)
        }
        if written != data.count {
            // Couldn't write payload; clean up the empty/partial file so a
            // future caller doesn't read garbage.
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }
}
