@testable import ScribeAppLogic
import TranscriberCore
import XCTest

@MainActor
final class SettingsFormModelTests: XCTestCase {
    func testSaveWritesTrimmedKeyBeforeCommittingSettings() async {
        let keychain = FormKeychain()
        let model = makeModel(keychain)
        model.apiKey = "  test-key  "
        var committed: SessionSettings?
        let saved = await model.persistAPIKeyIfChanged { settings in
            XCTAssertEqual(keychain.readValue(), "test-key")
            committed = settings
        }
        XCTAssertTrue(saved)
        XCTAssertEqual(committed, model.currentSettings)
        XCTAssertEqual(model.apiKey, "test-key")
        XCTAssertFalse(model.cloudAPIKeyHasChanges)
        XCTAssertTrue(model.canCloseOrSurfaceUnsavedCloudKeyWarning())
    }

    func testClearDeletesKeyBeforeCommittingSettings() async {
        let keychain = FormKeychain(value: "saved-key")
        let model = makeModel(keychain)
        var commits = 0
        let cleared = await model.clearCloudAPIKey { _ in
            XCTAssertNil(keychain.readValue())
            commits += 1
        }
        XCTAssertTrue(cleared)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(model.apiKey, "")
        XCTAssertFalse(model.cloudAPIKeyHasChanges)
    }

    func testFailedSaveRetainsEditAndDoesNotCommitSettingsOrAllowClose() async {
        let keychain = FormKeychain(value: "old-key", fails: true)
        let model = makeModel(keychain)
        model.apiKey = "secret-new-key"
        let saved = await model.persistAPIKeyIfChanged { _ in XCTFail("Settings committed after Keychain failure") }
        XCTAssertFalse(saved)
        XCTAssertEqual(keychain.readValue(), "old-key")
        XCTAssertEqual(model.apiKey, "secret-new-key")
        XCTAssertTrue(model.cloudAPIKeyHasChanges)
        XCTAssertFalse(model.saveError?.contains("secret-new-key") ?? true)
        XCTAssertFalse(model.isSavingCloudAPIKey)
        XCTAssertFalse(model.canCloseOrSurfaceUnsavedCloudKeyWarning())
    }

    func testFailedClearRetainsSavedKeyAndDoesNotCommitSettingsOrAllowClose() async {
        let keychain = FormKeychain(value: "saved-key", fails: true)
        let model = makeModel(keychain)
        let cleared = await model.clearCloudAPIKey { _ in XCTFail("Settings committed after Keychain failure") }
        XCTAssertFalse(cleared)
        XCTAssertEqual(keychain.readValue(), "saved-key")
        XCTAssertTrue(model.cloudAPIKeyHasChanges)
        XCTAssertFalse(model.canCloseOrSurfaceUnsavedCloudKeyWarning())
    }

    func testWhitespaceEditDeletesKey() async {
        let keychain = FormKeychain(value: "saved-key")
        let model = makeModel(keychain)
        model.apiKey = "  \n "
        let saved = await model.persistAPIKeyIfChanged { _ in XCTAssertNil(keychain.readValue()) }
        XCTAssertTrue(saved)
        XCTAssertEqual(model.apiKey, "")
    }

    func testRetryAndConfirmedRemovalInvokeModelActionsWithoutChangingEngine() async {
        let keychain = FormKeychain()
        var retries = 0
        var removals = 0
        let model = SettingsFormModel(
            initial: SessionSettings(
                outputRoot: URL(fileURLWithPath: "/tmp/scribe-settings-test"), engineMode: .local,
                keepRawStreams: false, aecEnabled: false, privacyAcknowledged: true
            ),
            keychainService: "unused", keychainAccount: "unused",
            engineReadiness: FormReadiness(keychain: keychain), keychain: keychain,
            onRetryLocalModel: {
                retries += 1
                return .notDownloaded(modelID: "test")
            },
            onClearLocalModelCache: { removals += 1 }
        )
        await model.handleEngineAction(.retryLocalSetup)
        XCTAssertEqual(retries, 1)
        await model.handleEngineAction(.requestRemoveLocalModel)
        XCTAssertEqual(removals, 0)
        XCTAssertNotNil(model.pendingLocalModelRemoval)
        await model.handleEngineAction(.cancelRemoveLocalModel)
        XCTAssertNil(model.pendingLocalModelRemoval)
        XCTAssertEqual(removals, 0)
        await model.handleEngineAction(.requestRemoveLocalModel)
        await model.handleEngineAction(.confirmRemoveLocalModel)
        XCTAssertEqual(removals, 1)
        XCTAssertNil(model.pendingLocalModelRemoval)
        XCTAssertEqual(model.engineMode, .local)
    }

