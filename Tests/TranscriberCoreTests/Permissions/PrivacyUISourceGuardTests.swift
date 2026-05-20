import XCTest

/// Source / copy guard tests for privacy disclosure and confidential-window UI.
///
/// VAL-PRIVACY-001: Privacy acknowledgement must disclose Cloud upload and Calendar keyterms.
/// VAL-PRIVACY-002: Confidential windows use .none by default; DEBUG override requires env var.
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
