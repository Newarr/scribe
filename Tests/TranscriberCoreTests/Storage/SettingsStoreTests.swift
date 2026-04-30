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

        let snap = await store.snapshot()
        XCTAssertEqual(snap.outputRoot, altRoot)
        XCTAssertEqual(snap.engineMode, .local)
        XCTAssertEqual(snap.keepRawStreams, true)
        XCTAssertEqual(snap.aecEnabled, false)
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
        await store.commit(target)
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
                privacyAcknowledged: true
            )
        )
        let snap = await store.snapshot()
        XCTAssertEqual(snap.engineMode, .local)
        XCTAssertEqual(snap.keepRawStreams, true)
        XCTAssertEqual(snap.aecEnabled, false)
        XCTAssertEqual(snap.privacyAcknowledged, true)
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
        await store.commit(target)

        let syncSnap = SettingsSnapshotReader.read(
            from: suite.box,
            fallback: .init(outputRoot: root)
        )
        XCTAssertEqual(syncSnap, target)
    }
}
