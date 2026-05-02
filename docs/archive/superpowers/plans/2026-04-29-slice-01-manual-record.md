# Slice 1 — Manual Record Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Click `Record Now` in the menu bar → microphone + system audio captured as two separate `.m4a` files in `~/Documents/Transcriber/<session>/` with `pts.json` sidecar. Click `Stop` → atomic rename, files final. No transcription yet.

**Architecture:** A `CaptureSession` actor owns the full lifecycle. Two `AudioCaptureSource` instances (one for mic, one for system) feed `CMSampleBuffer`s into two `AudioFileWriter` instances backed by `AVAssetWriter`. `PTSCollector` records the first `CMSampleBuffer.presentationTimeStamp` and frame count per stream into a sidecar JSON. SCK and AVFoundation are accessed only through narrow protocols so tests use fakes.

**Tech Stack:** ScreenCaptureKit (`SCStream`, `SCContentFilter`, `SCStreamConfiguration`), AVFoundation (`AVAssetWriter`, `AVAssetWriterInput`), Foundation, AppKit (status item).

**Spec sections covered:** Capture (lines 168-179), folder structure (lines 213-225), permissions (lines 311-336 partial — mic + screen only).

---

## File Structure

After this slice:

```
Sources/TranscriberCore/
  Session/
    SessionID.swift                # Pure-data types
    SessionDirectory.swift         # Output folder creation + atomic rename
    SessionStatus.swift            # Enum: idle/starting/recording/stopping/finalized/failed
    PTSMetadata.swift              # Codable sidecar struct
    PTSCollector.swift             # Aggregates first PTS + frame count from CMSampleBuffer stream
  Capture/
    AudioCaptureSource.swift       # Protocol abstraction over SCK + AVCapture
    AudioFileWriter.swift          # Wraps AVAssetWriter for .m4a output
    CaptureSession.swift           # Actor: wires sources -> writers -> PTSCollector
    SCKAudioCaptureSource.swift    # Production SCK implementation
  Permissions/
    PermissionsService.swift       # Microphone + screen recording status

Tests/TranscriberCoreTests/
  Session/
    SessionIDTests.swift
    SessionDirectoryTests.swift
    PTSMetadataTests.swift
    PTSCollectorTests.swift
  Capture/
    AudioFileWriterTests.swift
    CaptureSessionTests.swift
    Fakes/
      FakeAudioCaptureSource.swift
      SyntheticSampleBuffer.swift  # Test helper: synthesized CMSampleBuffer

TranscriberApp/TranscriberApp/
  AppDelegate.swift                # MODIFY: wire menu items to CaptureSession
  RecordingMenu.swift              # NEW: builds menu states (idle/recording/stopping)
```

---

## Task 1: SessionID and folder naming

**Files:**
- Create: `Sources/TranscriberCore/Session/SessionID.swift`
- Create: `Tests/TranscriberCoreTests/Session/SessionIDTests.swift`

`SessionID` carries the canonical session identifier (`YYYY-MM-DD-HHMM`) and produces a folder slug. The slug is what becomes the directory name in `~/Documents/Transcriber/`. Stable, sortable, TZ-aware (Europe/Warsaw default; configurable for tests).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TranscriberCore

final class SessionIDTests: XCTestCase {
    func testFromDateInWarsawTimezone() {
        // 2026-04-29 14:30:00 UTC = 16:30 in CEST (Warsaw)
        let utc = Date(timeIntervalSince1970: 1777819800)
        let id = SessionID(from: utc, timeZone: TimeZone(identifier: "Europe/Warsaw")!)
        XCTAssertEqual(id.slug, "2026-04-29-1630")
    }

