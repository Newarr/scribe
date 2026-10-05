import XCTest
@testable import TranscriberCore

final class OnboardingFlowTests: XCTestCase {

    func testRequiredOrderAndSkipSemanticsMatchSpec() {
        XCTAssertEqual(OnboardingFlowStep.ordered, [
            .welcome,
            .microphone,
            .calendar,
            .notifications,
            .screenRecording,
            .elevenLabsAPIKey,
            .chooseEngine,
            .outputFolder,
            .testRecording,
            .done
        ])
        XCTAssertEqual(
            OnboardingFlowStep.ordered.filter(\.canSkip),
            [.calendar, .notifications, .elevenLabsAPIKey]
        )
        XCTAssertFalse(OnboardingFlowStep.microphone.canSkip)
        XCTAssertFalse(OnboardingFlowStep.screenRecording.canSkip)
    }

    func testResumesAtFirstUnresolvedRequiredStep() {
        let outputRoot = URL(fileURLWithPath: "/tmp/Scribe", isDirectory: true)
        let localReady = LocalModelCacheStatus.verified(.init(modelID: CohereMLXBackend.modelID, cacheURL: outputRoot, diskUsageBytes: 1))

        XCTAssertEqual(OnboardingFlowPresenter.resumeStep(from: .init(
            microphone: .notDetermined,
            calendar: .granted,
            notifications: .granted,
            screenRecording: .granted,
            cloudKeyAvailable: true,
            localModelStatus: localReady,
            selectedEngine: .cloud,
            outputFolderReady: true,
            testRecordingComplete: false
        )), .microphone)

        XCTAssertEqual(OnboardingFlowPresenter.resumeStep(from: .init(
            microphone: .granted,
            calendar: .denied,
            notifications: .denied,
            screenRecording: .notDetermined,
            cloudKeyAvailable: true,
            localModelStatus: localReady,
            selectedEngine: .cloud,
            outputFolderReady: true,
            testRecordingComplete: false
        )), .screenRecording, "recommended Calendar/Notifications may be skipped; resume must not get stuck there")

        XCTAssertEqual(OnboardingFlowPresenter.resumeStep(from: .init(
            microphone: .granted,
            calendar: .denied,
            notifications: .denied,
            screenRecording: .granted,
            cloudKeyAvailable: false,
            localModelStatus: localReady,
            selectedEngine: .local,
            outputFolderReady: true,
            testRecordingComplete: false
        )), .testRecording)
    }

    func testScreenRecordingStepStartsCohereDownloadInBackgroundExactlyOnceAndCanRetryFailure() async {
        let starter = DownloadStarterSpy()
        let controller = OnboardingFlowController(downloadStarter: starter)

        let start = ContinuousClock.now
        await controller.enter(.screenRecording)
        let elapsed = start.duration(to: ContinuousClock.now)
        XCTAssertLessThan(elapsed, .milliseconds(200), "entering Screen Recording must return immediately instead of awaiting the multi-GB download")
        await controller.waitForStagingDispatch()
        let countsAfterEnter = await starter.counts()
        XCTAssertEqual(countsAfterEnter.start, 1, "background start should be scheduled before enter returns")

        await controller.enter(.screenRecording)
        await controller.enter(.screenRecording)
        await controller.waitForStagingDispatch()
        let firstCounts = await starter.counts()
        XCTAssertEqual(firstCounts.start, 1)
        XCTAssertEqual(firstCounts.retry, 0)

        await controller.retryLocalModelDownload()
        let retryCounts = await starter.counts()
        XCTAssertEqual(retryCounts.start, 1)
        XCTAssertEqual(retryCounts.retry, 1)
    }

