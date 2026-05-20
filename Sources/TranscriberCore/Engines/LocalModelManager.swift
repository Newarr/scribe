import CryptoKit
import Foundation

public struct LocalModelArtifact: Sendable, Equatable, Hashable {
    public let relativePath: String
    public let byteCount: Int64
    public let sha256Hex: String

    public init(relativePath: String, byteCount: Int64, sha256Hex: String) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256Hex = sha256Hex.lowercased()
    }

    public var partialRelativePath: String {
        relativePath + ".partial"
    }
}

public struct LocalModelManifest: Sendable, Equatable {
    public let modelID: String
    public let artifacts: [LocalModelArtifact]
    public let requiredFreeBytes: Int64

    public init(modelID: String, artifacts: [LocalModelArtifact], requiredFreeBytes: Int64? = nil) {
        self.modelID = modelID
        self.artifacts = artifacts.sorted { $0.relativePath < $1.relativePath }
        let artifactBytes = artifacts.reduce(Int64(0)) { $0 + $1.byteCount }
        // Keep enough room for the final file plus the in-flight .partial and
        // a small filesystem overhead buffer.
        self.requiredFreeBytes = requiredFreeBytes ?? (artifactBytes * 2 + 512 * 1024 * 1024)
    }

    public static let cohereTranscribePinned = LocalModelManifest(
        modelID: CohereMLXBackend.modelID,
        artifacts: [
            LocalModelArtifact(
                relativePath: "config.json",
                byteCount: 3_998,
                sha256Hex: "5de7e586cec6d8f51225c8d5fe17a56a3043dda9af8c42f9cb01dd545905eb18"
            ),
            LocalModelArtifact(
                relativePath: "conversion_summary.json",
                byteCount: 5_237,
                sha256Hex: "f3f763b9ff233b194df209277ab670d7768745f92eab0efb52b769991743b159"
            ),
            LocalModelArtifact(
                relativePath: "key_map.json",
                byteCount: 179_652,
                sha256Hex: "42cf585ab25335db650b353abcaa9d219d51a04ef04eae5869de6122e85a7be8"
            ),
            LocalModelArtifact(
                relativePath: "model.safetensors",
                byteCount: 4_131_827_448,
                sha256Hex: "1ec6ba9ee27da02b21b3ffdb5183b77020351d3331d05a74ad8d58a09394a2b8"
            ),
            LocalModelArtifact(
                relativePath: "preprocessor_config.json",
                byteCount: 420,
                sha256Hex: "9f297d330646ecc8ebb9dc5784f48b7c35b118c913e306a1ccd0192f2c976332"
            ),
            LocalModelArtifact(
                relativePath: "special_tokens_map.json",
                byteCount: 4_091,
                sha256Hex: "1814ce01458ff6a72b04a6618e75f18ce627be4dc17619cd3a7cd7f71e137f0f"
            ),
            LocalModelArtifact(
                relativePath: "tokenizer.model",
                byteCount: 492_827,
                sha256Hex: "6d21e6a83b2d0d3e1241a7817e4bef8eb63bcb7cfe4a2675af9a35ff3bbf0e14"
            ),
            LocalModelArtifact(
                relativePath: "tokenizer_config.json",
                byteCount: 48_141,
                sha256Hex: "0dfeb3eeba07bccaa1b4bf78f3135ad3059acf8d18f681675832b285ac0035b0"
            )
        ]
    )
}

public struct LocalModelDownloadProgress: Sendable, Equatable {
    public let completedBytes: Int64
    public let totalBytes: Int64?

    public init(completedBytes: Int64, totalBytes: Int64?) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

public struct LocalModelCacheInfo: Sendable, Equatable {
    public let modelID: String
    public let cacheURL: URL
    public let diskUsageBytes: Int64

