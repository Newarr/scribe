import XCTest

/// Source / copy guard tests for privacy disclosure and confidential-window UI.
///
/// VAL-PRIVACY-001: Privacy acknowledgement must disclose Cloud upload and Calendar keyterms.
/// VAL-PRIVACY-002: Confidential windows use .none by default; DEBUG override requires env var.
///   Expanded: full Scribe AppKit inventory (NSAlert/NSWindow/NSPanel/NSPopover) across
///   TranscriberApp/Scribe must apply WindowChromeSharing.confidential at each confidential
///   surface. SCRIBE_VISUAL_TEST_OVERRIDE=1 is the only permitted exception.
/// VAL-PRIVACY-003: No live transcript / history / unsupported AI workflow UI.
/// VAL-PRIVACY-004: Engine copy distinguishes local processing from Cloud processing.
/// VAL-SETTINGS-003: Settings Shortcuts must not expose clipboard/import transcript workflow.
/// VAL-SETTINGS-005: Settings General and Privacy panels must not make unconditional local-only claims.
final class PrivacyUISourceGuardTests: XCTestCase {

    // MARK: - VAL-PRIVACY-001

    /// Privacy acknowledgement must not claim files "always stay on your Mac"
    /// unconditionally — that is false for Cloud mode.
    func testPrivacyAcknowledgementDoesNotMakeUnconditionalLocalOnlyClaims() throws {
        let source = try appSource("PrivacyAcknowledgementSheet.swift")
        // These phrases are forbidden unconditional local-only claims.
        let forbiddenPhrases = [
            "The files always stay on your Mac",
            "nothing leaves the device",
            "Everything stays on your Mac",
        ]
        for phrase in forbiddenPhrases {
            XCTAssertFalse(
                source.localizedCaseInsensitiveContains(phrase),
                "PrivacyAcknowledgementSheet must not make the unconditional local-only claim: \"\(phrase)\""
            )
        }
    }

    /// Privacy acknowledgement must disclose that Cloud mode uploads audio to ElevenLabs.
    func testPrivacyAcknowledgementDiscloseCloudAudioUpload() throws {
        let source = try appSource("PrivacyAcknowledgementSheet.swift")
        XCTAssertTrue(
            source.contains("ElevenLabs") && (source.contains("upload") || source.contains("uploaded")),
            "PrivacyAcknowledgementSheet must disclose that Cloud mode uploads audio to ElevenLabs"
        )
    }

    /// Privacy acknowledgement must disclose that Calendar keyterms may be sent in Cloud mode.
    func testPrivacyAcknowledgementDiscloseCalendarKeyterms() throws {
        let source = try appSource("PrivacyAcknowledgementSheet.swift")
        XCTAssertTrue(
            source.contains("keyterm") || source.contains("Calendar"),
            "PrivacyAcknowledgementSheet must disclose that calendar keyterms may be sent in Cloud mode"
        )
    }

    /// Privacy acknowledgement must state that Local mode keeps everything on-device.
    func testPrivacyAcknowledgementDiscloseLocalOnDevice() throws {
        let source = try appSource("PrivacyAcknowledgementSheet.swift")
        XCTAssertTrue(
            source.contains("on-device") || source.contains("on your Mac") || source.contains("on this Mac"),
            "PrivacyAcknowledgementSheet must state that Local mode keeps audio/transcription on-device"
        )
    }

    // MARK: - VAL-PRIVACY-002

