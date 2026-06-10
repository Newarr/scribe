import XCTest
@testable import TranscriberCore

/// Behavioral tests for `CloudKeyCommitCoordinator` using a fake
/// `KeychainPersisting` seam.
///
/// These tests assert the three-step ordering contract:
///   1. Keychain save/delete is awaited first.
///   2. Non-secret settings commit happens only on Keychain success.
///   3. Readiness refresh happens after settings commit.
///
/// Failure path: Keychain throws → settings are NOT committed, readiness
/// is NOT refreshed, and close-guard is implicitly preserved (settings
/// remain open with an error).
final class CloudKeyCommitCoordinatorTests: XCTestCase {

    // MARK: - Save key (non-empty candidate) — success path

    func testSaveKeyInvokesKeychainWriteBeforeSettingsCommit() async {
        let log = ThreadSafeLog()
        let fake = ThrowingKeychain()
        fake.writeHandler = { _ in log.append("keychain.write") }
        let coordinator = makeCoordinator(
            keychain: fake,
            settingsCommit: { _ in log.append("settings.commit") },
            readinessRefresh: { log.append("readiness.refresh") }
        )

        let outcome = await coordinator.saveKey(candidate: "sk_test_abc", currentSettings: stubSettings)
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(log.entries, ["keychain.write", "settings.commit", "readiness.refresh"],
                       "Keychain write must precede settings commit and readiness refresh for Save key")
    }

    func testSaveKeyTrimsWhitespaceThenWritesToKeychain() async {
        var written: String?
        let fake = ThrowingKeychain()
        fake.writeHandler = { written = $0 }
        let coordinator = makeCoordinator(keychain: fake)

        let outcome = await coordinator.saveKey(candidate: "  sk_abc  \n", currentSettings: stubSettings)
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(written, "sk_abc", "Candidate must be trimmed before writing to Keychain")
    }

    // MARK: - Save key (empty candidate → delete) — success path

    func testSaveKeyWithEmptyCandidateInvokesKeychainDeleteBeforeSettingsCommit() async {
        let log = ThreadSafeLog()
        let fake = ThrowingKeychain()
        fake.deleteHandler = { log.append("keychain.delete") }
        let coordinator = makeCoordinator(
            keychain: fake,
            settingsCommit: { _ in log.append("settings.commit") },
            readinessRefresh: { log.append("readiness.refresh") }
        )

        let outcome = await coordinator.saveKey(candidate: "", currentSettings: stubSettings)
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(log.entries, ["keychain.delete", "settings.commit", "readiness.refresh"],
                       "Keychain delete must precede settings commit and readiness refresh for empty-candidate Save key")
    }

    // MARK: - Clear key — success path

    func testClearKeyInvokesKeychainDeleteBeforeSettingsCommit() async {
        let log = ThreadSafeLog()
        let fake = ThrowingKeychain()
        fake.deleteHandler = { log.append("keychain.delete") }
        let coordinator = makeCoordinator(
            keychain: fake,
            settingsCommit: { _ in log.append("settings.commit") },
            readinessRefresh: { log.append("readiness.refresh") }
        )

        let outcome = await coordinator.clearKey(currentSettings: stubSettings)
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(log.entries, ["keychain.delete", "settings.commit", "readiness.refresh"],
                       "Keychain delete must precede settings commit and readiness refresh for Clear key")
    }

    // MARK: - Keychain write failure — settings NOT committed

    func testSaveKeyKeychainWriteFailureDoesNotCommitSettingsOrRefreshReadiness() async {
        let log = ThreadSafeLog()
        let fake = ThrowingKeychain()
        fake.writeHandler = { _ in throw KeychainFakeError.simulatedFailure }
        let coordinator = makeCoordinator(
            keychain: fake,
            settingsCommit: { _ in log.append("settings.commit") },
            readinessRefresh: { log.append("readiness.refresh") }
        )

        let outcome = await coordinator.saveKey(candidate: "sk_test", currentSettings: stubSettings)
        guard case .keychainFailure(let msg) = outcome else {
            return XCTFail("Expected .keychainFailure, got \(outcome)")
        }
        XCTAssertFalse(msg.isEmpty, "Failure message must be non-empty")
        XCTAssertTrue(log.entries.isEmpty,
                      "Settings commit and readiness refresh must NOT be called when Keychain write fails; got: \(log.entries)")
    }

