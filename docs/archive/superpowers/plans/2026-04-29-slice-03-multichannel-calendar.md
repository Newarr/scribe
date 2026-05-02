# Slice 3 — Multichannel + Calendar Attendee Mapping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace slice 2's single-channel mixed upload with a 2-channel WAV (ch0 = mic, ch1 = system) sent to ElevenLabs Scribe v2 with `use_multi_channel=true, diarize=false`. Use EventKit (basic, point-in-time lookup) to find the calendar event overlapping session start; extract attendees; map `speaker_0` to the current user and `speaker_1` to the remote attendee in the rendered `transcript.md`.

**Why this slice now:** Slice 2 validated the engine layer (Keychain, multipart upload, response parser, transcript writer) on the simplest possible payload. Slice 3 changes only the WAV builder + the call params + the speaker mapping, so any new bug is isolated to multichannel-specific code. EventKit is added here because it's the smallest external dependency that delivers user-visible value (real names instead of `speaker_0`).

**Caveat re AEC:** Spec says `decision_engine_payload_multichannel` assumes `mic.cleaned.wav` (AEC-cleaned). AEC is slice 4. Until then, slice 3's multichannel upload uses raw `mic.m4a`. With headphones (no acoustic bleed), multichannel works correctly. Without headphones, the spec warns of "remote speaker decoded twice as two speakers". Slice 4 fixes this. Until slice 4 ships, **the smoke test for this slice requires headphones** and we ship multichannel as the default with that caveat.

**Architecture:**
- `MultichannelWAVBuilder` — interleaves resampled `mic.m4a` and `system.m4a` into a single 16kHz int16 stereo WAV (ch0 = mic, ch1 = system). Replaces `AudioMixer` only on the upload path; the user-facing mixed audio for playback stays slice 2's mono mix (or comes back later in slice 9 polish).
- `CalendarLookup` — wraps `EKEventStore`. Two operations: `requestAccess()` and `eventOverlapping(date)`. Returns a small `CalendarEvent` value type with `title`, `attendees: [Attendee]`. Attendees carry `name`, `isCurrentUser`. No watchers, no caching, no polling. That's slice 6.
- `SpeakerMappingBuilder` — pure function: given a `CalendarEvent?` plus the upload mode (multichannel vs single-channel), produces the `[String: String]` map fed into `TranscriptWriter.writeComplete`.
- `AppDelegate.transcribe` reorganized: pick mode from settings (default multichannel for now), build the right WAV, call backend, render with the right speaker mapping.

**Tech Stack:** EventKit (`EKEventStore`, `EKEvent`, `EKParticipant`), AVFoundation (`AVAudioFile`, `AVAudioConverter`, `AVAudioPCMBuffer` interleaved stereo), Foundation. No new third-party deps.

**Spec sections covered:** Engines lines 117 (`decision_engine_payload_multichannel`), Calendar lines 77-88, Finalization lines 209 (speaker mapping rule), Permissions lines 311-336 (calendar TCC).

---

## File Structure

After this slice:

```
Sources/TranscriberCore/
  Audio/
    MultichannelWAVBuilder.swift   # NEW: mic + system -> 2-channel int16 WAV
  Calendar/
    CalendarLookup.swift            # NEW: EKEventStore wrapper
    CalendarEvent.swift             # NEW: value type (title, attendees)
  Engines/
    SpeakerMappingBuilder.swift     # NEW: pure mapping function

Tests/TranscriberCoreTests/
  Audio/
    MultichannelWAVBuilderTests.swift
  Calendar/
    CalendarEventTests.swift        # value-type + mapping logic
  Engines/
    SpeakerMappingBuilderTests.swift
    Fixtures/
      elevenlabs-multichannel-success.json   # NEW fixture: words with channel_index

TranscriberApp/TranscriberApp/
  AppDelegate.swift                 # MODIFY: switch upload to multichannel + calendar
  Info.plist                        # MODIFY: add NSCalendarsUsageDescription
```

---

## Task 1: MultichannelWAVBuilder

**Files:**
- Create: `Sources/TranscriberCore/Audio/MultichannelWAVBuilder.swift`
- Create: `Tests/TranscriberCoreTests/Audio/MultichannelWAVBuilderTests.swift`

Reads `mic.m4a` + `system.m4a`, resamples each to the target sample rate (16kHz default), and writes an interleaved stereo WAV with mic on ch0 and system on ch1. Same plan-deviation lesson from slice 2's `AudioMixer` applies: write a float buffer to an int16-settings `AVAudioFile` and let it convert on disk. **Buffers full files in memory same as slice 2's mixer.** Streaming is slice 4 scope.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import AVFoundation
@testable import TranscriberCore

final class MultichannelWAVBuilderTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testProducesTwoChannelWAV() async throws {
        let micURL = tmp.appendingPathComponent("mic.m4a")
        let sysURL = tmp.appendingPathComponent("system.m4a")
        let outURL = tmp.appendingPathComponent("multichannel.wav")
        try writeSilent(to: micURL, durationSec: 1.0)
        try writeSilent(to: sysURL, durationSec: 1.0)

        try await MultichannelWAVBuilder.build(
            mic: micURL,
            system: sysURL,
            output: outURL,
            sampleRate: 16000
        )

        let file = try AVAudioFile(forReading: outURL)
        XCTAssertEqual(file.fileFormat.sampleRate, 16000)
        XCTAssertEqual(file.fileFormat.channelCount, 2, "must produce a 2-channel file")
        XCTAssertGreaterThan(file.length, 0)
    }

    func testChannelOrderingMicOnZeroSystemOnOne() async throws {
        // Generate distinct sine waves: mic = 440Hz, system = 880Hz.
        // After mux, ch0 of the stereo output should match mic, ch1 should match system.
        let micURL = tmp.appendingPathComponent("mic.m4a")
        let sysURL = tmp.appendingPathComponent("system.m4a")
        let outURL = tmp.appendingPathComponent("multichannel.wav")
        try writeSine(to: micURL, frequency: 440, durationSec: 0.5)
        try writeSine(to: sysURL, frequency: 880, durationSec: 0.5)

        try await MultichannelWAVBuilder.build(mic: micURL, system: sysURL, output: outURL, sampleRate: 16000)

        // Read back as float interleaved stereo and check that ch0 RMS ≈ ch1 RMS for sine
        // waves of equal amplitude — both nonzero, both comparable.
        let file = try AVAudioFile(forReading: outURL)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        XCTAssertEqual(Int(buf.frameLength), 8000, accuracy: 200)

        let ch0 = buf.floatChannelData![0]
        let ch1 = buf.floatChannelData![1]
        var rms0: Float = 0, rms1: Float = 0
        for i in 0..<Int(buf.frameLength) { rms0 += ch0[i] * ch0[i]; rms1 += ch1[i] * ch1[i] }
        rms0 = sqrt(rms0 / Float(buf.frameLength))
        rms1 = sqrt(rms1 / Float(buf.frameLength))
        XCTAssertGreaterThan(rms0, 0.05, "ch0 should carry the mic sine")
        XCTAssertGreaterThan(rms1, 0.05, "ch1 should carry the system sine")
    }

    private func writeSilent(to url: URL, durationSec: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(durationSec * 48000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
    }

    private func writeSine(to url: URL, frequency: Double, durationSec: Double) throws {
        let sr: Double = 48000
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(durationSec * sr)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ptr = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            ptr[i] = Float(sin(2.0 * .pi * frequency * Double(i) / sr) * 0.4)
        }
        try file.write(from: buffer)
    }
}
```

- [ ] **Step 2: Run to fail** — `swift test --filter MultichannelWAVBuilderTests` → FAIL.

- [ ] **Step 3: Write the implementation**

```swift
import AVFoundation
import Foundation

public enum MultichannelWAVBuilder {
    public enum BuildError: Error {
        case readFailed(URL)
        case writeFailed(URL)
    }

    /// Read mic.m4a + system.m4a, resample each to `sampleRate`, write an interleaved
    /// 16-bit stereo WAV with mic on ch0 and system on ch1. AVAudioFile handles the
    /// float -> int16 conversion on write.
    ///
    /// TODO(slice 4): same memory footprint concern as `AudioMixer` — buffers each
    /// full input plus the full output. Stream in chunks once the AEC subprocess
    /// pipeline lands.
    public static func build(
        mic: URL,
        system: URL,
        output: URL,
        sampleRate: Double = 16000
    ) async throws {
        let micFile = try AVAudioFile(forReading: mic)
        let sysFile = try AVAudioFile(forReading: system)

        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let micBuf = try resampleFully(file: micFile, to: monoFormat)
        let sysBuf = try resampleFully(file: sysFile, to: monoFormat)

        let frames = max(micBuf.frameLength, sysBuf.frameLength)
        guard frames > 0 else { return }

        let stereoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let stereo = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: frames)!
        stereo.frameLength = frames