    /// WindowChromeSharing.confidential must return .none in Debug by default.
    /// The DEBUG block must check for an explicit env-var override, not
    /// return .readWrite unconditionally.
    func testWindowChromeSharingDebugBlockRequiresEnvVarOverrideNotUnconditionalReadWrite() throws {
        let source = try appSource("DesignSystem.swift")

        // The DEBUG block must NOT unconditionally return .readWrite.
        // A common failure mode: `#if DEBUG\nreturn .readWrite\n#else\nreturn .none`
        // We check that the pattern "DEBUG" and ".readWrite" only appear
        // together in the presence of "SCRIBE_VISUAL_TEST_OVERRIDE" (the env-var override).
        XCTAssertTrue(
            source.contains("SCRIBE_VISUAL_TEST_OVERRIDE"),
            "WindowChromeSharing.confidential DEBUG override must require SCRIBE_VISUAL_TEST_OVERRIDE env var"
        )

        // Extract the WindowChromeSharing block and verify .readWrite is
        // gated on the env-var check.
        if let range = source.range(of: "enum WindowChromeSharing") {
            let block = String(source[range.lowerBound...].prefix(600))
            // .readWrite must only appear after the env-var check.
            if let rwRange = block.range(of: ".readWrite"),
               let envVarRange = block.range(of: "SCRIBE_VISUAL_TEST_OVERRIDE") {
                XCTAssertTrue(
                    envVarRange.lowerBound < rwRange.lowerBound,
                    "WindowChromeSharing: SCRIBE_VISUAL_TEST_OVERRIDE check must appear before .readWrite in the DEBUG block"
                )
            }
        }
    }

    /// WindowChromeSharing must return .none as the default (non-override) path.
    func testWindowChromeSharingDefaultIsNone() throws {
        let source = try appSource("DesignSystem.swift")
        if let range = source.range(of: "enum WindowChromeSharing") {
            let block = String(source[range.lowerBound...].prefix(600))
            XCTAssertTrue(
                block.contains("return .none"),
                "WindowChromeSharing.confidential must return .none as the default sharing type"
            )
        }
    }

    // MARK: - VAL-PRIVACY-003

    /// No app UI source file may expose live transcript content, transcript history,
    /// or unsupported AI workflow affordances.
    func testSettingsSourceHasNoLiveTranscriptOrHistoryUI() throws {
        let settingsSource = try appSource("SettingsWindow.swift")
        let forbiddenPatterns = [
            "live transcript",
            "transcript history",
            "transcript browser",
            "AI notes",
            "AI summaries",
            "vector search",
            "knowledge base",
        ]
        for pattern in forbiddenPatterns {
            XCTAssertFalse(
                settingsSource.localizedCaseInsensitiveContains(pattern),
                "SettingsWindow must not expose forbidden UI: \"\(pattern)\""
            )
        }
    }

    // MARK: - VAL-PRIVACY-004

    /// Settings General panel must not claim "Nothing leaves the device" unconditionally.
    func testSettingsGeneralPanelDoesNotMakeUnconditionalLocalOnlyClaims() throws {
        let source = try appSource("SettingsWindow.swift")
        let forbiddenPhrases = [
            "Nothing leaves the device",
            "Everything stays on your Mac",
        ]
        for phrase in forbiddenPhrases {
            XCTAssertFalse(
                source.localizedCaseInsensitiveContains(phrase),
                "SettingsWindow must not make the unconditional local-only claim: \"\(phrase)\""
            )
        }
    }

    /// Settings General panel must distinguish Local on-device processing from
    /// Cloud processing (upload to ElevenLabs).
    func testSettingsGeneralPanelDisclosesBothLocalAndCloudBehavior() throws {
        let source = try appSource("SettingsWindow.swift")
        XCTAssertTrue(
            source.contains("ElevenLabs") || source.contains("uploads audio"),
            "SettingsWindow must disclose Cloud audio upload behavior (ElevenLabs)"
        )
        XCTAssertTrue(
            source.contains("on-device") || source.contains("on your Mac") || source.contains("locally"),
            "SettingsWindow must state Local keeps audio/transcription on-device"
        )
    }

    /// Settings Privacy panel must disclose Cloud upload and Calendar keyterms.
    func testSettingsPrivacyPanelDiscloseCloudUploadAndCalendarKeyterms() throws {
        let source = try appSource("SettingsWindow.swift")
        // FidelityPrivacyPanel subtitle must mention Cloud upload and keyterms.
        XCTAssertTrue(
            source.contains("uploads mixed audio") || source.contains("upload") && source.contains("ElevenLabs"),
            "Settings Privacy panel must disclose Cloud audio upload"
        )
        XCTAssertTrue(
            source.contains("keyterm") || source.contains("Calendar") && source.contains("sent"),
            "Settings Privacy panel must disclose that Calendar keyterms may be sent in Cloud mode"
        )
    }

    // MARK: - VAL-SETTINGS-003