    // MARK: - Keychain delete failure — settings NOT committed

    func testClearKeyKeychainDeleteFailureDoesNotCommitSettingsOrRefreshReadiness() async {
        let log = ThreadSafeLog()
        let fake = ThrowingKeychain()
        fake.deleteHandler = { throw KeychainFakeError.simulatedFailure }
        let coordinator = makeCoordinator(
            keychain: fake,
            settingsCommit: { _ in log.append("settings.commit") },
            readinessRefresh: { log.append("readiness.refresh") }
        )

        let outcome = await coordinator.clearKey(currentSettings: stubSettings)
        guard case .keychainFailure = outcome else {
            return XCTFail("Expected .keychainFailure, got \(outcome)")
        }
        XCTAssertTrue(log.entries.isEmpty,
                      "Settings commit and readiness refresh must NOT be called when Keychain delete fails; got: \(log.entries)")
    }

    // MARK: - Settings commit receives correct snapshot

    func testSaveKeyPassesCurrentSettingsSnapshotToCommit() async {
        let committed = CommittedSettingsBox()
        let fake = ThrowingKeychain()
        let coordinator = makeCoordinator(
            keychain: fake,
            settingsCommit: { committed.record($0) }
        )

        let settings = stubSettings
        let outcome = await coordinator.saveKey(candidate: "sk_xyz", currentSettings: settings)
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(committed.value, settings,
                       "Settings commit must receive the caller-supplied current snapshot")
    }

    // MARK: - Error message is non-secret

    func testKeychainFailureMessageDoesNotContainSensitiveContext() async {
        let fake = ThrowingKeychain()
        fake.writeHandler = { _ in throw KeychainFakeError.simulatedFailure }
        let coordinator = makeCoordinator(keychain: fake)

        let outcome = await coordinator.saveKey(candidate: "sk_secret_value", currentSettings: stubSettings)
        guard case .keychainFailure(let msg) = outcome else {
            return XCTFail("Expected .keychainFailure")
        }
        XCTAssertFalse(msg.contains("sk_secret_value"),
                       "Failure message must not echo the raw key value")
        XCTAssertFalse(msg.lowercased().contains("osstatus"),
                       "Failure message must not include low-level OSStatus context")
    }

    // MARK: - Source guard: Save key / Clear key call onCommitSettings

    func testSettingsWindowSaveKeyClearKeyInvokeOnCommitSettingsAfterKeychainSuccess() throws {
        let source = try CombinedAppSources.settingsWindow()

        // Save key button must call onCommitSettings after successful Keychain persist
        guard let saveKeyRange = source.range(of: "\"Save key\"") else {
            return XCTFail("Save key button not found in SettingsWindow.swift")
        }
        let saveKeyContext = String(
            source[saveKeyRange.lowerBound..<source.index(
                saveKeyRange.lowerBound,
                offsetBy: min(600, source.distance(from: saveKeyRange.lowerBound, to: source.endIndex))
            )]
        )
        XCTAssertTrue(
            saveKeyContext.contains("persistAPIKeyIfChanged"),
            "Save key must call persistAPIKeyIfChanged for Keychain-first ordering"
        )
        XCTAssertTrue(
            saveKeyContext.contains("onCommitSettings"),
            "Save key must call onCommitSettings to commit concurrent non-secret settings after Keychain success"
        )
        // Keychain persist must appear before onCommitSettings call in the same button body
        let persistIdx = saveKeyContext.range(of: "persistAPIKeyIfChanged")!.lowerBound
        let commitIdx = saveKeyContext.range(of: "onCommitSettings")!.lowerBound
        XCTAssertLessThan(
            persistIdx, commitIdx,
            "persistAPIKeyIfChanged must be called before onCommitSettings in Save key"
        )

        // Clear key button must call onCommitSettings after successful Keychain delete
        guard let clearKeyRange = source.range(of: "\"Clear key\"") else {
            return XCTFail("Clear key button not found in SettingsWindow.swift")
        }
        let clearKeyContext = String(
            source[clearKeyRange.lowerBound..<source.index(
                clearKeyRange.lowerBound,
                offsetBy: min(600, source.distance(from: clearKeyRange.lowerBound, to: source.endIndex))
            )]
        )
        XCTAssertTrue(
            clearKeyContext.contains("clearCloudAPIKey"),
            "Clear key must call clearCloudAPIKey for Keychain-first ordering"
        )
        XCTAssertTrue(
            clearKeyContext.contains("onCommitSettings"),
            "Clear key must call onCommitSettings to commit concurrent non-secret settings after Keychain success"
        )
        let clearIdx = clearKeyContext.range(of: "clearCloudAPIKey")!.lowerBound
        let clearCommitIdx = clearKeyContext.range(of: "onCommitSettings")!.lowerBound
        XCTAssertLessThan(
            clearIdx, clearCommitIdx,
            "clearCloudAPIKey must be called before onCommitSettings in Clear key"
        )
    }