    func testProductionOnboardingTestRecordingRouteAllowsScopedPrivacyPendingStartAndBlocksUnavailableStates() async {
        let readyLocal = LocalModelCacheStatus.verified(.init(modelID: CohereMLXBackend.modelID, cacheURL: URL(fileURLWithPath: "/tmp/model"), diskUsageBytes: 1))
        let pendingLocal = LocalModelCacheStatus.downloading(modelID: CohereMLXBackend.modelID, progress: .init(completedBytes: 1, totalBytes: 10))

        let starter = RouteStarterSpy(result: true)
        let route = OnboardingTestRecordingRoute(
            snapshot: {
                OnboardingResumeSnapshot(
                    microphone: .granted,
                    calendar: .denied,
                    notifications: .denied,
                    screenRecording: .granted,
                    cloudKeyAvailable: false,
                    localModelStatus: readyLocal,
                    selectedEngine: .local,
                    outputFolderReady: true,
                    testRecordingComplete: false
                )
            },
            starter: starter
        )

        let routeStarted = await route.run()
        XCTAssertTrue(routeStarted)
        let starterCalls = await starter.calls()
        XCTAssertEqual(starterCalls, [true], "ready onboarding Test Recording must start capture through the scoped privacy-pending route")

        let blockedStarter = RouteStarterSpy(result: true)
        let blockedRoute = OnboardingTestRecordingRoute(
            snapshot: {
                OnboardingResumeSnapshot(
                    microphone: .granted,
                    calendar: .granted,
                    notifications: .granted,
                    screenRecording: .granted,
                    cloudKeyAvailable: false,
                    localModelStatus: pendingLocal,
                    selectedEngine: .local,
                    outputFolderReady: true,
                    testRecordingComplete: false
                )
            },
            starter: blockedStarter
        )
        let blockedStarted = await blockedRoute.run()
        XCTAssertFalse(blockedStarted)
        let blockedCalls = await blockedStarter.calls()
        XCTAssertEqual(blockedCalls, [], "blocked Test Recording states must not start capture")
    }

    func testReadyTestRecordingInvokesCaptureSeamAndBlockedStatesDoNot() async {
        let readyLocal = LocalModelCacheStatus.verified(.init(modelID: CohereMLXBackend.modelID, cacheURL: URL(fileURLWithPath: "/tmp/model"), diskUsageBytes: 1))
        let pendingLocal = LocalModelCacheStatus.downloading(modelID: CohereMLXBackend.modelID, progress: .init(completedBytes: 1, totalBytes: 10))
        let failedLocal = LocalModelCacheStatus.failed(modelID: CohereMLXBackend.modelID, reason: .init(code: .downloadFailed, message: "No network"), retryAvailable: true)
        let unsupportedLocal = LocalModelCacheStatus.unsupported(modelID: CohereMLXBackend.modelID, reason: .init(code: .unsupportedRuntime, message: "No MLX"))
        let starter = TestRecordingStarterSpy(result: true)
        let gate = OnboardingTestRecordingGate(starter: starter)

        let readyLocalStarted = await gate.startIfReady(selectedEngine: .local, cloudKeyAvailable: false, localModelStatus: readyLocal, requiredCaptureReady: true)
        XCTAssertTrue(readyLocalStarted)
        let countAfterReadyLocal = await starter.startCount()
        XCTAssertEqual(countAfterReadyLocal, 1)

        let pendingLocalStarted = await gate.startIfReady(selectedEngine: .local, cloudKeyAvailable: false, localModelStatus: pendingLocal, requiredCaptureReady: true)
        XCTAssertFalse(pendingLocalStarted)
        let failedLocalStarted = await gate.startIfReady(selectedEngine: .local, cloudKeyAvailable: false, localModelStatus: failedLocal, requiredCaptureReady: true)
        XCTAssertFalse(failedLocalStarted)
        let unsupportedLocalStarted = await gate.startIfReady(selectedEngine: .local, cloudKeyAvailable: false, localModelStatus: unsupportedLocal, requiredCaptureReady: true)
        XCTAssertFalse(unsupportedLocalStarted)
        let missingCloudKeyStarted = await gate.startIfReady(selectedEngine: .cloud, cloudKeyAvailable: false, localModelStatus: readyLocal, requiredCaptureReady: true)
        XCTAssertFalse(missingCloudKeyStarted)
        let missingCaptureStarted = await gate.startIfReady(selectedEngine: .local, cloudKeyAvailable: false, localModelStatus: readyLocal, requiredCaptureReady: false)
        XCTAssertFalse(missingCaptureStarted)
        let countAfterBlockedStates = await starter.startCount()
        XCTAssertEqual(countAfterBlockedStates, 1, "blocked Test Recording states must not invoke capture")

        let readyCloudStarted = await gate.startIfReady(selectedEngine: .cloud, cloudKeyAvailable: true, localModelStatus: pendingLocal, requiredCaptureReady: true)
        XCTAssertTrue(readyCloudStarted)
        let countAfterReadyCloud = await starter.startCount()
        XCTAssertEqual(countAfterReadyCloud, 2)
    }

