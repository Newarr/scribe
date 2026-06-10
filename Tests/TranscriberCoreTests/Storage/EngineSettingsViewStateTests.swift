import XCTest
@testable import TranscriberCore

final class EngineSettingsViewStateTests: XCTestCase {
    private let modelID = CohereMLXBackend.modelID

    func testCloudReadinessTracksKeychainAvailabilityWithoutRawKey() async {
        let ready = await EngineSettingsViewState.make(
            selectedEngine: .cloud,
            readiness: StubEngineReadiness(cloudKey: true, localStatus: .notDownloaded(modelID: CohereMLXBackend.modelID))
        )
        XCTAssertTrue(ready.cloud.isReady)
        XCTAssertTrue(ready.cloud.isSelectionEnabled)
        XCTAssertEqual(ready.cloud.statusText, "Ready")
        XCTAssertNil(ready.cloud.rawAPIKey)

        let missing = await EngineSettingsViewState.make(
            selectedEngine: .cloud,
            readiness: StubEngineReadiness(cloudKey: false, localStatus: .notDownloaded(modelID: CohereMLXBackend.modelID))
        )
        XCTAssertFalse(missing.cloud.isReady)
        XCTAssertFalse(missing.cloud.isSelectionEnabled)
        XCTAssertEqual(missing.cloud.statusText, "API key required")
        XCTAssertNil(missing.cloud.rawAPIKey)
    }

    func testLocalCardShowsExactPrivacyCopyForAllStates() async {
        let states: [LocalModelCacheStatus] = [
            .notDownloaded(modelID: modelID),
            .downloading(modelID: modelID, progress: .init(completedBytes: 1_000, totalBytes: 10_000)),
            .verifying(modelID: modelID),
            .verified(.init(modelID: modelID, cacheURL: URL(fileURLWithPath: "/tmp/model"), diskUsageBytes: 4_200_000_000)),
            .failed(modelID: modelID, reason: .init(code: .downloadFailed, message: "network"), retryAvailable: true),
            .unsupported(modelID: modelID, reason: .init(code: .unsupportedRuntime, message: "no mlx"))
        ]

        for status in states {
            let viewState = await EngineSettingsViewState.make(
                selectedEngine: .cloud,
                readiness: StubEngineReadiness(cloudKey: true, localStatus: status)
            )
            XCTAssertEqual(viewState.local.privacyCopy, "Local keeps audio on this Mac.", "privacy copy drifted for \(status)")
            XCTAssertEqual(viewState.local.modelName, "Cohere Transcribe 03-2026")
            XCTAssertEqual(viewState.local.modelID, modelID)
        }
    }

    func testLocalCardStatusDiskUsageAndActions() async {
        let downloading = await EngineSettingsViewState.make(
            selectedEngine: .cloud,
            readiness: StubEngineReadiness(cloudKey: true, localStatus: .downloading(modelID: modelID, progress: .init(completedBytes: 500, totalBytes: 1_000)))
        )
        XCTAssertEqual(downloading.local.statusText, "Downloading 50%")
        XCTAssertEqual(downloading.local.diskUsageText, "Waiting for verified cache")
        XCTAssertEqual(downloading.local.availableActions, [])
        XCTAssertFalse(downloading.local.isSelectionEnabled)

        let ready = await EngineSettingsViewState.make(
            selectedEngine: .local,
            readiness: StubEngineReadiness(cloudKey: false, localStatus: .verified(.init(modelID: modelID, cacheURL: URL(fileURLWithPath: "/tmp/model"), diskUsageBytes: 4_200_000_000)))
        )
        XCTAssertEqual(ready.local.statusText, "Ready")
        XCTAssertEqual(ready.local.diskUsageText, "4.2 GB on disk")
        XCTAssertEqual(ready.local.availableActions, [.remove])
        XCTAssertTrue(ready.local.isSelectionEnabled)

        let failed = await EngineSettingsViewState.make(
            selectedEngine: .cloud,
            readiness: StubEngineReadiness(cloudKey: true, localStatus: .failed(modelID: modelID, reason: .init(code: .verificationFailed, message: "checksum"), retryAvailable: true))
        )
        XCTAssertEqual(failed.local.statusText, "Setup failed")
        XCTAssertEqual(failed.local.diskUsageText, "Waiting for verified cache")
        XCTAssertEqual(failed.local.availableActions, [.retry])
        XCTAssertFalse(failed.local.isSelectionEnabled)
    }

