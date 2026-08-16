import XCTest
@testable import TranscriberCore

final class TrustStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func inputs(
        status: SessionStatus = .idle,
        setupNeedsAttention: Bool = false,
        parkedDetection: Bool = false,
        endPromptActive: Bool = false,
        lastSavedAt: Date? = nil,
        lastFailureAt: Date? = nil
    ) -> TrustState.Inputs {
        TrustState.Inputs(
            status: status,
            setupNeedsAttention: setupNeedsAttention,
            parkedDetection: parkedDetection,
            endPromptActive: endPromptActive,
            lastSavedAt: lastSavedAt,
            lastFailureAt: lastFailureAt,
            now: now
        )
    }

    // MARK: - Active session beats everything

    func testRecordingBeatsSetupBlocker() {
        let s = TrustState.resolve(inputs(status: .recording, setupNeedsAttention: true))
        XCTAssertEqual(s, .recording)
    }

    func testStoppingBeatsParkedDetection() {
        let s = TrustState.resolve(inputs(status: .stopping, parkedDetection: true))
        XCTAssertEqual(s, .stopping)
    }

    func testEndPromptActiveMapsRecordingToStopping() {
        let s = TrustState.resolve(inputs(status: .recording, endPromptActive: true))
        XCTAssertEqual(s, .stopping)
    }

    func testFinalizedMapsToFinalizing() {
        let s = TrustState.resolve(inputs(status: .finalized))
        XCTAssertEqual(s, .finalizing)
    }

    // MARK: - Idle session falls through to flag layer

    func testParkedDetectionShowsDetected() {
        let s = TrustState.resolve(inputs(parkedDetection: true))
        XCTAssertEqual(s, .detected)
    }

    func testSetupBlockerBeatsDetectedPromptIcon() {
        let s = TrustState.resolve(inputs(setupNeedsAttention: true, parkedDetection: true))
        XCTAssertEqual(s, .setupRequired)
    }

    func testSetupBlockerBeatsFailure() {
        let s = TrustState.resolve(inputs(setupNeedsAttention: true, lastFailureAt: now))
        XCTAssertEqual(s, .setupRequired)
    }

    func testFailureWhenIdleWithoutSetupBlocker() {
        let s = TrustState.resolve(inputs(lastFailureAt: now))
        XCTAssertEqual(s, .failed)
    }

    func testSetupBlockerWhenIdle() {
        let s = TrustState.resolve(inputs(setupNeedsAttention: true))
        XCTAssertEqual(s, .setupRequired)
    }

    // MARK: - Saved flash window

    func testSavedFlashWithinWindow() {
        let saved = now.addingTimeInterval(-1.0)
        let s = TrustState.resolve(inputs(lastSavedAt: saved))
        XCTAssertEqual(s, .saved)
    }

    func testSavedFlashExpiresAfterWindow() {
        let saved = now.addingTimeInterval(-5.0)
        let s = TrustState.resolve(inputs(lastSavedAt: saved))
        XCTAssertEqual(s, .idle)
    }

    func testSavedFlashLosesToActiveRecording() {
        let saved = now.addingTimeInterval(-1.0)
        let s = TrustState.resolve(inputs(status: .recording, lastSavedAt: saved))
        XCTAssertEqual(s, .recording)
    }

    // MARK: - Default

    func testIdleBaseline() {
        let s = TrustState.resolve(inputs())
        XCTAssertEqual(s, .idle)
    }

    // MARK: - Asset name coverage

    func testEveryStateHasUniqueAssetName() {
        let names = TrustState.allCases.map(\.assetName)
        XCTAssertEqual(names.count, Set(names).count, "asset names must be unique per state")
    }
}
