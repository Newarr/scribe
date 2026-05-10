import XCTest
@testable import TranscriberCore

final class SessionRepairRoutingTests: XCTestCase {
    func testLocalUnavailableRecoveryNoticeUsesSessionSpecificRepairWithoutTranscribingCopy() {
        let session = URL(fileURLWithPath: "/tmp/scribe-local-session", isDirectory: true)
        var result = SessionSupervisor.ScanResult()
        result.rescued = 1
        result.skipped = 1
        result.localSetupRequired = 1
        result.localSetupRequiredSessions = [session]

        let notice = SessionRepairRouting.recoveryNotice(for: result)

        XCTAssertEqual(notice?.transcribingStarted, false)
        XCTAssertEqual(notice?.localRepairPayloads, [
            SessionRepairRouting.LocalRepairPayload(
                sessionDirectory: session,
                reason: "Cohere setup is required before this recovered Local session can be transcribed."
            )
        ])
        XCTAssertFalse(notice?.message.localizedCaseInsensitiveContains("being transcribed") ?? true)
        XCTAssertTrue(notice?.message.contains("Cohere setup is required") ?? false)
    }

    func testNormalRecoveryNoticeKeepsTranscribingCopyWhenWorkerStarts() {
        var result = SessionSupervisor.ScanResult()
        result.rescued = 1
        result.resumed = 1

        let notice = SessionRepairRouting.recoveryNotice(for: result)

        XCTAssertEqual(notice?.transcribingStarted, true)
        XCTAssertTrue(notice?.message.contains("being transcribed now") ?? false)
        XCTAssertEqual(notice?.localRepairPayloads, [])
    }

    func testRetryLocalSetupRequiredRoutesToSessionSpecificCohereRepair() {
        let session = URL(fileURLWithPath: "/tmp/failed-local", isDirectory: true)

        let route = SessionRepairRouting.routeRetry(
            sessionDirectory: session,
            error: .localSetupRequired,
            savedAudioExists: true,
            persistedEngine: "cohere"
        )

        XCTAssertEqual(route, .localSetupRequired(SessionRepairRouting.LocalRepairPayload(
            sessionDirectory: session,
            reason: "Cohere setup is required before retrying this Local session."
        )))
    }

    func testFailedRecentWithoutSavedAudioExposesRepairAndSavedAudioFailureExposesRetry() {
        let noAudio = SessionFolderEnumerator.Entry(
            directory: URL(fileURLWithPath: "/tmp/no-audio", isDirectory: true),
            transcript: URL(fileURLWithPath: "/tmp/no-audio/transcript.md"),
            title: "No audio",
            status: .failed,
            createdAt: Date(timeIntervalSince1970: 0),
            durationSeconds: nil,
            hasSavedAudio: false,
            engineIdentifier: "cohere"
        )
        let withAudio = SessionFolderEnumerator.Entry(
            directory: URL(fileURLWithPath: "/tmp/with-audio", isDirectory: true),
            transcript: URL(fileURLWithPath: "/tmp/with-audio/transcript.md"),
            title: "With audio",
            status: .failed,
            createdAt: Date(timeIntervalSince1970: 0),
            durationSeconds: nil,
            hasSavedAudio: true,
            engineIdentifier: "cohere"
        )

        XCTAssertEqual(SessionRepairRouting.recentAction(for: noAudio), .repair(SessionRepairRouting.LocalRepairPayload(
            sessionDirectory: noAudio.directory,
            reason: "Saved audio is missing; open setup to repair this failed session before retrying."
        )))
        XCTAssertEqual(SessionRepairRouting.recentAction(for: withAudio), .retry(sessionDirectory: withAudio.directory))
    }



    func testFailedLocalRecentWithSavedAudioShowsLoadingWhileReadinessIsUnknown() {
        let entry = SessionFolderEnumerator.Entry(
            directory: URL(fileURLWithPath: "/tmp/local-loading", isDirectory: true),
            transcript: URL(fileURLWithPath: "/tmp/local-loading/transcript.md"),
            title: "Local loading",
            status: .failed,
            createdAt: Date(timeIntervalSince1970: 0),
            durationSeconds: nil,
            hasSavedAudio: true,
            engineIdentifier: "cohere"
        )

        XCTAssertEqual(
            SessionRepairRouting.recentAction(for: entry, localModelReady: nil),
            .loading(sessionDirectory: entry.directory)
        )
    }