    func testChooseEngineExposesProgressFailureRetryAndIndependentReadiness() {
        let downloading = OnboardingFlowPresenter.chooseEngineState(cloudKeyAvailable: false, localModelStatus: .downloading(
            modelID: CohereMLXBackend.modelID,
            progress: .init(completedBytes: 25, totalBytes: 100)
        ))
        XCTAssertFalse(downloading.cloud.isReady)
        XCTAssertEqual(downloading.cloud.statusText, "ElevenLabs API key required")
        XCTAssertFalse(downloading.local.isReady)
        XCTAssertEqual(downloading.local.modelID, CohereMLXBackend.modelID)
        XCTAssertEqual(downloading.local.progress?.fractionCompleted, 0.25)
        XCTAssertEqual(downloading.local.statusText, "Downloading Cohere model")
        XCTAssertFalse(downloading.local.retryAvailable)

        let failed = OnboardingFlowPresenter.chooseEngineState(cloudKeyAvailable: false, localModelStatus: .failed(
            modelID: CohereMLXBackend.modelID,
            reason: .init(code: .downloadFailed, message: "Network failed"),
            retryAvailable: true
        ))
        XCTAssertEqual(failed.local.statusText, "Cohere download failed")
        XCTAssertTrue(failed.local.retryAvailable)
        XCTAssertFalse(failed.cloud.isReady)

        let ready = OnboardingFlowPresenter.chooseEngineState(cloudKeyAvailable: true, localModelStatus: .verified(.init(
            modelID: CohereMLXBackend.modelID,
            cacheURL: URL(fileURLWithPath: "/tmp/model", isDirectory: true),
            diskUsageBytes: 42
        )))
        XCTAssertTrue(ready.cloud.isReady)
        XCTAssertTrue(ready.local.isReady)
        XCTAssertEqual(ready.local.statusText, "Cohere ready")
    }

    func testKeylessDefaultsToLocalOnlyAfterVerificationAndKeyedStaysCloud() {
        XCTAssertNil(OnboardingFlowPresenter.defaultEngineAfterVerification(
            cloudKeyAvailable: false,
            localModelStatus: .downloading(modelID: CohereMLXBackend.modelID, progress: .init(completedBytes: 0, totalBytes: 100)),
            currentSelection: .cloud
        ))

        XCTAssertEqual(OnboardingFlowPresenter.defaultEngineAfterVerification(
            cloudKeyAvailable: false,
            localModelStatus: .verified(.init(modelID: CohereMLXBackend.modelID, cacheURL: URL(fileURLWithPath: "/tmp/model"), diskUsageBytes: 1)),
            currentSelection: .cloud
        ), .local)

        XCTAssertEqual(OnboardingFlowPresenter.defaultEngineAfterVerification(
            cloudKeyAvailable: true,
            localModelStatus: .verified(.init(modelID: CohereMLXBackend.modelID, cacheURL: URL(fileURLWithPath: "/tmp/model"), diskUsageBytes: 1)),
            currentSelection: .cloud
        ), .cloud)
    }