    public init(modelID: String, cacheURL: URL, diskUsageBytes: Int64) {
        self.modelID = modelID
        self.cacheURL = cacheURL
        self.diskUsageBytes = diskUsageBytes
    }
}

public enum LocalModelFailureCode: String, Sendable, Equatable {
    case insufficientDiskSpace
    case downloadFailed
    case verificationFailed
    case ioFailure
    case unsupportedRuntime
}

public struct LocalModelFailure: Sendable, Equatable {
    public let code: LocalModelFailureCode
    public let message: String

    public init(code: LocalModelFailureCode, message: String) {
        self.code = code
        self.message = String(message.prefix(240))
    }
}

public enum LocalModelCacheStatus: Sendable, Equatable {
    case notDownloaded(modelID: String)
    case downloading(modelID: String, progress: LocalModelDownloadProgress)
    case verifying(modelID: String)
    case verified(LocalModelCacheInfo)
    case failed(modelID: String, reason: LocalModelFailure, retryAvailable: Bool)
    case unsupported(modelID: String, reason: LocalModelFailure)

    public var isReady: Bool {
        if case .verified = self { return true }
        return false
    }
}

public protocol LocalModelDownloading: Sendable {
    func download(
        artifact: LocalModelArtifact,
        modelID: String,
        to partialURL: URL,
        progress: @Sendable @escaping (Int64, Int64?) async -> Void
    ) async throws
}


public struct HuggingFaceLocalModelDownloader: LocalModelDownloading {
    public let baseURL: URL

    public init(baseURL: URL = URL(string: "https://huggingface.co")!) {
        self.baseURL = baseURL
    }

    public func download(
        artifact: LocalModelArtifact,
        modelID: String,
        to partialURL: URL,
        progress: @Sendable @escaping (Int64, Int64?) async -> Void
    ) async throws {
        guard modelID == CohereMLXBackend.modelID else {
            throw LocalModelManagerError.unpinnedModel(modelID)
        }
        guard LocalModelManifest.cohereTranscribePinned.artifacts.contains(where: { $0.relativePath == artifact.relativePath }) else {
            throw LocalModelManagerError.downloadFailed("Unexpected Cohere model artifact requested.")
        }
        let escapedPath = artifact.relativePath.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        let url = baseURL
            .appendingPathComponent(modelID)
            .appendingPathComponent("resolve")
            .appendingPathComponent("main")
            .appendingPathComponent(escapedPath)
        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw LocalModelManagerError.downloadFailed("Cohere model artifact download failed.")
            }
            try FileManager.default.createDirectory(at: partialURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: partialURL.path) {
                try FileManager.default.removeItem(at: partialURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: partialURL)
            await progress(artifact.byteCount, artifact.byteCount)
        } catch let error as LocalModelManagerError {
            throw error
        } catch {
            throw LocalModelManagerError.downloadFailed(String(describing: error))
        }
    }
}

public protocol LocalModelDiskSpaceProbing: Sendable {
    func availableBytes(at url: URL) async -> Int64?
}

public protocol LocalModelRuntimeProbing: Sendable {
    func isRuntimeAvailable() async -> Bool
}

public struct FileSystemLocalModelDiskSpaceProbe: LocalModelDiskSpaceProbing {
    public init() {}

    public func availableBytes(at url: URL) async -> Int64? {
        var probeURL = url
        var isDirectory: ObjCBool = false
        while !FileManager.default.fileExists(atPath: probeURL.path, isDirectory: &isDirectory) {
            let parent = probeURL.deletingLastPathComponent()
            guard parent.path != probeURL.path else { return nil }
            probeURL = parent
        }
        guard let values = try? FileManager.default.attributesOfFileSystem(forPath: probeURL.path),
              let free = values[.systemFreeSize] as? NSNumber else {
            return nil
        }
        return free.int64Value
    }
}

public struct DefaultLocalModelRuntimeProbe: LocalModelRuntimeProbing {
    public init() {}

    public func isRuntimeAvailable() async -> Bool {
#if arch(arm64)
        return true
#else
        return false
#endif
    }
}

public enum LocalModelManagerError: Error, Sendable, Equatable {
    case unsupportedRuntime
    case insufficientDiskSpace(required: Int64, available: Int64?)
    case downloadFailed(String)
    case verificationFailed(String)
    case ioFailure(String)
    case unpinnedModel(String)
}