    /// Settings Shortcuts must not expose clipboard/import transcript workflow.
    func testSettingsShortcutsHasNoClipboardTranscriptWorkflow() throws {
        let source = try appSource("SettingsWindow.swift")
        let forbiddenPatterns = [
            "New transcript from clipboard",
            "clipboard transcript",
            "import transcript",
            "paste.*transcript",
        ]
        for pattern in forbiddenPatterns {
            XCTAssertFalse(
                source.localizedCaseInsensitiveContains(pattern),
                "SettingsWindow Shortcuts must not expose: \"\(pattern)\""
            )
        }
        // The clipboardShortcut state variable must also be absent.
        XCTAssertFalse(
            source.contains("clipboardShortcut"),
            "SettingsWindow must not maintain clipboardShortcut state — clipboard transcript creation is not a supported product surface"
        )
    }

    // MARK: - VAL-SETTINGS-004 / VAL-CROSS-004

    /// Settings Vault must render the same synced-storage warning class that
    /// PermissionDoctor surfaces before recording. This guards against saving
    /// Dropbox/iCloud/Drive-style roots silently in Settings while only warning
    /// later at record time.
    func testSettingsVaultRendersSyncedStorageWarningUsingPermissionDoctorHeuristic() throws {
        let source = try appSource("SettingsWindow.swift")
        XCTAssertTrue(source.contains("DefaultOutputFolderProbe().syncedStorageHint(outputRoot)"))
        XCTAssertTrue(source.contains("outputRootIsInICloudDrive"))
        XCTAssertTrue(source.contains("outputRootIsInSyncedStorage"))
        XCTAssertTrue(source.contains("FidelityVaultWarning"))
        XCTAssertTrue(source.contains("Permission Doctor will show the same non-blocking warning before recording"))
        XCTAssertTrue(source.contains("Sync races can corrupt durable meeting audio"))
    }

    // MARK: - VAL-A11Y-001

    /// Custom switches must use a native activation surface and expose an
    /// accessibility action/value. Gesture-only drawings are not keyboard or
    /// VoiceOver actionable.
    func testCustomSwitchesAreButtonBackedAndAccessibilityActionable() throws {
        let designSource = try appSource("DesignSystem.swift")
        guard let styleRange = designSource.range(of: "struct ScribeSwitchStyle") else {
            XCTFail("ScribeSwitchStyle must exist")
            return
        }
        let styleBlock = String(designSource[styleRange.lowerBound...].prefix(1800))
        XCTAssertTrue(styleBlock.contains("Button"))
        XCTAssertTrue(styleBlock.contains(".accessibilityAction"))
        XCTAssertTrue(styleBlock.contains(".accessibilityValue(configuration.isOn ? \"on\" : \"off\")"))
        XCTAssertFalse(styleBlock.contains(".onTapGesture"))

        let settingsSource = try appSource("SettingsWindow.swift")
        guard let toggleRange = settingsSource.range(of: "private struct FidelityToggle") else {
            XCTFail("FidelityToggle must exist")
            return
        }
        let toggleBlock = String(settingsSource[toggleRange.lowerBound...].prefix(1600))
        XCTAssertTrue(toggleBlock.contains("Button"))
        XCTAssertTrue(toggleBlock.contains(".accessibilityAction"))
        XCTAssertTrue(toggleBlock.contains(".accessibilityValue(isOn ? \"on\" : \"off\")"))
    }

    // MARK: - VAL-PRIVACY-002: NSAlert call-site inventory