    func testTestRecordingWaitsForSelectedEngineAndCapturePrerequisites() {
        let readyLocal = LocalModelCacheStatus.verified(.init(modelID: CohereMLXBackend.modelID, cacheURL: URL(fileURLWithPath: "/tmp/model"), diskUsageBytes: 1))
        let pendingLocal = LocalModelCacheStatus.downloading(modelID: CohereMLXBackend.modelID, progress: .init(completedBytes: 1, totalBytes: 10))
        let failedLocal = LocalModelCacheStatus.failed(modelID: CohereMLXBackend.modelID, reason: .init(code: .downloadFailed, message: "No network"), retryAvailable: true)
        let unsupportedLocal = LocalModelCacheStatus.unsupported(modelID: CohereMLXBackend.modelID, reason: .init(code: .unsupportedRuntime, message: "No MLX"))

        XCTAssertEqual(OnboardingFlowPresenter.testRecordingState(selectedEngine: .local, cloudKeyAvailable: false, localModelStatus: pendingLocal, requiredCaptureReady: true).waitingCopy, "Waiting for Cohere to finish downloading before the test recording.")
        XCTAssertEqual(OnboardingFlowPresenter.testRecordingState(selectedEngine: .local, cloudKeyAvailable: false, localModelStatus: failedLocal, requiredCaptureReady: true).waitingCopy, "Cohere download failed. Retry Local setup before the test recording.")
        XCTAssertEqual(OnboardingFlowPresenter.testRecordingState(selectedEngine: .local, cloudKeyAvailable: false, localModelStatus: unsupportedLocal, requiredCaptureReady: true).waitingCopy, "Cohere local transcription is not supported on this Mac.")
        XCTAssertEqual(OnboardingFlowPresenter.testRecordingState(selectedEngine: .cloud, cloudKeyAvailable: false, localModelStatus: readyLocal, requiredCaptureReady: true).waitingCopy, "Enter an ElevenLabs API key or choose Cohere (local) before the test recording.")
        XCTAssertEqual(OnboardingFlowPresenter.testRecordingState(selectedEngine: .local, cloudKeyAvailable: false, localModelStatus: readyLocal, requiredCaptureReady: false).waitingCopy, "Grant Microphone and System Audio Recording before the test recording.")

        XCTAssertTrue(OnboardingFlowPresenter.testRecordingState(selectedEngine: .local, cloudKeyAvailable: false, localModelStatus: readyLocal, requiredCaptureReady: true).isEnabled)
        XCTAssertTrue(OnboardingFlowPresenter.testRecordingState(selectedEngine: .cloud, cloudKeyAvailable: true, localModelStatus: pendingLocal, requiredCaptureReady: true).isEnabled)
    }

    // VAL-ONBOARDING-001 / VAL-ONBOARDING-005: ElevenLabs key step is
    // skippable (canSkip), routes to Local on skip, and has a secure key
    // entry path that refreshes Cloud readiness.

    func testElevenLabsAPIKeyStepIsSkippable() {
        XCTAssertTrue(
            OnboardingFlowStep.elevenLabsAPIKey.canSkip,
            "ElevenLabs API key step must be skippable so Cloud users can skip to Local"
        )
    }

    func testResumeRoutesBackToElevenLabsKeyStepWhenCloudSelectedAndKeyMissing() {
        let readyLocal = LocalModelCacheStatus.verified(.init(
            modelID: CohereMLXBackend.modelID,
            cacheURL: URL(fileURLWithPath: "/tmp/model"),
            diskUsageBytes: 1
        ))

        // Cloud selected, no key -> must resume at ElevenLabs key step
        let resumeStep = OnboardingFlowPresenter.resumeStep(from: .init(
            microphone: .granted,
            calendar: .denied,
            notifications: .denied,
            screenRecording: .granted,
            cloudKeyAvailable: false,
            localModelStatus: readyLocal,
            selectedEngine: .cloud,
            outputFolderReady: true,
            testRecordingComplete: false
        ))
        XCTAssertEqual(
            resumeStep,
            .elevenLabsAPIKey,
            "resume must return to ElevenLabs key step when Cloud is selected but no key is present"
        )
    }

