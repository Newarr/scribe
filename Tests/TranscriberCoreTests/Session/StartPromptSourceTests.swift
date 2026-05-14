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
        XCTAssertTrue(source.contains("NSAlert()"))
        XCTAssertTrue(source.contains("alert.window.sharingType = WindowChromeSharing.confidential"))
    }

    func testPrimaryChoicesAreStartRecordingAndNotNowOnly() throws {
        let source = try source
        XCTAssertTrue(source.contains("alert.addButton(withTitle: \"Start Recording\")"))
        XCTAssertTrue(source.contains("alert.addButton(withTitle: \"Not now\")"))
        XCTAssertFalse(source.contains("alert.addButton(withTitle: \"Stop detecting"))
    }

    func testBackupNotificationUsesMatchingActionsWithoutSuppressionAction() throws {
        let source = try source
        XCTAssertTrue(source.contains("title: \"Start Recording\""))
        XCTAssertTrue(source.contains("title: \"Not now\""))
        XCTAssertFalse(source.contains("UNNotificationAction(\n                    identifier: Action.suppress"))
        XCTAssertTrue(source.contains("modal/menu recovery remain active"))
        XCTAssertTrue(source.contains("UNNotificationDismissActionIdentifier"))
    }

    func testSuppressionLivesBehindClosedMoreOptionsDisclosure() throws {
        let source = try source
        XCTAssertTrue(source.contains("More options ▾"))
        XCTAssertTrue(source.contains("suppressButton.isHidden = true"))
        XCTAssertTrue(source.contains("Stop detecting \\(appDisplayName) for 30 minutes"))
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
        XCTAssertTrue(source.contains("func expireActivePrompt(for app: MeetingApp)"), "prompt coordinator must expose an app-scoped stale-call expiry seam")
        XCTAssertTrue(source.contains("entry.app.bundleID == app.bundleID"), "stale-call expiry must only resolve the matching active prompt")
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

    func testPromptPlacementUsesActiveMeetingWindowScreen() throws {
        let source = try source
        XCTAssertTrue(source.contains("place(window: alert.window, nearActiveWindowFor: app)"))
        XCTAssertTrue(source.contains("CGWindowListCopyWindowInfo"))
        XCTAssertTrue(source.contains("NSScreen.screens.max"))
    }
}