        let micSrc = micBuf.floatChannelData![0]
        let sysSrc = sysBuf.floatChannelData![0]
        let ch0 = stereo.floatChannelData![0]
        let ch1 = stereo.floatChannelData![1]
        for i in 0..<Int(frames) {
            ch0[i] = i < Int(micBuf.frameLength) ? micSrc[i] : 0
            ch1[i] = i < Int(sysBuf.frameLength) ? sysSrc[i] : 0
        }

        let outFile = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ])
        try outFile.write(from: stereo)
    }

    private static func resampleFully(file: AVAudioFile, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let totalFrames = AVAudioFrameCount(
            Double(file.length) * format.sampleRate / file.fileFormat.sampleRate
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames + 1024)!
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        let readBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!

        var endOfFile = false
        var status: AVAudioConverterOutputStatus = .haveData
        while status == .haveData && !endOfFile {
            var error: NSError?
            status = converter.convert(to: buffer, error: &error) { _, outStatus in
                do {
                    try file.read(into: readBuffer)
                } catch {
                    outStatus.pointee = .endOfStream
                    endOfFile = true
                    return nil
                }
                if readBuffer.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    endOfFile = true
                    return nil
                }
                outStatus.pointee = .haveData
                return readBuffer
            }
            if let err = error { throw err }
        }
        return buffer
    }
}
```

- [ ] **Step 4: Run to pass** — `swift test --filter MultichannelWAVBuilderTests` → 2/2 PASS.

- [ ] **Step 5: Commit**
```bash
git add Sources/TranscriberCore/Audio/MultichannelWAVBuilder.swift \
        Tests/TranscriberCoreTests/Audio/MultichannelWAVBuilderTests.swift
git commit -m "audio: MultichannelWAVBuilder produces 2-channel WAV (ch0=mic, ch1=system)"
```

---

## Task 2: CalendarLookup + CalendarEvent value type

**Files:**
- Create: `Sources/TranscriberCore/Calendar/CalendarEvent.swift`
- Create: `Sources/TranscriberCore/Calendar/CalendarLookup.swift`
- Create: `Tests/TranscriberCoreTests/Calendar/CalendarEventTests.swift`

`CalendarEvent` is a pure value type — testable. `CalendarLookup` wraps `EKEventStore` and is integration-tested manually (CI agents have no calendar). Permission flow keeps the same shape as `PermissionsService` from slice 1.

- [ ] **Step 1: Write CalendarEvent**

```swift
import Foundation

public struct CalendarEvent: Sendable, Equatable {
    public struct Attendee: Sendable, Equatable {
        public let name: String
        public let isCurrentUser: Bool

        public init(name: String, isCurrentUser: Bool) {
            self.name = name
            self.isCurrentUser = isCurrentUser
        }
    }

    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let attendees: [Attendee]

    public init(title: String, startDate: Date, endDate: Date, attendees: [Attendee]) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.attendees = attendees
    }

    /// Returns the local user's display name (`isCurrentUser == true`) if the event
    /// has one; nil otherwise.
    public var currentUser: String? {
        attendees.first(where: { $0.isCurrentUser })?.name
    }

    /// Returns the first non-current-user attendee. For 1:1 meetings this is the
    /// remote speaker. For group meetings, the caller decides what to do; slice 3
    /// only maps `speaker_1` for 1:1 events.
    public var firstRemoteAttendee: String? {
        attendees.first(where: { !$0.isCurrentUser })?.name
    }

    public var isOneOnOne: Bool {
        attendees.count == 2 && attendees.contains(where: { $0.isCurrentUser })
    }
}
```

- [ ] **Step 2: Write CalendarEvent tests**

```swift
import XCTest
@testable import TranscriberCore

final class CalendarEventTests: XCTestCase {
    func testCurrentUserAndFirstRemoteAttendee() {
        let now = Date()
        let event = CalendarEvent(
            title: "1:1 with Faris",
            startDate: now,
            endDate: now.addingTimeInterval(1800),
            attendees: [
                .init(name: "Szymon", isCurrentUser: true),
                .init(name: "Faris Riaz", isCurrentUser: false)
            ]
        )
        XCTAssertEqual(event.currentUser, "Szymon")
        XCTAssertEqual(event.firstRemoteAttendee, "Faris Riaz")
        XCTAssertTrue(event.isOneOnOne)
    }

