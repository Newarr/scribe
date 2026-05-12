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
