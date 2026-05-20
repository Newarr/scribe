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

        guard let promptRange = source.range(of: "private func presentStartPrompt") else {
            return XCTFail("meeting detection prompt handler must exist")
        }
        let promptBody = String(source[promptRange.lowerBound..<source.index(promptRange.lowerBound, offsetBy: min(2600, source.distance(from: promptRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(promptBody.contains("await startRecording()"), "meeting prompt Start Recording must enter the same startRecording preflight denial path as manual Record Now")

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


    func testPromptStartCarriesCalendarEventIntoRecordingStartWhenCalendarLaterUnavailable() throws {
        let source = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("private var pendingPromptCalendarEventForStart: CalendarEvent?"))
        XCTAssertTrue(source.contains("pendingPromptCalendarEventForStart = event"))
        XCTAssertTrue(source.contains("let promptedEvent = pendingPromptCalendarEventForStart"), "prompt Start Recording must preserve the enriched event instead of depending on a second calendar lookup that may be denied/unavailable")
    }

    func testPendingPromptRecoveryUsesLateJoinCopyAndAppleCalendarSource() throws {
        let source = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Self.promptRecoveryTitle(for: app, event: event)"))
        XCTAssertTrue(source.contains("Recording will capture from now onward."))
        XCTAssertTrue(source.contains("From Apple Calendar · \\(app.displayName)."))
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

    func testRetrySuccessResetsAppAndMenuToIdle() throws {
        let source = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)

        guard let retryRange = source.range(of: "private func retryFailedSession(at sessionURL: URL) async") else {
            return XCTFail("AppDelegate must keep failed-session retry routed through a visible state transition")
        }
        let body = String(source[retryRange.lowerBound..<source.index(retryRange.lowerBound, offsetBy: min(2200, source.distance(from: retryRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(body.contains("case .complete:"), "Retry completion must handle successful workers explicitly.")
        XCTAssertTrue(body.contains("status = .idle"), "Successful retry must return app status to idle instead of finalized/transcribing.")
        XCTAssertTrue(body.contains("resetMenuAfterWorker(status: status)"), "Successful retry must clear active/finalized menu fields and rebuild the idle menu.")
        XCTAssertFalse(body.contains("case .complete:\n                status = .finalized"), "Successful retry must not leave the menu in finalized/transcribing state.")
    }

    func testSavedNotificationUsesCanonicalAudioAndExistingArtifacts() throws {
        let source = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("FileManager.default.fileExists(atPath: dir.transcript.path)"), "Saved notification must be suppressed until durable transcript exists.")
        XCTAssertTrue(source.contains("audioByteSize(at: dir.url.appendingPathComponent(\"audio.m4a\"))"), "Saved notification size must prefer canonical audio.m4a.")
        guard let sizeRange = source.range(of: "private nonisolated func totalAudioBytes") else {
            return XCTFail("AppDelegate must calculate saved notification audio size in one helper")
        }
        let sizeBody = String(source[sizeRange.lowerBound..<source.index(sizeRange.lowerBound, offsetBy: min(900, source.distance(from: sizeRange.lowerBound, to: source.endIndex)))])
        XCTAssertLessThan(
            sizeBody.distance(from: sizeBody.startIndex, to: sizeBody.range(of: "audio.m4a")?.lowerBound ?? sizeBody.endIndex),
            sizeBody.distance(from: sizeBody.startIndex, to: sizeBody.range(of: "dir.micFinal")?.lowerBound ?? sizeBody.endIndex),
            "Canonical audio.m4a must be checked before raw stream fallback."
        )
    }

    func testSavedNotificationActionsAreKeyboardAndVoiceOverReachable() throws {
        let source = try String(contentsOfFile: appSourcePath("SavedNotificationWindow.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("accessibilityLabel(\"Open saved recording folder\")"), "Open Folder action must have a meaningful VoiceOver label.")
        XCTAssertTrue(source.contains("accessibilityLabel(\"Open saved transcript\")"), "Open Transcript action must have a meaningful VoiceOver label.")
        XCTAssertTrue(source.contains("keyboardShortcut(\"o\", modifiers: [.command])"), "Open Folder action must be keyboard reachable.")
        XCTAssertTrue(source.contains("keyboardShortcut(\"t\", modifiers: [.command])"), "Open Transcript action must be keyboard reachable.")
        XCTAssertTrue(source.contains("accessibilityValue(\"\\(model.summary.title), \\(model.metaCaption)\")"), "Saved notification summary must expose useful VoiceOver value without transcript content.")
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

    func testEndedCallsInvalidatePendingPromptBeforeStaleActionsCanStartRecording() throws {
        let source = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("private var pendingPromptAppBundleID: String?"), "AppDelegate must track which prompt can be expired by recognition stale-state signals")
        XCTAssertTrue(source.contains("onCandidateEnded:"), "DetectionEngine stale-candidate callback must be wired into AppDelegate")
        XCTAssertTrue(source.contains("handleEndedDetectionCandidate"), "AppDelegate must handle ended-call notifications from recognition")
        XCTAssertTrue(source.contains("DetectionTriggerIdentity.matchesEndedCandidate"), "only the current trigger identity or the explicit calendar-to-app transition may be invalidated by an ended-call signal")

        guard let endedRange = source.range(of: "private func handleEndedDetectionCandidate") else {
            return XCTFail("ended candidate handler must exist")
        }
        let endedBody = String(source[endedRange.lowerBound..<source.index(endedRange.lowerBound, offsetBy: min(1400, source.distance(from: endedRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(endedBody.contains("startPromptCoordinator.expireActivePrompt(for: candidate)"), "ended calls must invalidate modal/notification/menu prompt workflow instead of leaving stale actions live")
        XCTAssertFalse(endedBody.contains("pendingPromptAppBundleID == candidate.app.bundleID"), "same-app candidates from a different meeting must not expire the active prompt")
        XCTAssertTrue(endedBody.contains("detectionPromptActive = false"), "ended calls must clear retained setup-blocked Meeting detected trust state")
        XCTAssertTrue(endedBody.contains("pendingPromptAppBundleID = nil"), "ended calls must clear the stale invalidation marker so later actions require fresh recognition")
        XCTAssertTrue(endedBody.contains("pendingPromptCalendarEventForStart = nil"), "ended calls must clear retained setup-blocked calendar context before stale menu Start Recording can retry")
        XCTAssertTrue(endedBody.contains("menu?.pendingPrompt = nil"), "ended calls must remove stale menu Start Recording / Not now recovery actions")
        XCTAssertTrue(endedBody.contains("applyTrustIcon()"), "ended calls must refresh the menu-bar trust surface after clearing retained recovery")

        guard let promptRange = source.range(of: "private func presentStartPrompt") else {
            return XCTFail("prompt presentation route must exist")
        }
        let promptBody = String(source[promptRange.lowerBound..<source.index(promptRange.lowerBound, offsetBy: min(2600, source.distance(from: promptRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(promptBody.contains("pendingPromptAppBundleID = app.bundleID"), "prompt presentation must mark the active app for stale invalidation")
        XCTAssertTrue(promptBody.contains("pendingPromptAppBundleID = nil"), "any terminal prompt resolution must clear the stale invalidation marker")
    }

    func testEndedCurrentRecordingRoutesToEndGuardStopPrompt() throws {
        let source = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("private var endGuard: EndGuard?"), "AppDelegate must own the recording end guard")
        XCTAssertTrue(source.contains("private let endCountdownController = EndCountdownWindowController()"), "AppDelegate must own the stop-prompt HUD")
        XCTAssertTrue(source.contains("await endGuard?.suspectCallEnded(at: Date())"), "ended-call recognition during recording must enter the stop-prompt flow")
        XCTAssertTrue(source.contains("await startEndGuard(startedAt:"), "recording start must arm the end guard")
        XCTAssertTrue(source.contains("endGuard.observeAudioLevel"), "live mic/system levels must feed the silence fallback")
        XCTAssertTrue(source.contains("keepRecordingFromEndPrompt"), "stop prompt must expose Keep Recording")
        XCTAssertTrue(source.contains("stopRecordingFromEndPrompt"), "stop prompt must expose Stop Now")
    }

    func testMenuEndPromptActionsCarryGeneration() throws {
        let menuSource = try String(contentsOfFile: appSourcePath("RecordingMenu.swift"), encoding: .utf8)
        XCTAssertTrue(menuSource.contains("let generation: Int"), "menu prompt model must retain the prompt generation")
        XCTAssertTrue(menuSource.contains("case endPromptKeepRecording(generation: Int)"), "Keep Recording menu actions must be prompt-scoped")
        XCTAssertTrue(menuSource.contains("case endPromptStopNow(generation: Int)"), "Stop Now menu actions must be prompt-scoped")
        XCTAssertTrue(menuSource.contains("onAction(.endPromptKeepRecording(generation: endPrompt.generation))"), "menu Keep Recording must send the captured generation")
        XCTAssertTrue(menuSource.contains("onAction(.endPromptStopNow(generation: endPrompt.generation))"), "menu Stop Now must send the captured generation")

        let appSource = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)
        guard let keepRange = appSource.range(of: "case .endPromptKeepRecording(let generation):"),
              let stopRange = appSource.range(of: "case .endPromptStopNow(let generation):") else {
            return XCTFail("AppDelegate must route prompt-scoped menu actions")
        }
        let actionBody = String(appSource[keepRange.lowerBound..<appSource.index(stopRange.upperBound, offsetBy: min(160, appSource.distance(from: stopRange.upperBound, to: appSource.endIndex)))])
        XCTAssertFalse(actionBody.contains("activeEndPromptGeneration"), "menu actions must not read the live prompt generation at click handling time")
    }

    func testPromptStartClearsRecoveryAndUsesExactlyOneManualStartRoute() throws {
        let source = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)

        guard let promptRange = source.range(of: "private func presentStartPrompt") else {
            return XCTFail("prompt Start Recording handler must be factored for source-inspection")
        }
        let promptBody = String(source[promptRange.lowerBound..<source.index(promptRange.lowerBound, offsetBy: min(2600, source.distance(from: promptRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(promptBody.contains("case .start:"), "prompt handler must handle Start Recording decisions")
        XCTAssertTrue(promptBody.contains("await startRecording()"), "prompt Start Recording must enter the normal manual Record Now startRecording route")
        XCTAssertEqual(promptBody.components(separatedBy: "await startRecording()").count - 1, 1, "one prompt decision must invoke the normal start route exactly once")
        XCTAssertTrue(promptBody.contains("detectionPromptActive = false"), "explicit prompt resolution must clear Meeting detected trust state before recording starts")
        XCTAssertTrue(promptBody.contains("menu?.pendingPrompt = nil"), "explicit prompt resolution must clear stale menu recovery actions")

        guard let startRange = source.range(of: "private func startRecording(allowPendingPrivacyAcknowledgementForOnboardingTest: Bool = false) async") else {
            return XCTFail("normal startRecording route must exist")
        }
        let startBody = String(source[startRange.lowerBound..<source.index(startRange.lowerBound, offsetBy: min(7600, source.distance(from: startRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(startBody.contains("guard status != .recording, status != .starting"), "normal start route must guard against duplicate capture sessions")
        XCTAssertTrue(startBody.contains("let report = await preflightDoctor.audit"), "normal start route must surface preflight blockers for prompt and manual starts")
        XCTAssertTrue(startBody.contains("try await session.start()"), "normal start route must be the capture session start point")
    }

    func testActiveRecordingQueuesCandidateAndReevaluatesAfterStop() throws {
        let source = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("private struct QueuedDetectionCandidate"), "AppDelegate must store queued candidates while recording.")
        XCTAssertTrue(source.contains("private var queuedDetectionCandidate"), "AppDelegate must retain exactly one active-recording queued candidate.")
        XCTAssertTrue(source.contains("queueDetectionCandidate(candidate, event: event)"), "detection during recording must queue instead of dropping.")
        XCTAssertTrue(source.contains("menu?.queuedNextMeeting = RecordingMenuQueuedMeeting"), "queued context must be surfaced to the active recording popover.")
        XCTAssertTrue(source.contains("reevaluateQueuedDetectionCandidateAfterStop()"), "stop flow must re-evaluate queued candidates after the active session is finalized to durable audio.")
        XCTAssertTrue(source.contains("queued.isStillActive(at: now)"), "expired queued calendar candidates must be dropped after stop.")
        XCTAssertTrue(source.contains("releaseActiveCandidate(queued.candidate)"), "still-active queued candidates must be allowed to prompt again after coalescing during recording.")
        XCTAssertTrue(source.contains("detectionEngine?.reevaluate(queued.app)"), "still-active queued candidates must pass through detection re-evaluation after stop instead of prompting stale state directly.")

        guard let handlerRange = source.range(of: "func handleDetectionCandidate") else {
            return XCTFail("detection handler must exist")
        }
        let handlerBody = String(source[handlerRange.lowerBound..<source.index(handlerRange.lowerBound, offsetBy: min(900, source.distance(from: handlerRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(handlerBody.contains("if status == .recording || status == .starting"), "active recording and starting states must suppress intrusive prompts")
        XCTAssertFalse(handlerBody.contains("startPromptCoordinator.prompt"), "active recording branch must not present a new prompt directly")
    }

    func testPromptStopPathWritesPendingTranscriptBeforeQueueReevaluation() throws {
        let source = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)
        guard let stopRange = source.range(of: "private func stopRecording() async") else {
            return XCTFail("stopRecording route must exist")
        }
        let stopBody = String(source[stopRange.lowerBound..<source.index(stopRange.lowerBound, offsetBy: min(5200, source.distance(from: stopRange.lowerBound, to: source.endIndex)))])
        guard let stopCall = stopBody.range(of: "try await session.stop()"),
              let pendingWrite = stopBody.range(of: "TranscriptWriter.writePending"),
              let workerCreation = stopBody.range(of: "let worker = Self.makeWorker"),
              let queueReeval = stopBody.range(of: "reevaluateQueuedDetectionCandidateAfterStop()") else {
            return XCTFail("stopRecording must stop capture, write pending transcript, create worker, and then re-evaluate queue")
        }
        XCTAssertLessThan(stopBody.distance(from: stopBody.startIndex, to: stopCall.lowerBound), stopBody.distance(from: stopBody.startIndex, to: pendingWrite.lowerBound), "durable capture stop/finalize must precede transcript state writes")
        XCTAssertLessThan(stopBody.distance(from: stopBody.startIndex, to: pendingWrite.lowerBound), stopBody.distance(from: stopBody.startIndex, to: workerCreation.lowerBound), "pending transcript must be written before transcription worker runs")
        XCTAssertLessThan(stopBody.distance(from: stopBody.startIndex, to: workerCreation.lowerBound), stopBody.distance(from: stopBody.startIndex, to: queueReeval.lowerBound), "queued prompt re-evaluation must wait until the stopped recording has a durable worker path")
    }

    func testAppDelegateMakeContextPropagatesCalendarOccurrenceIdentity() throws {
        let source = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)

        guard let contextRange = source.range(of: "nonisolated static func makeContext") else {
            return XCTFail("AppDelegate.makeContext must exist")
        }
        let body = String(source[contextRange.lowerBound..<source.index(contextRange.lowerBound, offsetBy: min(1600, source.distance(from: contextRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(body.contains("calendarEventID: event?.calendarEventID"), "makeContext must propagate event ID plus occurrence start into TranscriptContext.calendarEventID")
    }

    func testCalendarLookupMapsEventKitIdentifierAndOccurrenceDate() throws {
        let source = try String(contentsOfFile: coreSourcePath("Calendar/CalendarLookup.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("eventIdentifier: ek.eventIdentifier"), "CalendarLookup must preserve EventKit eventIdentifier")
        XCTAssertTrue(source.contains("occurrenceStartDate: ek.occurrenceDate ?? ek.startDate"), "CalendarLookup must preserve recurring occurrence identity")
    }

    private func appSourcePath(_ file: String) -> String {
        repoRoot()
            .appendingPathComponent("TranscriberApp/Scribe")
            .appendingPathComponent(file)
            .path
    }

    private func coreSourcePath(_ file: String) -> String {
        repoRoot()
            .appendingPathComponent("Sources/TranscriberCore")
            .appendingPathComponent(file)
            .path
    }

    private func repoRoot() -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        return testFile
            .deletingLastPathComponent() // Recovery
            .deletingLastPathComponent() // TranscriberCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

}
