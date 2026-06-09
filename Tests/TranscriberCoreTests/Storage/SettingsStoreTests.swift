import XCTest
@testable import TranscriberCore

final class SettingsStoreTests: XCTestCase {
    private struct TestSuite {
        let box: UserDefaultsBox
        let suiteName: String
    }

    private func makeSuite() throws -> TestSuite {
        // Per-test ephemeral suite so test runs don't pollute each other
        // OR the developer's actual UserDefaults.
        let suiteName = "test.SettingsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("could not create UserDefaults suite")
        }
        let box = UserDefaultsBox(defaults)
        // Capture the box (Sendable) instead of the raw UserDefaults.
        addTeardownBlock { box.defaults.removePersistentDomain(forName: suiteName) }
        return TestSuite(box: box, suiteName: suiteName)
    }

    private func tempDir() -> URL {
        // isDirectory:true so trailing-slash representation matches
        // SettingsStore's URL(fileURLWithPath:..., isDirectory: true)
        // round-trip — otherwise stored vs read URL string differ.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testEmptyStoreReturnsFallbacks() async throws {
        let suite = try makeSuite()
        let root = tempDir()
        let store = SettingsStore(
            defaults: suite.box,
            fallback: .init(outputRoot: root)
        )
        let snap = await store.snapshot()
        XCTAssertEqual(snap.outputRoot, root)
        XCTAssertEqual(snap.engineMode, .cloud)
        XCTAssertEqual(snap.keepRawStreams, false, "spec line 102 default OFF")
        XCTAssertEqual(snap.aecEnabled, true, "D2 default ON")
        XCTAssertEqual(snap.privacyAcknowledged, false, "spec line 348: first launch must re-prompt")
        XCTAssertEqual(snap.appearanceTheme, .system)
        XCTAssertEqual(snap.launchAtLogin, false)
        XCTAssertEqual(snap.showInMenuBar, true)
        XCTAssertEqual(snap.startStopShortcut, .defaultStartStop)
        XCTAssertNil(snap.transcriptionLanguage, "default language is Auto (nil)")
    }

    func testTranscriptionLanguageIsRoundTrippedAndClearable() async throws {
        let suite = try makeSuite()
        let root = tempDir()
        let store = SettingsStore(
            defaults: suite.box,
            fallback: .init(outputRoot: root)
        )

        await store.setTranscriptionLanguage("pl")
        let forced = await store.snapshot()
        XCTAssertEqual(forced.transcriptionLanguage, "pl")

        // Back to Auto: nil must overwrite the stored code, not be
        // dropped by the encoder.
        await store.setTranscriptionLanguage(nil)
        let auto = await store.snapshot()
        XCTAssertNil(auto.transcriptionLanguage)
    }

    func testPrivacyAckIsRoundTripped() async throws {
        let suite = try makeSuite()
        let root = tempDir()
        let store = SettingsStore(
            defaults: suite.box,
            fallback: .init(outputRoot: root)
        )
        let preSnap = await store.snapshot()
        XCTAssertEqual(preSnap.privacyAcknowledged, false)

        await store.setPrivacyAcknowledged(true)
        let postSnap = await store.snapshot()
        XCTAssertEqual(postSnap.privacyAcknowledged, true)
    }

    func testCommitCannotDemotePrivacyAcknowledgement() async throws {
        // Codex Phase η P0.3: privacyAcknowledged is a one-way flag (spec
        // line 348). A stale Settings form snapshot must not be able to
        // unset it after the user has acknowledged in another flow.
        let suite = try makeSuite()
        let root = tempDir()
        let store = SettingsStore(
            defaults: suite.box,
            fallback: .init(outputRoot: root)
        )

        // User acknowledges privacy.
        await store.setPrivacyAcknowledged(true)
        let postAck = await store.snapshot()
        XCTAssertEqual(postAck.privacyAcknowledged, true)

        // Stale Settings form (privacyAcknowledged=false in its frozen
        // snapshot) tries to commit. Store must preserve the true.
        let staleSettings = SessionSettings(
            outputRoot: root,
            engineMode: .local,
            keepRawStreams: true,
            aecEnabled: false,
            privacyAcknowledged: false  // stale
        )
        try await store.commit(staleSettings)

        let snap = await store.snapshot()
        XCTAssertEqual(snap.privacyAcknowledged, true, "store must NOT demote privacyAcknowledged from true to false")
        XCTAssertEqual(snap.engineMode, .local, "other fields must still commit normally")
    }

    func testOlderBlobMissingPrivacyAckRollsForwardAsFalse() async throws {
        // Spec line 348: a downgrade or pre-η blob without privacyAcknowledged
        // should re-prompt rather than silently treating the user as having
        // ack'd. Plant a blob with the legacy fields only and assert the
        // missing field decodes as false.
        let suite = try makeSuite()
        let root = tempDir()
        let legacyJSON = """
        {
            "outputRoot": "\(root.absoluteString)",
            "engineMode": "cloud",
            "keepRawStreams": false,
            "aecEnabled": true
        }
        """
        suite.box.defaults.set(Data(legacyJSON.utf8), forKey: SettingsStore.Key.storage.rawValue)

        let store = SettingsStore(defaults: suite.box, fallback: .init(outputRoot: root))
        let snap = await store.snapshot()
        XCTAssertEqual(snap.privacyAcknowledged, false, "missing privacy ack key must decode as not-acked")
        XCTAssertEqual(snap.appearanceTheme, .system, "older blobs missing appearanceTheme should follow macOS")
        XCTAssertEqual(snap.launchAtLogin, false, "older blobs missing launchAtLogin should not opt users in")
        XCTAssertEqual(snap.showInMenuBar, true, "older blobs missing showInMenuBar should keep the app accessible")
        XCTAssertEqual(snap.startStopShortcut, .defaultStartStop)
        XCTAssertNil(snap.transcriptionLanguage, "older blobs missing transcriptionLanguage should stay on Auto")
        XCTAssertEqual(snap.engineMode, .cloud, "non-missing fields must still decode normally")
    }

    func testWritesAreRoundTripped() async throws {
        let suite = try makeSuite()
        let root = tempDir()
        let altRoot = tempDir()
        let store = SettingsStore(
            defaults: suite.box,
            fallback: .init(outputRoot: root)
        )
        await store.setOutputRoot(altRoot)
        await store.setEngineMode(.local)
        await store.setKeepRawStreams(true)
        await store.setAECEnabled(false)
        await store.setAppearanceTheme(.light)
        await store.setLaunchAtLogin(true)
        await store.setShowInMenuBar(false)
        let shortcut = KeyboardShortcutSetting(key: "R", keyCode: 15, modifiers: [.command, .option])
        await store.setStartStopShortcut(shortcut)

        let snap = await store.snapshot()
        XCTAssertEqual(snap.outputRoot, altRoot)
        XCTAssertEqual(snap.engineMode, .local)
        XCTAssertEqual(snap.keepRawStreams, true)
        XCTAssertEqual(snap.aecEnabled, false)
        XCTAssertEqual(snap.appearanceTheme, .light)
        XCTAssertEqual(snap.launchAtLogin, true)
        XCTAssertEqual(snap.showInMenuBar, false)
        XCTAssertEqual(snap.startStopShortcut, shortcut)
    }

    func testCommitWritesAllKeysAtomically() async throws {
        // Phase ζ P1.4: a single commit() must overwrite every field at
        // once. Concurrent setters would force a read-modify-write cycle;
        // commit should bypass that and just stamp the whole struct.
        let suite = try makeSuite()
        let root = tempDir()
        let altRoot = tempDir()
        let store = SettingsStore(
            defaults: suite.box,
            fallback: .init(outputRoot: root)
        )
        let target = SessionSettings(
            outputRoot: altRoot,
            engineMode: .local,
            keepRawStreams: true,
            aecEnabled: false,
            privacyAcknowledged: true
        )
        try await store.commit(target)
        let snap = await store.snapshot()
        XCTAssertEqual(snap, target, "commit must persist every field")
    }

    func testCorruptStoredBlobFallsBackToDefaults() async throws {
        // Phase ζ P1.4 / P1.1: a malformed blob (e.g. older format,
        // truncation, wrong type planted by a downgrade) must NOT crash
        // and must NOT misclassify Bool fields as false. Snapshot must
        // return the spec-correct fallbacks.
        let suite = try makeSuite()
        let root = tempDir()
        suite.box.defaults.set(Data("definitely not json".utf8), forKey: SettingsStore.Key.storage.rawValue)

        let store = SettingsStore(
            defaults: suite.box,
            fallback: .init(outputRoot: root, engineMode: .cloud, keepRawStreams: false, aecEnabled: true)
        )
        let snap = await store.snapshot()
        XCTAssertEqual(snap.outputRoot, root)
        XCTAssertEqual(snap.engineMode, .cloud)
        XCTAssertEqual(snap.keepRawStreams, false)
        XCTAssertEqual(snap.aecEnabled, true, "corrupt blob must NOT silently coerce aecEnabled to false")
    }

    func testWrongTypePlantedUnderStorageKeyFallsBack() async throws {
        // A user with a downgraded version might have written a String
        // or an Int under the storage key (not realistic post-rc1, but
        // exercises the resilience path).
        let suite = try makeSuite()
        let root = tempDir()
        suite.box.defaults.set("string-where-we-expect-data", forKey: SettingsStore.Key.storage.rawValue)

        let store = SettingsStore(
            defaults: suite.box,
            fallback: .init(outputRoot: root, aecEnabled: true)
        )
        let snap = await store.snapshot()
        XCTAssertEqual(snap.aecEnabled, true)
    }

    func testSnapshotsAreImmutableValueTypes() async throws {
        // SessionSettings is a struct — taking a snapshot twice must
        // give two independent values, and mutating one must not affect
        // the store.
        //
        // Codex Phase ζ P2.2: also assert snap1 (mutated locally) is now
        // distinct from snap3 (re-fetched from store) so a future class
        // refactor that shared a reference would visibly fail.
        let suite = try makeSuite()
        let root = tempDir()
        let store = SettingsStore(
            defaults: suite.box,
            fallback: .init(outputRoot: root, keepRawStreams: false)
        )
        var snap1 = await store.snapshot()
        let snap2 = await store.snapshot()
        XCTAssertEqual(snap1, snap2)

        snap1.keepRawStreams.toggle()
        let snap3 = await store.snapshot()
        XCTAssertEqual(snap2, snap3, "mutating a snapshot must not write back through to the store")
        XCTAssertNotEqual(snap1.keepRawStreams, snap3.keepRawStreams, "local mutation must diverge from the store snapshot")
    }

    func testDefaultsConstructorAcceptsCustomFallbacks() async throws {
        let suite = try makeSuite()
        let root = tempDir()
        let store = SettingsStore(
            defaults: suite.box,
            fallback: .init(
                outputRoot: root,
                engineMode: .local,
                keepRawStreams: true,
                aecEnabled: false,
                privacyAcknowledged: true,
                appearanceTheme: .dark,
                launchAtLogin: true,
                showInMenuBar: false,
                startStopShortcut: KeyboardShortcutSetting(key: "R", keyCode: 15, modifiers: [.control])
            )
        )
        let snap = await store.snapshot()
        XCTAssertEqual(snap.engineMode, .local)
        XCTAssertEqual(snap.keepRawStreams, true)
        XCTAssertEqual(snap.aecEnabled, false)
        XCTAssertEqual(snap.privacyAcknowledged, true)
        XCTAssertEqual(snap.appearanceTheme, .dark)
        XCTAssertEqual(snap.launchAtLogin, true)
        XCTAssertEqual(snap.showInMenuBar, false)
        XCTAssertEqual(snap.startStopShortcut, KeyboardShortcutSetting(key: "R", keyCode: 15, modifiers: [.control]))
    }

    func testSyncReaderObservesStoreCommit() async throws {
        // SettingsSnapshotReader is the synchronous counterpart for
        // MainActor-bound code. After the actor commits, a sync read of
        // the same UserDefaultsBox must see the new state.
        let suite = try makeSuite()
        let root = tempDir()
        let altRoot = tempDir()
        let store = SettingsStore(
            defaults: suite.box,
            fallback: .init(outputRoot: root)
        )
        let target = SessionSettings(
            outputRoot: altRoot,
            engineMode: .local,
            keepRawStreams: true,
            aecEnabled: false,
            privacyAcknowledged: true
        )
        try await store.commit(target)

        let syncSnap = SettingsSnapshotReader.read(
            from: suite.box,
            fallback: .init(outputRoot: root)
        )
        XCTAssertEqual(syncSnap, target)
    }
    func testEngineSelectionRefusesUnavailableLocalAndPreservesPriorEngine() async throws {
        let current = EngineMode.cloud
        let unavailableStates: [LocalModelCacheStatus] = [
            .notDownloaded(modelID: CohereMLXBackend.modelID),
            .downloading(modelID: CohereMLXBackend.modelID, progress: .init(completedBytes: 1, totalBytes: 10)),
            .verifying(modelID: CohereMLXBackend.modelID),
            .failed(modelID: CohereMLXBackend.modelID, reason: .init(code: .verificationFailed, message: "bad cache"), retryAvailable: true),
            .unsupported(modelID: CohereMLXBackend.modelID, reason: .init(code: .unsupportedRuntime, message: "unsupported"))
        ]

        for status in unavailableStates {
            let attempt = await EngineSelectionPolicy.evaluate(
                requested: .local,
                current: current,
                readiness: StubReadiness(cloudKey: true, localStatus: status)
            )
            XCTAssertFalse(attempt.accepted, "Local must not be selectable for \(status)")
            XCTAssertEqual(attempt.selectedEngineMode, current)
            XCTAssertNotNil(attempt.repairReason)
        }
    }

    func testEngineSelectionAcceptsVerifiedLocalWithoutRestart() async throws {
        let verified = LocalModelCacheStatus.verified(.init(modelID: CohereMLXBackend.modelID, cacheURL: tempDir(), diskUsageBytes: 1))
        let attempt = await EngineSelectionPolicy.evaluate(
            requested: .local,
            current: .cloud,
            readiness: StubReadiness(cloudKey: false, localStatus: verified)
        )
        XCTAssertTrue(attempt.accepted)
        XCTAssertEqual(attempt.selectedEngineMode, .local)
        XCTAssertNil(attempt.repairReason)
    }


    func testSetEngineModeIfReadyPreservesConcurrentSettingsMutation() async throws {
        let suite = try makeSuite()
        let root = tempDir()
        let concurrentRoot = tempDir()
        let store = SettingsStore(defaults: suite.box, fallback: .init(outputRoot: root, engineMode: .cloud))
        let readiness = SuspendingReadiness(localStatus: .verified(.init(
            modelID: CohereMLXBackend.modelID,
            cacheURL: tempDir(),
            diskUsageBytes: 1
        )))

        let selectionTask = Task {
            await store.setEngineModeIfReady(.local, readiness: readiness)
        }

        await readiness.waitUntilProbeStarted()
        await store.setOutputRoot(concurrentRoot)
        await store.setKeepRawStreams(true)
        await store.setAECEnabled(false)
        await store.setAppearanceTheme(.dark)
        await store.setPrivacyAcknowledged(true)
        await readiness.resume()

        let attempt = await selectionTask.value
        XCTAssertTrue(attempt.accepted)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.engineMode, .local)
        XCTAssertEqual(snapshot.outputRoot, concurrentRoot)
        XCTAssertEqual(snapshot.keepRawStreams, true)
        XCTAssertEqual(snapshot.aecEnabled, false)
        XCTAssertEqual(snapshot.appearanceTheme, .dark)
        XCTAssertEqual(snapshot.privacyAcknowledged, true)
    }

    func testStoreSetEngineModeIfReadyDoesNotPersistRejectedLocal() async throws {
        let suite = try makeSuite()
        let root = tempDir()
        let store = SettingsStore(defaults: suite.box, fallback: .init(outputRoot: root, engineMode: .cloud))

        let rejected = await store.setEngineModeIfReady(.local, readiness: StubReadiness(
            cloudKey: true,
            localStatus: .failed(modelID: CohereMLXBackend.modelID, reason: .init(code: .verificationFailed, message: "removed"), retryAvailable: true)
        ))
        XCTAssertFalse(rejected.accepted)
        let rejectedSnapshot = await store.snapshot()
        XCTAssertEqual(rejectedSnapshot.engineMode, .cloud)

        let accepted = await store.setEngineModeIfReady(.local, readiness: StubReadiness(
            cloudKey: false,
            localStatus: .verified(.init(modelID: CohereMLXBackend.modelID, cacheURL: root, diskUsageBytes: 1))
        ))
        XCTAssertTrue(accepted.accepted)
        let acceptedSnapshot = await store.snapshot()
        XCTAssertEqual(acceptedSnapshot.engineMode, .local)
    }

    @MainActor
    func testSettingsFormModelLocalReadinessAwaitCommitsFreshUIDraftAndPreservesPrivacyAck() async throws {
        let suite = try makeSuite()
        let root = tempDir()
        let concurrentRoot = tempDir()
        let store = SettingsStore(defaults: suite.box, fallback: .init(outputRoot: root, engineMode: .cloud))
        let readiness = SuspendingReadiness(localStatus: .verified(.init(
            modelID: CohereMLXBackend.modelID,
            cacheURL: tempDir(),
            diskUsageBytes: 1
        )))
        let model = SettingsFormModelIntegrationHarness(initial: await store.snapshot(), readiness: readiness)

        let selectionTask = Task { @MainActor in
            await model.attemptEngineSelection(.local)
        }

        await readiness.waitUntilProbeStarted()
        model.outputRoot = concurrentRoot
        model.keepRawStreams = true
        model.aecEnabled = false
        model.appearanceTheme = .dark
        model.showInMenuBar = false
        model.startStopShortcut = KeyboardShortcutSetting(
            key: "R",
            keyCode: 15,
            modifiers: [.command, .option]
        )
        await store.setPrivacyAcknowledged(true)
        await readiness.resume()

        let attempt = await selectionTask.value
        XCTAssertTrue(attempt.accepted)
        try await store.commit(model.currentSettings)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.engineMode, .local)
        XCTAssertEqual(snapshot.outputRoot, concurrentRoot)
        XCTAssertEqual(snapshot.keepRawStreams, true)
        XCTAssertEqual(snapshot.aecEnabled, false)
        XCTAssertEqual(snapshot.appearanceTheme, .dark)
        XCTAssertEqual(snapshot.showInMenuBar, false)
        XCTAssertEqual(
            snapshot.startStopShortcut,
            KeyboardShortcutSetting(key: "R", keyCode: 15, modifiers: [.command, .option])
        )
        XCTAssertEqual(
            snapshot.privacyAcknowledged,
            true,
            "SettingsFormModel's stale initial snapshot must not demote a concurrent privacy acknowledgement"
        )
    }

    @MainActor
    func testSettingsFormModelCloudReadinessAwaitCommitsFreshUIDraftWithoutSecretPersistence() async throws {
        let suite = try makeSuite()
        let root = tempDir()
        let concurrentRoot = tempDir()
        let store = SettingsStore(defaults: suite.box, fallback: .init(outputRoot: root, engineMode: .local))
        let readiness = SuspendingReadiness(localStatus: .verified(.init(
            modelID: CohereMLXBackend.modelID,
            cacheURL: tempDir(),
            diskUsageBytes: 1
        )))
        let model = SettingsFormModelIntegrationHarness(initial: await store.snapshot(), readiness: readiness)

        let selectionTask = Task { @MainActor in
            await model.attemptEngineSelection(.cloud)
        }

        await readiness.waitUntilProbeStarted()
        model.outputRoot = concurrentRoot
        model.keepRawStreams = true
        model.aecEnabled = false
        model.launchAtLogin = true
        await readiness.resume()

        let attempt = await selectionTask.value
        XCTAssertTrue(attempt.accepted)
        try await store.commit(model.currentSettings)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.engineMode, .cloud)
        XCTAssertEqual(snapshot.outputRoot, concurrentRoot)
        XCTAssertEqual(snapshot.keepRawStreams, true)
        XCTAssertEqual(snapshot.aecEnabled, false)
        XCTAssertEqual(snapshot.launchAtLogin, true)
        XCTAssertEqual(snapshot.privacyAcknowledged, false)
    }

}