    func testGroupMeetingIsNotOneOnOne() {
        let event = CalendarEvent(
            title: "Team weekly",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            attendees: [
                .init(name: "Szymon", isCurrentUser: true),
                .init(name: "Faris", isCurrentUser: false),
                .init(name: "Maciek", isCurrentUser: false)
            ]
        )
        XCTAssertFalse(event.isOneOnOne)
        XCTAssertEqual(event.firstRemoteAttendee, "Faris")
    }

    func testEventWithoutCurrentUserHasNilCurrentUser() {
        // An event the user accepted but was added by the organizer; user not in attendee list.
        let event = CalendarEvent(
            title: "Meeting",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            attendees: [.init(name: "Faris", isCurrentUser: false)]
        )
        XCTAssertNil(event.currentUser)
        XCTAssertEqual(event.firstRemoteAttendee, "Faris")
        XCTAssertFalse(event.isOneOnOne)
    }
}
```

- [ ] **Step 3: Write CalendarLookup**

```swift
import EventKit
import Foundation

public final class CalendarLookup: Sendable {
    public enum LookupError: Error {
        case accessDenied
        case noEventStore
    }

    public init() {}

    /// Triggers the EKEventStore.requestFullAccessToEvents prompt. Returns the
    /// resulting authorization status. Per spec, missing calendar permission must
    /// not block recording — callers degrade gracefully when this returns .denied.
    public func requestAccess() async -> EKAuthorizationStatus {
        let store = EKEventStore()
        do {
            // macOS 14+: requestFullAccessToEvents. Older API pre-13 was requestAccess(to:).
            _ = try await store.requestFullAccessToEvents()
        } catch {
            // Foundation rejects the call when the user denies; status reflects it.
        }
        return EKEventStore.authorizationStatus(for: .event)
    }

    /// Returns the calendar event whose [start, end] range overlaps `date`, or the
    /// closest event that started in the last 15 minutes / will start in the next
    /// 15 minutes. nil if no matching event or access is denied.
    public func eventOverlapping(_ date: Date) -> CalendarEvent? {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized else { return nil }

        let store = EKEventStore()
        let windowStart = date.addingTimeInterval(-15 * 60)
        let windowEnd = date.addingTimeInterval(15 * 60)
        let predicate = store.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: nil
        )
        let events = store.events(matching: predicate)
        guard !events.isEmpty else { return nil }

        // Prefer events that strictly contain `date`; fall back to the nearest one.
        let containing = events.filter { $0.startDate <= date && date <= $0.endDate }
        let candidate = containing.first
            ?? events.min(by: { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) })
        return candidate.map(Self.makeEvent(from:))
    }

    private static func makeEvent(from ek: EKEvent) -> CalendarEvent {
        let attendees: [CalendarEvent.Attendee] = (ek.attendees ?? []).map { participant in
            let name = participant.name ?? participant.url.absoluteString
                .replacingOccurrences(of: "mailto:", with: "")
            return .init(name: name, isCurrentUser: participant.isCurrentUser)
        }
        return CalendarEvent(
            title: ek.title ?? "(untitled)",
            startDate: ek.startDate,
            endDate: ek.endDate,
            attendees: attendees
        )
    }
}
```

- [ ] **Step 4: Verify it compiles** — `swift build` → success.

- [ ] **Step 5: Run tests** — `swift test --filter CalendarEventTests` → 3/3 PASS.

- [ ] **Step 6: Commit**
```bash
git add Sources/TranscriberCore/Calendar/ \
        Tests/TranscriberCoreTests/Calendar/