    func testResumeSkipsElevenLabsKeyStepWhenLocalSelected() {
        let readyLocal = LocalModelCacheStatus.verified(.init(
            modelID: CohereMLXBackend.modelID,
            cacheURL: URL(fileURLWithPath: "/tmp/model"),
            diskUsageBytes: 1
        ))

        // Local selected, no key -> must skip ElevenLabs step and go to testRecording
        let resumeStep = OnboardingFlowPresenter.resumeStep(from: .init(
            microphone: .granted,
            calendar: .denied,
            notifications: .denied,
            screenRecording: .granted,
            cloudKeyAvailable: false,
            localModelStatus: readyLocal,
            selectedEngine: .local,
            outputFolderReady: true,
            testRecordingComplete: false
        ))
        XCTAssertNotEqual(
            resumeStep,
            .elevenLabsAPIKey,
            "resume must not stop at ElevenLabs key step when Local is selected"
        )
    }

    func testCloudEngineDisabledWithoutKeyInChooseEngine() {
        let cloudState = OnboardingFlowPresenter.chooseEngineState(
            cloudKeyAvailable: false,
            localModelStatus: .verified(.init(
                modelID: CohereMLXBackend.modelID,
                cacheURL: URL(fileURLWithPath: "/tmp/model"),
                diskUsageBytes: 1
            ))
        )
        XCTAssertFalse(
            cloudState.cloud.isReady,
            "Cloud engine must not be selectable in chooseEngine when key is absent"
        )
        XCTAssertTrue(
            cloudState.local.isReady,
            "Local engine must remain selectable when Cohere is verified, regardless of Cloud key"
        )
    }

    func testCloudEngineReadyAfterKeySaved() {
        let cloudReadyState = OnboardingFlowPresenter.chooseEngineState(
            cloudKeyAvailable: true,
            localModelStatus: .notDownloaded(modelID: CohereMLXBackend.modelID)
        )
        XCTAssertTrue(
            cloudReadyState.cloud.isReady,
            "Cloud engine must be ready in chooseEngine after key is saved"
        )
    }

    func testTestRecordingBlockedWithActionableCopyWhenCloudSelectedAndNoKeyAfterSkip() {
        // After skipping key entry with Cloud still selected, test recording must
        // be blocked with actionable copy, not silently enabled.
        let noKeyCloudBlocked = OnboardingFlowPresenter.testRecordingState(
            selectedEngine: .cloud,
            cloudKeyAvailable: false,
            localModelStatus: .notDownloaded(modelID: CohereMLXBackend.modelID),
            requiredCaptureReady: true
        )
        XCTAssertFalse(noKeyCloudBlocked.isEnabled, "test recording must not be enabled when Cloud is selected but no key is saved")
        XCTAssertNotNil(noKeyCloudBlocked.waitingCopy, "a blocking wait copy must be present so the user has actionable guidance")
    }

    func testOnboardingWindowSourceHasSecureFieldForElevenLabsKey() throws {
        let source = try CombinedAppSources.appSource("OnboardingWindow.swift")
        XCTAssertTrue(
            source.contains("SecureField"),
            "OnboardingWindow must use a SecureField for ElevenLabs key entry"
        )
        XCTAssertTrue(
            source.contains("saveCloudAPIKey"),
            "OnboardingWindow must expose a saveCloudAPIKey closure for Keychain-backed persistence"
        )
        XCTAssertTrue(
            source.contains("pendingAPIKey"),
            "OnboardingWindow must maintain pendingAPIKey state for the ElevenLabs key field"
        )
        XCTAssertTrue(
            source.contains("apiKeySaveError"),
            "OnboardingWindow must surface apiKeySaveError so Keychain failures are visible without revealing the key"
        )
    }