    /// Every NSAlert() in AppDelegate must set alert.window.sharingType to
    /// WindowChromeSharing.confidential before runModal().
    ///
    /// This is a regression guard: if a new NSAlert is added without the
    /// confidential treatment, this test fails.
    func testAppDelegateNSAlertCallSitesAllSetConfidentialSharingType() throws {
        let source = try appSource("AppDelegate.swift")
        // Collect all ranges of "let alert = NSAlert()" in the source.
        var searchRange = source.startIndex..<source.endIndex
        var alertCreationIndices: [String.Index] = []
        while let range = source.range(of: "NSAlert()", range: searchRange) {
            alertCreationIndices.append(range.lowerBound)
            searchRange = range.upperBound..<source.endIndex
        }
        XCTAssertFalse(
            alertCreationIndices.isEmpty,
            "Expected at least one NSAlert() in AppDelegate.swift"
        )
        // For each NSAlert() creation site, check that WindowChromeSharing.confidential
        // appears before runModal() in the local window (within 800 chars).
        for idx in alertCreationIndices {
            let snippet = String(source[idx...].prefix(800))
            let hasConfidential = snippet.contains("WindowChromeSharing.confidential")
            let hasRunModal = snippet.contains("runModal()")
            if hasRunModal {
                XCTAssertTrue(
                    hasConfidential,
                    "AppDelegate NSAlert at offset \(source.distance(from: source.startIndex, to: idx)) must set alert.window.sharingType = WindowChromeSharing.confidential before runModal()"
                )
            }
        }
    }

    /// presentScreenRecordingRestartRequiredAlert specifically must set
    /// WindowChromeSharing.confidential on the alert window before runModal().
    func testScreenRecordingRestartAlertSetsConfidentialSharingType() throws {
        let source = try appSource("AppDelegate.swift")
        guard let fnRange = source.range(of: "func presentScreenRecordingRestartRequiredAlert") else {
            XCTFail("presentScreenRecordingRestartRequiredAlert must exist in AppDelegate.swift")
            return
        }
        // Extract the function body (next 600 chars covers the full implementation)
        let body = String(source[fnRange.lowerBound...].prefix(600))
        XCTAssertTrue(
            body.contains("WindowChromeSharing.confidential"),
            "presentScreenRecordingRestartRequiredAlert must set alert.window.sharingType = WindowChromeSharing.confidential before runModal()"
        )
        // Confidential assignment must precede runModal() call
        if let confRange = body.range(of: "WindowChromeSharing.confidential"),
           let modalRange = body.range(of: "runModal()") {
            XCTAssertTrue(
                confRange.lowerBound < modalRange.lowerBound,
                "WindowChromeSharing.confidential must be assigned before runModal() in presentScreenRecordingRestartRequiredAlert"
            )
        }
    }

    // MARK: - VAL-PRIVACY-002: Full AppKit inventory across all Scribe sources

    /// DiagnosticsView creates one NSWindow for diagnostics display.
    /// That window must set WindowChromeSharing.confidential before makeKeyAndOrderFront.
    func testDiagnosticsViewWindowSetsConfidentialSharingType() throws {
        let source = try appSource("DiagnosticsView.swift")
        // There must be an NSWindow( construction.
        XCTAssertTrue(
            source.contains("NSWindow("),
            "DiagnosticsView must create an NSWindow for the diagnostics surface"
        )
        // WindowChromeSharing.confidential must appear within the same source file.
        XCTAssertTrue(
            source.contains("WindowChromeSharing.confidential"),
            "DiagnosticsView NSWindow must set WindowChromeSharing.confidential (sharingType)"
        )
        // The confidential assignment must precede makeKeyAndOrderFront in the window-creation block.
        if let winRange = source.range(of: "NSWindow("),
           let bodyEnd = source.range(of: "makeKeyAndOrderFront", range: winRange.upperBound..<source.endIndex) {
            let block = String(source[winRange.lowerBound..<bodyEnd.upperBound])
            XCTAssertTrue(
                block.contains("WindowChromeSharing.confidential"),
                "DiagnosticsView must set WindowChromeSharing.confidential before makeKeyAndOrderFront"
            )
        }
    }

    /// EndCountdownWindow creates one NSPanel for the countdown overlay.
    /// That panel must set WindowChromeSharing.confidential before it is made visible.
    func testEndCountdownWindowPanelSetsConfidentialSharingType() throws {
        let source = try appSource("EndCountdownWindow.swift")
        XCTAssertTrue(
            source.contains("NSPanel("),
            "EndCountdownWindow must create an NSPanel for the countdown surface"
        )
        XCTAssertTrue(
            source.contains("WindowChromeSharing.confidential"),
            "EndCountdownWindow NSPanel must set WindowChromeSharing.confidential (sharingType)"
        )
        // Confidential assignment must appear before makeKeyAndOrderFront in the panel block.
        if let panelRange = source.range(of: "NSPanel("),
           let orderRange = source.range(of: "makeKeyAndOrderFront", range: panelRange.upperBound..<source.endIndex) {
            let block = String(source[panelRange.lowerBound..<orderRange.upperBound])
            XCTAssertTrue(
                block.contains("WindowChromeSharing.confidential"),
                "EndCountdownWindow must set WindowChromeSharing.confidential before makeKeyAndOrderFront"
            )
        }
    }