git commit -m "calendar: CalendarEvent value type + CalendarLookup (EventKit basic point-in-time)"
```

---

## Task 3: SpeakerMappingBuilder

**Files:**
- Create: `Sources/TranscriberCore/Engines/SpeakerMappingBuilder.swift`
- Create: `Tests/TranscriberCoreTests/Engines/SpeakerMappingBuilderTests.swift`

Pure mapping function: `(CalendarEvent?, EngineRequest.Mode) -> [String: String]`. Centralizes the rule "speaker_0 = current user, speaker_1 = remote attendee for 1:1" so AppDelegate, slice 6's calendar enrichment, and slice 7's recovery all behave identically.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TranscriberCore

final class SpeakerMappingBuilderTests: XCTestCase {
    func testOneOnOneMultichannelMapsBothSpeakers() {
        let event = CalendarEvent(
            title: "1:1",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            attendees: [
                .init(name: "Szymon", isCurrentUser: true),
                .init(name: "Faris", isCurrentUser: false)
            ]
        )
        let mapping = SpeakerMappingBuilder.build(event: event, mode: .multichannel)
        XCTAssertEqual(mapping["speaker_0"], "Szymon")
        XCTAssertEqual(mapping["speaker_1"], "Faris")
    }

    func testGroupMeetingDoesNotMapSpeakerOne() {
        let event = CalendarEvent(
            title: "Team weekly",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            attendees: [
                .init(name: "Szymon", isCurrentUser: true),
                .init(name: "Faris", isCurrentUser: false),
                .init(name: "Maciek", isCurrentUser: false)
            ]
        )
        let mapping = SpeakerMappingBuilder.build(event: event, mode: .multichannel)
        XCTAssertEqual(mapping["speaker_0"], "Szymon")
        XCTAssertNil(mapping["speaker_1"], "group meetings: speaker_1 stays unmapped, downstream renders it raw")
    }

    func testNoEventReturnsEmptyMap() {
        let mapping = SpeakerMappingBuilder.build(event: nil, mode: .multichannel)
        XCTAssertTrue(mapping.isEmpty)
    }

    func testSingleChannelDiarizedReturnsEmptyMapEvenWithEvent() {
        // Slice 2 fallback: diarization labels are speaker_0 / speaker_1 / ... but
        // they don't reliably correspond to mic vs system. Don't pretend they do.
        let event = CalendarEvent(
            title: "1:1",
            startDate: Date(), endDate: Date().addingTimeInterval(1800),
            attendees: [
                .init(name: "Szymon", isCurrentUser: true),
                .init(name: "Faris", isCurrentUser: false)
            ]
        )
        let mapping = SpeakerMappingBuilder.build(event: event, mode: .singleChannelDiarized(numSpeakers: 2))
        XCTAssertTrue(mapping.isEmpty)
    }
}
```

- [ ] **Step 2: Run to fail** — `swift test --filter SpeakerMappingBuilderTests` → FAIL.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

public enum SpeakerMappingBuilder {
    /// Build the speaker -> display name map fed to `TranscriptWriter.writeComplete`.
    /// Empty map means the writer renders raw speaker IDs (`speaker_0`, etc.).
    ///
    /// Multichannel mode: speaker_0 is the mic channel (the local user), speaker_1
    /// is the system channel (remote). Map both only for 1:1 meetings, since group
    /// meetings have multiple remotes mixed onto ch1 and a single name there is
    /// misleading.
    ///
    /// Single-channel diarized mode: ElevenLabs assigns speaker_0 / speaker_1 by
    /// voice clustering, not channel. The cluster ID does not reliably correspond
    /// to mic vs system, so we never auto-map. Slice 6 may revisit if calendar
    /// attendees prove distinctive enough.
    public static func build(event: CalendarEvent?, mode: EngineRequest.Mode) -> [String: String] {
        guard case .multichannel = mode, let event else { return [:] }

        var mapping: [String: String] = [:]
        if let me = event.currentUser {
            mapping["speaker_0"] = me
        }
        if event.isOneOnOne, let other = event.firstRemoteAttendee {
            mapping["speaker_1"] = other
        }
        return mapping
    }
}
```

- [ ] **Step 4: Run to pass** — `swift test --filter SpeakerMappingBuilderTests` → 4/4 PASS.

- [ ] **Step 5: Commit**
```bash
git add Sources/TranscriberCore/Engines/SpeakerMappingBuilder.swift \
        Tests/TranscriberCoreTests/Engines/SpeakerMappingBuilderTests.swift
