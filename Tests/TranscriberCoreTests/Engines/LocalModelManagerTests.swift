import CryptoKit
import XCTest
@testable import TranscriberCore

final class LocalModelManagerTests: XCTestCase {
    private var root: URL!
    private let modelID = "beshkenadze/cohere-transcribe-03-2026-mlx-fp16"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("local-model-manager-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPartialDownloadDoesNotMarkLocalReadyUntilAtomicRename() async throws {
        let bytes = Data("verified model".utf8)
        let manifest = manifestFor(bytes: bytes)
        let downloader = BlockingDownloader(bytes: bytes)
        let manager = makeManager(manifest: manifest, downloader: downloader)

        let task = Task { await manager.startDownload() }
        await downloader.waitUntilStarted()

        let partial = modelRoot().appendingPathComponent("model.safetensors.partial")
        let final = modelRoot().appendingPathComponent("model.safetensors")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        let status = await manager.status()
        XCTAssertFalse(status.isReady)

        await downloader.unblock()
        let finalStatus = await task.value
        XCTAssertTrue(finalStatus.isReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
    }

    func testVerificationRejectsCorruptWrongTruncatedOrMismatchedArtifactsAndAcceptsPinnedExpectedArtifact() async throws {
        let expected = Data("expected artifact".utf8)
        let manifest = manifestFor(bytes: expected)
        let manager = makeManager(manifest: manifest, downloader: DataDownloader(bytes: expected))
        let final = modelRoot().appendingPathComponent("model.safetensors")
        try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)

        try Data("wrong artifact".utf8).write(to: final)
        var status = await manager.status()
        XCTAssertFalse(status.isReady)
        assertFailureCode(status, .verificationFailed)

        try expected.dropLast().write(to: final)
        status = await manager.status()
        XCTAssertFalse(status.isReady)
        assertFailureCode(status, .verificationFailed)

        try expected.write(to: final)
        status = await manager.status()
        XCTAssertTrue(status.isReady)
    }