    /// OnboardingWindow creates one NSWindow for the first-run flow.
    /// That window must set WindowChromeSharing.confidential before it is made visible.
    func testOnboardingWindowSetsConfidentialSharingType() throws {
        let source = try appSource("OnboardingWindow.swift")
        XCTAssertTrue(
            source.contains("NSWindow("),
            "OnboardingWindow must create an NSWindow for the onboarding surface"
        )
        XCTAssertTrue(
            source.contains("WindowChromeSharing.confidential"),
            "OnboardingWindow NSWindow must set WindowChromeSharing.confidential (sharingType)"
        )
        // Verify confidential assignment precedes makeKeyAndOrderFront.
        if let winRange = source.range(of: "NSWindow("),
           let orderRange = source.range(of: "makeKeyAndOrderFront", range: winRange.upperBound..<source.endIndex) {
            let block = String(source[winRange.lowerBound..<orderRange.upperBound])
            XCTAssertTrue(
                block.contains("WindowChromeSharing.confidential"),
                "OnboardingWindow must set WindowChromeSharing.confidential before makeKeyAndOrderFront"
            )
        }
    }

    /// PromptModalWindow creates one NSPanel for start prompts.
    /// That panel must set WindowChromeSharing.confidential before NSApp.runModal.
    func testPromptModalWindowPanelSetsConfidentialSharingType() throws {
        let source = try appSource("PromptModalWindow.swift")
        XCTAssertTrue(
            source.contains("NSPanel("),
            "PromptModalWindow must create an NSPanel for the prompt modal surface"
        )
        XCTAssertTrue(
            source.contains("WindowChromeSharing.confidential"),
            "PromptModalWindow NSPanel must set WindowChromeSharing.confidential (sharingType)"
        )
        // Confidential assignment must appear before runModal in the panel block.
        if let panelRange = source.range(of: "NSPanel("),
           let modalRange = source.range(of: "runModal", range: panelRange.upperBound..<source.endIndex) {
            let block = String(source[panelRange.lowerBound..<modalRange.upperBound])
            XCTAssertTrue(
                block.contains("WindowChromeSharing.confidential"),
                "PromptModalWindow must set WindowChromeSharing.confidential before runModal"
            )
        }
    }

    /// PrivacyAcknowledgementSheet creates one NSWindow for the privacy gate.
    /// That window must set WindowChromeSharing.confidential before it is made visible.
    func testPrivacyAcknowledgementSheetWindowSetsConfidentialSharingType() throws {
        let source = try appSource("PrivacyAcknowledgementSheet.swift")
        XCTAssertTrue(
            source.contains("NSWindow("),
            "PrivacyAcknowledgementSheet must create an NSWindow for the privacy gate"
        )
        XCTAssertTrue(
            source.contains("WindowChromeSharing.confidential"),
            "PrivacyAcknowledgementSheet NSWindow must set WindowChromeSharing.confidential (sharingType)"
        )
        // Confidential assignment must appear before makeKeyAndOrderFront in the window block.
        if let winRange = source.range(of: "NSWindow("),
           let orderRange = source.range(of: "makeKeyAndOrderFront", range: winRange.upperBound..<source.endIndex) {
            let block = String(source[winRange.lowerBound..<orderRange.upperBound])
            XCTAssertTrue(
                block.contains("WindowChromeSharing.confidential"),
                "PrivacyAcknowledgementSheet must set WindowChromeSharing.confidential before makeKeyAndOrderFront"
            )
        }
    }

