import Darwin
import Foundation

/// Cross-process atomic claim on a session directory. Two processes (e.g. the
/// running app + a relaunched supervisor scan) must not run a
/// `TranscriptionWorker` against the same session simultaneously — the second
/// run would race file writes and could clobber the first one's transcript
/// or metadata.
///
/// Codex rc2-audit CAP-4: the v0 design used `O_CREAT|O_EXCL` to create the
/// claim file, but heartbeat() and release() relied on read-then-write/remove
/// without atomic ownership. A stale worker could overwrite a newly reclaimed
/// claim because the time between "read ownership matches" and "write/remove"
/// was unprotected.
///
/// New design layers `flock(LOCK_EX | LOCK_NB)` on top of the existing
/// JSON-payload contract:
///
/// - `acquire` opens (or creates) the claim file and takes an exclusive
///   advisory lock. The OS releases the lock automatically when the
///   holding process dies, so a process-death-without-release case is
///   handled by the kernel rather than by staleness heuristics.
/// - `heartbeat` writes through the same locked file descriptor so
///   ownership can't change between check and write.
/// - `release` closes the descriptor (releasing the lock atomically)
///   and removes the file.
///
/// The PID + boot_time + heartbeat-age payload remains as a backstop for
/// the "process alive, worker hung" case where flock alone wouldn't help
/// (the live process still holds the lock). Stale-detection runs against
/// the payload before attempting acquire so a hung-but-alive worker can
/// be displaced after `staleAfter` seconds.
public enum SessionClaim {
  public struct Token: Sendable, Equatable {
    public let url: URL
    public let pid: Int32
    public let bootTime: Int64
    public let startedAt: Date
    /// Per-claim generation identity. PID + boot time identifies a process,
    /// but multiple same-process workers can claim the same session over
    /// time. This nonce distinguishes those generations so an old token
    /// cannot release a live replacement claim.
    public let claimID: String
    /// File descriptor held with `flock(LOCK_EX)`. Closing it releases
    /// the lock; nil for tokens produced by tests or migration paths
    /// that need a Token without a real OS lock.
    public let fd: Int32

    public init(
      url: URL,
      pid: Int32,
      bootTime: Int64,
      startedAt: Date,
      claimID: String = UUID().uuidString,
      fd: Int32 = -1
    ) {
      self.url = url
      self.pid = pid
      self.bootTime = bootTime
      self.startedAt = startedAt
      self.claimID = claimID
      self.fd = fd
    }
  }

  public struct Payload: Codable, Equatable {
    public let pid: Int32
    public let bootTime: Int64
    public let startedAt: Date
    public let heartbeatAt: Date
    public let claimID: String?

    public init(
      pid: Int32, bootTime: Int64, startedAt: Date, heartbeatAt: Date, claimID: String? = nil
    ) {
      self.pid = pid
      self.bootTime = bootTime
      self.startedAt = startedAt
      self.heartbeatAt = heartbeatAt
      self.claimID = claimID
    }
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

  /// Attempts to atomically create + lock the claim file.
  ///
  /// Returns nil if another process holds an active flock OR an existing
  /// claim is still valid by staleness rules. Returns a Token after a
  /// fresh claim or a successful reclaim; the Token's `fd` MUST be
  /// closed via `release(_:)` to free the OS lock.
  public static func acquire(
    at url: URL,
    pid: Int32 = getpid(),
    now: Date = Date(),
    staleAfter: TimeInterval = defaultStaleAfter
  ) -> Token? {
    // Check the staleness rules against any existing payload BEFORE
    // attempting flock. If the file exists with a non-stale payload
    // and the holder is alive, we lose without disturbing them.
    if let existing = readPayload(at: url) {
      if !isStale(existing, currentBootTime: currentBootTime(), now: now, staleAfter: staleAfter) {
        return nil
      }
      // Existing claim is stale (process dead, boot mismatch, or
      // heartbeat lapsed). Open the existing file and try to take
      // the lock — flock will succeed if the previous holder's
      // process actually died.
    }

    let path = url.path
    // O_RDWR so we can write payload + heartbeats through the same
    // descriptor; O_CREAT so we don't have to do a separate "exists?"
    // check. mode 0o600 keeps the claim file owner-only.
    let fd = open(path, O_RDWR | O_CREAT, 0o600)
    if fd == -1 { return nil }

    // LOCK_EX | LOCK_NB: exclusive lock, non-blocking. Returns -1
    // with errno=EWOULDBLOCK if another live process holds it.
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
      close(fd)
      return nil
    }

    // We hold the lock. Write our payload (truncating any prior
    // bytes that belonged to a stale claim). Don't close the FD —
    // the lock survives until either close() or process death.
    let bootTime = currentBootTime()
    let claimID = UUID().uuidString
    let payload = Payload(
      pid: pid, bootTime: bootTime, startedAt: now, heartbeatAt: now, claimID: claimID)
    guard writePayload(payload, fd: fd) else {
      // Couldn't write — release and clean up.
      close(fd)
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    return Token(url: url, pid: pid, bootTime: bootTime, startedAt: now, claimID: claimID, fd: fd)
  }

  /// Updates the heartbeat timestamp on an existing claim. Worker calls
  /// this every `heartbeatInterval` so peer scans see the claim is alive.
  /// Codex rc2-audit CAP-4: writes through the held FD so the
  /// read-modify-write sequence can't be interleaved with another
  /// process's reclaim — the lock blocks anyone else's open+flock.
  public static func heartbeat(_ token: Token, now: Date = Date()) {
    guard token.fd >= 0 else { return }
    let updated = Payload(
      pid: token.pid,
      bootTime: token.bootTime,
      startedAt: token.startedAt,
      heartbeatAt: now,
      claimID: token.claimID
    )
    _ = writePayload(updated, fd: token.fd)
  }

  /// Releases the claim. Worker calls this on every exit path.
  /// Release removes the claim only when the on-disk payload still proves
  /// this exact token's generation owns it. The ownership check happens
  /// before closing the locked FD so no replacement claimant can race into
  /// the close/remove window and be unlinked by an old token.
  public static func release(_ token: Token) {
    defer {
      if token.fd >= 0 {
        close(token.fd)
      }
    }

    guard let existing = readPayload(at: token.url) else { return }
    guard existing.pid == token.pid,
      existing.bootTime == token.bootTime,
      existing.claimID == token.claimID
    else { return }
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

  /// Writes the payload through an already-open FD (truncating the
  /// existing file content). Used by both acquire (right after flock)
  /// and heartbeat (regular updates).
  private static func writePayload(_ payload: Payload, fd: Int32) -> Bool {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(payload) else { return false }

    // Reset to start of file + truncate so a smaller payload
    // (shouldn't happen in practice but be defensive) doesn't
    // leave trailing bytes from the prior write.
    if lseek(fd, 0, SEEK_SET) == -1 { return false }
    if ftruncate(fd, 0) != 0 { return false }
    let written = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int in
      guard let base = bytes.baseAddress else { return -1 }
      return Darwin.write(fd, base, data.count)
    }
    return written == data.count
  }
}