    func testLocalSelectionDisabledUntilVerified() async {
        let unavailableStates: [LocalModelCacheStatus] = [
            .notDownloaded(modelID: modelID),
            .downloading(modelID: modelID, progress: .init(completedBytes: 1, totalBytes: 2)),
            .verifying(modelID: modelID),
            .failed(modelID: modelID, reason: .init(code: .verificationFailed, message: "bad"), retryAvailable: true),
            .unsupported(modelID: modelID, reason: .init(code: .unsupportedRuntime, message: "unsupported"))
        ]
        for status in unavailableStates {
            let viewState = await EngineSettingsViewState.make(
                selectedEngine: .cloud,
                readiness: StubEngineReadiness(cloudKey: true, localStatus: status)
            )
            XCTAssertFalse(viewState.local.isSelectionEnabled, "Local should be disabled for \(status)")
        }
    }

    func testRetryAndRemoveStateTransitionsDoNotSwitchSelectedEngine() {
        var reducer = EngineSettingsActionReducer(selectedEngine: .local)
        XCTAssertEqual(reducer.handle(.retryLocalSetup), .startLocalRetry)
        XCTAssertEqual(reducer.selectedEngine, .local)

        XCTAssertEqual(reducer.handle(.requestRemoveLocalModel), .confirmRemoveLocalModel(modelName: "Cohere Transcribe 03-2026"))
        XCTAssertEqual(reducer.handle(.cancelRemoveLocalModel), .none)
        XCTAssertEqual(reducer.selectedEngine, .local)

        XCTAssertEqual(reducer.handle(.confirmRemoveLocalModel), .clearLocalModelCache)
        XCTAssertEqual(reducer.selectedEngine, .local, "confirmed removal must leave Local selected so preflight enters Setup Required instead of silently switching to Cloud")
    }

    func testSetupActionsDeepLinkToRelevantEngineCard() {
        XCTAssertEqual(EngineSettingsNavigation.focus(for: .missingCloudAPIKey), .cloud)
        XCTAssertEqual(EngineSettingsNavigation.focus(for: .localModelNotVerified(modelID: modelID)), .local)
        XCTAssertEqual(EngineSettingsNavigation.focus(for: .localRuntimeUnavailable), .local)

        let payload = SessionRepairRouting.LocalRepairPayload(
            sessionDirectory: URL(fileURLWithPath: "/tmp/local-failed", isDirectory: true),
            reason: "Cohere setup required"
        )
        XCTAssertEqual(SessionRepairRouting.engineSettingsFocus(for: payload), .local)
        XCTAssertNil(SessionRepairRouting.engineSettingsFocus(for: nil))
    }