@MainActor
private final class SettingsFormModelIntegrationHarness {
    var outputRoot: URL
    var engineMode: EngineMode
    var keepRawStreams: Bool
    var aecEnabled: Bool
    var appearanceTheme: AppearanceTheme
    var launchAtLogin: Bool
    var showInMenuBar: Bool
    var startStopShortcut: KeyboardShortcutSetting

    private let initialSnapshot: SessionSettings
    private let readiness: any EngineReadinessProbing

    init(initial: SessionSettings, readiness: any EngineReadinessProbing) {
        self.initialSnapshot = initial
        self.outputRoot = initial.outputRoot
        self.engineMode = initial.engineMode
        self.keepRawStreams = initial.keepRawStreams
        self.aecEnabled = initial.aecEnabled
        self.appearanceTheme = initial.appearanceTheme
        self.launchAtLogin = initial.launchAtLogin
        self.showInMenuBar = initial.showInMenuBar
        self.startStopShortcut = initial.startStopShortcut
        self.readiness = readiness
    }

    var currentSettings: SessionSettings {
        SessionSettings(
            outputRoot: outputRoot,
            engineMode: engineMode,
            keepRawStreams: keepRawStreams,
            aecEnabled: aecEnabled,
            privacyAcknowledged: initialSnapshot.privacyAcknowledged,
            appearanceTheme: appearanceTheme,
            launchAtLogin: launchAtLogin,
            showInMenuBar: showInMenuBar,
            startStopShortcut: startStopShortcut
        )
    }