    func testOnboardingWindowSkipRoutesToLocalEngine() throws {
        let source = try CombinedAppSources.appSource("OnboardingWindow.swift")
        // Skip must route to local engine selection, not just advance blindly.
        XCTAssertTrue(
            source.contains("selectEngine(.local)"),
            "OnboardingWindow skip on the elevenLabsAPIKey step must select .local engine to route toward Local guidance"
        )
    }

    func testOnboardingWindowSaveKeyPathDoesNotAdvanceOnFailure() throws {
        let source = try CombinedAppSources.appSource("OnboardingWindow.swift")
        XCTAssertTrue(
            source.contains("apiKeySaveError ="),
            "OnboardingWindow must set apiKeySaveError and not advance when Keychain save fails"
        )
    }

    func testAppDelegateWiresSaveCloudAPIKeyClosureToKeychain() throws {
        let source = try CombinedAppSources.appSource("AppDelegate.swift")
        XCTAssertTrue(
            source.contains("saveCloudAPIKey:"),
            "AppDelegate must wire saveCloudAPIKey to OnboardingWindowController init"
        )
        XCTAssertTrue(
            source.contains("keychain.write(candidate)"),
            "AppDelegate saveCloudAPIKey closure must write the key to Keychain"
        )
    }

    func testScreenRecordingPrivacyCopyIsExplicit() {
        let copy = OnboardingFlowPresenter.screenRecordingCopy
        XCTAssertTrue(copy.whatIsCaptured.contains("microphone audio"))
        XCTAssertTrue(copy.whatIsCaptured.contains("system audio"))
        XCTAssertTrue(copy.whatIsNotCaptured.contains("video"))
        XCTAssertTrue(copy.whatIsNotCaptured.contains("screenshots"))
        XCTAssertTrue(copy.whatIsNotCaptured.contains("keystrokes"))
        XCTAssertTrue(copy.whatIsNotCaptured.contains("browser history"))
        XCTAssertTrue(copy.tagline.contains("no video or screen content ever leaves your machine"))
    }


    func testScreenRecordingDeferredGrantResultRequiresRelaunchGuidance() {
        let result = OnboardingScreenRecordingRequestResult(requestGranted: true, status: .denied)
        XCTAssertTrue(result.isDeferredGrantRequiringRelaunch)

        let guidance = OnboardingFlowPresenter.screenRecordingDeferredGuidance
        XCTAssertTrue(guidance.title.contains("Restart Scribe"))
        XCTAssertTrue(guidance.message.contains("macOS approved Screen & System Audio Recording"))
        XCTAssertTrue(guidance.message.contains("relaunches"))
        XCTAssertTrue(guidance.message.contains("onboarding will resume past this step"))
        XCTAssertEqual(guidance.actionTitle, "Relaunch Scribe")
    }

    func testScreenRecordingGrantedStatusIsNotDeferredAfterRelaunch() {
        let outputRoot = URL(fileURLWithPath: "/tmp/Scribe", isDirectory: true)
        let localReady = LocalModelCacheStatus.verified(.init(modelID: CohereMLXBackend.modelID, cacheURL: outputRoot, diskUsageBytes: 1))
        let result = OnboardingScreenRecordingRequestResult(requestGranted: false, status: .granted)
        XCTAssertFalse(result.isDeferredGrantRequiringRelaunch)

        XCTAssertEqual(OnboardingFlowPresenter.resumeStep(from: .init(
            microphone: .granted,
            calendar: .denied,
            notifications: .denied,
            screenRecording: .granted,
            cloudKeyAvailable: false,
            localModelStatus: localReady,
            selectedEngine: .local,
            outputFolderReady: false,
            testRecordingComplete: false
        )), .outputFolder, "after relaunch sees Screen Recording as granted, onboarding must resume past the Screen Recording step")
    }

