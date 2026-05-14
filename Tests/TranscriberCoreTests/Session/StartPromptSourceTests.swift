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
        XCTAssertTrue(source.contains("Start prompt expired without decision"))
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