    func testLowDiskPreflightBlocksDownloadAndLeavesNoFinalCache() async throws {
        let bytes = Data("verified model".utf8)
        let manifest = manifestFor(bytes: bytes, requiredFreeBytes: 1_000)
        let downloader = DataDownloader(bytes: bytes)
        let manager = makeManager(
            manifest: manifest,
            downloader: downloader,
            diskSpace: FixedDiskSpaceProbe(availableBytes: 999)
        )

        let status = await manager.startDownload()
        XCTAssertFalse(status.isReady)
        assertFailureCode(status, .insufficientDiskSpace)
        let downloadCount = await downloader.downloadCount()
        XCTAssertEqual(downloadCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelRoot().appendingPathComponent("model.safetensors").path))
    }

    func testFailedDownloadExposesReasonAndRetryReplacesPartialWithOneVerifiedCache() async throws {
        let bytes = Data("verified model".utf8)
        let manifest = manifestFor(bytes: bytes)
        let downloader = FailingThenSucceedingDownloader(successBytes: bytes)
        let manager = makeManager(manifest: manifest, downloader: downloader)

        let failed = await manager.startDownload()
        XCTAssertFalse(failed.isReady)
        assertFailureCode(failed, .downloadFailed)
        let partial = modelRoot().appendingPathComponent("model.safetensors.partial")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))

        let retried = await manager.retryDownload()
        XCTAssertTrue(retried.isReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        let finalFiles = try FileManager.default.contentsOfDirectory(atPath: modelRoot().path).filter { $0 == "model.safetensors" }
        XCTAssertEqual(finalFiles.count, 1)
    }

    func testClearCacheDeletesOnlyModelCacheAndLeavesUserSessionsUntouched() async throws {
        let bytes = Data("verified model".utf8)
        let manifest = manifestFor(bytes: bytes)
        let manager = makeManager(manifest: manifest, downloader: DataDownloader(bytes: bytes))
        let downloaded = await manager.startDownload()
        XCTAssertTrue(downloaded.isReady)

        let sessionsRoot = root.appendingPathComponent("Sessions", isDirectory: true)
        let session = sessionsRoot.appendingPathComponent("2026-05-09-Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let audio = session.appendingPathComponent("audio.m4a")
        let transcript = session.appendingPathComponent("transcript.md")
        let metadata = session.appendingPathComponent("metadata.json")
        try Data("audio".utf8).write(to: audio)
        try Data("transcript".utf8).write(to: transcript)
        try Data("metadata".utf8).write(to: metadata)

        try await manager.clearCache()

        XCTAssertFalse(FileManager.default.fileExists(atPath: modelRoot().path))
        XCTAssertEqual(try Data(contentsOf: audio), Data("audio".utf8))
        XCTAssertEqual(try Data(contentsOf: transcript), Data("transcript".utf8))
        XCTAssertEqual(try Data(contentsOf: metadata), Data("metadata".utf8))
    }

    func testVerifiedCachePersistsAcrossRelaunchWithoutRedownload() async throws {
        let bytes = Data("verified model".utf8)
        let manifest = manifestFor(bytes: bytes)
        let firstDownloader = DataDownloader(bytes: bytes)
        let first = makeManager(manifest: manifest, downloader: firstDownloader)
        let firstStatus = await first.startDownload()
        XCTAssertTrue(firstStatus.isReady)

        let secondDownloader = DataDownloader(bytes: bytes)
        let relaunched = makeManager(manifest: manifest, downloader: secondDownloader)
        let status = await relaunched.status()

        XCTAssertTrue(status.isReady)
        let relaunchDownloadCount = await secondDownloader.downloadCount()
        XCTAssertEqual(relaunchDownloadCount, 0)
    }

    func testConcurrentStartsCoalesceIntoOneDownloadAndOneVerifiedCache() async throws {
        let bytes = Data("verified model".utf8)
        let manifest = manifestFor(bytes: bytes)
        let downloader = BlockingDownloader(bytes: bytes)
        let manager = makeManager(manifest: manifest, downloader: downloader)

        async let first = manager.startDownload()
        async let second = manager.startDownload()
        async let third = manager.retryDownload()

        await downloader.waitUntilStarted()
        let inFlightDownloadCount = await downloader.downloadCount()
        XCTAssertEqual(inFlightDownloadCount, 1)
        await downloader.unblock()

        let statuses = await [first, second, third]
        XCTAssertTrue(statuses.allSatisfy(\.isReady))
        let finalDownloadCount = await downloader.downloadCount()
        XCTAssertEqual(finalDownloadCount, 1)
        let finalFiles = try FileManager.default.contentsOfDirectory(atPath: modelRoot().path).filter { $0 == "model.safetensors" }
        XCTAssertEqual(finalFiles.count, 1)
    }

    func testDownloadSourceIsConstrainedToPinnedModelAndExpectedArtifactSet() async throws {
        let bytes = Data("verified model".utf8)
        let manifest = manifestFor(bytes: bytes)
        let downloader = DataDownloader(bytes: bytes)
        let manager = makeManager(manifest: manifest, downloader: downloader)
        let status = await manager.startDownload()
        XCTAssertTrue(status.isReady)

        let requestedModelIDs = await downloader.requestedModelIDs()
        let requestedArtifactPaths = await downloader.requestedArtifactPaths()
        XCTAssertEqual(requestedModelIDs, [modelID])
        XCTAssertEqual(requestedArtifactPaths, ["model.safetensors"])
        XCTAssertEqual(manifest.modelID, CohereMLXBackend.modelID)
    }

    func testPinnedCohereManifestIncludesCompleteRequiredSidecarArtifactSet() {
        let manifest = LocalModelManifest.cohereTranscribePinned
        XCTAssertEqual(manifest.modelID, modelID)
        XCTAssertEqual(
            manifest.artifacts.map(\.relativePath),
            [
                "config.json",
                "conversion_summary.json",
                "key_map.json",
                "model.safetensors",
                "preprocessor_config.json",
                "special_tokens_map.json",
                "tokenizer.model",
                "tokenizer_config.json"
            ]
        )
        for artifact in manifest.artifacts {
            XCTAssertGreaterThan(artifact.byteCount, 0, artifact.relativePath)
            XCTAssertEqual(artifact.sha256Hex.count, 64, artifact.relativePath)
            XCTAssertTrue(Set(artifact.sha256Hex).subtracting(Set("0123456789abcdef")).isEmpty, artifact.relativePath)
            XCTAssertNotEqual(artifact.sha256Hex, String(repeating: "0", count: 64), artifact.relativePath)
        }
    }

    func testMissingOrTamperedSidecarKeepsLocalNotReady() async throws {
        let artifacts = fixtureArtifacts([
            "model.safetensors": Data("model".utf8),
            "config.json": Data("config".utf8),
            "tokenizer.model": Data("tokenizer".utf8),
            "tokenizer_config.json": Data("tokenizer config".utf8)
        ])
        let manifest = LocalModelManifest(modelID: modelID, artifacts: artifacts, requiredFreeBytes: 1)
        let manager = makeManager(manifest: manifest, downloader: ArtifactMapDownloader(artifactBytes: Dictionary(uniqueKeysWithValues: artifacts.map { ($0.relativePath, Data()) })))
        try writeFixtureArtifacts(artifacts, missing: "config.json")

        var status = await manager.status()
        XCTAssertFalse(status.isReady)

        try Data("tampered config".utf8).write(to: modelRoot().appendingPathComponent("config.json"))
        status = await manager.status()
        XCTAssertFalse(status.isReady)
        assertFailureCode(status, .verificationFailed)
    }

    func testWrongModelManifestIsRejectedBeforeDownload() async throws {
        let bytes = Data("verified model".utf8)
        let manifest = LocalModelManifest(
            modelID: "someone-else/other-model",
            artifacts: [LocalModelArtifact(relativePath: "model.safetensors", byteCount: Int64(bytes.count), sha256Hex: sha256(bytes))],
            requiredFreeBytes: 1
        )
        let downloader = DataDownloader(bytes: bytes)
        let manager = makeManager(manifest: manifest, downloader: downloader)

        let status = await manager.startDownload()
        XCTAssertFalse(status.isReady)
        assertFailureCode(status, .verificationFailed)
        let count = await downloader.downloadCount()
        XCTAssertEqual(count, 0)
    }

    func testDownloaderRequestsOnlyPinnedRepositoryAndFullExpectedArtifactSet() async throws {
        let bytesByPath: [String: Data] = [
            "model.safetensors": Data("model".utf8),
            "config.json": Data("config".utf8),
            "tokenizer.model": Data("tokenizer".utf8),
            "tokenizer_config.json": Data("tokenizer config".utf8)
        ]
        let manifest = LocalModelManifest(modelID: modelID, artifacts: fixtureArtifacts(bytesByPath), requiredFreeBytes: 1)
        let downloader = ArtifactMapDownloader(artifactBytes: bytesByPath)
        let manager = makeManager(manifest: manifest, downloader: downloader)

        let status = await manager.startDownload()
        XCTAssertTrue(status.isReady)
        let requestedModelIDs = await downloader.requestedModelIDs()
        let requestedArtifactPaths = await downloader.requestedArtifactPaths()
        XCTAssertEqual(requestedModelIDs, Array(repeating: modelID, count: manifest.artifacts.count))
        XCTAssertEqual(requestedArtifactPaths, manifest.artifacts.map(\.relativePath))
    }

    func testChecksumVerificationStreamsInBoundedChunks() throws {
        let chunkSize = 7
        let data = Data((0..<100).map { UInt8($0 % 251) })
        let url = root.appendingPathComponent("streaming-checksum.bin")
        try data.write(to: url)

        let digest = try LocalModelManager.sha256Hex(of: url, chunkSize: chunkSize)
        XCTAssertEqual(digest, sha256(data))
    }

    private func makeManager(
        manifest: LocalModelManifest,
        downloader: any LocalModelDownloading,
        diskSpace: any LocalModelDiskSpaceProbing = FixedDiskSpaceProbe(availableBytes: 1_000_000),
        runtime: any LocalModelRuntimeProbing = RuntimeProbe(available: true)
    ) -> LocalModelManager {
        LocalModelManager(cacheRoot: root.appendingPathComponent("ModelCache", isDirectory: true), manifest: manifest, downloader: downloader, diskSpace: diskSpace, runtime: runtime)
    }

    private func modelRoot() -> URL {
        root.appendingPathComponent("ModelCache", isDirectory: true)
            .appendingPathComponent(LocalModelManager.cacheDirectoryName(for: modelID), isDirectory: true)
    }

    private func manifestFor(bytes: Data, requiredFreeBytes: Int64 = 1) -> LocalModelManifest {
        LocalModelManifest(
            modelID: modelID,
            artifacts: [LocalModelArtifact(relativePath: "model.safetensors", byteCount: Int64(bytes.count), sha256Hex: sha256(bytes))],
            requiredFreeBytes: requiredFreeBytes
        )
    }

    private func fixtureArtifacts(_ bytesByPath: [String: Data]) -> [LocalModelArtifact] {
        bytesByPath.map { path, bytes in
            LocalModelArtifact(relativePath: path, byteCount: Int64(bytes.count), sha256Hex: sha256(bytes))
        }.sorted { $0.relativePath < $1.relativePath }
    }

    private func writeFixtureArtifacts(_ artifacts: [LocalModelArtifact], missing: String? = nil) throws {
        try FileManager.default.createDirectory(at: modelRoot(), withIntermediateDirectories: true)
        for artifact in artifacts where artifact.relativePath != missing {
            let url = modelRoot().appendingPathComponent(artifact.relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fixtureData(for: artifact).write(to: url)
        }
    }

    private func fixtureData(for artifact: LocalModelArtifact) -> Data {
        switch artifact.relativePath {
        case "model.safetensors": return Data("model".utf8)
        case "config.json": return Data("config".utf8)
        case "tokenizer.model": return Data("tokenizer".utf8)
        case "tokenizer_config.json": return Data("tokenizer config".utf8)
        default: return Data()
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func assertFailureCode(_ status: LocalModelCacheStatus, _ code: LocalModelFailureCode, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed(_, let reason, _) = status else {
            return XCTFail("Expected failed status, got \(status)", file: file, line: line)
        }
        XCTAssertEqual(reason.code, code, file: file, line: line)
    }
}

private actor DataDownloader: LocalModelDownloading {
    let bytes: Data
    private var count = 0
    private var modelIDs: [String] = []
    private var artifactPaths: [String] = []

    init(bytes: Data) {
        self.bytes = bytes
    }

    func download(artifact: LocalModelArtifact, modelID: String, to partialURL: URL, progress: @Sendable @escaping (Int64, Int64?) async -> Void) async throws {
        count += 1
        modelIDs.append(modelID)
        artifactPaths.append(artifact.relativePath)
        try bytes.write(to: partialURL)
        await progress(Int64(bytes.count), Int64(bytes.count))
    }

    func downloadCount() -> Int { count }
    func requestedModelIDs() -> [String] { modelIDs }
    func requestedArtifactPaths() -> [String] { artifactPaths }
}

private actor BlockingDownloader: LocalModelDownloading {
    let bytes: Data
    private var count = 0
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var unblockContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private var isUnblocked = false

    init(bytes: Data) {
        self.bytes = bytes
    }

    func download(artifact: LocalModelArtifact, modelID: String, to partialURL: URL, progress: @Sendable @escaping (Int64, Int64?) async -> Void) async throws {
        count += 1
        try bytes.write(to: partialURL)
        await progress(Int64(bytes.count / 2), Int64(bytes.count))
        hasStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        if !isUnblocked {
            await withCheckedContinuation { continuation in
                unblockContinuation = continuation
            }
        }
        await progress(Int64(bytes.count), Int64(bytes.count))
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func unblock() {
        isUnblocked = true
        unblockContinuation?.resume()
        unblockContinuation = nil
    }

    func downloadCount() -> Int { count }
}

private actor FailingThenSucceedingDownloader: LocalModelDownloading {
    let successBytes: Data
    private var count = 0

    init(successBytes: Data) {
        self.successBytes = successBytes
    }

    func download(artifact: LocalModelArtifact, modelID: String, to partialURL: URL, progress: @Sendable @escaping (Int64, Int64?) async -> Void) async throws {
        count += 1
        if count == 1 {
            try Data("failed partial".utf8).write(to: partialURL)
            await progress(1, Int64(successBytes.count))
            throw LocalModelManagerError.downloadFailed("network interrupted")
        }
        try successBytes.write(to: partialURL)
        await progress(Int64(successBytes.count), Int64(successBytes.count))
    }
}

private struct FixedDiskSpaceProbe: LocalModelDiskSpaceProbing {
    let availableBytes: Int64?
    func availableBytes(at url: URL) async -> Int64? { availableBytes }
}

private struct RuntimeProbe: LocalModelRuntimeProbing {
    let available: Bool
    func isRuntimeAvailable() async -> Bool { available }
}


private actor ArtifactMapDownloader: LocalModelDownloading {
    let artifactBytes: [String: Data]
    private var modelIDs: [String] = []
    private var artifactPaths: [String] = []

    init(artifactBytes: [String: Data]) {
        self.artifactBytes = artifactBytes
    }

    func download(artifact: LocalModelArtifact, modelID: String, to partialURL: URL, progress: @Sendable @escaping (Int64, Int64?) async -> Void) async throws {
        modelIDs.append(modelID)
        artifactPaths.append(artifact.relativePath)
        guard let bytes = artifactBytes[artifact.relativePath] else {
            throw LocalModelManagerError.downloadFailed("missing fixture for \(artifact.relativePath)")
        }
        try bytes.write(to: partialURL)
        await progress(Int64(bytes.count), Int64(bytes.count))
    }

    func requestedModelIDs() -> [String] { modelIDs }
    func requestedArtifactPaths() -> [String] { artifactPaths }
}