    func testResumedOnboardingPastScreenRecordingStartsLocalModelStagingOnce() async {
        let starter = DownloadStarterSpy()
        let controller = OnboardingFlowController(downloadStarter: starter)
        let notDownloaded = LocalModelCacheStatus.notDownloaded(modelID: CohereMLXBackend.modelID)

        await controller.startLocalModelStagingIfNeeded(localModelStatus: notDownloaded)
        await controller.startLocalModelStagingIfNeeded(localModelStatus: notDownloaded)
        await controller.waitForStagingDispatch()

        let counts = await starter.counts()
        XCTAssertEqual(counts.start, 1, "resumed onboarding must start Local staging once even when it resumes after the Screen Recording visual step")
        XCTAssertEqual(counts.retry, 0)
    }

    func testLocalModelStagingDoesNotRestartWhenAlreadyReady() async {
        let starter = DownloadStarterSpy()
        let controller = OnboardingFlowController(downloadStarter: starter)
        let readyLocal = LocalModelCacheStatus.verified(.init(
            modelID: CohereMLXBackend.modelID,
            cacheURL: URL(fileURLWithPath: "/tmp/model"),
            diskUsageBytes: 1
        ))

        await controller.startLocalModelStagingIfNeeded(localModelStatus: readyLocal)
        let counts = await starter.counts()
        XCTAssertEqual(counts.start, 0)
        XCTAssertEqual(counts.retry, 0)
    }

    func testAutomaticLocalModelStagingContinuesForDownloadAppropriateStates() async {
        let states: [LocalModelCacheStatus] = [
            .notDownloaded(modelID: CohereMLXBackend.modelID),
            .downloading(modelID: CohereMLXBackend.modelID, progress: .init(completedBytes: 10, totalBytes: 100)),
            .verifying(modelID: CohereMLXBackend.modelID)
        ]

        for state in states {
            let starter = DownloadStarterSpy()
            let controller = OnboardingFlowController(downloadStarter: starter)

            await controller.startLocalModelStagingIfNeeded(localModelStatus: state)
            await controller.startLocalModelStagingIfNeeded(localModelStatus: state)
            await controller.waitForStagingDispatch()

            let counts = await starter.counts()
            XCTAssertEqual(counts.start, 1, "automatic onboarding staging should continue for download-appropriate state \(state)")
            XCTAssertEqual(counts.retry, 0)
        }
    }

    func testAutomaticLocalModelStagingDoesNotRestartFailedOrUnsupportedStates() async {
        let states: [LocalModelCacheStatus] = [
            .failed(
                modelID: CohereMLXBackend.modelID,
                reason: .init(code: .downloadFailed, message: "Network failed"),
                retryAvailable: true
            ),
            .failed(
                modelID: CohereMLXBackend.modelID,
                reason: .init(code: .verificationFailed, message: "Checksum mismatch"),
                retryAvailable: false
            ),
            .unsupported(
                modelID: CohereMLXBackend.modelID,
                reason: .init(code: .unsupportedRuntime, message: "No MLX runtime")
            )
        ]

        for state in states {
            let starter = DownloadStarterSpy()
            let controller = OnboardingFlowController(downloadStarter: starter)

            await controller.startLocalModelStagingIfNeeded(localModelStatus: state)

            let counts = await starter.counts()
            XCTAssertEqual(counts.start, 0, "automatic onboarding staging must leave failed/unsupported state visible for explicit repair: \(state)")
            XCTAssertEqual(counts.retry, 0)
        }
    }

