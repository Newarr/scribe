import XCTest

final class RecordingMenuAnimationTests: XCTestCase {
  func testActiveRecordingWaveformAnimationIsGatedByBothCaptureLevels() throws {
    let source = try String(contentsOfFile: appSourcePath("RecordingMenu.swift"), encoding: .utf8)

    guard let layoutRange = source.range(of: "private func recordingLayout") else {
      return XCTFail("Recording menu must keep a dedicated active recording layout")
    }
    let layoutEnd =
      source[layoutRange.upperBound...].range(of: "private var activeStatusCopy")?.lowerBound
      ?? source.endIndex
    let layout = String(source[layoutRange.lowerBound..<layoutEnd])

    XCTAssertTrue(
      layout.contains("AnimatedWaveform("), "Active recording layout must render the waveform.")
    XCTAssertTrue(
      layout.contains("isAnimating: shouldAnimateWaveform"),
      "Waveform motion must be gated by level-aware capture state.")
    XCTAssertTrue(
      layout.contains("isActive: shouldAnimateWaveform"),
      "Waveform must be visually subdued whenever animation is paused.")
    XCTAssertFalse(
      layout.contains("StaticWaveform"),
      "Active recording layout must not regress to the static waveform view.")
    XCTAssertFalse(
      layout.contains("isAnimating: model.status == .recording"),
      "Waveform must not loop decoratively based only on recording status.")

    XCTAssertTrue(
      source.contains("private var audioCaptureIsActive"),
      "Menu must calculate whether both channels are actively capturing.")
    XCTAssertTrue(
      source.contains("channelIsActive(model.micLevel) && channelIsActive(model.systemLevel)"),
      "Both microphone and system levels must be non-silent before wave animation starts.")
    XCTAssertTrue(
      source.contains("private var shouldAnimateWaveform"),
      "Menu must expose a single level-gated animation decision.")
    XCTAssertTrue(
      source.contains("model.status == .recording && audioCaptureIsActive"),
      "Waveform should animate only during recording with both channels active.")

    guard let waveformRange = source.range(of: "private struct AnimatedWaveform") else {
      return XCTFail("Recording menu must define the animated waveform view")
    }
    let waveformEnd =
      source[waveformRange.upperBound...].range(of: "private struct PrimaryPopoverButtonStyle")?
      .lowerBound ?? source.endIndex
    let waveform = String(source[waveformRange.lowerBound..<waveformEnd])

    XCTAssertTrue(
      waveform.contains("TimelineView(.animation"),
      "Waveform animation must be driven by animation timeline ticks.")
    XCTAssertTrue(
      waveform.contains("accessibilityReduceMotion"),
      "Waveform must still respect reduced-motion accessibility settings.")
    XCTAssertTrue(
      waveform.contains("isActive ? 1 : 0.42"),
      "Inactive capture state must make the waveform visually subdued.")
  }