    func testFailedLocalRecentWithSavedAudioRoutesToRetryOnlyWhenLocalReady() {
        let entry = SessionFolderEnumerator.Entry(
            directory: URL(fileURLWithPath: "/tmp/local-ready", isDirectory: true),
            transcript: URL(fileURLWithPath: "/tmp/local-ready/transcript.md"),
            title: "Local failed",
            status: .failed,
            createdAt: Date(timeIntervalSince1970: 0),
            durationSeconds: nil,
            hasSavedAudio: true,
            engineIdentifier: "cohere"
        )

        XCTAssertEqual(SessionRepairRouting.recentAction(for: entry, localModelReady: true), .retry(sessionDirectory: entry.directory))
        XCTAssertEqual(SessionRepairRouting.recentAction(for: entry, localModelReady: false), .repair(SessionRepairRouting.LocalRepairPayload(
            sessionDirectory: entry.directory,
            reason: "Cohere setup is required before retrying this Local session."
        )))
    }

    func testFailedCloudRecentWithSavedAudioRemainsRetryRegardlessOfLocalReadiness() {
        let entry = SessionFolderEnumerator.Entry(
            directory: URL(fileURLWithPath: "/tmp/cloud-failed", isDirectory: true),
            transcript: URL(fileURLWithPath: "/tmp/cloud-failed/transcript.md"),
            title: "Cloud failed",
            status: .failed,
            createdAt: Date(timeIntervalSince1970: 0),
            durationSeconds: nil,
            hasSavedAudio: true,
            engineIdentifier: "elevenlabs"
        )

        XCTAssertEqual(SessionRepairRouting.recentAction(for: entry, localModelReady: false), .retry(sessionDirectory: entry.directory))
    }


    func testVisiblePreflightDenialUsesExactReportForSetupFocusBeforeShowingPopover() throws {
        let source = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("showSetupRequiredPopover(report: report, sessionRepairPayload: nil)"), "direct preflight denial must pass the exact denial report to the shared setup popover presenter")
        XCTAssertTrue(source.contains("setupRequiredEngineFocus(report: report, sessionRepairPayload:"), "shared presenter must derive setup focus from the current report/payload")
        XCTAssertTrue(source.contains("setupEngineFocus = setupRequiredEngineFocus(report: report, sessionRepairPayload: payload)"), "setup focus must be assigned immediately before showing the popover")
        XCTAssertFalse(source.contains("let steps = PermissionRemediation.steps(from: report)\n            if let anchor = statusItem?.button"), "preflight denial must not bypass shared focus derivation with an inline popover.show path")

