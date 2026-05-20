import XCTest

final class RecordingMenuAnimationTests: XCTestCase {
    func testActiveRecordingUsesAnimatedWaveform() throws {
        let source = try String(contentsOfFile: appSourcePath("RecordingMenu.swift"), encoding: .utf8)

        guard let layoutRange = source.range(of: "private func recordingLayout") else {
            return XCTFail("Recording menu must keep a dedicated active recording layout")
        }
        let layoutEnd = source[layoutRange.upperBound...].range(of: "private var activeStatusCopy")?.lowerBound ?? source.endIndex
        let layout = String(source[layoutRange.lowerBound..<layoutEnd])

        XCTAssertTrue(
            layout.contains("AnimatedWaveform("),
            "Active recording layout must render the time-driven waveform, not a flattened static graphic."
        )
        XCTAssertTrue(
            layout.contains("isAnimating: model.status == .recording"),
            "Waveform motion must be tied to the actual active recording state."
        )
        XCTAssertFalse(
            layout.contains("StaticWaveform"),
            "Active recording layout must not regress to the static waveform view."
        )

        guard let waveformRange = source.range(of: "private struct AnimatedWaveform") else {
            return XCTFail("Recording menu must define the animated waveform view")
        }
        let waveformEnd = source[waveformRange.upperBound...].range(of: "private struct PrimaryPopoverButtonStyle")?.lowerBound ?? source.endIndex
        let waveform = String(source[waveformRange.lowerBound..<waveformEnd])

        XCTAssertTrue(waveform.contains("TimelineView(.animation"), "Waveform animation must be driven by animation timeline ticks.")
        XCTAssertTrue(waveform.contains("accessibilityReduceMotion"), "Waveform must still respect reduced-motion accessibility settings.")
    }

    func testActiveRecordingSurfacesQueuedNextMeetingNonIntrusively() throws {
        let source = try String(contentsOfFile: appSourcePath("RecordingMenu.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("struct RecordingMenuQueuedMeeting"), "Recording menu model must represent a queued next meeting while recording.")
        XCTAssertTrue(source.contains("@Published var queuedNextMeeting"), "Queued meeting context must be observable by the active recording popover.")
        XCTAssertTrue(source.contains("var queuedNextMeeting: RecordingMenuQueuedMeeting?"), "AppDelegate must be able to update queued meeting context without changing status.")
        XCTAssertTrue(source.contains(#"Next: '\(queued.title)' at \(queued.time)"#), "Active recording layout must surface queued context as a non-intrusive Next line.")

        guard let layoutRange = source.range(of: "private func recordingLayout") else {
            return XCTFail("Recording menu must keep a dedicated active recording layout")
        }
        let layoutEnd = source[layoutRange.upperBound...].range(of: "private var activeStatusCopy")?.lowerBound ?? source.endIndex
        let layout = String(source[layoutRange.lowerBound..<layoutEnd])
        XCTAssertTrue(layout.contains("if let queued = model.queuedNextMeeting"), "Queued context must render only in the active recording layout.")
        XCTAssertFalse(layout.contains("onAction(.promptStartRecording)"), "Queued context while recording must not expose a start action that interrupts capture.")
    }

    func testActiveRecordingRendersAccessibleDataDrivenMicAndSystemMeters() throws {
        let source = try String(contentsOfFile: appSourcePath("RecordingMenu.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("private struct LiveAudioMeters"), "Recording popover must render explicit live audio meters.")
        XCTAssertTrue(source.contains("micLevel: model.micLevel"), "MIC meter must be driven from RecordingMenuModel.micLevel.")
        XCTAssertTrue(source.contains("systemLevel: model.systemLevel"), "SYS meter must be driven from RecordingMenuModel.systemLevel.")
        XCTAssertTrue(source.contains("label: \"MIC\""), "MIC channel label must be visible.")
        XCTAssertTrue(source.contains("label: \"SYS\""), "SYS channel label must be visible.")
        XCTAssertTrue(source.contains("accessibilityLabel(accessibilityLabel)"), "Meters must expose channel-specific VoiceOver labels.")
        XCTAssertTrue(source.contains("accessibilityValue(\"\\(stateText), \\(Int((normalizedLevel * 100).rounded())) percent\")"), "Meters must expose active/silent state and level value to VoiceOver.")
        XCTAssertTrue(source.contains("isSilent ? \"silent\" : \"active\""), "Silent-channel state must be text/accessibility backed, not color-only.")
    }

    func testRecentsRemainBoundedFiveItemShortcut() throws {
        let source = try String(contentsOfFile: appSourcePath("RecordingMenu.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("static let recentsLimit = 5"), "Menu recents must show the spec-bounded five item shortcut, not a broader history UI.")
        XCTAssertTrue(source.contains("Open Folder"), "Recent rows must expose inline Open Folder actions.")
        XCTAssertTrue(source.contains("Open Transcript"), "Recent rows must expose inline Open Transcript actions.")
        XCTAssertFalse(source.localizedCaseInsensitiveContains("search transcripts"), "Menu must not become a transcript history/search UI.")
    }

    private func appSourcePath(_ file: String) -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent() // Session
            .deletingLastPathComponent() // TranscriberCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        return repoRoot
            .appendingPathComponent("TranscriberApp/Scribe")
            .appendingPathComponent(file)
            .path
    }
}
