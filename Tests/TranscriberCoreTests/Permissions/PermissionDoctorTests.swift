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
                      "screen/system audio is required per spec line 339 (no mic-only fallback)")
        XCTAssertEqual(PreflightReason.systemAudioRequiredMessage, "System Audio is required to capture other people in calls.")
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

    func testUnavailableLocalModelStatesBlockLocalModeWithRepairGuidance() async {
        let blockingStates: [LocalModelCacheStatus] = [
            .notDownloaded(modelID: CohereMLXBackend.modelID),
            .downloading(modelID: CohereMLXBackend.modelID, progress: LocalModelDownloadProgress(completedBytes: 10, totalBytes: 100)),
            .verifying(modelID: CohereMLXBackend.modelID),
            .failed(
                modelID: CohereMLXBackend.modelID,
                reason: LocalModelFailure(code: .verificationFailed, message: "Checksum mismatch"),
                retryAvailable: true
            )
        ]

        for status in blockingStates {
            let outputRoot = makeWritableTempDir()
            defer { try? FileManager.default.removeItem(at: outputRoot) }
            let doctor = PermissionDoctor(
                permissions: StubPermissions(mic: .granted, screen: .granted, calendar: .granted),
                engine: StubEngine(cloudKey: true, localStatus: status)
            )
            let report = await doctor.audit(outputRoot: outputRoot, engineMode: .local)
            XCTAssertEqual(report.blockers, [.localModelNotVerified(modelID: CohereMLXBackend.modelID)], "Unexpected blockers for \(status)")
            XCTAssertEqual(RecordRequestGate().verdict(from: report), .deny(report.blockers))
        }
    }

    func testVerifiedLocalModelAllowsLocalModeWithoutCloudKey() async {
        let outputRoot = makeWritableTempDir()
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .granted, screen: .granted, calendar: .granted),
            engine: StubEngine(
                cloudKey: false,
                localStatus: .verified(LocalModelCacheInfo(modelID: CohereMLXBackend.modelID, cacheURL: outputRoot, diskUsageBytes: 1))
            )
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .local)
        XCTAssertEqual(report.blockers, [])
        XCTAssertEqual(RecordRequestGate().verdict(from: report), .allow)
    }

    func testUnsupportedLocalRuntimeBlocksWithoutCloudFallback() async {
        let outputRoot = makeWritableTempDir()
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let probe = StubEngine(
            cloudKey: true,
            localStatus: .unsupported(
                modelID: CohereMLXBackend.modelID,
                reason: LocalModelFailure(code: .unsupportedRuntime, message: "No MLX runtime")
            )
        )
        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .granted, screen: .granted, calendar: .granted),
            engine: probe
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .local)
        XCTAssertEqual(report.blockers, [.localRuntimeUnavailable])
    }


    func testRemovedLocalCacheBlocksSelectedLocalWithoutCloudFallback() async {
        let outputRoot = makeWritableTempDir()
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .granted, screen: .granted, calendar: .granted),
            engine: StubEngine(cloudKey: true, localStatus: .notDownloaded(modelID: CohereMLXBackend.modelID))
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .local)
        XCTAssertEqual(report.blockers, [.localModelNotVerified(modelID: CohereMLXBackend.modelID)])
    }

    func testCloudMissingKeyBlocksEvenWhenLocalIsVerified() async {
        let outputRoot = makeWritableTempDir()
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .granted, screen: .granted, calendar: .granted),
            engine: StubEngine(
                cloudKey: false,
                localStatus: .verified(LocalModelCacheInfo(modelID: CohereMLXBackend.modelID, cacheURL: outputRoot, diskUsageBytes: 1))
            )
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .cloud)
        XCTAssertEqual(report.blockers, [.missingCloudAPIKey])
    }

    func testRequiredCapturePrerequisitesBlockBothEnginesWhileRecommendedWarnOnly() async {
        let outputRoot = makeWritableTempDir()
        defer { try? FileManager.default.removeItem(at: outputRoot) }
        let localReady = StubEngine(
            cloudKey: true,
            localStatus: .verified(LocalModelCacheInfo(modelID: CohereMLXBackend.modelID, cacheURL: outputRoot, diskUsageBytes: 1))
        )

        for mode in [EngineMode.cloud, .local] {
            let doctor = PermissionDoctor(
                permissions: StubPermissions(mic: .denied, screen: .denied, calendar: .denied, notifications: .denied),
                engine: localReady,
                folder: AlwaysUnwritableFolderProbe()
            )
            let report = await doctor.audit(outputRoot: outputRoot, engineMode: mode)
            XCTAssertTrue(report.blockers.contains(.microphoneDenied))
            XCTAssertTrue(report.blockers.contains(.screenRecordingDenied))
            XCTAssertTrue(report.blockers.contains(where: { if case .outputFolderUnwritable = $0 { return true }; return false }))
            XCTAssertTrue(report.warnings.contains(.calendarDeniedOptional))
            XCTAssertTrue(report.warnings.contains(.notificationsDeniedOptional))
            XCTAssertEqual(RecordRequestGate().verdict(from: report), .deny(report.blockers))
        }
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

    func testSyncedStorageOutputSurfacesWarningPerSpec() async {
        // Spec line 231 says "Warn" not "block" for synced storage — codex
        // Phase α review P1.1.
        let outputRoot = URL(fileURLWithPath: "/Users/example/Library/Mobile Documents/com~apple~CloudDocs/Scribe")
        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .granted, screen: .granted, calendar: .granted),
            engine: StubEngine(cloudKey: true),
            folder: HeuristicOnlyFolderProbe()
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .cloud)
        XCTAssertEqual(report.blockers, [],
                       "synced storage must NOT block per spec line 231")
        XCTAssertTrue(report.warnings.contains(where: {
            if case .outputFolderInSyncedStorage(_, let hint) = $0 { return hint == "iCloud Drive" }
            return false
        }), "synced storage surfaces a warning so the user knows about possible file conflicts")
    }

    func testCloudStorageHeuristicCoversModernMacOSPaths() {
        // macOS 12+ uses ~/Library/CloudStorage/ for File Provider mirrored
        // folders. Codex Phase α review P1.2 caught that the original
        // heuristic missed every modern Drive/OneDrive/Dropbox install.
        let probe = DefaultOutputFolderProbe()
        XCTAssertEqual(probe.syncedStorageHint(URL(fileURLWithPath: "/Users/me/Library/CloudStorage/GoogleDrive-me@example.com/My Drive/Scribe")),
                       "Google Drive")
        XCTAssertEqual(probe.syncedStorageHint(URL(fileURLWithPath: "/Users/me/Library/CloudStorage/OneDrive-Personal/Scribe")),
                       "OneDrive")
        XCTAssertEqual(probe.syncedStorageHint(URL(fileURLWithPath: "/Users/me/Library/CloudStorage/Dropbox/Scribe")),
                       "Dropbox")
        XCTAssertEqual(probe.syncedStorageHint(URL(fileURLWithPath: "/Users/me/Library/CloudStorage/Box/Scribe")),
                       "Box")
        XCTAssertEqual(probe.syncedStorageHint(URL(fileURLWithPath: "/Users/me/Dropbox (Personal)/Scribe")),
                       "Dropbox")
        XCTAssertNil(probe.syncedStorageHint(URL(fileURLWithPath: "/Users/me/Documents/Scribe")),
                     "ordinary Documents folder must not false-positive")
    }


    func testRecommendedCalendarAndNotificationsSurfaceWarningsNotBlockers() async {
        let outputRoot = makeWritableTempDir()
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .granted, screen: .granted, calendar: .denied, notifications: .denied),
            engine: StubEngine(
                cloudKey: false,
                localStatus: .verified(LocalModelCacheInfo(modelID: CohereMLXBackend.modelID, cacheURL: outputRoot, diskUsageBytes: 1))
            )
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .local)
        XCTAssertEqual(report.blockers, [], "recommended permissions must never block recording when required prerequisites and selected engine are ready")
        XCTAssertTrue(report.warnings.contains(.calendarDeniedOptional))
        XCTAssertTrue(report.warnings.contains(.notificationsDeniedOptional))
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

    func testNotificationsNotDeterminedSurfacesWarning() async {
        let outputRoot = makeWritableTempDir()
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let doctor = PermissionDoctor(
            permissions: StubPermissions(mic: .granted, screen: .granted, calendar: .granted, notifications: .notDetermined),
            engine: StubEngine(cloudKey: true)
        )
        let report = await doctor.audit(outputRoot: outputRoot, engineMode: .cloud)
        XCTAssertEqual(report.blockers, [])
        XCTAssertTrue(report.warnings.contains(.notificationsNotDetermined))
        XCTAssertEqual(RecordRequestGate().verdict(from: report), .allowWithWarnings(report.warnings))
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
    let notificationsStatus: PermissionStatus

    init(mic: PermissionStatus, screen: PermissionStatus, calendar: PermissionStatus, notifications: PermissionStatus = .granted) {
        self.mic = mic
        self.screen = screen
        self.cal = calendar
        self.notificationsStatus = notifications
    }

    func microphone() async -> PermissionStatus { mic }
    func screenRecording() async -> PermissionStatus { screen }
    func calendar() async -> PermissionStatus { cal }
    func notifications() async -> PermissionStatus { notificationsStatus }
}

private struct StubEngine: EngineReadinessProbing {
    let cloudKey: Bool
    let localStatus: LocalModelCacheStatus
    let modelID: String

    init(
        cloudKey: Bool,
        localStatus: LocalModelCacheStatus = .notDownloaded(modelID: CohereMLXBackend.modelID),
        modelID: String = CohereMLXBackend.modelID
    ) {
        self.cloudKey = cloudKey
        self.localStatus = localStatus
        self.modelID = modelID
    }

    func cloudKeyAvailable() async -> Bool { cloudKey }
    func localModelStatus() async -> LocalModelCacheStatus { localStatus }
    func localModelID() -> String { modelID }
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
