import XCTest
@testable import TranscriberCore

final class SettingsStoreTests: XCTestCase {
    private struct TestSuite {
        let defaults: UserDefaults
        let suiteName: String
    }

    private func makeSuite() throws -> TestSuite {
        // Per-test ephemeral suite so test runs don't pollute each other
        // OR the developer's actual UserDefaults.
        let suiteName = "test.SettingsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("could not create UserDefaults suite")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return TestSuite(defaults: defaults, suiteName: suiteName)
    }

    private func tempDir() -> URL {
        // isDirectory:true so the trailing-slash representation matches
        // SettingsStore's `URL(fileURLWithPath: path, isDirectory: true)`
        // round-trip — otherwise the stored vs. read URL string differ
        // by one trailing `/`.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testEmptyStoreReturnsFallbacks() async throws {
        let suite = try makeSuite()
        let root = tempDir()
        let store = SettingsStore(
            defaults: suite.defaults,
            fallback: .init(outputRoot: root)
        )
        let snap = await store.snapshot()
        XCTAssertEqual(snap.outputRoot, root)
        XCTAssertEqual(snap.engineMode, .cloud)
        XCTAssertEqual(snap.keepRawStreams, false, "spec line 102 default OFF")
        XCTAssertEqual(snap.aecEnabled, true, "D2 default ON")
    }

    func testWritesAreRoundTripped() async throws {
        let suite = try makeSuite()
        let root = tempDir()
        let altRoot = tempDir()
        let store = SettingsStore(
            defaults: suite.defaults,
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

    func testExplicitFalseIsDistinguishedFromUnset() async throws {
        // Codex regression guard: a Bool-only `defaults.bool(forKey:)`
        // returns false for both "unset" and "set to false." For
        // aecEnabled where the fallback is true, that matters: an unset
        // key should read true, but a deliberate user-set false must read
        // false.
        let suite = try makeSuite()
        let root = tempDir()
        let store = SettingsStore(
            defaults: suite.defaults,
            fallback: .init(outputRoot: root, aecEnabled: true)
        )
        let unsetSnap = await store.snapshot()
        XCTAssertEqual(unsetSnap.aecEnabled, true, "unset key honors fallback")

        await store.setAECEnabled(false)
        let setSnap = await store.snapshot()
        XCTAssertEqual(setSnap.aecEnabled, false, "explicit false overrides fallback")
    }

    func testInvalidEngineModeStringFallsBackToDefault() async throws {
        let suite = try makeSuite()
        let root = tempDir()
        suite.defaults.set("nonsense-engine", forKey: SettingsStore.Key.engineMode.rawValue)
        let store = SettingsStore(
            defaults: suite.defaults,
            fallback: .init(outputRoot: root, engineMode: .cloud)
        )
        let snap = await store.snapshot()
        XCTAssertEqual(snap.engineMode, .cloud, "garbage in defaults must not crash; fall back to default")
    }

    func testSnapshotsAreImmutableValueTypes() async throws {
        // SessionSettings is a struct — taking a snapshot twice must
        // give two independent values, and mutating one must not affect
        // the store. (Failsafe against a future refactor turning it into
        // a class.)
        let suite = try makeSuite()
        let root = tempDir()
        let store = SettingsStore(
            defaults: suite.defaults,
            fallback: .init(outputRoot: root)
        )
        var snap1 = await store.snapshot()
        let snap2 = await store.snapshot()
        XCTAssertEqual(snap1, snap2)

        snap1.keepRawStreams.toggle()
        let snap3 = await store.snapshot()
        XCTAssertEqual(snap2, snap3, "mutating a snapshot must not write back through to the store")
    }

    func testDefaultsConstructorAcceptsCustomFallbacks() async throws {
        let suite = try makeSuite()
        let root = tempDir()
        let store = SettingsStore(
            defaults: suite.defaults,
            fallback: .init(
                outputRoot: root,
                engineMode: .local,
                keepRawStreams: true,
                aecEnabled: false
            )
        )
        let snap = await store.snapshot()
        XCTAssertEqual(snap.engineMode, .local)
        XCTAssertEqual(snap.keepRawStreams, true)
        XCTAssertEqual(snap.aecEnabled, false)
    }
}