    func testSettingsWindowOnCommitSettingsIsPassedToCloudAPIKeyEditor() throws {
        let source = try CombinedAppSources.settingsWindow()

        // FidelityCloudAPIKeyEditor init site must pass onCommitSettings (or onSettingsChange)
        guard let editorRange = source.range(of: "FidelityCloudAPIKeyEditor(") else {
            return XCTFail("FidelityCloudAPIKeyEditor instantiation not found")
        }
        let editorInit = String(
            source[editorRange.lowerBound..<source.index(
                editorRange.lowerBound,
                offsetBy: min(400, source.distance(from: editorRange.lowerBound, to: source.endIndex))
            )]
        )
        XCTAssertTrue(
            editorInit.contains("onCommitSettings"),
            "FidelityCloudAPIKeyEditor must receive onCommitSettings callback at init site"
        )
    }

    // MARK: - Helpers

    private func makeCoordinator(
        keychain: any KeychainPersisting,
        settingsCommit: @escaping @Sendable (SessionSettings) async -> Void = { _ in },
        readinessRefresh: @escaping @Sendable () async -> Void = {}
    ) -> CloudKeyCommitCoordinator {
        CloudKeyCommitCoordinator(
            keychain: keychain,
            settingsCommit: settingsCommit,
            readinessRefresh: readinessRefresh
        )
    }

    private var stubSettings: SessionSettings {
        SessionSettings(
            outputRoot: URL(fileURLWithPath: "/tmp/scribe-test"),
            engineMode: .cloud,
            keepRawStreams: false,
            aecEnabled: true,
            privacyAcknowledged: true
        )
    }

}

// MARK: - Helpers

private enum KeychainFakeError: Error {
    case simulatedFailure
}

/// Box for capturing the committed settings value across @Sendable closures.
private final class CommittedSettingsBox: @unchecked Sendable {
    private var _value: SessionSettings?
    var value: SessionSettings? { _value }
    func record(_ s: SessionSettings) { _value = s }
}

/// Thread-safe ordered log for recording call sequences in tests.
private final class ThreadSafeLog: @unchecked Sendable {
    private var _entries: [String] = []
    private let lock = NSLock()

    var entries: [String] {
        lock.withLock { _entries }
    }

    func append(_ entry: String) {
        lock.withLock { _entries.append(entry) }
    }
}

/// Mutable fake `KeychainPersisting` with configurable throw/action handlers.
/// Uses `@unchecked Sendable` because handlers are set before any async work.
private final class ThrowingKeychain: KeychainPersisting, @unchecked Sendable {
    var writeHandler: ((String) throws -> Void)?
    var readHandler: (() throws -> String?)?
    var deleteHandler: (() throws -> Void)?

    func write(_ value: String) throws {
        try writeHandler?(value)
    }

    func read(allowingUserInteraction: Bool = true) throws -> String? {
        try readHandler?()
    }

    func delete(allowingUserInteraction: Bool = true) throws {
        try deleteHandler?()
    }
}
