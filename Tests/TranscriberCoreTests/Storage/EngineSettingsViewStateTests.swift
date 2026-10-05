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
        let source = try CombinedAppSources.appSource("SettingsWindow.swift")

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

    func testProductionSetupRequiredActionsOpenFocusedEngineCards() throws {
        let appDelegate = try CombinedAppSources.appSource("AppDelegate.swift")
        let settings = try CombinedAppSources.appSource("SettingsWindow.swift")

        XCTAssertTrue(appDelegate.contains("settingsWindowController?.show(focus: self.setupEngineFocus)"), "Setup Required Settings action must pass a card focus instead of opening generic Settings")
        XCTAssertTrue(appDelegate.contains("SessionRepairRouting.engineSettingsFocus"), "Session-specific Local repairs must focus the Local Engine card")
        XCTAssertTrue(appDelegate.contains("EngineSettingsNavigation.focus"), "Cloud missing-key and Local blockers must route through Engine Settings navigation")
        XCTAssertTrue(settings.contains("focusedEngineCard"), "Settings must retain Engine card focus state for visible focus treatment")
        XCTAssertTrue(settings.contains("settingsEngineFocusRequested"), "Already-open Settings must accept focused Engine deep links")
    }

}

private struct StubEngineReadiness: EngineReadinessProbing {
    let cloudKey: Bool
    let localStatus: LocalModelCacheStatus
    func cloudKeyAvailable() async -> Bool { cloudKey }
    func localModelStatus() async -> LocalModelCacheStatus { localStatus }
    func localModelID() -> String { CohereMLXBackend.modelID }
}