    /// RecordingMenu creates one NSPopover for the menu bar popover.
    /// After show(), it must set sharingType via WindowChromeSharing.confidential on the backing window.
    func testRecordingMenuPopoverSetsConfidentialSharingType() throws {
        let source = try appSource("RecordingMenu.swift")
        XCTAssertTrue(
            source.contains("NSPopover()"),
            "RecordingMenu must create an NSPopover for the recording menu surface"
        )
        XCTAssertTrue(
            source.contains("WindowChromeSharing.confidential"),
            "RecordingMenu NSPopover must set WindowChromeSharing.confidential on the backing window after show"
        )
        // The show(from:) function body must contain both popover.show and WindowChromeSharing.confidential.
        // Use a generous prefix (1200 chars) to cover the full function body including the sharingType line.
        if let showRange = source.range(of: "func show(from button:") {
            let funcBody = String(source[showRange.lowerBound...].prefix(1200))
            XCTAssertTrue(
                funcBody.contains("WindowChromeSharing.confidential"),
                "RecordingMenu show(from:) must set WindowChromeSharing.confidential on the popover backing window"
            )
            // The confidential assignment must come after popover.show in the function.
            if let showCallRange = funcBody.range(of: "popover.show("),
               let confRange = funcBody.range(of: "WindowChromeSharing.confidential") {
                XCTAssertTrue(
                    showCallRange.lowerBound < confRange.lowerBound,
                    "RecordingMenu: WindowChromeSharing.confidential must be set after popover.show() returns"
                )
            }
        }
    }

    /// PermissionRecoveryPopoverController creates one NSPopover for permission recovery.
    /// After show(), it must set sharingType via WindowChromeSharing.confidential on the backing window.
    func testPermissionRecoveryPopoverSetsConfidentialSharingType() throws {
        let source = try appSource("PermissionRecoveryView.swift")
        XCTAssertTrue(
            source.contains("NSPopover()"),
            "PermissionRecoveryView must create an NSPopover for permission recovery surface"
        )
        XCTAssertTrue(
            source.contains("WindowChromeSharing.confidential"),
            "PermissionRecoveryPopoverController NSPopover must set WindowChromeSharing.confidential on backing window after show"
        )
        // The show function must set confidential after popover.show().
        // Use a generous prefix (800 chars) to cover the full show method including the sharingType line
        // (the comment block above sharingType is several lines).
        if let showRange = source.range(of: "popover.show(relativeTo:") {
            let context = String(source[showRange.lowerBound...].prefix(800))
            XCTAssertTrue(
                context.contains("WindowChromeSharing.confidential"),
                "PermissionRecoveryView must set WindowChromeSharing.confidential on popover backing window after popover.show()"
            )
        }
    }

    /// SavedNotificationWindow creates one NSPanel for the saved notification banner.
    /// That panel must set WindowChromeSharing.confidential before it is made visible.
    func testSavedNotificationWindowPanelSetsConfidentialSharingType() throws {
        let source = try appSource("SavedNotificationWindow.swift")
        XCTAssertTrue(
            source.contains("NSPanel("),
            "SavedNotificationWindow must create an NSPanel for the saved notification surface"
        )
        XCTAssertTrue(
            source.contains("WindowChromeSharing.confidential"),
            "SavedNotificationWindow NSPanel must set WindowChromeSharing.confidential (sharingType)"
        )
        // Confidential assignment must appear before orderFrontRegardless in the panel block.
        if let panelRange = source.range(of: "NSPanel("),
           let orderRange = source.range(of: "orderFrontRegardless", range: panelRange.upperBound..<source.endIndex) {
            let block = String(source[panelRange.lowerBound..<orderRange.upperBound])
            XCTAssertTrue(
                block.contains("WindowChromeSharing.confidential"),
                "SavedNotificationWindow must set WindowChromeSharing.confidential before orderFrontRegardless"
            )
        }
    }