git commit -m "engines: SpeakerMappingBuilder centralizes channel/diarized -> attendee mapping"
```

---

## Task 4: ElevenLabsScribeBackend multichannel test + parser fixture

**Files:**
- Create: `Tests/TranscriberCoreTests/Engines/Fixtures/elevenlabs-multichannel-success.json`
- Modify: `Tests/TranscriberCoreTests/Engines/ElevenLabsScribeBackendTests.swift`

Slice 2's backend already supports `mode: .multichannel` and the parser already prefers `channel_index` over `speaker_id`. What's missing is a fixture + test that proves the multichannel response path works and produces channel-keyed speakers. This task is pure test coverage.

- [ ] **Step 1: Write the multichannel fixture**

`Tests/TranscriberCoreTests/Engines/Fixtures/elevenlabs-multichannel-success.json`:

```json
{
  "language_code": "en",
  "language_probability": 0.99,
  "transcripts": [
    {
      "channel_index": 0,
      "language_code": "en",
      "text": "Hi Faris, can you hear me?",
      "words": [
        {"text": "Hi", "type": "word", "start": 0.10, "end": 0.30, "channel_index": 0},
        {"text": "Faris", "type": "word", "start": 0.31, "end": 0.65, "channel_index": 0},
        {"text": ",", "type": "spacing", "start": 0.65, "end": 0.66, "channel_index": 0},
        {"text": "can", "type": "word", "start": 0.80, "end": 0.95, "channel_index": 0},
        {"text": "you", "type": "word", "start": 0.96, "end": 1.05, "channel_index": 0},
        {"text": "hear", "type": "word", "start": 1.06, "end": 1.25, "channel_index": 0},
        {"text": "me", "type": "word", "start": 1.26, "end": 1.40, "channel_index": 0},
        {"text": "?", "type": "spacing", "start": 1.40, "end": 1.41, "channel_index": 0}
      ]
    },
    {
      "channel_index": 1,
      "language_code": "en",
      "text": "Yes, I can hear you.",
      "words": [
        {"text": "Yes", "type": "word", "start": 1.60, "end": 1.85, "channel_index": 1},
        {"text": ",", "type": "spacing", "start": 1.85, "end": 1.86, "channel_index": 1},
        {"text": "I", "type": "word", "start": 1.95, "end": 2.05, "channel_index": 1},
        {"text": "can", "type": "word", "start": 2.06, "end": 2.20, "channel_index": 1},
        {"text": "hear", "type": "word", "start": 2.21, "end": 2.40, "channel_index": 1},
        {"text": "you", "type": "word", "start": 2.41, "end": 2.55, "channel_index": 1},
        {"text": ".", "type": "spacing", "start": 2.55, "end": 2.56, "channel_index": 1}
      ]
    }
  ]
}
```

> **Note on schema:** ElevenLabs has documented two response shapes for multichannel — a flat `words[]` (same shape as single-channel, just with `channel_index` per word) and a `transcripts[]` per-channel array. **Slice 2's backend parser only handles the flat `words[]` shape.** This fixture covers the case the existing parser already supports, so test the flat shape. If the live API returns the nested `transcripts[]` shape, that's a parser bug to handle in a follow-up; capture it as `q_elevenlabs_multichannel_response_shape` in `QUESTIONS.md` and use the flat shape that the parser already groks until the question resolves.

Use this flat-shape fixture instead:

```json
{
  "language_code": "en",
  "language_probability": 0.99,
  "text": "Hi Faris, can you hear me? Yes, I can hear you.",
  "words": [
    {"text": "Hi", "type": "word", "start": 0.10, "end": 0.30, "channel_index": 0},
    {"text": "Faris", "type": "word", "start": 0.31, "end": 0.65, "channel_index": 0},
    {"text": ",", "type": "spacing", "start": 0.65, "end": 0.66, "channel_index": 0},
    {"text": "can", "type": "word", "start": 0.80, "end": 0.95, "channel_index": 0},
    {"text": "you", "type": "word", "start": 0.96, "end": 1.05, "channel_index": 0},
    {"text": "hear", "type": "word", "start": 1.06, "end": 1.25, "channel_index": 0},
    {"text": "me", "type": "word", "start": 1.26, "end": 1.40, "channel_index": 0},
    {"text": "?", "type": "spacing", "start": 1.40, "end": 1.41, "channel_index": 0},
    {"text": "Yes", "type": "word", "start": 1.60, "end": 1.85, "channel_index": 1},
    {"text": ",", "type": "spacing", "start": 1.85, "end": 1.86, "channel_index": 1},
    {"text": "I", "type": "word", "start": 1.95, "end": 2.05, "channel_index": 1},
    {"text": "can", "type": "word", "start": 2.06, "end": 2.20, "channel_index": 1},
    {"text": "hear", "type": "word", "start": 2.21, "end": 2.40, "channel_index": 1},
    {"text": "you", "type": "word", "start": 2.41, "end": 2.55, "channel_index": 1},
    {"text": ".", "type": "spacing", "start": 2.55, "end": 2.56, "channel_index": 1}
  ]
}
```

- [ ] **Step 2: Append a multichannel test to `ElevenLabsScribeBackendTests`**

```swift
func testMultichannelResponseProducesChannelKeyedSpeakers() async throws {
    let body = try Data(contentsOf: fixture("elevenlabs-multichannel-success"))
    MockURLProtocol.handler = { request in
        // Verify the request actually used multichannel params: use_multi_channel=true,
        // diarize=false, no num_speakers.
        let bodyData = request.httpBody ?? Data()
        let bodyStr = String(data: bodyData, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyStr.contains("name=\"use_multi_channel\""), "missing use_multi_channel")
        XCTAssertTrue(bodyStr.contains("name=\"diarize\""), "missing diarize")
        XCTAssertFalse(bodyStr.contains("name=\"num_speakers\""), "num_speakers must be omitted in multichannel")
        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
    }

    let backend = ElevenLabsScribeBackend(apiKey: "test-key", session: mockSession)
    let req = EngineRequest(
        audioURL: try makeTinyWAV(),
        mode: .multichannel,
        languageCode: "en",
        keyterms: []
    )
    let response = try await backend.transcribe(req)

    XCTAssertEqual(response.utterances.count, 2)
    XCTAssertEqual(response.utterances[0].speaker, "speaker_0")
    XCTAssertTrue(response.utterances[0].text.contains("Hi"))
    XCTAssertTrue(response.utterances[0].text.contains("Faris"))
    XCTAssertEqual(response.utterances[1].speaker, "speaker_1")
    XCTAssertTrue(response.utterances[1].text.contains("Yes"))
}
```

> **Note on URLProtocol body:** When Foundation hands the body to a URLProtocol mock, `httpBody` may be empty if the body went via an `httpBodyStream`. The current backend uses `httpBody` directly (no stream), so the assertion above works. If Slice 4 switches to `uploadTask(with:fromFile:)` for streaming, this test will need to adapt.

- [ ] **Step 3: Run to fail / pass**

Run: `swift test --filter testMultichannelResponseProducesChannelKeyedSpeakers`
Expected: PASS first try (parser already handles `channel_index`).

If the test fails on the body inspection, the backend's body handling has changed since slice 2; update the test to match.

- [ ] **Step 4: Commit**
```bash
git add Tests/TranscriberCoreTests/Engines/Fixtures/elevenlabs-multichannel-success.json \
        Tests/TranscriberCoreTests/Engines/ElevenLabsScribeBackendTests.swift