    func testSettingsCloudKeyEditorHasSecureExplicitCommitClearAndSafeClose() throws {
        let source = try String(contentsOfFile: appSourcePath("SettingsWindow.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("FidelityCloudAPIKeyEditor"), "Settings Engine must expose a Cloud key editor")
        XCTAssertTrue(source.contains("SecureField("), "Cloud key entry must use secure text entry")
        XCTAssertTrue(source.contains("Save key"), "Cloud key editor needs a visible commit action")
        XCTAssertTrue(source.contains("Clear key"), "Cloud key editor needs a visible delete action")
        XCTAssertTrue(source.contains("accessibilityLabel(\"ElevenLabs API key\")"), "Secure key field needs a purpose label")
        XCTAssertTrue(source.contains("accessibilityLabel(\"Save ElevenLabs API key\")"), "Save action must be accessible")
        XCTAssertTrue(source.contains("accessibilityLabel(\"Clear ElevenLabs API key\")"), "Clear action must be accessible")
        XCTAssertFalse(source.contains("accessibilityValue(model.apiKey)"), "Accessibility must not expose raw key values")
        XCTAssertTrue(source.contains("canCloseOrSurfaceUnsavedCloudKeyWarning"), "Close path must guard unsaved key edits")
        XCTAssertTrue(source.contains("windowShouldClose"), "Title-bar close must use the safe-close guard")
    }

    func testSettingsSavePersistsKeychainBeforeSettingsCommitAndReadinessRefresh() throws {
        let source = try String(contentsOfFile: appSourcePath("SettingsWindow.swift"), encoding: .utf8)

        guard let saveRange = source.range(of: "onSave: { [weak self, weak host] settings in") else {
            return XCTFail("Settings save handler not found")
        }
        let saveBody = String(source[saveRange.lowerBound..<source.index(saveRange.lowerBound, offsetBy: min(850, source.distance(from: saveRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(saveBody.contains("guard await model.persistAPIKeyIfChanged() else { return }"), "Save must stop if Keychain persistence fails")
        XCTAssertLessThan(saveBody.range(of: "persistAPIKeyIfChanged")!.lowerBound, saveBody.range(of: "self.store.commit")!.lowerBound, "Keychain persistence must happen before settings commit")
        XCTAssertLessThan(saveBody.range(of: "self.store.commit")!.lowerBound, saveBody.range(of: "model.refreshEngineViewState")!.lowerBound, "Readiness refresh must happen after persistence and settings commit")
        XCTAssertFalse(saveBody.contains("apiKey"), "Save handler must not write the raw key into settings")

        guard let persistRange = source.range(of: "func persistAPIKeyIfChanged(keychainOverride") else {
            return XCTFail("Keychain persistence helper with injectable seam not found")
        }
        let persistBody = String(source[persistRange.lowerBound..<source.index(persistRange.lowerBound, offsetBy: min(1400, source.distance(from: persistRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(persistBody.contains("KeychainStore(service: keychainService, account: keychainAccount)"), "Key writes must go through the configured Keychain locator")
        XCTAssertTrue(persistBody.contains("try keychain.write(candidate)"), "Saving must write the key to Keychain")
        XCTAssertTrue(persistBody.contains("try keychain.delete()"), "Clearing must delete the Keychain item")
        XCTAssertTrue(persistBody.contains("Could not update the ElevenLabs API key in Keychain"), "Failure copy must be non-secret and actionable")
        XCTAssertFalse(persistBody.contains("localizedDescription"), "Keychain failure UI should not echo low-level strings that may include sensitive context")
    }

    func testSaveKeyAndClearKeyCommitNonSecretSettingsViaOnCommitSettings() throws {
        let source = try String(contentsOfFile: appSourcePath("SettingsWindow.swift"), encoding: .utf8)

        // Save key button: Keychain persist must happen before onCommitSettings
        guard let saveKeyRange = source.range(of: "\"Save key\"") else {
            return XCTFail("Save key button not found")
        }
        let saveKeyBody = String(source[saveKeyRange.lowerBound..<source.index(saveKeyRange.lowerBound, offsetBy: min(700, source.distance(from: saveKeyRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(saveKeyBody.contains("persistAPIKeyIfChanged"), "Save key must call persistAPIKeyIfChanged (Keychain-first)")
        XCTAssertTrue(saveKeyBody.contains("onCommitSettings"), "Save key must call onCommitSettings to commit concurrent non-secret settings on success")
        let persistIdx = saveKeyBody.range(of: "persistAPIKeyIfChanged")!.lowerBound
        let commitIdx = saveKeyBody.range(of: "onCommitSettings")!.lowerBound
        XCTAssertLessThan(persistIdx, commitIdx, "persistAPIKeyIfChanged must appear before onCommitSettings in Save key body")
        // Failure path: onCommitSettings is NOT called when Keychain fails (guarded by `if ok`)
        XCTAssertTrue(saveKeyBody.contains("if ok"), "Save key must guard onCommitSettings on Keychain success")

        // Clear key button: Keychain delete must happen before onCommitSettings
        guard let clearKeyRange = source.range(of: "\"Clear key\"") else {
            return XCTFail("Clear key button not found")
        }
        let clearKeyBody = String(source[clearKeyRange.lowerBound..<source.index(clearKeyRange.lowerBound, offsetBy: min(700, source.distance(from: clearKeyRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(clearKeyBody.contains("clearCloudAPIKey"), "Clear key must call clearCloudAPIKey (Keychain-first)")
        XCTAssertTrue(clearKeyBody.contains("onCommitSettings"), "Clear key must call onCommitSettings to commit concurrent non-secret settings on success")
        let clearIdx = clearKeyBody.range(of: "clearCloudAPIKey")!.lowerBound
        let clearCommitIdx = clearKeyBody.range(of: "onCommitSettings")!.lowerBound
        XCTAssertLessThan(clearIdx, clearCommitIdx, "clearCloudAPIKey must appear before onCommitSettings in Clear key body")
        XCTAssertTrue(clearKeyBody.contains("if ok"), "Clear key must guard onCommitSettings on Keychain success")

        // FidelityCloudAPIKeyEditor must declare and receive onCommitSettings
        guard let editorRange = source.range(of: "struct FidelityCloudAPIKeyEditor") else {
            return XCTFail("FidelityCloudAPIKeyEditor struct not found")
        }
        let editorDecl = String(source[editorRange.lowerBound..<source.index(editorRange.lowerBound, offsetBy: min(600, source.distance(from: editorRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(editorDecl.contains("onCommitSettings"), "FidelityCloudAPIKeyEditor must declare onCommitSettings property")

        // FidelityCloudAPIKeyEditor init site in FidelityAudioPanel must pass onCommitSettings
        guard let editorInitRange = source.range(of: "FidelityCloudAPIKeyEditor(") else {
            return XCTFail("FidelityCloudAPIKeyEditor instantiation not found")
        }
        let editorInit = String(source[editorInitRange.lowerBound..<source.index(editorInitRange.lowerBound, offsetBy: min(400, source.distance(from: editorInitRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(editorInit.contains("onCommitSettings"), "FidelityCloudAPIKeyEditor must be initialized with onCommitSettings callback")
    }

    func testProductionSettingsRetryAndRemoveButtonsCallAppOwnedLocalModelManagerActions() throws {
        let source = try String(contentsOfFile: appSourcePath("SettingsWindow.swift"), encoding: .utf8)
        let appDelegate = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)

        XCTAssertTrue(appDelegate.contains("onRetryLocalModel"), "AppDelegate must inject a production retry side-effect into Settings")
        XCTAssertTrue(appDelegate.contains("localModelManager.retryDownload()"), "visible Settings Retry must call the app-owned LocalModelManager.retryDownload()")
        XCTAssertTrue(appDelegate.contains("onClearLocalModelCache"), "AppDelegate must inject a production clear-cache side-effect into Settings")
        XCTAssertTrue(appDelegate.contains("localModelManager.clearCache()"), "confirmed Settings Remove must call the app-owned LocalModelManager.clearCache()")

        guard let retryRange = source.range(of: "case .startLocalRetry:") else { return XCTFail("SettingsFormModel must handle retry effect") }
        let retryBody = String(source[retryRange.lowerBound..<source.index(retryRange.lowerBound, offsetBy: min(260, source.distance(from: retryRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(retryBody.contains("await onRetryLocalModel()"), "Retry button handler must invoke the injected production side-effect")

        guard let clearRange = source.range(of: "case .clearLocalModelCache:") else { return XCTFail("SettingsFormModel must handle clear-cache effect") }
        let clearBody = String(source[clearRange.lowerBound..<source.index(clearRange.lowerBound, offsetBy: min(360, source.distance(from: clearRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(clearBody.contains("try await onClearLocalModelCache()"), "Remove confirmation must invoke clear cache only after confirmation")

        guard let removeButton = source.range(of: "case .remove:") else { return XCTFail("Visible Remove action must exist") }
        let removeSnippet = String(source[removeButton.lowerBound..<source.index(removeButton.lowerBound, offsetBy: min(220, source.distance(from: removeButton.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(removeSnippet.contains("requestRemoveLocalModel"), "Visible Remove should first request confirmation")
        XCTAssertFalse(removeSnippet.contains("clearLocalModelCache"), "Visible Remove must not clear cache before confirmation")
    }

    func testProductionSetupRequiredActionsOpenFocusedEngineCards() throws {
        let appDelegate = try String(contentsOfFile: appSourcePath("AppDelegate.swift"), encoding: .utf8)
        let settings = try String(contentsOfFile: appSourcePath("SettingsWindow.swift"), encoding: .utf8)

        XCTAssertTrue(appDelegate.contains("settingsWindowController?.show(focus: self.setupEngineFocus)"), "Setup Required Settings action must pass a card focus instead of opening generic Settings")
        XCTAssertTrue(appDelegate.contains("SessionRepairRouting.engineSettingsFocus"), "Session-specific Local repairs must focus the Local Engine card")
        XCTAssertTrue(appDelegate.contains("EngineSettingsNavigation.focus"), "Cloud missing-key and Local blockers must route through Engine Settings navigation")
        XCTAssertTrue(settings.contains("focusedEngineCard"), "Settings must retain Engine card focus state for visible focus treatment")
        XCTAssertTrue(settings.contains("settingsEngineFocusRequested"), "Already-open Settings must accept focused Engine deep links")
    }

    private func appSourcePath(_ file: String) -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent() // Storage
            .deletingLastPathComponent() // TranscriberCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let scribeDir = repoRoot.appendingPathComponent("TranscriberApp/Scribe")
        if file == "AppDelegate.swift",
           let combined = Self.combinedAppDelegateSourcePath(scribeDir: scribeDir) {
            return combined
        }
        if file == "SettingsWindow.swift",
           let combined = Self.combinedSettingsWindowSourcePath(scribeDir: scribeDir) {
            return combined
        }
        return scribeDir.appendingPathComponent(file).path
    }

    /// AppDelegate is split across AppDelegate.swift plus AppDelegate+<Area>.swift
    /// extension files. Source guards treat them as one logical source, so the
    /// split files are concatenated into a temp file read like the original
    /// single file.
    private static func combinedAppDelegateSourcePath(scribeDir: URL) -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: scribeDir.path) else { return nil }
        let parts = ["AppDelegate.swift"]
            + names.filter { $0.hasPrefix("AppDelegate+") && $0.hasSuffix(".swift") }.sorted()
        let combined = parts.compactMap {
            try? String(contentsOfFile: scribeDir.appendingPathComponent($0).path, encoding: .utf8)
        }.joined(separator: "\n")
        guard combined.isEmpty == false else { return nil }
        let url = fm.temporaryDirectory.appendingPathComponent(
            "scribe-appdelegate-combined-\(ProcessInfo.processInfo.processIdentifier).swift")
        guard (try? combined.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url.path
    }

    /// SettingsWindow is split across files under Settings/. Source guards treat
    /// them as one logical source, so the split files are concatenated in the
    /// original file's layout order (declarations before their call sites) into
    /// a temp file read like the original single file.
    private static func combinedSettingsWindowSourcePath(scribeDir: URL) -> String? {
        let fm = FileManager.default
        let settingsDir = scribeDir.appendingPathComponent("Settings")
        guard let names = try? fm.contentsOfDirectory(atPath: settingsDir.path) else { return nil }
        let layoutOrder = [
            "SettingsWindowController.swift", "SettingsFormModel.swift", "SettingsForm.swift",
            "FidelityChrome.swift", "ShortcutCapture.swift", "GeneralPanel.swift",
            "AudioPanel.swift", "ShortcutsPanel.swift", "VaultPanel.swift",
            "PrivacyPanel.swift", "PermissionsPanel.swift", "AboutPanel.swift",
            "FidelityComponents.swift", "PermissionsOnboardingWindow.swift",
            "InstalledAppSmokeSettingsFrame.swift",
        ]
        let parts = layoutOrder.filter { names.contains($0) }
            + names.filter { $0.hasSuffix(".swift") && !layoutOrder.contains($0) }.sorted()
        let combined = parts.compactMap {
            try? String(contentsOfFile: settingsDir.appendingPathComponent($0).path, encoding: .utf8)
        }.joined(separator: "\n")
        guard combined.isEmpty == false else { return nil }
        let url = fm.temporaryDirectory.appendingPathComponent(
            "scribe-settingswindow-combined-\(ProcessInfo.processInfo.processIdentifier).swift")
        guard (try? combined.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url.path
    }
}

private struct StubEngineReadiness: EngineReadinessProbing {
    let cloudKey: Bool
    let localStatus: LocalModelCacheStatus
    func cloudKeyAvailable() async -> Bool { cloudKey }
    func localModelStatus() async -> LocalModelCacheStatus { localStatus }
    func localModelID() -> String { CohereMLXBackend.modelID }
}