        guard let denialRange = source.range(of: "case .deny(let reasons):") else {
            return XCTFail("startRecording preflight denial path must exist")
        }
        let denialBody = String(source[denialRange.lowerBound..<source.index(denialRange.lowerBound, offsetBy: min(1500, source.distance(from: denialRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(denialBody.contains("self.sessionRepairPayload = nil"), "manual/meeting preflight denial must clear stale session repair payload before routing current report")
        XCTAssertTrue(denialBody.contains("showSetupRequiredPopover(report: report, sessionRepairPayload: nil)"), "manual/meeting preflight denial must show Setup Required through shared current-report route")
        XCTAssertFalse(denialBody.contains("popover.show("), "manual/meeting preflight denial must not show Setup Required before deriving focus")
    }

    func testVisibleMeetingPromptStartSharesManualPreflightFocusRouting() throws {
        let source = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)

        guard let detectionRange = source.range(of: "func handleDetectionCandidate") else {
            return XCTFail("meeting detection prompt handler must exist")
        }
        let detectionBody = String(source[detectionRange.lowerBound..<source.index(detectionRange.lowerBound, offsetBy: min(1800, source.distance(from: detectionRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(detectionBody.contains("await startRecording()"), "meeting prompt Start Recording must enter the same startRecording preflight denial path as manual Record Now")

        guard let startRange = source.range(of: "private func startRecording(allowPendingPrivacyAcknowledgementForOnboardingTest: Bool = false) async") else {
            return XCTFail("startRecording must exist")
        }
        let startBody = String(source[startRange.lowerBound..<source.index(startRange.lowerBound, offsetBy: min(5200, source.distance(from: startRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(startBody.contains("let report = await preflightDoctor.audit"), "startRecording must derive a fresh current preflight report")
        XCTAssertTrue(startBody.contains("showSetupRequiredPopover(report: report, sessionRepairPayload: nil)"), "meeting/manual denial must pass the exact current preflight report into setup routing")
    }

    func testSetupReportForSessionRepairPayloadUsesCohereBeforeCurrentSettings() {
        let session = URL(fileURLWithPath: "/tmp/recovered-local", isDirectory: true)
        let payload = SessionRepairRouting.LocalRepairPayload(
            sessionDirectory: session,
            modelID: "beshkenadze/cohere-transcribe-03-2026-mlx-fp16",
            reason: "Cohere setup is required before this recovered Local session can be transcribed."
        )

        let report = SessionRepairRouting.setupReport(for: payload)

        XCTAssertEqual(report.blockers, [.localModelNotVerified(modelID: payload.modelID)])
        XCTAssertEqual(report.warnings, [])
    }

    func testVisibleAppDelegateSetupPopoverPrioritizesSessionRepairPayloadBeforeCurrentSettingsAudit() throws {
        let source = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)

        guard let range = source.range(of: "private func presentSetupRequiredPopover() async") else {
            return XCTFail("presentSetupRequiredPopover must exist")
        }
        let body = String(source[range.lowerBound..<source.index(range.lowerBound, offsetBy: min(900, source.distance(from: range.lowerBound, to: source.endIndex)))])

        XCTAssertTrue(body.contains("sessionRepairPayload"), "actual setup popover must consume the session-specific repair payload")
        XCTAssertTrue(body.contains("SessionRepairRouting.setupReport"), "setup popover should use the tested routing helper for session repair payloads")
        guard let payloadIndex = body.range(of: "sessionRepairPayload")?.lowerBound,
              let auditIndex = body.range(of: "preflightDoctor.audit")?.lowerBound else {
            return XCTFail("setup popover must reference both sessionRepairPayload and current Settings preflight audit")
        }
        XCTAssertLessThan(
            body.distance(from: body.startIndex, to: payloadIndex),
            body.distance(from: body.startIndex, to: auditIndex),
            "session-specific repair payload must be checked before current Settings preflight audit"
        )
    }

    func testVisibleRecordingMenuRepairActionDispatchesThroughAppRouteInsteadOfFinder() throws {
        let source = try String(contentsOfFile: appSourcePath("RecordingMenu.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("case repairRecentFailedSession(URL)"), "RecordingMenu must expose a visible repair action routed to AppDelegate")
        XCTAssertTrue(source.contains("onRepair"), "MenuRow must receive a repair dispatcher instead of handling repair locally")
        XCTAssertTrue(source.contains("localModelStatusProvider"), "RecordingMenu must use the app-owned LocalModelManager/readiness source for Recents retry routing")
        XCTAssertTrue(source.contains("SessionRepairRouting.recentAction(for: entry, localModelReady:"), "failed Recent actions must pass readiness into the tested routing helper")
        XCTAssertTrue(source.contains("@Published var localModelReadyForRetry: Bool? = nil"), "RecordingMenu must represent unknown async readiness explicitly instead of defaulting to repair")
        XCTAssertTrue(source.contains("model.localModelReadyForRetry = nil"), "RecordingMenu must render loading/disabled state while app-owned LocalModelManager readiness is fetched")
        XCTAssertTrue(source.contains("Button(\"Checking…\")"), "Local failed Recents must show a disabled loading action while readiness is unknown")
        XCTAssertTrue(source.contains("onAction(.repairRecentFailedSession"), "failed Recent repair buttons must dispatch through the app action route")

        guard let repairButtonRange = source.range(of: "Button(\"Repair\")") else {
            return XCTFail("failed no-audio Recents must render a Repair button")
        }
        let snippet = String(source[repairButtonRange.lowerBound..<source.index(repairButtonRange.lowerBound, offsetBy: min(260, source.distance(from: repairButtonRange.lowerBound, to: source.endIndex)))])
        XCTAssertFalse(snippet.contains("NSWorkspace.shared.open"), "Repair must not be Finder/open-folder behavior")
    }


    func testRecordingMenuActiveLocalPrivacyBlockAndSnapshotStableEngineCopy() throws {
        let source = try String(contentsOfFile: appSourcePath("RecordingMenu.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("Audio: local"), "active privacy block must name local audio storage")
        XCTAssertTrue(source.contains("Captured: mic + system audio · no video, no screenshots"), "active privacy block must state captured sources and exclusions")
        XCTAssertTrue(source.contains("Engine:"), "active privacy block must include a full engine line")
        XCTAssertTrue(source.contains("Cohere (local)"), "Local sessions must display Cohere (local)")
        XCTAssertTrue(source.contains("ElevenLabs (cloud)"), "Cloud sessions must display ElevenLabs (cloud)")
        XCTAssertTrue(source.contains("sessionEngineMode"), "menu model must use a session-start engine snapshot")

        guard let localCopyRange = source.range(of: "case (_, .local):") else {
            return XCTFail("local active copy branch must exist")
        }
        let end = source[localCopyRange.upperBound...].range(of: "case (_, .cloud):")?.lowerBound ?? source.endIndex
        let localCopy = String(source[localCopyRange.lowerBound..<end])
        XCTAssertTrue(localCopy.contains("Cohere"))
        XCTAssertTrue(localCopy.localizedCaseInsensitiveContains("on this Mac"))
        for forbidden in ["upload", "cloud", "ElevenLabs"] {
            XCTAssertFalse(localCopy.localizedCaseInsensitiveContains(forbidden), "Local active/finalizing copy must not imply cloud/provider upload: \(localCopy)")
        }
    }

    func testAppDelegatePassesSessionEngineSnapshotToMenuAndSavedNotification() throws {
        let source = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("currentSessionEngineMode"), "AppDelegate must snapshot session engine at start")
        XCTAssertTrue(source.contains("menu?.sessionEngineMode = sessionEngineMode"), "active menu must be labelled from session snapshot")
        XCTAssertTrue(source.contains(#"let engineLabel = sessionEngineMode == .cloud ? "ElevenLabs" : "Cohere""#), "saved notification must use Cohere label for Local sessions")
        XCTAssertFalse(source.contains(#"engineLabel = "Local""#), "saved notification must not use generic Local label")
    }


    func testSavedNotificationTitleSuffixAndVisiblePanelRefreshWiring() throws {
        let appSource = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)
        let notificationSource = try String(contentsOfFile: appSourcePath("SavedNotificationWindow.swift"), encoding: .utf8)

        XCTAssertTrue(appSource.contains(#"title: "\(title) · transcript saved""#), "saved notification payload title must include transcript saved suffix")
        XCTAssertTrue(appSource.contains(#"let engineLabel = sessionEngineMode == .cloud ? "ElevenLabs" : "Cohere""#), "Local saved notification body must use Cohere label")
        XCTAssertTrue(notificationSource.contains("currentModel.summary = summary"), "visible saved notification panel must refresh its model when a newer transcript is saved")
        XCTAssertTrue(notificationSource.contains("self?.currentModel?.summary.folderURL"), "visible panel actions must read the refreshed model, not stale captured summary")
        XCTAssertTrue(notificationSource.contains("self?.currentModel?.summary.transcriptURL"), "visible panel transcript action must read the refreshed model")
    }

    func testNoStaleLocalBinaryRustOrWhisperCopyInModifiedAppSurfaces() throws {
        let files = ["RecordingMenu.swift", "AppDelegate.swift", "PermissionRecoveryView.swift", "SettingsWindow.swift", "DiagnosticsView.swift", "SavedNotificationWindow.swift"]
        let forbidden = ["local binary", "rust binary", "missing local binary", "Whisper-tiny", "cohere_transcribe_rs"]
        for file in files {
            let source = try String(contentsOfFile: appSourcePath(file), encoding: .utf8)
            for term in forbidden {
                XCTAssertFalse(source.localizedCaseInsensitiveContains(term), "stale Local setup copy '\(term)' leaked into \(file)")
            }
        }
    }

    func testProductRemainsRecordOnlyInModifiedAppSurfaces() throws {
        let files = ["RecordingMenu.swift", "AppDelegate.swift", "SettingsWindow.swift", "SavedNotificationWindow.swift"]
        let forbidden = ["Import audio", "Live transcript", "Transcript history", "Summarize", "Summaries", "Chat with", "Vector database", "Search transcripts", "Polish transcript"]
        for file in files {
            let source = try String(contentsOfFile: appSourcePath(file), encoding: .utf8)
            for term in forbidden {
                XCTAssertFalse(source.localizedCaseInsensitiveContains(term), "prohibited product surface '\(term)' appeared in \(file)")
            }
        }
    }

    func testModifiedScribeOwnedSurfacesUseConfidentialWindowTreatment() throws {
        let expected: [(String, String)] = [
            ("RecordingMenu.swift", "WindowChromeSharing.confidential"),
            ("AppDelegate.swift", "WindowChromeSharing.confidential"),
            ("DiagnosticsView.swift", "WindowChromeSharing.confidential"),
            ("SavedNotificationWindow.swift", "WindowChromeSharing.confidential"),
            ("PermissionRecoveryView.swift", "WindowChromeSharing.confidential"),
            ("SettingsWindow.swift", "WindowChromeSharing.confidential")
        ]
        for (file, marker) in expected {
            let source = try String(contentsOfFile: appSourcePath(file), encoding: .utf8)
            XCTAssertTrue(source.contains(marker), "\(file) must keep Scribe-owned windows confidential")
        }
    }

    private func appSourcePath(_ file: String) -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent() // Recovery
            .deletingLastPathComponent() // TranscriberCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        return repoRoot
            .appendingPathComponent("TranscriberApp/Scribe")
            .appendingPathComponent(file)
            .path
    }

}