git commit -m "engines: multichannel ElevenLabs response test + fixture, asserts use_multi_channel/diarize=false/no num_speakers"
```

---

## Task 5: Wire multichannel + calendar into AppDelegate

**Files:**
- Modify: `TranscriberApp/TranscriberApp/AppDelegate.swift`
- Modify: `TranscriberApp/TranscriberApp/Info.plist` (add `NSCalendarsUsageDescription`)

Replace slice 2's `AudioMixer.mix → mixed.wav → singleChannelDiarized` flow with `MultichannelWAVBuilder.build → multichannel.wav → multichannel`. Look up the calendar event at session start; pass it into `SpeakerMappingBuilder` for the final transcript.

- [ ] **Step 1: Add calendar usage description to Info.plist**

```xml
<key>NSCalendarsUsageDescription</key>
<string>Transcriber reads the calendar event overlapping the current recording so the transcript can label speakers with attendee names. Calendar access is optional; recording works without it.</string>
```

- [ ] **Step 2: Trigger calendar access on first launch**

Modify `applicationDidFinishLaunching` in `AppDelegate.swift` to call `CalendarLookup.requestAccess()` once after launch. Don't block on it.

```swift
let lookup = CalendarLookup()
Task { _ = await lookup.requestAccess() }
```

- [ ] **Step 3: Capture calendar event at session start**

Add stored property:
```swift
private var currentCalendarEvent: CalendarEvent?
```

In `startRecording`, after creating `dir`, look up the overlapping event:

```swift
self.currentCalendarEvent = CalendarLookup().eventOverlapping(Date())
```

Log lifecycle without leaking event content:
```swift
Log.calendar.info("Calendar lookup at session start: matched=\(self.currentCalendarEvent != nil ? "yes" : "no", privacy: .public)")
```

Reset in the `.failure` branch and at the start of `stopRecording`'s post-handoff cleanup.

- [ ] **Step 4: Replace the transcribe pipeline**

Replace the body of `func transcribe(directory:startedAt:endedAt:)` with:

```swift
let multichannelURL = dir.url.appendingPathComponent("multichannel.wav")
let transcriptURL = dir.transcript
let isoFmt = ISO8601DateFormatter()
let dayFmt = DateFormatter()
dayFmt.dateFormat = "yyyy-MM-dd"

