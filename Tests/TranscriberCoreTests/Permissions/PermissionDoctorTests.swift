import Foundation
import XCTest
@testable import TranscriberCore

final class PermissionDoctorTests: XCTestCase {

    // MARK: helpers

    private func makeWritableTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("permission-doctor-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: clean path

    func testAllGreenCloudReturnsAllow() async {
        let outputRoot = makeWritableTempDir()
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .granted, screen: .granted, calendar: .granted),
            engine: StubEngine(cloudKey: true),
            folder: DefaultOutputFolderProbe()
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .cloud)
        XCTAssertEqual(report.blockers, [])
        XCTAssertEqual(report.warnings, [])
        XCTAssertEqual(RecordRequestGate().verdict(from: report), .allow)
    }

    // MARK: blockers

    func testMicDeniedDeniesStart() async {
        let outputRoot = makeWritableTempDir()
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .denied, screen: .granted, calendar: .granted),
            engine: StubEngine(cloudKey: true)
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .cloud)
        XCTAssertTrue(report.blockers.contains(.microphoneDenied))
        XCTAssertEqual(RecordRequestGate().verdict(from: report), .deny(report.blockers))
    }

    func testMicNotDeterminedDeniesStartButFlagsForRequestPath() async {
        let outputRoot = makeWritableTempDir()
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .notDetermined, screen: .granted, calendar: .granted),
            engine: StubEngine(cloudKey: true)
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .cloud)
        XCTAssertTrue(report.blockers.contains(.microphoneNotDetermined))
    }

    func testScreenRecordingDeniedBlocksRecording() async {
        let outputRoot = makeWritableTempDir()
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .granted, screen: .denied, calendar: .granted),
            engine: StubEngine(cloudKey: true)
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .cloud)
        XCTAssertTrue(report.blockers.contains(.screenRecordingDenied),
                      "screen recording is required per spec line 339 (no mic-only fallback)")
    }

    func testMissingCloudKeyBlocksCloudMode() async {
        let outputRoot = makeWritableTempDir()
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .granted, screen: .granted, calendar: .granted),
            engine: StubEngine(cloudKey: false)
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .cloud)
        XCTAssertTrue(report.blockers.contains(.missingCloudAPIKey),
                      "cloud mode without a Keychain API key must block; today AppDelegate only discovers this after capture")
    }

    func testMissingLocalBinaryBlocksLocalMode() async {
        let outputRoot = makeWritableTempDir()
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let probe = StubEngine(
            cloudKey: false,
            localBinary: nil,
            localModel: URL(fileURLWithPath: "/tmp/model"),
            binaryReady: false,
            modelReady: true
        )
        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .granted, screen: .granted, calendar: .granted),
            engine: probe
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .local)
        XCTAssertTrue(report.blockers.contains(where: {
            if case .missingLocalEngineBinary = $0 { return true } else { return false }
        }))
    }

    func testMissingLocalModelBlocksLocalMode() async {
        let outputRoot = makeWritableTempDir()
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let probe = StubEngine(
            cloudKey: false,
            localBinary: URL(fileURLWithPath: "/tmp/cohere"),
            localModel: URL(fileURLWithPath: "/tmp/model"),
            binaryReady: true,
            modelReady: false
        )
        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .granted, screen: .granted, calendar: .granted),
            engine: probe
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .local)
        XCTAssertTrue(report.blockers.contains(where: {
            if case .missingLocalLanguageModel = $0 { return true } else { return false }
        }))
    }

    func testUnwritableOutputFolderBlocks() async {
        let outputRoot = URL(fileURLWithPath: "/this/path/does/not/exist/and/cannot/be/created")
        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .granted, screen: .granted, calendar: .granted),
            engine: StubEngine(cloudKey: true),
            folder: AlwaysUnwritableFolderProbe()
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .cloud)
        XCTAssertTrue(report.blockers.contains(where: {
            if case .outputFolderUnwritable = $0 { return true } else { return false }
        }))
    }

    func testSyncedStorageOutputBlocksRecording() async {
        let outputRoot = URL(fileURLWithPath: "/Users/example/Library/Mobile Documents/com~apple~CloudDocs/Transcriber")
        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .granted, screen: .granted, calendar: .granted),
            engine: StubEngine(cloudKey: true),
            folder: HeuristicOnlyFolderProbe()
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .cloud)
        XCTAssertTrue(report.blockers.contains(where: {
            if case .outputFolderInSyncedStorage(_, let hint) = $0 { return hint == "iCloud Drive" }
            return false
        }), "synced storage parents must block recording (silent file conflicts mid-call would be worse than aborting)")
    }

    // MARK: warnings

    func testCalendarDeniedSurfacesWarningNotBlocker() async {
        let outputRoot = makeWritableTempDir()
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .granted, screen: .granted, calendar: .denied),
            engine: StubEngine(cloudKey: true)
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .cloud)
        XCTAssertEqual(report.blockers, [], "spec line 88 + 333: calendar denial NEVER blocks recording")
        XCTAssertTrue(report.warnings.contains(.calendarDeniedOptional))
        XCTAssertEqual(RecordRequestGate().verdict(from: report), .allowWithWarnings(report.warnings))
    }

    func testCalendarNotDeterminedSurfacesWarning() async {
        let outputRoot = makeWritableTempDir()
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .granted, screen: .granted, calendar: .notDetermined),
            engine: StubEngine(cloudKey: true)
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .cloud)
        XCTAssertEqual(report.blockers, [])
        XCTAssertTrue(report.warnings.contains(.calendarNotDetermined))
    }

    // MARK: gate

    func testGateMapsBlockersToDeny() {
        let report = PreflightReport(blockers: [.microphoneDenied], warnings: [.calendarDeniedOptional])
        XCTAssertEqual(RecordRequestGate().verdict(from: report), .deny([.microphoneDenied]),
                       "blockers always win over warnings")
    }

    func testGateAllowsCleanReports() {
        let report = PreflightReport(blockers: [], warnings: [])
        XCTAssertEqual(RecordRequestGate().verdict(from: report), .allow)
    }

    func testReasonsAreIndividuallyAddressableForUI() async {
        // The popover deep-links per-permission. If reasons collapsed into a
        // single "deny" boolean we couldn't render which fix to suggest first.
        let outputRoot = makeWritableTempDir()
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .denied, screen: .denied, calendar: .denied),
            engine: StubEngine(cloudKey: false)
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .cloud)
        XCTAssertTrue(report.blockers.contains(.microphoneDenied))
        XCTAssertTrue(report.blockers.contains(.screenRecordingDenied))
        XCTAssertTrue(report.blockers.contains(.missingCloudAPIKey))
        XCTAssertTrue(report.warnings.contains(.calendarDeniedOptional))
    }
}