    func testOnboardingWindowSourceSurfacesAccessibleDeferredScreenRecordingGuidance() throws {
        let source = try CombinedAppSources.appSource("OnboardingWindow.swift")
        XCTAssertTrue(source.contains("screenRecordingDeferredGrant"), "Onboarding must retain a deferred Screen Recording grant state")
        XCTAssertTrue(source.contains("OnboardingScreenRecordingRequestResult"), "Onboarding request seam must preserve requestGranted plus post-request status")
        XCTAssertTrue(source.contains("deferredScreenRecordingGuidance"), "Onboarding must render explicit deferred relaunch guidance")
        XCTAssertTrue(source.contains("guidance.actionTitle"), "Deferred guidance must expose the shared relaunch action")
        XCTAssertTrue(source.contains("accessibilityLabel(\"Warning:"), "Deferred warning must be announced as a warning to VoiceOver")
        XCTAssertTrue(source.contains("Screen Recording relaunch guidance"), "Deferred explanation must have accessible status text")
        XCTAssertTrue(source.contains("accessibilityHint"), "Relaunch action must include an accessibility hint")
    }

    func testOnboardingWindowSourcePreservesRecordOnlyCopyBoundaries() throws {
        let source = try CombinedAppSources.appSource("OnboardingWindow.swift")
        XCTAssertTrue(source.contains("records mic + system audio"))
        XCTAssertTrue(source.contains("durable Markdown transcripts next to saved audio"))

        let forbidden = [
            "import audio",
            "import transcript",
            "clipboard transcript",
            "live transcript",
            "transcript history",
            "summary",
            "summaries",
            "AI notes",
            "chat",
            "polish",
            "vector"
        ]
        for phrase in forbidden {
            XCTAssertFalse(source.localizedCaseInsensitiveContains(phrase), "Onboarding must not advertise unsupported product surface: \\(phrase)")
        }
    }


    func testInstalledVisualSnapshotsCoverKeyEntryAndSkipToLocalPath() throws {
        let source = try CombinedAppSources.appSource("SettingsWindow.swift")
        XCTAssertTrue(source.contains("onboarding-elevenlabs-key-entry-light"), "visual snapshot set must include the ElevenLabs key-entry step")
        XCTAssertTrue(source.contains("onboarding-skip-to-local-readiness-light"), "visual snapshot set must include the Skip-to-Local path")
        XCTAssertTrue(source.contains("Paste ElevenLabs API key…"), "key-entry snapshot must show the secure empty key field placeholder")
        XCTAssertTrue(source.contains("Continue with Local"), "skip path snapshot must expose the Local continuation")
    }

}

private actor DownloadStarterSpy: LocalModelDownloadStarting {
    private(set) var startCount = 0
    private(set) var retryCount = 0

    func counts() -> (start: Int, retry: Int) { (startCount, retryCount) }

    func startDownload() async -> LocalModelCacheStatus {
        startCount += 1
        return .downloading(modelID: CohereMLXBackend.modelID, progress: .init(completedBytes: 0, totalBytes: 100))
    }

    func retryDownload() async -> LocalModelCacheStatus {
        retryCount += 1
        return .downloading(modelID: CohereMLXBackend.modelID, progress: .init(completedBytes: 0, totalBytes: 100))
    }
}

private actor RouteStarterSpy: OnboardingRecordingRouteStarting {
    private let result: Bool
    private var invocations: [Bool] = []

    init(result: Bool) { self.result = result }

    func calls() -> [Bool] { invocations }

    func startRecording(allowPendingPrivacyAcknowledgementForOnboardingTest: Bool) async -> Bool {
        invocations.append(allowPendingPrivacyAcknowledgementForOnboardingTest)
        return result
    }
}

private actor TestRecordingStarterSpy: OnboardingTestRecordingStarting {
    private let result: Bool
    private var count = 0

    init(result: Bool) { self.result = result }

    func startCount() -> Int { count }

    func startTestRecording() async -> Bool {
        count += 1
        return result
    }
}