let event = currentCalendarEvent
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
    let req = EngineRequest(
        audioURL: multichannelURL,
        mode: .multichannel,
        languageCode: nil,
        keyterms: []
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
```

- [ ] **Step 5: Regenerate the Xcode project + build**

```bash
cd TranscriberApp && xcodegen generate
xcodebuild -project TranscriberApp.xcodeproj -scheme TranscriberApp -configuration Debug -destination 'platform=macOS' build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**
```bash
git add TranscriberApp/
git commit -m "app: switch upload pipeline to multichannel + calendar attendee mapping"
```

---

## Task 6: Manual smoke test

**Pre-reqs:** Same as slice 2 plus calendar permission on first launch. **Headphones required** — see slice intro for why.

- [ ] **Step 1: Create a test calendar event**

In Calendar.app, make a 30-minute event starting "now":
- Title: `1:1 with Faris (test)`
- Attendees: yourself + a fake email like `faris@example.com`

This populates the `attendees` field with one current-user entry and one remote.

- [ ] **Step 2: Record a 1-minute test call (with headphones)**

Quit and ⌘R the app. Click `Record Now`. Speak yourself, play a short YouTube clip with someone else's voice. Click `Stop`.

- [ ] **Step 3: Verify the artifacts**

```bash
ls -la ~/Documents/Transcriber/$(ls -t ~/Documents/Transcriber/ | head -1)/
```

Expected within ~1-3 minutes:
- `mic.m4a`, `system.m4a`, `pts.json`
- `multichannel.wav` (the new 2-channel upload artifact)
- `transcript.md` with `status: complete` and **named speakers**

- [ ] **Step 4: Read the transcript**

```bash
cat ~/Documents/Transcriber/$(ls -t ~/Documents/Transcriber/ | head -1)/transcript.md
```

Expected:
- Frontmatter title matches the calendar event's title.
- `attendees:` lists both wikilink-formatted names.
- Body has `**<your-name>** [00:00]: ...` and `**<remote-name>** [00:??]: ...` instead of `speaker_0`/`speaker_1`.

- [ ] **Step 5: Test the no-calendar path**

Delete the test calendar event. Re-record briefly. Expected: transcript falls back to `Manual recording <slug>` title and renders raw `**speaker_0**` / `**speaker_1**` since `SpeakerMappingBuilder` returns an empty map for `event == nil`.

---

## Task 7: Slice acceptance + tag

- [ ] **Step 1: Run full test suite**

`swift test`
Expected: All tests pass — at least 41+ tests now (34 carry-over + 9 new from slice 3: 2 mixer + 3 calendar event + 4 mapping + 1 multichannel backend = 10 — but mapping reuses pure-data tests so allow some variance, anywhere 40-43 is fine).

- [ ] **Step 2: Update master roadmap**

```markdown
| 3 | ✅ `2026-04-29-slice-03-multichannel-calendar.md` | `transcriber-slice-3` | shipped 2026-04-29 |
```

- [ ] **Step 3: Run codex review against the slice**

```bash
codex review --base v0.2.0-slice-2 -c 'model_reasoning_effort="high"' --enable web_search_cached
```

Triage findings the same way slice 2 did: P1 fixes inline; defer slice-4-and-later concerns with a clear note.

- [ ] **Step 4: Commit, merge, push, tag**

```bash
git add docs/superpowers/plans/2026-04-29-MASTER-ROADMAP.md
git commit -m "roadmap: Slice 3 shipped"

# back in main worktree:
git merge --ff-only slice-3
git push origin main
git tag -a v0.3.0-slice-3 -m "Slice 3: multichannel ElevenLabs + EventKit attendee mapping"
git push origin v0.3.0-slice-3
git worktree remove ../transcriber-slice-3
git branch -d slice-3
```

---

## Definition of done for Slice 3

- [ ] Click `Record Now` during a live calendar event → speak ~60 seconds with headphones → click `Stop` → wait → `transcript.md` appears with `status: complete`, the calendar event's title, attendees populated, and speaker labels mapped to attendee names.
- [ ] Without an overlapping calendar event, `transcript.md` still has `status: complete`; speaker labels render as raw `speaker_0` / `speaker_1` (no attendee mapping was possible).
- [ ] `multichannel.wav` exists in the session folder and is a 2-channel 16kHz int16 WAV.
- [ ] All XCTest tests pass.
- [ ] CI green.
- [ ] No calendar event content leaks into Console.app logs (only `matched=yes/no`).
- [ ] No regressions: slice 2's KeychainStore, AudioMixer, MultipartBody, etc. all still pass their tests.

When all checked, slice 3 is done. Slice 4 (AEC pre-pass) follows; depends on Spike B (AEC3 quality validation).