    func testFromDateInUTC() {
        let utc = Date(timeIntervalSince1970: 1777819800)
        let id = SessionID(from: utc, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(id.slug, "2026-04-29-1430")
    }

    func testCollisionSuffix() {
        let utc = Date(timeIntervalSince1970: 1777819800)
        let id = SessionID(from: utc, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(id.slugWithSuffix(2), "2026-04-29-1430-2")
        XCTAssertEqual(id.slugWithSuffix(3), "2026-04-29-1430-3")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionIDTests`
Expected: FAIL — `SessionID` undefined.

- [ ] **Step 3: Write implementation**

```swift
import Foundation

public struct SessionID: Equatable, Hashable, Sendable {
    public let slug: String

    public init(from date: Date, timeZone: TimeZone = TimeZone(identifier: "Europe/Warsaw")!) {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        self.slug = formatter.string(from: date)
    }

    public func slugWithSuffix(_ n: Int) -> String {
        precondition(n >= 2, "suffix only for collisions, n>=2")
        return "\(slug)-\(n)"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionIDTests`
Expected: PASS, all three tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriberCore/Session/SessionID.swift Tests/TranscriberCoreTests/Session/SessionIDTests.swift
git commit -m "session: SessionID with TZ-aware slug + collision suffixes"
```

---

## Task 2: SessionDirectory

**Files:**
- Create: `Sources/TranscriberCore/Session/SessionDirectory.swift`
- Create: `Tests/TranscriberCoreTests/Session/SessionDirectoryTests.swift`

`SessionDirectory` owns: creating the session folder, returning `.m4a.partial` paths, atomic rename to `.m4a`, owner-only permissions (`0700` per spec).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TranscriberCore

final class SessionDirectoryTests: XCTestCase {
    var tmpRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    func testCreateMakesOwnerOnlyFolder() throws {
        let id = SessionID(from: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
        let dir = try SessionDirectory.create(under: tmpRoot, id: id)

        XCTAssertEqual(dir.url.lastPathComponent, "1970-01-01-0000")

        let attrs = try FileManager.default.attributesOfItem(atPath: dir.url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o700)
    }

    func testCollisionResolvedBySuffix() throws {
        let id = SessionID(from: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
        let first = try SessionDirectory.create(under: tmpRoot, id: id)
        let second = try SessionDirectory.create(under: tmpRoot, id: id)
        XCTAssertEqual(first.url.lastPathComponent, "1970-01-01-0000")
        XCTAssertEqual(second.url.lastPathComponent, "1970-01-01-0000-2")
    }

    func testPartialPaths() {
        let url = tmpRoot.appendingPathComponent("session-x")
        let dir = SessionDirectory(url: url)
        XCTAssertEqual(dir.micPartial, url.appendingPathComponent("mic.m4a.partial"))
        XCTAssertEqual(dir.systemPartial, url.appendingPathComponent("system.m4a.partial"))
        XCTAssertEqual(dir.micFinal, url.appendingPathComponent("mic.m4a"))
        XCTAssertEqual(dir.systemFinal, url.appendingPathComponent("system.m4a"))
        XCTAssertEqual(dir.ptsSidecar, url.appendingPathComponent("pts.json"))
    }

    func testAtomicRenameMicAndSystem() throws {
        let id = SessionID(from: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
        let dir = try SessionDirectory.create(under: tmpRoot, id: id)
        try Data("mic-data".utf8).write(to: dir.micPartial)
        try Data("system-data".utf8).write(to: dir.systemPartial)

        try dir.finalize()

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.micPartial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.systemPartial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.micFinal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.systemFinal.path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionDirectoryTests`
Expected: FAIL — `SessionDirectory` undefined.

- [ ] **Step 3: Write implementation**

```swift
import Foundation

public struct SessionDirectory: Equatable, Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public var micPartial: URL    { url.appendingPathComponent("mic.m4a.partial") }
    public var systemPartial: URL { url.appendingPathComponent("system.m4a.partial") }
    public var micFinal: URL      { url.appendingPathComponent("mic.m4a") }
    public var systemFinal: URL   { url.appendingPathComponent("system.m4a") }
    public var ptsSidecar: URL    { url.appendingPathComponent("pts.json") }

    public static func create(under root: URL, id: SessionID) throws -> SessionDirectory {
        let fm = FileManager.default
        var candidate = root.appendingPathComponent(id.slug, isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent(id.slugWithSuffix(suffix), isDirectory: true)
            suffix += 1
        }
        try fm.createDirectory(
            at: candidate,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        return SessionDirectory(url: candidate)
    }

    public func finalize() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: micPartial.path) {
            try fm.moveItem(at: micPartial, to: micFinal)
        }
        if fm.fileExists(atPath: systemPartial.path) {
            try fm.moveItem(at: systemPartial, to: systemFinal)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionDirectoryTests`
Expected: PASS, all four tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriberCore/Session/SessionDirectory.swift Tests/TranscriberCoreTests/Session/SessionDirectoryTests.swift
git commit -m "session: SessionDirectory with atomic finalize and 0700 perms"
```

---

## Task 3: SessionStatus enum

**Files:**
- Create: `Sources/TranscriberCore/Session/SessionStatus.swift`

This is a small enum but central — every UI state and lifecycle log keys off it.

- [ ] **Step 1: Write the implementation directly (enum only, no behavior to TDD)**

```swift
public enum SessionStatus: String, Codable, Sendable, Equatable {
    case idle
    case starting     // permission check, SCK content list
    case recording
    case stopping     // user hit stop, awaiting writer flush
    case finalized    // .m4a files renamed, ready for next slice (transcription)
    case failed       // any error during the above
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/TranscriberCore/Session/SessionStatus.swift
git commit -m "session: SessionStatus enum"
```

---

## Task 4: PTSMetadata sidecar

**Files:**
- Create: `Sources/TranscriberCore/Session/PTSMetadata.swift`
- Create: `Tests/TranscriberCoreTests/Session/PTSMetadataTests.swift`

The sidecar carries everything Slice 4 (AEC) needs to align mic and system frames at the sample level. Both streams share a single SCK clock, so we record the first PTS of each, the sample rate, channel count, and total frame count.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TranscriberCore

final class PTSMetadataTests: XCTestCase {
    func testRoundTripJSON() throws {
        let original = PTSMetadata(
            mic: PTSMetadata.Stream(
                firstPTSSeconds: 12345.678,
                sampleRate: 48000,
                channelCount: 1,
                frameCount: 480000
            ),
            system: PTSMetadata.Stream(
                firstPTSSeconds: 12345.679,
                sampleRate: 48000,
                channelCount: 1,
                frameCount: 480000
            )
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PTSMetadata.self, from: encoded)
        XCTAssertEqual(original, decoded)
    }

    func testFrameAlignmentDeltaInSamples() {
        let m = PTSMetadata(
            mic: .init(firstPTSSeconds: 0.000, sampleRate: 48000, channelCount: 1, frameCount: 0),
            system: .init(firstPTSSeconds: 0.010, sampleRate: 48000, channelCount: 1, frameCount: 0)
        )
        // 10ms gap at 48kHz = 480 samples
        XCTAssertEqual(m.systemLeadInMicSamples, 480)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PTSMetadataTests`
Expected: FAIL — `PTSMetadata` undefined.

- [ ] **Step 3: Write implementation**

```swift
import Foundation

public struct PTSMetadata: Codable, Equatable, Sendable {
    public struct Stream: Codable, Equatable, Sendable {
        public let firstPTSSeconds: Double
        public let sampleRate: Int
        public let channelCount: Int
        public let frameCount: Int64

        public init(firstPTSSeconds: Double, sampleRate: Int, channelCount: Int, frameCount: Int64) {
            self.firstPTSSeconds = firstPTSSeconds
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.frameCount = frameCount
        }
    }

    public let mic: Stream
    public let system: Stream

    public init(mic: Stream, system: Stream) {
        self.mic = mic
        self.system = system
    }

    /// Sample offset of the system stream relative to mic at mic's sample rate.
    /// Positive => system started AFTER mic; negative => system started before mic.
    public var systemLeadInMicSamples: Int64 {
        let deltaSec = system.firstPTSSeconds - mic.firstPTSSeconds
        return Int64((deltaSec * Double(mic.sampleRate)).rounded())
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PTSMetadataTests`
Expected: PASS, both tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriberCore/Session/PTSMetadata.swift Tests/TranscriberCoreTests/Session/PTSMetadataTests.swift
git commit -m "session: PTSMetadata sidecar with sample-level alignment helper"
```

---

## Task 5: PTSCollector

**Files:**
- Create: `Sources/TranscriberCore/Session/PTSCollector.swift`
- Create: `Tests/TranscriberCoreTests/Session/PTSCollectorTests.swift`
- Create: `Tests/TranscriberCoreTests/Capture/Fakes/SyntheticSampleBuffer.swift`

`PTSCollector` is fed `CMSampleBuffer` instances (one stream at a time) and accumulates per-stream `firstPTS`, frame count, and rolling sample-rate / channel-count assertions. It writes the JSON sidecar on `finalize()`.

- [ ] **Step 1: Create the synthetic CMSampleBuffer test helper**

`Tests/TranscriberCoreTests/Capture/Fakes/SyntheticSampleBuffer.swift`:

```swift
import CoreMedia
import AVFoundation

enum SyntheticSampleBuffer {
    /// Build a silent CMSampleBuffer with the given timing and a stub audio format description.
    static func make(
        ptsSeconds: Double,
        sampleRate: Int,
        channelCount: Int,
        frameCount: Int
    ) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float32>.size * channelCount),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float32>.size * channelCount),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDesc: CMFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )

        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: CMTime(seconds: ptsSeconds, preferredTimescale: 48000),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: [timing],
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer!
    }
}
```

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
import CoreMedia
@testable import TranscriberCore

final class PTSCollectorTests: XCTestCase {
    func testAccumulatesFirstPTSAndFrameCount() {
        let collector = PTSCollector()

        let buf1 = SyntheticSampleBuffer.make(
            ptsSeconds: 100.0, sampleRate: 48000, channelCount: 1, frameCount: 480
        )
        let buf2 = SyntheticSampleBuffer.make(
            ptsSeconds: 100.01, sampleRate: 48000, channelCount: 1, frameCount: 480
        )

        collector.observe(.mic, buffer: buf1)
        collector.observe(.mic, buffer: buf2)

        let snapshot = collector.snapshot()
        XCTAssertEqual(snapshot.mic.firstPTSSeconds, 100.0, accuracy: 1e-6)
        XCTAssertEqual(snapshot.mic.sampleRate, 48000)
        XCTAssertEqual(snapshot.mic.channelCount, 1)
        XCTAssertEqual(snapshot.mic.frameCount, 960)
    }

    func testAcceptsBothStreamsIndependently() {
        let collector = PTSCollector()
        let micBuf = SyntheticSampleBuffer.make(ptsSeconds: 50.0, sampleRate: 48000, channelCount: 1, frameCount: 1000)
        let sysBuf = SyntheticSampleBuffer.make(ptsSeconds: 50.005, sampleRate: 48000, channelCount: 1, frameCount: 2000)
        collector.observe(.mic, buffer: micBuf)
        collector.observe(.system, buffer: sysBuf)

        let snap = collector.snapshot()
        XCTAssertEqual(snap.mic.frameCount, 1000)
        XCTAssertEqual(snap.system.frameCount, 2000)
        XCTAssertEqual(snap.systemLeadInMicSamples, 240) // 5ms at 48kHz
    }

    func testWritesSidecarJSON() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let collector = PTSCollector()
        collector.observe(.mic, buffer: SyntheticSampleBuffer.make(
            ptsSeconds: 0, sampleRate: 48000, channelCount: 1, frameCount: 100
        ))
        collector.observe(.system, buffer: SyntheticSampleBuffer.make(
            ptsSeconds: 0.001, sampleRate: 48000, channelCount: 1, frameCount: 200
        ))

        try collector.writeSidecar(to: tmp)
        let data = try Data(contentsOf: tmp)
        let decoded = try JSONDecoder().decode(PTSMetadata.self, from: data)
        XCTAssertEqual(decoded.mic.frameCount, 100)
        XCTAssertEqual(decoded.system.frameCount, 200)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter PTSCollectorTests`
Expected: FAIL — `PTSCollector` undefined.

- [ ] **Step 4: Write implementation**

```swift
import Foundation
import CoreMedia

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

    public init() {}

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

        lock.lock(); defer { lock.unlock() }
        switch stream {
        case .mic:
            if micFirstPTS == nil { micFirstPTS = pts; micRate = rate; micChannels = channels }
            micFrames += frames
        case .system:
            if sysFirstPTS == nil { sysFirstPTS = pts; sysRate = rate; sysChannels = channels }
            sysFrames += frames
        }
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

    public func writeSidecar(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot())
        try data.write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter PTSCollectorTests`
Expected: PASS, all three tests green.

- [ ] **Step 6: Commit**

```bash
git add Sources/TranscriberCore/Session/PTSCollector.swift \
        Tests/TranscriberCoreTests/Session/PTSCollectorTests.swift \
        Tests/TranscriberCoreTests/Capture/Fakes/SyntheticSampleBuffer.swift
git commit -m "session: PTSCollector aggregates per-stream timing into sidecar JSON"
```

---

## Task 6: AudioFileWriter

**Files:**
- Create: `Sources/TranscriberCore/Capture/AudioFileWriter.swift`
- Create: `Tests/TranscriberCoreTests/Capture/AudioFileWriterTests.swift`

Wraps `AVAssetWriter` with one input. Accepts `CMSampleBuffer`, writes AAC into `.m4a.partial`, supports `finalize()`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import AVFoundation
@testable import TranscriberCore

final class AudioFileWriterTests: XCTestCase {
    var tmpURL: URL!

    override func setUpWithError() throws {
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a.partial")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpURL)
    }

    func testWriteAndFinalizeProducesNonEmptyFile() async throws {
        let writer = try AudioFileWriter(url: tmpURL, sampleRate: 48000, channelCount: 1)
        try writer.start()

        for i in 0..<10 {
            let buf = SyntheticSampleBuffer.make(
                ptsSeconds: Double(i) * 0.01,
                sampleRate: 48000, channelCount: 1, frameCount: 480
            )
            try writer.append(buf)
        }
        try await writer.finalize()

        let attrs = try FileManager.default.attributesOfItem(atPath: tmpURL.path)
        let size = (attrs[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "writer should produce non-empty file")
    }

    func testAppendBeforeStartThrows() {
        let writer = try? AudioFileWriter(url: tmpURL, sampleRate: 48000, channelCount: 1)
        let buf = SyntheticSampleBuffer.make(ptsSeconds: 0, sampleRate: 48000, channelCount: 1, frameCount: 480)
        XCTAssertThrowsError(try writer?.append(buf))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AudioFileWriterTests`
Expected: FAIL — type undefined.

- [ ] **Step 3: Write implementation**

```swift
import AVFoundation

public final class AudioFileWriter: @unchecked Sendable {
    public enum WriterError: Error {
        case notStarted
        case alreadyStarted
        case writerFailed(Error?)
    }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "audio.writer", qos: .userInitiated)
    private var started = false

    public init(url: URL, sampleRate: Int, channelCount: Int) throws {
        try? FileManager.default.removeItem(at: url) // overwrite stale partial
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: channelCount,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: 64_000  // mono voice; bump if stereo
        ]
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }

    public func start() throws {
        guard !started else { throw WriterError.alreadyStarted }
        guard writer.startWriting() else { throw WriterError.writerFailed(writer.error) }
        writer.startSession(atSourceTime: .zero)
        started = true
    }

    public func append(_ buffer: CMSampleBuffer) throws {
        guard started else { throw WriterError.notStarted }
        guard input.isReadyForMoreMediaData else { return } // drop on backpressure; capture will retry
        if !input.append(buffer) {
            throw WriterError.writerFailed(writer.error)
        }
    }

    public func finalize() async throws {
        guard started else { throw WriterError.notStarted }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed { throw WriterError.writerFailed(writer.error) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AudioFileWriterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriberCore/Capture/AudioFileWriter.swift Tests/TranscriberCoreTests/Capture/AudioFileWriterTests.swift
git commit -m "capture: AudioFileWriter wraps AVAssetWriter with .m4a partial output"
```

---

## Task 7: AudioCaptureSource protocol + fake

**Files:**
- Create: `Sources/TranscriberCore/Capture/AudioCaptureSource.swift`
- Create: `Tests/TranscriberCoreTests/Capture/Fakes/FakeAudioCaptureSource.swift`

Protocol defines what `CaptureSession` consumes. Production uses `SCKAudioCaptureSource` (next task); tests use the fake.

- [ ] **Step 1: Write protocol**

```swift
import CoreMedia
import Foundation

public protocol AudioCaptureSource: AnyObject, Sendable {
    /// Called by CaptureSession before start to wire the buffer handler.
    func setHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void)
    func start() async throws
    func stop() async
}
```

- [ ] **Step 2: Write fake**

```swift
import Foundation
import CoreMedia
@testable import TranscriberCore

final class FakeAudioCaptureSource: AudioCaptureSource, @unchecked Sendable {
    private var handler: ((CMSampleBuffer) -> Void)?
    private(set) var started = false
    private(set) var stopped = false

    func setHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.handler = handler
    }
    func start() async throws { started = true }
    func stop() async { stopped = true }

    /// Test-only: emit a buffer as if SCK delivered it.
    func emit(_ buffer: CMSampleBuffer) { handler?(buffer) }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/TranscriberCore/Capture/AudioCaptureSource.swift Tests/TranscriberCoreTests/Capture/Fakes/FakeAudioCaptureSource.swift
git commit -m "capture: AudioCaptureSource protocol + fake for tests"
```

---

## Task 8: CaptureSession

**Files:**
- Create: `Sources/TranscriberCore/Capture/CaptureSession.swift`
- Create: `Tests/TranscriberCoreTests/Capture/CaptureSessionTests.swift`

Actor that wires mic + system sources to mic + system writers, plus a single `PTSCollector`. Owns lifecycle: `start` → SCK starts → buffers flow → `stop` → finalize writers, write sidecar, atomic rename via `SessionDirectory.finalize()`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import AVFoundation
@testable import TranscriberCore

final class CaptureSessionTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFullLifecycleProducesAllArtifacts() async throws {
        let mic = FakeAudioCaptureSource()
        let sys = FakeAudioCaptureSource()
        let id = SessionID(from: Date(timeIntervalSince1970: 1_000_000), timeZone: TimeZone(identifier: "UTC")!)
        let dir = try SessionDirectory.create(under: root, id: id)

        let session = try CaptureSession(directory: dir, mic: mic, system: sys, sampleRate: 48000, channelCount: 1)
        try await session.start()

        for i in 0..<5 {
            let pts = Double(i) * 0.01
            mic.emit(SyntheticSampleBuffer.make(ptsSeconds: pts, sampleRate: 48000, channelCount: 1, frameCount: 480))
            sys.emit(SyntheticSampleBuffer.make(ptsSeconds: pts + 0.001, sampleRate: 48000, channelCount: 1, frameCount: 480))
        }

        try await session.stop()

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dir.micFinal.path), "mic.m4a missing")
        XCTAssertTrue(fm.fileExists(atPath: dir.systemFinal.path), "system.m4a missing")
        XCTAssertTrue(fm.fileExists(atPath: dir.ptsSidecar.path), "pts.json missing")

        let pts = try JSONDecoder().decode(PTSMetadata.self, from: try Data(contentsOf: dir.ptsSidecar))
        XCTAssertEqual(pts.mic.frameCount, 5 * 480)
        XCTAssertEqual(pts.system.frameCount, 5 * 480)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CaptureSessionTests`
Expected: FAIL — `CaptureSession` undefined.

- [ ] **Step 3: Write implementation**

```swift
import AVFoundation
import Foundation

public actor CaptureSession {
    public private(set) var status: SessionStatus = .idle

    private let directory: SessionDirectory
    private let mic: AudioCaptureSource
    private let system: AudioCaptureSource
    private let micWriter: AudioFileWriter
    private let systemWriter: AudioFileWriter
    private let collector = PTSCollector()

    public init(
        directory: SessionDirectory,
        mic: AudioCaptureSource,
        system: AudioCaptureSource,
        sampleRate: Int,
        channelCount: Int
    ) throws {
        self.directory = directory
        self.mic = mic
        self.system = system
        self.micWriter = try AudioFileWriter(url: directory.micPartial, sampleRate: sampleRate, channelCount: channelCount)
        self.systemWriter = try AudioFileWriter(url: directory.systemPartial, sampleRate: sampleRate, channelCount: channelCount)
    }

    public func start() async throws {
        status = .starting
        Log.lifecycle.info("Starting capture, dir=\(self.directory.url.lastPathComponent, privacy: .public)")

        try micWriter.start()
        try systemWriter.start()

        mic.setHandler { [weak self] buf in
            Task { await self?.ingest(stream: .mic, buffer: buf) }
        }
        system.setHandler { [weak self] buf in
            Task { await self?.ingest(stream: .system, buffer: buf) }
        }

        try await mic.start()
        try await system.start()
        status = .recording
        Log.lifecycle.info("Capture started")
    }

    public func stop() async throws {
        status = .stopping
        Log.lifecycle.info("Stopping capture")
        await mic.stop()
        await system.stop()
        try await micWriter.finalize()
        try await systemWriter.finalize()
        try collector.writeSidecar(to: directory.ptsSidecar)
        try directory.finalize()
        status = .finalized
        Log.lifecycle.info("Capture finalized")
    }

    private func ingest(stream: PTSCollector.StreamID, buffer: CMSampleBuffer) {
        collector.observe(stream, buffer: buffer)
        do {
            switch stream {
            case .mic:    try micWriter.append(buffer)
            case .system: try systemWriter.append(buffer)
            }
        } catch {
            Log.capture.error("Append failed: \(String(describing: error), privacy: .public)")
            status = .failed
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CaptureSessionTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriberCore/Capture/CaptureSession.swift Tests/TranscriberCoreTests/Capture/CaptureSessionTests.swift
git commit -m "capture: CaptureSession actor wires sources->writers->collector with full lifecycle"
```

---

## Task 9: SCKAudioCaptureSource (production implementation)

**Files:**
- Create: `Sources/TranscriberCore/Capture/SCKAudioCaptureSource.swift`

This is the only file that touches `SCStream` directly. No unit test — SCK requires Screen Recording permission, so coverage is via the manual smoke test in Task 12.

- [ ] **Step 1: Write the implementation**

```swift
import ScreenCaptureKit
import AVFoundation
import Foundation

public final class SCKAudioCaptureSource: NSObject, AudioCaptureSource, SCStreamOutput, @unchecked Sendable {
    public enum Kind { case microphone, system }

    public enum SCKError: Error {
        case noShareableContent
        case noDisplay
        case streamFailedToStart(Error)
    }

    private let kind: Kind
    private var stream: SCStream?
    private var handler: ((CMSampleBuffer) -> Void)?

    public init(kind: Kind) { self.kind = kind }

    public func setHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    public func start() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw SCKError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = (kind == .system)
        config.captureMicrophone = (kind == .microphone)
        config.excludesCurrentProcessAudio = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)  // we ignore video
        config.sampleRate = 48000
        config.channelCount = 1

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let outputType: SCStreamOutputType = (kind == .microphone) ? .microphone : .audio
        try stream.addStreamOutput(self, type: outputType, sampleHandlerQueue: .global(qos: .userInitiated))

        do {
            try await stream.startCapture()
        } catch {
            throw SCKError.streamFailedToStart(error)
        }
        self.stream = stream
    }

    public func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        handler?(sampleBuffer)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/TranscriberCore/Capture/SCKAudioCaptureSource.swift
git commit -m "capture: SCKAudioCaptureSource production implementation (mic + system kinds)"
```

---

## Task 10: PermissionsService

**Files:**
- Create: `Sources/TranscriberCore/Permissions/PermissionsService.swift`
- Create: `Tests/TranscriberCoreTests/Permissions/PermissionsServiceTests.swift`

Reports current state of mic + screen recording permissions. Triggers the system prompts.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TranscriberCore

final class PermissionsServiceTests: XCTestCase {
    func testStatusEnumIsExhaustive() {
        let cases: [PermissionStatus] = [.notDetermined, .denied, .granted]
        XCTAssertEqual(cases.count, 3)
    }
}
```

- [ ] **Step 2: Run to fail**

Run: `swift test --filter PermissionsServiceTests`
Expected: FAIL — `PermissionStatus` undefined.

- [ ] **Step 3: Write implementation**

```swift
import AVFoundation
import ScreenCaptureKit

public enum PermissionStatus: Sendable, Equatable {
    case notDetermined, denied, granted
}

public final class PermissionsService: Sendable {
    public init() {}

    public func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        case .authorized: return .granted
        @unknown default: return .denied
        }
    }

    public func requestMicrophone() async -> PermissionStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }

    /// Triggers the screen-recording prompt. We can't read status synchronously without trying to capture.
    public func screenRecordingStatus() async -> PermissionStatus {
        do {
            _ = try await SCShareableContent.current
            return .granted
        } catch {
            // SCSharingErrorCode 3 = .userDeclined, others => denied
            return .denied
        }
    }
}
```

- [ ] **Step 4: Run to pass**

Run: `swift test --filter PermissionsServiceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriberCore/Permissions/PermissionsService.swift Tests/TranscriberCoreTests/Permissions/PermissionsServiceTests.swift
git commit -m "permissions: PermissionsService with mic + screen recording status"
```

---

## Task 11: App wiring — RecordingMenu + AppDelegate updates

**Files:**
- Create: `TranscriberApp/TranscriberApp/RecordingMenu.swift`
- Modify: `TranscriberApp/TranscriberApp/AppDelegate.swift`
- Modify: `TranscriberApp/TranscriberApp/TranscriberApp.entitlements` (add mic + screen recording)
- Modify: `TranscriberApp/TranscriberApp/Info.plist` (add usage descriptions)

This is the only task in this slice that's tested manually (no XCTest for AppKit menu).

- [ ] **Step 1: Add usage descriptions to Info.plist**

In Xcode → Info tab on TranscriberApp target, add:
- `NSMicrophoneUsageDescription` = "Transcriber records meeting audio for transcription. Audio stays on your Mac unless you've configured a cloud engine."
- `NSScreenCaptureDescription` (string key, also called "Privacy - Screen Capture Description") = "Transcriber captures system audio so the other speakers in your call can be transcribed. No video is recorded."

- [ ] **Step 2: Update entitlements**

In `TranscriberApp.entitlements`, add:
```xml
<key>com.apple.security.device.audio-input</key>
<true/>
<key>com.apple.security.screencapture-target</key>
<true/>
```
(Also enable the corresponding capabilities in Signing & Capabilities → + Capability if missing.)

- [ ] **Step 3: Build RecordingMenu**

`TranscriberApp/TranscriberApp/RecordingMenu.swift`:

```swift
import AppKit
import TranscriberCore

@MainActor
final class RecordingMenu {
    enum Action {
        case record, stop, quit
    }

    private(set) var menu = NSMenu()
    private let onAction: (Action) -> Void

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        rebuild(for: .idle)
    }

    func rebuild(for status: SessionStatus) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "\(BuildInfo.appName) \(BuildInfo.version)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        switch status {
        case .idle, .finalized, .failed:
            let item = NSMenuItem(title: "Record Now", action: #selector(MenuTarget.record(_:)), keyEquivalent: "r")
            item.target = MenuTarget.shared
            MenuTarget.shared.delegate = self
            menu.addItem(item)
        case .recording:
            let item = NSMenuItem(title: "Stop", action: #selector(MenuTarget.stop(_:)), keyEquivalent: "s")
            item.target = MenuTarget.shared
            MenuTarget.shared.delegate = self
            menu.addItem(item)
        case .starting, .stopping:
            menu.addItem(NSMenuItem(title: status == .starting ? "Starting…" : "Stopping…", action: nil, keyEquivalent: ""))
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(MenuTarget.quit(_:)), keyEquivalent: "q")
        quit.target = MenuTarget.shared
        menu.addItem(quit)
    }

    fileprivate func dispatch(_ action: Action) { onAction(action) }
}

@MainActor
final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    weak var delegate: RecordingMenu?

    @objc func record(_ sender: Any?) { delegate?.dispatch(.record) }
    @objc func stop(_ sender: Any?)   { delegate?.dispatch(.stop) }
    @objc func quit(_ sender: Any?)   { delegate?.dispatch(.quit) }
}
```

- [ ] **Step 4: Update AppDelegate to wire CaptureSession**

```swift
import AppKit
import TranscriberCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var menu: RecordingMenu?
    private var session: CaptureSession?
    private var status: SessionStatus = .idle
    private let permissions = PermissionsService()

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
        // SCSharingContent triggers the screen capture prompt.
        _ = await permissions.screenRecordingStatus()

        let id = SessionID(from: Date())
        do {
            let dir = try SessionDirectory.create(under: outputRoot, id: id)
            let mic = SCKAudioCaptureSource(kind: .microphone)
            let sys = SCKAudioCaptureSource(kind: .system)
            let session = try CaptureSession(directory: dir, mic: mic, system: sys, sampleRate: 48000, channelCount: 1)
            self.session = session
            try await session.start()
            self.status = .recording
            await rebuildMenu()
        } catch {
            Log.lifecycle.error("Start failed: \(String(describing: error), privacy: .public)")
            self.status = .failed
            await rebuildMenu()
        }
    }

    @MainActor
    private func stopRecording() async {
        guard let session else { return }
        do {
            try await session.stop()
            self.status = .finalized
        } catch {
            Log.lifecycle.error("Stop failed: \(String(describing: error), privacy: .public)")
            self.status = .failed
        }
        self.session = nil
        await rebuildMenu()
    }

    @MainActor
    private func rebuildMenu() async {
        menu?.rebuild(for: status)
    }
}
```

- [ ] **Step 5: Build and run from Xcode**

⌘R. Click status bar "T" → "Record Now" → grant permissions when prompted → menu changes to "Stop". Talk for ~10 seconds, click Stop.

Expected: in `~/Documents/Transcriber/<YYYY-MM-DD-HHMM>/`:
- `mic.m4a` (non-empty)
- `system.m4a` (non-empty)
- `pts.json` (valid JSON)

- [ ] **Step 6: Commit**

```bash
git add TranscriberApp/
git commit -m "app: wire RecordingMenu + CaptureSession to status item"
```

---

## Task 12: Manual smoke test

This is verification, not new code. Do it before tagging.

- [ ] **Step 1: Fresh-state run**

```bash
rm -rf ~/Documents/Transcriber/*  # clean slate, we control the output
```

Quit the app if running, then ⌘R from Xcode.

- [ ] **Step 2: Record a 30-second test**

Open a YouTube video (or any system audio source). Click `Record Now`. Speak into the mic. Let it run for 30 seconds. Click `Stop`.

- [ ] **Step 3: Verify artifacts**

```bash
ls -la ~/Documents/Transcriber/$(ls -t ~/Documents/Transcriber/ | head -1)/
```

Expected: `mic.m4a`, `system.m4a`, `pts.json`. Sizes: mic ~200-500KB for 30s, system similar.

- [ ] **Step 4: Verify pts.json content**

```bash
cat ~/Documents/Transcriber/$(ls -t ~/Documents/Transcriber/ | head -1)/pts.json
```

Expected: JSON with `mic` and `system` blocks, both with non-zero `frameCount`, both with `sampleRate: 48000`.

- [ ] **Step 5: Verify audio plays**

```bash
afplay ~/Documents/Transcriber/$(ls -t ~/Documents/Transcriber/ | head -1)/mic.m4a
afplay ~/Documents/Transcriber/$(ls -t ~/Documents/Transcriber/ | head -1)/system.m4a
```

`mic.m4a` should be your voice. `system.m4a` should be the YouTube audio.

- [ ] **Step 6: If anything fails**

Do NOT proceed to tag. Common failures:
- Empty `system.m4a` → screen recording permission denied; check System Settings → Privacy → Screen Recording.
- `mic.m4a` is silence → mic permission denied.
- `pts.json` shows `frameCount: 0` → SCK delivered no buffers; check Console.app for `subsystem:com.szymonsypniewicz.transcriber` capture errors.

---

## Task 13: Slice acceptance + tag

- [ ] **Step 1: Run full test suite**

Run: `swift test`
Expected: All tests pass (BuildInfo, Logging, SessionID, SessionDirectory, PTSMetadata, PTSCollector, AudioFileWriter, CaptureSession, PermissionsService — at least 20+ tests).

- [ ] **Step 2: Update master roadmap status**

Edit `docs/superpowers/plans/2026-04-29-MASTER-ROADMAP.md`:
- Change Slice 1 status row to: `1 | ✅ ... | — | shipped YYYY-MM-DD`

- [ ] **Step 3: Commit and push**

```bash
git add docs/superpowers/plans/2026-04-29-MASTER-ROADMAP.md
git commit -m "roadmap: Slice 1 shipped"
git push origin main
```

- [ ] **Step 4: Tag**

```bash
git tag -a v0.1.0-slice-1 -m "Slice 1: manual record produces mic.m4a + system.m4a + pts.json"
git push origin v0.1.0-slice-1
```

---

## Definition of done for Slice 1

- [ ] Click `Record Now` from menu bar → both mic and system audio captured.
- [ ] Click `Stop` → session folder contains `mic.m4a`, `system.m4a`, `pts.json` only (no leftover `.partial` files).
- [ ] Folder name follows `YYYY-MM-DD-HHMM` (Europe/Warsaw TZ).
- [ ] `pts.json` validates against `PTSMetadata` schema with non-zero `frameCount` for both streams.
- [ ] Audio playback via `afplay` confirms mic recorded user voice; system recorded the other audio.
- [ ] All XCTest unit tests pass.
- [ ] CI green on push.
- [ ] Console.app shows lifecycle log entries for start and stop.

When all checked, this slice is done. Start Slice 2.