  func testActiveRecordingSurfacesQueuedNextMeetingNonIntrusively() throws {
    let source = try String(contentsOfFile: appSourcePath("RecordingMenu.swift"), encoding: .utf8)

    XCTAssertTrue(
      source.contains("struct RecordingMenuQueuedMeeting"),
      "Recording menu model must represent a queued next meeting while recording.")
    XCTAssertTrue(
      source.contains("@Published var queuedNextMeeting"),
      "Queued meeting context must be observable by the active recording popover.")
    XCTAssertTrue(
      source.contains("var queuedNextMeeting: RecordingMenuQueuedMeeting?"),
      "AppDelegate must be able to update queued meeting context without changing status.")
    XCTAssertTrue(
      source.contains(#"Next: '\(queued.title)' at \(queued.time)"#),
      "Active recording layout must surface queued context as a non-intrusive Next line.")

    guard let layoutRange = source.range(of: "private func recordingLayout") else {
      return XCTFail("Recording menu must keep a dedicated active recording layout")
    }
    let layoutEnd =
      source[layoutRange.upperBound...].range(of: "private var activeStatusCopy")?.lowerBound
      ?? source.endIndex
    let layout = String(source[layoutRange.lowerBound..<layoutEnd])
    XCTAssertTrue(
      layout.contains("if let queued = model.queuedNextMeeting"),
      "Queued context must render only in the active recording layout.")
    XCTAssertFalse(
      layout.contains("onAction(.promptStartRecording)"),
      "Queued context while recording must not expose a start action that interrupts capture.")
  }

  func testActiveRecordingRendersAccessibleCompactMicAndSystemActivity() throws {
    let source = try String(contentsOfFile: appSourcePath("RecordingMenu.swift"), encoding: .utf8)

    XCTAssertFalse(
      source.contains("private struct LiveAudioMeters"),
      "Recording popover must remove the old horizontal MIC/SYS bar component.")
    XCTAssertFalse(
      source.contains("private struct ChannelAudioMeter"),
      "Recording popover must not render horizontal channel bars.")
    XCTAssertTrue(
      source.contains("private struct CompactAudioActivity"),
      "Recording popover must keep compact channel health indicators.")
    XCTAssertTrue(
      source.contains("micLevel: model.micLevel"),
      "MIC activity must be driven from RecordingMenuModel.micLevel.")
    XCTAssertTrue(
      source.contains("systemLevel: model.systemLevel"),
      "SYS activity must be driven from RecordingMenuModel.systemLevel.")
    XCTAssertTrue(source.contains("label: \"MIC\""), "MIC channel label must be visible.")
    XCTAssertTrue(source.contains("label: \"SYS\""), "SYS channel label must be visible.")
    XCTAssertTrue(
      source.contains("accessibilityLabel(accessibilityLabel)"),
      "Channel activity must expose channel-specific VoiceOver labels.")
    XCTAssertTrue(
      source.contains(
        #"accessibilityValue("\(stateText), \(Int((normalizedLevel * 100).rounded())) percent")"#),
      "Channel activity must expose active/silent state and level value to VoiceOver.")
    XCTAssertTrue(
      source.contains("isSilent ? \"silent\" : \"active\""),
      "Silent-channel state must be text/accessibility backed, not color-only.")
  }

  func testTranscribingStatusIsSingleConciseFileTargetLine() throws {
    let source = try String(contentsOfFile: appSourcePath("RecordingMenu.swift"), encoding: .utf8)

    XCTAssertTrue(
      source.contains(#"Transcribing into \(outputTargetName)"#),
      "Finalized/transcribing menu copy must use the exact one-line Transcribing into [file] pattern."
    )
    XCTAssertTrue(
      source.contains(#"return "\(folder)/transcript.md""#),
      "The transcribing target must include the current output folder/file context.")
    XCTAssertTrue(source.contains(".lineLimit(1)"), "Status line must be constrained to one line.")
    XCTAssertTrue(
      source.contains(".truncationMode(.middle)"),
      "Long output targets should truncate neatly rather than wrapping into dense copy.")
    XCTAssertFalse(
      source.contains("Finalizing audio for ElevenLabs transcription."),
      "Old multi-concept status paragraph must be removed.")
    XCTAssertFalse(
      source.contains("Finalizing audio for Cohere transcription on this Mac."),
      "Old local finalizing paragraph must be removed.")
  }

  func testRecentsRemainBoundedFiveItemShortcut() throws {
    let source = try String(contentsOfFile: appSourcePath("RecordingMenu.swift"), encoding: .utf8)

    XCTAssertTrue(
      source.contains("static let recentsLimit = 5"),
      "Menu recents must show the spec-bounded five item shortcut, not a broader history UI.")
    XCTAssertTrue(
      source.contains("Open Folder"), "Recent rows must expose inline Open Folder actions.")
    XCTAssertTrue(
      source.contains("Open Transcript"), "Recent rows must expose inline Open Transcript actions.")
    XCTAssertFalse(
      source.localizedCaseInsensitiveContains("search transcripts"),
      "Menu must not become a transcript history/search UI.")
  }

  func testVisualSnapshotRecordingFixtureUsesObviousNonzeroMeterLevels() throws {
    let source = try String(contentsOfFile: appSourcePath("RecordingMenu.swift"), encoding: .utf8)
    XCTAssertTrue(
      source.contains("model.micLevel = 0.72"),
      "recording visual fixture must show an obvious nonzero MIC meter")
    XCTAssertTrue(
      source.contains("model.systemLevel = 0.58"),
      "recording visual fixture must show an obvious nonzero SYS meter")
    XCTAssertTrue(
      source.contains("max(model.micLevel, 0.72)"),
      "debug recording menu fixture should also force visible MIC activity")
    XCTAssertTrue(
      source.contains("max(model.systemLevel, 0.58)"),
      "debug recording menu fixture should also force visible SYS activity")
  }

  private func appSourcePath(_ file: String) -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let repoRoot =
      testFile
      .deletingLastPathComponent()  // Session
      .deletingLastPathComponent()  // TranscriberCoreTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
    return
      repoRoot
      .appendingPathComponent("TranscriberApp/Scribe")
      .appendingPathComponent(file)
      .path
  }
}
