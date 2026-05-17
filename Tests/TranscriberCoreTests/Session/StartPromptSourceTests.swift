import XCTest

final class StartPromptSourceTests: XCTestCase {
    private var source: String {
        get throws {
            let path = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("TranscriberApp/Scribe/StartPromptCoordinator.swift")
            return try String(contentsOf: path, encoding: .utf8)
        }
    }

    func testModalFirstPromptActivatesScribeAndIsConfidential() throws {
        let source = try source
        XCTAssertTrue(source.contains("NSApp.activate(ignoringOtherApps: true)"))
        XCTAssertTrue(source.contains("PromptModalWindow.run"))
        XCTAssertTrue(source.contains("onWindowReady"))
    }

    func testPrimaryChoicesAreStartRecordingAndNotNowOnly() throws {
        let source = try source
        XCTAssertTrue(source.contains("primaryTitle: \"Start Recording\""))
        XCTAssertTrue(source.contains("secondaryTitle: \"Not now\""))
        XCTAssertFalse(source.contains("alert.addButton(withTitle: \"Stop detecting"))
    }

    func testStartRecordingIsNotImplicitDefaultButtonAction() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TranscriberApp/Scribe/PromptModalWindow.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(source.contains("panel.defaultButtonCell = nil"), "the prompt window must not install a default button cell that can start capture on focus/activation")
        XCTAssertFalse(source.contains(".keyboardShortcut"), "Start Recording must not be invokable by an implicit keyboard shortcut")
    }

    func testBackupNotificationUsesMatchingActionsWithoutSuppressionAction() throws {
        let source = try source
        XCTAssertTrue(source.contains("title: \"Start Recording\""))
        XCTAssertTrue(source.contains("title: \"Not now\""))
        XCTAssertFalse(source.contains("UNNotificationAction(\n                    identifier: Action.suppress"))
        XCTAssertTrue(source.contains("modal/menu recovery remain active"))
        XCTAssertTrue(source.contains("UNNotificationDismissActionIdentifier"))
    }

    func testModalPromptDoesNotExposeSuppressionDisclosure() throws {
        let source = try source
        XCTAssertFalse(source.contains("More options ▾"))
        XCTAssertFalse(source.contains("Stop detecting \\(appDisplayName) for 30 minutes"))
    }

    func testMenuRecoveryStillExposesSuppressionBehindDisclosure() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TranscriberApp/Scribe/RecordingMenu.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(source.contains("DisclosureGroup(\"More options ▾\")"))
        XCTAssertTrue(source.contains("Stop detecting \\(prompt?.appDisplayName ?? \"this app\") for 30 minutes"))
    }

    func testDismissalKeepsPromptSessionRecoverableUntilResolutionOrExpiry() throws {
        let source = try source
        XCTAssertTrue(source.contains("A close/Esc/dismissal is not an implicit decline"))
        XCTAssertTrue(source.contains("menu recovery remains active"))
        XCTAssertTrue(source.contains("scheduleRecoveryTimers(for: entry)"))
    }

    func testIgnoredPromptReminderAndExpiryTimersExist() throws {
        let source = try source
        XCTAssertTrue(source.contains("var reminderDelay: TimeInterval = 60"))
        XCTAssertTrue(source.contains("var expiryDelay: TimeInterval = 180"))
        XCTAssertTrue(source.contains("kind: .reminder"))
        XCTAssertTrue(source.contains("handleIgnoredPromptExpiry(promptID: promptID)"))
    }

    func testNotificationDismissalDoesNotResolvePrompt() throws {
        let source = try source
        XCTAssertTrue(source.contains("Start prompt notification dismissed without decision"))
        XCTAssertFalse(source.contains("UNNotificationDismissActionIdentifier:\n                self.resolve"))
    }

    func testMenuRecoveryActionsResolveActivePrompt() throws {
        let source = try source
        XCTAssertTrue(source.contains("chooseStartFromRecovery"))
        XCTAssertTrue(source.contains("chooseNotNowFromRecovery"))
        XCTAssertTrue(source.contains("chooseSuppressAppFromRecovery"))
        XCTAssertTrue(source.contains("Ignoring stale start-prompt menu recovery"))
    }

    func testEndedCallExpiryResolvesPendingPromptWithoutStartingRecording() throws {
        let source = try source
        XCTAssertTrue(source.contains("func expireActivePrompt(for candidate: DetectionCandidate)"), "prompt coordinator must expose a trigger-scoped stale-call expiry seam")
        XCTAssertTrue(source.contains("DetectionTriggerIdentity.matchesEndedCandidate"), "stale-call expiry must use the shared trigger-scoped matcher")
        XCTAssertFalse(source.contains("entry.candidate.triggerIdentity == candidate.triggerIdentity || entry.app.bundleID == candidate.app.bundleID"), "stale-call expiry must not fall back to broad same-app matching")
        XCTAssertTrue(source.contains("resolve(identifier: identifier, with: .skipForNow, removeNotifications: true)"), "ended calls should clear recovery like Not now rather than starting capture")
        XCTAssertTrue(source.contains("Ignoring stale start-prompt action"), "late modal/notification actions for expired prompt IDs must be inert")
    }

    func testPendingStateInstallsBeforeAsynchronousBackupNotification() throws {
        let source = try source
        let pendingRange = try XCTUnwrap(source.range(of: "pending[identifier] = entry"))
        let notificationRange = try XCTUnwrap(source.range(of: "postNotificationIfPossible("))
        let modalRange = try XCTUnwrap(source.range(of: "presentModalPrompt(identifier: identifier"))
        XCTAssertLessThan(pendingRange.lowerBound, notificationRange.lowerBound)
        XCTAssertLessThan(notificationRange.lowerBound, modalRange.lowerBound)
        XCTAssertTrue(source.contains("Task { @MainActor [weak self] in"), "backup notification posting should be asynchronous relative to modal presentation")
    }

    func testResolvedPromptDismissesVisibleModalRunLoop() throws {
        let source = try source
        XCTAssertTrue(source.contains("weak var modalWindow: NSWindow?"))
        XCTAssertTrue(source.contains("var isModalVisible = false"))
        XCTAssertTrue(source.contains("dismissModalIfVisible(for: entry)"))
        XCTAssertTrue(source.contains("entry.modalWindow?.orderOut(nil)"))
        XCTAssertTrue(source.contains("NSApp.stopModal(withCode: NSApplication.ModalResponse.abort)"))
        XCTAssertTrue(source.contains("Stopped visible start prompt modal after non-modal resolution"))
    }

    func testStaleAsyncNotificationCompletionCannotPostAfterPromptResolved() throws {
        let source = try source
        XCTAssertTrue(source.contains("guard pending[promptID] != nil else"))
        XCTAssertTrue(source.contains(#"Skipping stale start prompt \(kind.rawValue, privacy: .public) notification after authorization completed"#))
    }

    func testIgnoredPromptExpiryUsesCallActivitySeamForFinalReminder() throws {
        let source = try source
        XCTAssertTrue(source.contains("var callActivityChecker: @MainActor (MeetingApp) async -> Bool"), "expiry must use an injectable call-activity seam instead of untestable wall-clock/UI behavior")
        XCTAssertTrue(source.contains("CoreAudioInputProbe().isActive(bundleID: app.bundleID) == true"), "production seam should require a positive active-call signal")
        XCTAssertTrue(source.contains("await self?.handleIgnoredPromptExpiry(promptID: promptID)"), "expiry timer should route through a deterministic policy method")
        XCTAssertTrue(source.contains("guard callStillActive else"), "inactive or ended calls should take the safe expiry path")
        XCTAssertTrue(source.contains("kind: .finalReminder"), "still-active calls should get a distinct one-time final reminder")
        XCTAssertTrue(source.contains("entry.expiryTimer = nil"), "active-call final reminder must not schedule repeated expiry spam")
        XCTAssertTrue(source.contains("does not start recording, does not auto-decline"), "source should document that final reminder leaves the decision user-controlled")
    }

    func testInactiveExpiryClearsStaleActionsWithoutStartRecording() throws {
        let source = try source
        XCTAssertTrue(source.contains("Start prompt expired for inactive or ended call"))
        XCTAssertTrue(source.contains("clearing stale recovery actions"))
        XCTAssertTrue(source.contains("resolve(identifier: promptID, with: .skipForNow, removeNotifications: true)"))
        XCTAssertFalse(source.contains("resolve(identifier: promptID, with: .start"), "expiry must never auto-start recording")
    }

    func testFinalReminderNotificationCopyIsDistinctFromSixtySecondReminder() throws {
        let source = try source
        XCTAssertTrue(source.contains("case finalReminder"))
        XCTAssertTrue(source.contains(#"content.body = "Still want to start recording?""#))
        XCTAssertTrue(source.contains(#"content.body = "Last reminder while this call appears active.""#))
    }


    func testLateJoinCalendarPromptCopyStatesCaptureFromNowOnward() throws {
        let source = try source
        XCTAssertTrue(source.contains("Record '\\(event.title)'? This event started"))
        XCTAssertTrue(source.contains("Recording will capture from now onward."))
        XCTAssertTrue(source.contains("event.endDate.timeIntervalSince(Date()) >= 10 * 60"))
    }

    func testNotificationPayloadDoesNotIncludeUnsafeCalendarContext() throws {
        let source = try source
        let userInfoStart = try XCTUnwrap(source.range(of: "content.userInfo = ["))
        let userInfoEnd = try XCTUnwrap(source[userInfoStart.lowerBound...].range(of: "]"))
        let body = source[userInfoStart.lowerBound..<userInfoEnd.upperBound]
        XCTAssertFalse(body.contains("event.title"))
        XCTAssertFalse(body.contains("keyterms"))
        XCTAssertFalse(body.contains("attendees"))
    }

    func testPromptIdentifierUsesTriggerIdentity() throws {
        let source = try source
        XCTAssertTrue(source.contains("func prompt(for candidate: DetectionCandidate"), "prompt coordinator should accept the detection candidate with trigger identity")
        XCTAssertTrue(source.contains("let identifier = candidate.triggerIdentity"), "prompt ID must use calendar occurrence identity when DetectionEngine provides it")
        XCTAssertTrue(source.contains(#""triggerIdentity": promptID"#), "notification payload should carry the same trigger identity for stale action de-dupe")
    }

    func testPromptPlacementUsesActiveMeetingWindowScreen() throws {
        let source = try source
        XCTAssertTrue(source.contains("self?.place(window: window, nearActiveWindowFor: app)"))
        XCTAssertTrue(source.contains("CGWindowListCopyWindowInfo"))
        XCTAssertTrue(source.contains("NSScreen.screens.max"))
    }
}

final class PromptPreflightRecoverySourceTests: XCTestCase {
    private var appDelegateSource: String {
        get throws {
            let path = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("TranscriberApp/Scribe/AppDelegate.swift")
            return try String(contentsOf: path, encoding: .utf8)
        }
    }

    private var startPromptSource: String {
        get throws {
            let path = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("TranscriberApp/Scribe/StartPromptCoordinator.swift")
            return try String(contentsOf: path, encoding: .utf8)
        }
    }

    func testPromptStartPreflightDenialKeepsPendingRecoveryActions() throws {
        let source = try appDelegateSource
        XCTAssertTrue(source.contains("let shouldClearPendingPrompt = choice != .start || !setupNeedsAttention"), "prompt start should not unconditionally clear pending recovery before preflight outcome is known")
        XCTAssertTrue(source.contains("if setupNeedsAttention {\n                pendingPromptCalendarEventForStart = event"), "preflight denial should preserve prompt calendar context for a later recovery retry")
        XCTAssertTrue(source.contains("Fix setup, then start recording."), "setup-required pending prompt copy should keep meeting recovery actionable")
        XCTAssertTrue(source.contains("menu?.pendingPrompt = PendingPromptRecovery"), "AppDelegate should restore menu-bar Start/Not now recovery after a blocked prompt start")
    }

    func testMenuRecoveryCanRetryAfterPromptCoordinatorResolved() throws {
        let appDelegate = try appDelegateSource
        let coordinator = try startPromptSource
        XCTAssertTrue(coordinator.contains("var hasActivePrompt: Bool { activePromptIdentifier != nil }"), "AppDelegate needs to distinguish live modal/notification prompts from retained setup-blocked recovery")
        XCTAssertTrue(appDelegate.contains("if startPromptCoordinator.hasActivePrompt"))
        XCTAssertTrue(appDelegate.contains("} else if detectionPromptActive {\n                let event = pendingPromptCalendarEventForStart"), "retained pending prompt recovery should keep the saved calendar context")
        XCTAssertTrue(appDelegate.contains("pendingPromptCandidateForStart = DetectionCandidate(app: app, triggerIdentity: triggerIdentity)"), "retained pending prompt recovery should preserve the detection candidate for end-call recognition")
        XCTAssertTrue(appDelegate.contains("await startRecording()"), "retained pending prompt recovery should retry the normal preflight/start path after setup is fixed")
    }

    func testRequiredSetupOutranksDetectedIconButDoesNotRemovePendingPromptModel() throws {
        let appDelegate = try appDelegateSource
        XCTAssertTrue(appDelegate.contains("setupNeedsAttention = true"), "required preflight denial should surface Setup Required")
        XCTAssertTrue(appDelegate.contains("menu?.setupNeedsAttention = true"), "required preflight denial should mark the popover setup state")
        XCTAssertTrue(appDelegate.contains("menu?.pendingPrompt = PendingPromptRecovery"), "setup-required state must coexist with pending meeting actions")
    }
}
