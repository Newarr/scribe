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
        XCTAssertTrue(source.contains("modal prompt will still be shown"))
        XCTAssertTrue(source.contains("modal prompt remains active"))
    }

    func testSuppressionLivesBehindClosedMoreOptionsDisclosure() throws {
        let source = try source
        XCTAssertTrue(source.contains("More options ▾"))
        XCTAssertTrue(source.contains("suppressButton.isHidden = true"))
        XCTAssertTrue(source.contains("Stop detecting \\(appDisplayName) for 30 minutes"))
    }

    func testDismissalKeepsBackupNotificationRecoverableWhenBackupPosted() throws {
        let source = try source
        XCTAssertTrue(source.contains("A close/Esc/dismissal is not an implicit decline"))
        XCTAssertTrue(source.contains("if backupNotificationPosted"))
        XCTAssertTrue(source.contains("backup notification remains recoverable"))
    }

    func testDismissalWithoutBackupDoesNotHangPromptTask() throws {
        let source = try source
        XCTAssertTrue(source.contains("there is no secondary channel to resolve later"))
        XCTAssertTrue(source.contains("resolve(identifier: identifier, with: .skipForNow, removeNotification: false)"))
    }

    func testPromptPlacementUsesActiveMeetingWindowScreen() throws {
        let source = try source
        XCTAssertTrue(source.contains("place(window: alert.window, nearActiveWindowFor: app)"))
        XCTAssertTrue(source.contains("CGWindowListCopyWindowInfo"))
        XCTAssertTrue(source.contains("NSScreen.screens.max"))
    }
}
