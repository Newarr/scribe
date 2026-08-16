import XCTest

/// Source guards for the auto-record cutover (plans/auto-record.md).
/// The pre-call start prompt is gone: detection records directly. What
/// survives is the EndGuard stop-prompt notification channel
/// (`EndPromptCoordinator`), the silent start path, and the discard
/// machinery.
final class StartPromptSourceTests: XCTestCase {
    private var source: String {
        get throws {
            try CombinedAppSources.appSource("EndPromptCoordinator.swift")
        }
    }

    // MARK: - End-prompt notification channel

    func testEndPromptNotificationActionsAreGenerationGuardedAndClearSurfaces() throws {
        let source = try source
        XCTAssertTrue(source.contains("let generation: Int"))
        XCTAssertTrue(source.contains(#""generation": generation"#), "end prompt notifications must carry the generation that produced them")
        XCTAssertTrue(source.contains("generation == entry.generation"), "notification actions must be ignored unless their generation is still active")
        XCTAssertTrue(source.contains("Ignoring stale end prompt notification action"))
        XCTAssertTrue(source.contains("clearEndPromptNotification(promptID: promptID)"), "accepted keep/stop notification actions must clear pending/delivered notification requests")
        XCTAssertTrue(source.contains("await entry.onKeep(entry.generation)"))
        XCTAssertTrue(source.contains("await entry.onStopNow(entry.generation)"))
    }

    func testEndPromptRegistrationUsesOnlyRecordingConsentActions() throws {
        let source = try source
        XCTAssertTrue(source.contains(#"title: "Keep Recording""#))
        XCTAssertTrue(source.contains(#"title: "Stop Now""#))
        XCTAssertFalse(source.contains("Import"))
        XCTAssertFalse(source.contains("Live Transcript"))
        XCTAssertFalse(source.contains("Transcript history"))
        XCTAssertFalse(source.contains("Summary"))
    }

    func testNotificationAuthorizationIsRequeriedForEveryPrompt() throws {
        let source = try source
        XCTAssertTrue(source.contains("Re-query every time instead of caching process-lifetime denial or"))
        XCTAssertFalse(source.contains("authorizationKnown"), "denied/granted notification authorization must not be cached for the app lifetime")
        XCTAssertFalse(source.contains("authorizationGranted"), "notification grant state must be re-read after System Settings changes")
        XCTAssertTrue(source.contains("let settings = await center.notificationSettings()"))
        XCTAssertTrue(source.contains("return try await center.requestAuthorization(options: [.alert, .sound])"))
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
}

/// Source guards for the silent-start path and the auto-record stop
/// flow, replacing the old prompt-preflight recovery guards.
final class PromptPreflightRecoverySourceTests: XCTestCase {
    private var appDelegateSource: String {
        get throws {
            try CombinedAppSources.appDelegate()
        }
    }

    func testDetectionCandidateAutoRecordsThroughTheSilentStartPath() throws {
        let source = try appDelegateSource
        XCTAssertFalse(source.contains("private func presentStartPrompt"), "the pre-call prompt handler is deleted")
        XCTAssertTrue(source.contains("origin: .detected"), "detection candidates start recording through the silent origin")
        XCTAssertTrue(source.contains("guard settings.autoRecordEnabled else"), "auto-record off parks the candidate instead of starting")
        XCTAssertTrue(source.contains("parkedCandidate = (candidate: candidate, event: event)"), "the parked hold is the single staged-start value")
    }

    func testSilentStartNeverOpensWindowsOnFailurePaths() throws {
        let source = try appDelegateSource
        guard let startRange = source.range(of: "func performStart(") else {
            return XCTFail("performStart must exist as the single start path")
        }
        let startBody = String(source[startRange.lowerBound..<source.index(startRange.lowerBound, offsetBy: min(6000, source.distance(from: startRange.lowerBound, to: source.endIndex)))])
        XCTAssertTrue(startBody.contains("let interactive = origin == .manual"), "the origin alone decides failure surfacing: one fact, one enum")
        XCTAssertFalse(startBody.contains("enum StartPresentation"), "the presentation enum must not exist apart from the origin")
        XCTAssertTrue(startBody.contains("if interactive {\n        presentPrivacyAcknowledgementIfNeeded()"), "only manual starts present the consent sheet")
        XCTAssertTrue(startBody.contains("if interactive {\n        denyStartForLowDisk"), "only manual starts show the low-disk alert")
        XCTAssertTrue(startBody.contains("if interactive {"), "only manual starts present onboarding/setup windows")
        XCTAssertTrue(startBody.contains("return .failed(reason:"), "silent failures return typed reasons")
    }

    func testParkedCandidateIsOneValueWithConsistentLifecycle() throws {
        let source = try appDelegateSource
        XCTAssertTrue(source.contains("var parkedCandidate: AppDelegate.StagedStart?"), "exactly one parked value, no companion flag")
        XCTAssertFalse(source.contains("var detectionAwaitingAction"), "the writable companion flag is gone")
        XCTAssertTrue(source.contains("parkedCandidate = nil"), "parked clears on consumption/discard/ended")
        XCTAssertTrue(source.contains("parkedCandidate != nil"), "the trust surface derives from the single parked value")
        // A failed detected start restores the hold instead of leaking a ghost identity.
        XCTAssertTrue(source.contains("Auto-record start declined"), "a failed silent start reports and keeps the hold for ended-call cleanup")
    }

    func testStopPathAutoDiscardsReleasesCandidateAndSuppressesSavedNotification() throws {
        let source = try appDelegateSource
        XCTAssertTrue(source.contains("AutoRecordPolicy.shouldAutoDiscard("), "stop consults the auto-record policy")
        XCTAssertTrue(source.contains("discardRequested"), "an explicit Discard overrides the threshold")
        XCTAssertTrue(source.contains("discardStoppedSession("), "the discard tail exists")
        XCTAssertTrue(source.contains("keepStoppedSession("), "the keep tail is shared by the normal stop and the failed-discard fallback")
        XCTAssertTrue(source.contains("await detectionEngine?.releaseActiveCandidate(candidate)"), "auto-discard releases its candidate so detection can re-fire")
        XCTAssertTrue(source.contains("if origin == .manual {"), "only manual sessions present the saved notification")
        XCTAssertTrue(source.contains("try dir.moveToTrash()"), "discard moves the folder to Trash")
    }

    func testWorkerTrackingIsOneTableKeyedByDirectory() throws {
        let source = try appDelegateSource
        XCTAssertTrue(source.contains("var inflightSessions: [UUID: (task: Task<Void, Never>, directory: URL?)]"), "one inflight table with optional directories")
        XCTAssertFalse(source.contains("workerTasksByDirectory"), "the second map is gone")
        XCTAssertTrue(source.contains("inflightSessions[id] = (task: task, directory: dir.url)"), "worker dispatch registers with its directory")
        XCTAssertTrue(source.contains("$0.value.directory == url"), "Recents Discard cancels by directory through the one table")
    }

    func testRequiredSetupStillOutranksDetectedIcon() throws {
        let source = try appDelegateSource
        XCTAssertTrue(source.contains("setupNeedsAttention = true"), "required preflight denial should surface Setup Required")
        XCTAssertTrue(source.contains("menu?.setupNeedsAttention = true"), "required preflight denial should mark the popover setup state")
    }
}
