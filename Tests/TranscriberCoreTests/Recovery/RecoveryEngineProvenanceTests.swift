import XCTest
@testable import TranscriberCore

final class RecoveryEngineProvenanceTests: XCTestCase {
    func testPersistedLocalRequiresReadyModelForRecovery() {
        let unavailable = RecoveryEngineProvenance.resolve(
            sessionEngineIdentifier: "cohere",
            localModelStatus: .notDownloaded(modelID: CohereMLXBackend.modelID)
        )
        XCTAssertEqual(unavailable, .localSetupRequired)
        XCTAssertNil(unavailable.engineMode, "unavailable Local recovery must not construct Local or fall back to Cloud")

        let ready = RecoveryEngineProvenance.resolve(
            sessionEngineIdentifier: "cohere",
            localModelStatus: .verified(LocalModelCacheInfo(modelID: CohereMLXBackend.modelID, cacheURL: URL(fileURLWithPath: "/tmp/model"), diskUsageBytes: 1))
        )
        XCTAssertEqual(ready, .localReady)
        XCTAssertEqual(ready.engineMode, .local)
    }

    func testPersistedCloudDoesNotConsultLocalReadinessForRecovery() {
        let provenance = RecoveryEngineProvenance.resolve(
            sessionEngineIdentifier: "elevenlabs",
            localModelStatus: .verified(LocalModelCacheInfo(modelID: CohereMLXBackend.modelID, cacheURL: URL(fileURLWithPath: "/tmp/model"), diskUsageBytes: 1))
        )
        XCTAssertEqual(provenance, .cloud)
        XCTAssertEqual(provenance.engineMode, .cloud)
    }

    func testMissingEngineProvenanceFailsClosed() {
        let provenance = RecoveryEngineProvenance.resolve(
            sessionEngineIdentifier: "unknown",
            localModelStatus: .verified(LocalModelCacheInfo(modelID: CohereMLXBackend.modelID, cacheURL: URL(fileURLWithPath: "/tmp/model"), diskUsageBytes: 1))
        )
        XCTAssertEqual(provenance, .missingOrInvalid)
        XCTAssertNil(provenance.engineMode, "missing provenance must not default to current Settings or ElevenLabs")
    }
}