    /// SettingsWindow creates multiple AppKit surfaces:
    ///   1. The main Settings NSWindow
    ///   2. The ShortcutCapturePanel NSPanel
    ///   3. The PermissionsOnboardingWindowController NSWindow
    /// All three must set WindowChromeSharing.confidential before being made visible.
    func testSettingsWindowAllSurfacesSetConfidentialSharingType() throws {
        let source = try appSource("SettingsWindow.swift")

        // Count WindowChromeSharing.confidential occurrences to verify all surfaces are covered.
        var searchRange = source.startIndex..<source.endIndex
        var confidentialCount = 0
        while let range = source.range(of: "WindowChromeSharing.confidential", range: searchRange) {
            confidentialCount += 1
            searchRange = range.upperBound..<source.endIndex
        }
        XCTAssertGreaterThanOrEqual(
            confidentialCount,
            3,
            "SettingsWindow must apply WindowChromeSharing.confidential on at least 3 confidential surfaces (main window, ShortcutCapturePanel, PermissionsOnboardingWindowController)"
        )

        // Main SettingsWindowController NSWindow must have confidential sharing.
        // Use 5000 chars to cover the full show() function body which appears ~3600 chars into the class.
        if let winRange = source.range(of: "class SettingsWindowController") {
            let classBody = String(source[winRange.lowerBound...].prefix(5000))
            XCTAssertTrue(
                classBody.contains("WindowChromeSharing.confidential"),
                "SettingsWindowController NSWindow must set WindowChromeSharing.confidential"
            )
        }

        // ShortcutCapturePanel must set confidential sharing.
        if let panelRange = source.range(of: "ShortcutCapturePanel") {
            let panelBody = String(source[panelRange.lowerBound...].prefix(600))
            XCTAssertTrue(
                panelBody.contains("WindowChromeSharing.confidential"),
                "ShortcutCapturePanel must set WindowChromeSharing.confidential on the NSPanel"
            )
        }

        // PermissionsOnboardingWindowController must set confidential sharing.
        if let onboardingRange = source.range(of: "PermissionsOnboardingWindowController") {
            let onboardingBody = String(source[onboardingRange.lowerBound...].prefix(3000))
            XCTAssertTrue(
                onboardingBody.contains("WindowChromeSharing.confidential"),
                "PermissionsOnboardingWindowController NSWindow must set WindowChromeSharing.confidential"
            )
        }
    }

    /// Full inventory regression guard: every NSAlert/NSWindow/NSPanel/NSPopover
    /// construction site under TranscriberApp/Scribe is validated independently.
    ///
    /// This intentionally checks sites, not files: adding an unprotected constructor to
    /// a file that already contains another confidential assignment must still fail.
    /// System-owned file panels are documented exceptions because Scribe does not own
    /// their backing NSWindow.
    func testFullScribeAppKitInventoryAllSurfacesHaveConfidentialSharingOrAreSystemPanels() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()  // Permissions
            .deletingLastPathComponent()  // TranscriberCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let scribeDir = repoRoot.appendingPathComponent("TranscriberApp/Scribe")

        guard let enumerator = FileManager.default.enumerator(
            at: scribeDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not enumerate TranscriberApp/Scribe directory")
            return
        }

        let appKitConstructors = ["NSAlert()", "NSWindow(", "NSPanel(", "NSPopover()"]
        let explicitSystemPanelExceptions = [
            "NSOpenPanel(", "NSOpenPanel()", "NSSavePanel(", "NSSavePanel()",
        ]
        var violations: [String] = []
        var inspectedSites = 0

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let filename = fileURL.lastPathComponent
            let source: String
            do {
                source = try String(contentsOf: fileURL, encoding: .utf8)
            } catch {
                XCTFail("Could not read \(filename): \(error)")
                continue
            }