    func testEngineSelectionPreservesEditsDuringReadinessAndConcurrentPrivacyAcknowledgement() async throws {
        for requested: EngineMode in [.local, .cloud] {
            let suiteName = "test.SettingsFormModel.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let editedRoot = root.appendingPathComponent("edited", isDirectory: true)
            try FileManager.default.createDirectory(at: editedRoot, withIntermediateDirectories: true)
            let store = SettingsStore(
                defaults: UserDefaultsBox(defaults),
                fallback: .init(outputRoot: root, engineMode: requested == .local ? .cloud : .local)
            )
            let readiness = SuspendedFormReadiness(modelURL: root)
            let keychain = FormKeychain(value: "saved-key")
            let model = SettingsFormModel(
                initial: await store.snapshot(), keychainService: "unused", keychainAccount: "unused",
                engineReadiness: readiness, keychain: keychain
            )
            let selection = Task { await model.attemptEngineSelection(requested) }
            await readiness.waitUntilSuspended()
            model.outputRoot = editedRoot
            model.keepRawStreams = true
            model.aecEnabled = false
            model.appearanceTheme = .dark
            model.launchAtLogin = true
            model.showInMenuBar = false
            model.transcriptionLanguage = "pl"
            model.apiKey = "unsaved-key"
            model.startStopShortcut = .init(key: "R", keyCode: 15, modifiers: [.command, .option])
            await store.setPrivacyAcknowledged(true)
            await readiness.resume()
            let attempt = await selection.value
            XCTAssertTrue(attempt.accepted)
            try await store.commit(model.currentSettings)
            let snapshot = await store.snapshot()
            XCTAssertEqual(snapshot.engineMode, requested)
            XCTAssertEqual(snapshot.outputRoot, editedRoot)
            XCTAssertTrue(snapshot.keepRawStreams)
            XCTAssertFalse(snapshot.aecEnabled)
            XCTAssertEqual(snapshot.appearanceTheme, .dark)
            XCTAssertTrue(snapshot.launchAtLogin)
            XCTAssertFalse(snapshot.showInMenuBar)
            XCTAssertEqual(snapshot.transcriptionLanguage, "pl")
            XCTAssertEqual(snapshot.startStopShortcut, .init(key: "R", keyCode: 15, modifiers: [.command, .option]))
            XCTAssertTrue(snapshot.privacyAcknowledged)
            XCTAssertEqual(keychain.readValue(), "saved-key")
            XCTAssertTrue(model.cloudAPIKeyHasChanges)
        }
    }

    private func makeModel(_ keychain: FormKeychain) -> SettingsFormModel {
        SettingsFormModel(
            initial: SessionSettings(
                outputRoot: URL(fileURLWithPath: "/tmp/scribe-settings-test"), engineMode: .cloud,
                keepRawStreams: false, aecEnabled: false, privacyAcknowledged: true
            ),
            keychainService: "unused", keychainAccount: "unused",
            engineReadiness: FormReadiness(keychain: keychain), keychain: keychain
        )
    }
}

private final class FormKeychain: KeychainPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private let fails: Bool

    init(value: String? = nil, fails: Bool = false) {
        self.value = value
        self.fails = fails
    }

    func readValue() -> String? { lock.withLock { value } }
    func read(allowingUserInteraction: Bool) throws -> String? { readValue() }

    func write(_ value: String) throws {
        if fails { throw Failure.rejected }
        lock.withLock { self.value = value }
    }

    func delete(allowingUserInteraction: Bool) throws {
        if fails { throw Failure.rejected }
        lock.withLock { value = nil }
    }

    private enum Failure: Error { case rejected }
}

private struct FormReadiness: EngineReadinessProbing {
    let keychain: FormKeychain
    func cloudKeyAvailable() async -> Bool { keychain.readValue() != nil }
    func localModelStatus() async -> LocalModelCacheStatus { .notDownloaded(modelID: "test") }
    func localModelID() -> String { "test" }
}

private actor SuspendedFormReadiness: EngineReadinessProbing {
    private let modelURL: URL
    private var resumed = false
    private var probes: [CheckedContinuation<Void, Never>] = []
    private var started: CheckedContinuation<Void, Never>?

    init(modelURL: URL) { self.modelURL = modelURL }

    func cloudKeyAvailable() async -> Bool {
        await suspend()
        return true
    }

    func localModelStatus() async -> LocalModelCacheStatus {
        await suspend()
        return .verified(.init(modelID: "test", cacheURL: modelURL, diskUsageBytes: 1))
    }

    nonisolated func localModelID() -> String { "test" }

    func waitUntilSuspended() async {
        if !probes.isEmpty { return }
        await withCheckedContinuation { started = $0 }
    }

    func resume() {
        resumed = true
        let pending = probes
        probes.removeAll()
        for continuation in pending { continuation.resume() }
    }

    private func suspend() async {
        if resumed { return }
        await withCheckedContinuation { continuation in
            probes.append(continuation)
            started?.resume()
            started = nil
        }
    }
}