public actor LocalModelManager {
    public let manifest: LocalModelManifest

    private let cacheRoot: URL
    private let downloader: any LocalModelDownloading
    private let diskSpace: any LocalModelDiskSpaceProbing
    private let runtime: any LocalModelRuntimeProbing
    private let fileManager: FileManager

    private var currentStatus: LocalModelCacheStatus
    private var inFlightDownload: Task<LocalModelCacheStatus, Never>?

    public init(
        cacheRoot: URL,
        manifest: LocalModelManifest = .cohereTranscribePinned,
        downloader: any LocalModelDownloading,
        diskSpace: any LocalModelDiskSpaceProbing = FileSystemLocalModelDiskSpaceProbe(),
        runtime: any LocalModelRuntimeProbing = DefaultLocalModelRuntimeProbe(),
        fileManager: FileManager = .default
    ) {
        self.cacheRoot = cacheRoot
        self.manifest = manifest
        self.downloader = downloader
        self.diskSpace = diskSpace
        self.runtime = runtime
        self.fileManager = fileManager
        self.currentStatus = .notDownloaded(modelID: manifest.modelID)
    }

    public func status() async -> LocalModelCacheStatus {
        if inFlightDownload != nil {
            return currentStatus
        }
        guard manifest.modelID == CohereMLXBackend.modelID else {
            let reason = LocalModelFailure(code: .verificationFailed, message: "Unpinned Cohere model identity is not allowed.")
            currentStatus = .failed(modelID: manifest.modelID, reason: reason, retryAvailable: false)
            return currentStatus
        }
        guard await runtime.isRuntimeAvailable() else {
            let reason = LocalModelFailure(code: .unsupportedRuntime, message: "Local Cohere runtime is unavailable on this Mac.")
            currentStatus = .unsupported(modelID: manifest.modelID, reason: reason)
            return currentStatus
        }
        do {
            if try verifyCachedArtifacts() {
                let info = try cacheInfo()
                currentStatus = .verified(info)
            } else if hasPartialArtifacts() {
                let reason = LocalModelFailure(code: .verificationFailed, message: "Only partial Cohere model artifacts are present.")
                currentStatus = .failed(modelID: manifest.modelID, reason: reason, retryAvailable: true)
            } else {
                currentStatus = .notDownloaded(modelID: manifest.modelID)
            }
        } catch {
            currentStatus = .failed(
                modelID: manifest.modelID,
                reason: LocalModelFailure(code: .verificationFailed, message: String(describing: error)),
                retryAvailable: true
            )
        }
        return currentStatus
    }

    @discardableResult
    public func startDownload() async -> LocalModelCacheStatus {
        if let inFlightDownload {
            return await inFlightDownload.value
        }

        let task = Task { [cacheRoot, manifest, downloader, diskSpace, runtime, fileManager] in
            let worker = LocalModelDownloadWorker(
                cacheRoot: cacheRoot,
                manifest: manifest,
                downloader: downloader,
                diskSpace: diskSpace,
                runtime: runtime,
                fileManager: fileManager
            ) { [weak self] status in
                await self?.setStatus(status)
            }
            return await worker.run()
        }
        inFlightDownload = task
        let result = await task.value
        inFlightDownload = nil
        currentStatus = result
        return result
    }

    @discardableResult
    public func retryDownload() async -> LocalModelCacheStatus {
        if let inFlightDownload {
            return await inFlightDownload.value
        }
        try? removePartialArtifacts()
        return await startDownload()
    }

    public func clearCache() async throws {
        if let inFlightDownload {
            _ = await inFlightDownload.value
        }
        let modelRoot = modelCacheURL()
        if fileManager.fileExists(atPath: modelRoot.path) {
            try fileManager.removeItem(at: modelRoot)
        }
        currentStatus = .notDownloaded(modelID: manifest.modelID)
    }

    public func modelCacheURL() -> URL {
        cacheRoot.appendingPathComponent(Self.cacheDirectoryName(for: manifest.modelID), isDirectory: true)
    }

    public static func cacheDirectoryName(for modelID: String) -> String {
        modelID.replacingOccurrences(of: "/", with: "--")
    }

    private func setStatus(_ status: LocalModelCacheStatus) {
        currentStatus = status
    }

    private func artifactURL(_ artifact: LocalModelArtifact) -> URL {
        modelCacheURL().appendingPathComponent(artifact.relativePath, isDirectory: false)
    }

    private func partialURL(_ artifact: LocalModelArtifact) -> URL {
        artifactURL(artifact).appendingPathExtension("partial")
    }

    private func hasPartialArtifacts() -> Bool {
        manifest.artifacts.contains { fileManager.fileExists(atPath: partialURL($0).path) }
    }

    private func removePartialArtifacts() throws {
        for artifact in manifest.artifacts {
            let partial = partialURL(artifact)
            if fileManager.fileExists(atPath: partial.path) {
                try fileManager.removeItem(at: partial)
            }
        }
    }

    private func verifyCachedArtifacts() throws -> Bool {
        for artifact in manifest.artifacts {
            let url = artifactURL(artifact)
            guard fileManager.fileExists(atPath: url.path) else { return false }
            try verify(artifact: artifact, at: url)
        }
        return true
    }

    private func verify(artifact: LocalModelArtifact, at url: URL) throws {
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        guard size == artifact.byteCount else {
            throw LocalModelManagerError.verificationFailed("Expected \(artifact.relativePath) to be \(artifact.byteCount) bytes, got \(size).")
        }
        let digest = try Self.sha256Hex(of: url)
        guard digest == artifact.sha256Hex else {
            throw LocalModelManagerError.verificationFailed("Checksum mismatch for \(artifact.relativePath).")
        }
    }

    private func cacheInfo() throws -> LocalModelCacheInfo {
        LocalModelCacheInfo(modelID: manifest.modelID, cacheURL: modelCacheURL(), diskUsageBytes: try diskUsage(of: modelCacheURL()))
    }

    private func diskUsage(of url: URL) throws -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    static func sha256Hex(of url: URL, chunkSize: Int = 1024 * 1024) throws -> String {
        guard chunkSize > 0 else {
            throw LocalModelManagerError.ioFailure("Checksum chunk size must be positive.")
        }
        guard let stream = InputStream(url: url) else {
            throw LocalModelManagerError.ioFailure("Unable to open \(url.lastPathComponent) for checksum verification.")
        }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: chunkSize)
            if read < 0 {
                throw stream.streamError ?? LocalModelManagerError.ioFailure("Checksum read failed for \(url.lastPathComponent).")
            }
            if read == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: read))
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct LocalModelDownloadWorker {
    let cacheRoot: URL
    let manifest: LocalModelManifest
    let downloader: any LocalModelDownloading
    let diskSpace: any LocalModelDiskSpaceProbing
    let runtime: any LocalModelRuntimeProbing
    let fileManager: FileManager
    let statusSink: @Sendable (LocalModelCacheStatus) async -> Void

    func run() async -> LocalModelCacheStatus {
        do {
            guard manifest.modelID == CohereMLXBackend.modelID else {
                throw LocalModelManagerError.unpinnedModel(manifest.modelID)
            }
            guard await runtime.isRuntimeAvailable() else {
                throw LocalModelManagerError.unsupportedRuntime
            }
            let available = await diskSpace.availableBytes(at: cacheRoot)
            guard let available else {
                throw LocalModelManagerError.insufficientDiskSpace(required: manifest.requiredFreeBytes, available: nil)
            }
            if available < manifest.requiredFreeBytes {
                throw LocalModelManagerError.insufficientDiskSpace(required: manifest.requiredFreeBytes, available: available)
            }
            try fileManager.createDirectory(at: modelCacheURL(), withIntermediateDirectories: true)
            try removePartialArtifacts()

            var completedBeforeCurrent: Int64 = 0
            let totalBytes = manifest.artifacts.reduce(Int64(0)) { $0 + $1.byteCount }
            for artifact in manifest.artifacts {
                let final = artifactURL(artifact)
                let partial = partialURL(artifact)
                try fileManager.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
                await statusSink(.downloading(
                    modelID: manifest.modelID,
                    progress: LocalModelDownloadProgress(completedBytes: completedBeforeCurrent, totalBytes: totalBytes)
                ))
                let completedBase = completedBeforeCurrent
                let modelID = manifest.modelID
                let sink = statusSink
                try await downloader.download(artifact: artifact, modelID: modelID, to: partial) { bytes, _ in
                    await sink(.downloading(
                        modelID: modelID,
                        progress: LocalModelDownloadProgress(completedBytes: completedBase + bytes, totalBytes: totalBytes)
                    ))
                }
                await statusSink(.verifying(modelID: manifest.modelID))
                try verify(artifact: artifact, at: partial)
                if fileManager.fileExists(atPath: final.path) {
                    try fileManager.removeItem(at: final)
                }
                try fileManager.moveItem(at: partial, to: final)
                completedBeforeCurrent += artifact.byteCount
            }
            let info = LocalModelCacheInfo(modelID: manifest.modelID, cacheURL: modelCacheURL(), diskUsageBytes: try diskUsage(of: modelCacheURL()))
            return .verified(info)
        } catch let error as LocalModelManagerError {
            return failedStatus(for: error)
        } catch {
            return failedStatus(for: .ioFailure(String(describing: error)))
        }
    }

    private func failedStatus(for error: LocalModelManagerError) -> LocalModelCacheStatus {
        let failure: LocalModelFailure
        switch error {
        case .unsupportedRuntime:
            failure = LocalModelFailure(code: .unsupportedRuntime, message: "Local Cohere runtime is unavailable on this Mac.")
            return .unsupported(modelID: manifest.modelID, reason: failure)
        case .insufficientDiskSpace(let required, let available):
            failure = LocalModelFailure(code: .insufficientDiskSpace, message: "Not enough disk space for Cohere model download. Required \(required) bytes, available \(available.map(String.init) ?? "unknown").")
        case .downloadFailed(let message):
            failure = LocalModelFailure(code: .downloadFailed, message: message)
        case .verificationFailed(let message):
            failure = LocalModelFailure(code: .verificationFailed, message: message)
        case .ioFailure(let message):
            failure = LocalModelFailure(code: .ioFailure, message: message)
        case .unpinnedModel(let modelID):
            failure = LocalModelFailure(code: .verificationFailed, message: "Unpinned Cohere model identity is not allowed: \(modelID)")
        }
        return .failed(modelID: manifest.modelID, reason: failure, retryAvailable: true)
    }

    private func modelCacheURL() -> URL {
        cacheRoot.appendingPathComponent(LocalModelManager.cacheDirectoryName(for: manifest.modelID), isDirectory: true)
    }

    private func artifactURL(_ artifact: LocalModelArtifact) -> URL {
        modelCacheURL().appendingPathComponent(artifact.relativePath, isDirectory: false)
    }

    private func partialURL(_ artifact: LocalModelArtifact) -> URL {
        artifactURL(artifact).appendingPathExtension("partial")
    }

    private func removePartialArtifacts() throws {
        for artifact in manifest.artifacts {
            let partial = partialURL(artifact)
            if fileManager.fileExists(atPath: partial.path) {
                try fileManager.removeItem(at: partial)
            }
        }
    }

    private func verify(artifact: LocalModelArtifact, at url: URL) throws {
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        guard size == artifact.byteCount else {
            throw LocalModelManagerError.verificationFailed("Expected \(artifact.relativePath) to be \(artifact.byteCount) bytes, got \(size).")
        }
        let digest = try LocalModelManager.sha256Hex(of: url)
        guard digest == artifact.sha256Hex else {
            throw LocalModelManagerError.verificationFailed("Checksum mismatch for \(artifact.relativePath).")
        }
    }

    private func diskUsage(of url: URL) throws -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}