            let constructorSites = appKitConstructors.flatMap { constructor in
                ranges(of: constructor, in: source).map { (constructor: constructor, range: $0) }
            }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }

            for (index, site) in constructorSites.enumerated() {
                guard !isExplicitSystemPanelException(
                    at: site.range,
                    in: source,
                    exceptions: explicitSystemPanelExceptions
                ) else { continue }

                inspectedSites += 1
                let nextConstructorStart = constructorSites.dropFirst(index + 1).first?.range.lowerBound
                let siteEnd = nextConstructorStart ?? source.endIndex
                let siteContext = String(source[site.range.lowerBound..<siteEnd])

                guard constructorSiteIsProtected(site.constructor, context: siteContext) else {
                    let location = lineAndColumn(for: site.range.lowerBound, in: source)
                    let snippet = constructorSnippet(at: site.range, in: source)
                    violations.append(
                        "\(filename):\(location.line):\(location.column) `\(snippet)` lacks local WindowChromeSharing.confidential protection"
                    )
                    continue
                }
            }
        }

        XCTAssertGreaterThan(
            inspectedSites,
            0,
            "Expected to inspect at least one Scribe-owned AppKit construction site"
        )
        XCTAssertTrue(
            violations.isEmpty,
            """
            Found Scribe-owned AppKit construction sites without local capture-exclusion protection.
            Each NSAlert/NSWindow/NSPanel/NSPopover site must set `sharingType = WindowChromeSharing.confidential` in its own local constructor/display window before use, except documented system panels (NSOpenPanel/NSSavePanel) and the explicit SCRIBE_VISUAL_TEST_OVERRIDE=1 path in DesignSystem.swift.
            Violations:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    private func constructorSiteIsProtected(_ constructor: String, context: String) -> Bool {
        let protection = "WindowChromeSharing.confidential"
        guard let protectionRange = context.range(of: protection) else { return false }

        if constructor == "NSPopover()" {
            // NSPopover backing windows exist only after AppKit shows the popover, so
            // the valid local pattern is `popover.show(...)` followed immediately by
            // setting the backing window sharing type.
            guard let showRange = firstRange(ofAny: ["popover.show(", "show(relativeTo:"], in: context) else {
                return false
            }
            return showRange.lowerBound < protectionRange.lowerBound
        }

        if constructor == "NSAlert()" {
            return protectionAppearsBeforeFirstUse(
                protectionRange: protectionRange,
                useMarkers: ["runModal()", "beginSheetModal", "runModal"],
                in: context
            )
        }

        return protectionAppearsBeforeFirstUse(
            protectionRange: protectionRange,
            useMarkers: [
                "makeKeyAndOrderFront",
                "orderFrontRegardless",
                "orderFront(",
                "runModal",
                "showWindow",
            ],
            in: context
        )
    }

    private func protectionAppearsBeforeFirstUse(
        protectionRange: Range<String.Index>,
        useMarkers: [String],
        in context: String
    ) -> Bool {
        guard let firstUse = firstRange(ofAny: useMarkers, in: context) else {
            return true
        }
        return protectionRange.lowerBound < firstUse.lowerBound
    }

    private func firstRange(ofAny patterns: [String], in source: String) -> Range<String.Index>? {
        patterns
            .compactMap { source.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
    }

    private func ranges(of pattern: String, in source: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchRange = source.startIndex..<source.endIndex
        while let range = source.range(of: pattern, range: searchRange) {
            result.append(range)
            searchRange = range.upperBound..<source.endIndex
        }
        return result
    }

    private func isExplicitSystemPanelException(
        at range: Range<String.Index>,
        in source: String,
        exceptions: [String]
    ) -> Bool {
        let lineStart = source[..<range.lowerBound].lastIndex(of: "\n")
            .map { source.index(after: $0) } ?? source.startIndex
        let lineEnd = source[range.lowerBound...].firstIndex(of: "\n") ?? source.endIndex
        let line = String(source[lineStart..<lineEnd])
        return exceptions.contains { line.contains($0) }
    }

    private func lineAndColumn(for index: String.Index, in source: String) -> (line: Int, column: Int) {
        var line = 1
        var lineStart = source.startIndex
        var cursor = source.startIndex
        while cursor < index {
            if source[cursor] == "\n" {
                line += 1
                lineStart = source.index(after: cursor)
            }
            cursor = source.index(after: cursor)
        }
        return (line, source.distance(from: lineStart, to: index) + 1)
    }

    private func constructorSnippet(at range: Range<String.Index>, in source: String) -> String {
        let lineStart = source[..<range.lowerBound].lastIndex(of: "\n")
            .map { source.index(after: $0) } ?? source.startIndex
        let snippetEnd = source.index(range.upperBound, offsetBy: 220, limitedBy: source.endIndex) ?? source.endIndex
        return String(source[lineStart..<snippetEnd])
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(4)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private func appSource(_ file: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent() // Permissions
            .deletingLastPathComponent() // TranscriberCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let path = repoRoot
            .appendingPathComponent("TranscriberApp/Scribe")
            .appendingPathComponent(file)
            .path
        return try String(contentsOfFile: path, encoding: .utf8)
    }
}