    func attemptEngineSelection(_ requestedMode: EngineMode) async -> EngineSelectionAttempt {
        let attempt = await EngineSelectionPolicy.evaluate(
            requested: requestedMode,
            current: engineMode,
            readiness: readiness
        )
        engineMode = attempt.selectedEngineMode
        return attempt
    }
}

private struct StubReadiness: EngineReadinessProbing {
    let cloudKey: Bool
    let localStatus: LocalModelCacheStatus

    func cloudKeyAvailable() async -> Bool { cloudKey }
    func localModelStatus() async -> LocalModelCacheStatus { localStatus }
    func localModelID() -> String { CohereMLXBackend.modelID }
}


private actor SuspendingReadiness: EngineReadinessProbing {
    private let localStatusValue: LocalModelCacheStatus
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var probeStarted = false
    private var resumed = false

    init(localStatus: LocalModelCacheStatus) {
        self.localStatusValue = localStatus
    }

    func cloudKeyAvailable() async -> Bool {
        await suspendUntilResumed()
        return true
    }

    func localModelStatus() async -> LocalModelCacheStatus {
        await suspendUntilResumed()
        return localStatusValue
    }

    nonisolated func localModelID() -> String { CohereMLXBackend.modelID }

    func waitUntilProbeStarted() async {
        if probeStarted { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func resume() {
        resumed = true
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    private func suspendUntilResumed() async {
        probeStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        if resumed { return }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }
}