// MARK: - Stubs

private struct StubPermissions: PermissionStatusProbing {
    let mic: PermissionStatus
    let screen: PermissionStatus
    let cal: PermissionStatus

    init(mic: PermissionStatus, screen: PermissionStatus, calendar: PermissionStatus) {
        self.mic = mic
        self.screen = screen
        self.cal = calendar
    }

    func microphone() async -> PermissionStatus { mic }
    func screenRecording() async -> PermissionStatus { screen }
    func calendar() async -> PermissionStatus { cal }
}

private struct StubEngine: EngineReadinessProbing {
    let cloudKey: Bool
    let localBinary: URL?
    let localModel: URL?
    let binaryReady: Bool
    let modelReady: Bool

    init(
        cloudKey: Bool,
        localBinary: URL? = nil,
        localModel: URL? = nil,
        binaryReady: Bool = false,
        modelReady: Bool = false
    ) {
        self.cloudKey = cloudKey
        self.localBinary = localBinary
        self.localModel = localModel
        self.binaryReady = binaryReady
        self.modelReady = modelReady
    }

    func cloudKeyAvailable() async -> Bool { cloudKey }
    func localEngineBinaryURL() -> URL? { localBinary }
    func localLanguageModelURL() -> URL? { localModel }
    func localBinaryReady(_ url: URL) async -> Bool { binaryReady }
    func localModelReady(_ url: URL) async -> Bool { modelReady }
}

private struct AlwaysUnwritableFolderProbe: OutputFolderProbing {
    func isWritable(_ url: URL) async -> Bool { false }
    func syncedStorageHint(_ url: URL) -> String? { nil }
}

private struct HeuristicOnlyFolderProbe: OutputFolderProbing {
    // For the synced-storage test we need writability to NOT short-circuit.
    func isWritable(_ url: URL) async -> Bool { true }
    func syncedStorageHint(_ url: URL) -> String? {
        DefaultOutputFolderProbe().syncedStorageHint(url)
    }
}
