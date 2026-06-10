import CryptoKit
import Foundation

/// Shared path/file math for the on-disk Cohere model cache. The actor
/// and `LocalModelDownloadWorker` operate on the same layout; routing
/// both through this struct keeps the helpers from drifting (the two
/// copies of `verify` had already diverged on the hash fast-path).
private struct LocalModelCacheLayout {
    let cacheRoot: URL
    let manifest: LocalModelManifest
    let fileManager: FileManager

    func modelCacheURL() -> URL {
        cacheRoot.appendingPathComponent(LocalModelManager.cacheDirectoryName(for: manifest.modelID), isDirectory: true)
    }

    func artifactURL(_ artifact: LocalModelArtifact) -> URL {
        modelCacheURL().appendingPathComponent(artifact.relativePath, isDirectory: false)
    }

    func partialURL(_ artifact: LocalModelArtifact) -> URL {
        artifactURL(artifact).appendingPathExtension("partial")
    }

    func removePartialArtifacts() throws {
        for artifact in manifest.artifacts {
            let partial = partialURL(artifact)
            if fileManager.fileExists(atPath: partial.path) {
                try fileManager.removeItem(at: partial)
            }
        }
    }

    /// Byte-size revalidation always runs; `fullHash` additionally
    /// streams a SHA-256 of the artifact (the slow path the actor
    /// skips after a successful first verification).
    func verify(artifact: LocalModelArtifact, at url: URL, fullHash: Bool = true) throws {
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        guard size == artifact.byteCount else {
            throw LocalModelManagerError.verificationFailed("Expected \(artifact.relativePath) to be \(artifact.byteCount) bytes, got \(size).")
        }
        guard fullHash else { return }
        let digest = try LocalModelManager.sha256Hex(of: url)
        guard digest == artifact.sha256Hex else {
            throw LocalModelManagerError.verificationFailed("Checksum mismatch for \(artifact.relativePath).")
        }
    }

    func diskUsage(of url: URL) throws -> Int64 {
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

public actor LocalModelManager {
    public let manifest: LocalModelManifest

    private let cacheRoot: URL
    private let downloader: any LocalModelDownloading
    private let diskSpace: any LocalModelDiskSpaceProbing
    private let runtime: any LocalModelRuntimeProbing
    private let fileManager: FileManager
    private let layout: LocalModelCacheLayout

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
        self.layout = LocalModelCacheLayout(cacheRoot: cacheRoot, manifest: manifest, fileManager: fileManager)
        self.currentStatus = .notDownloaded(modelID: manifest.modelID)
    }

    public func status() async -> LocalModelCacheStatus {
        if inFlightDownload != nil {
            return currentStatus
        }
        guard LocalModelManifest.pinned(modelID: manifest.modelID) != nil else {
            let reason = LocalModelFailure(code: .verificationFailed, message: "Unpinned model identity is not allowed.")
            currentStatus = .failed(modelID: manifest.modelID, reason: reason, retryAvailable: false)
            return currentStatus
        }
        guard await runtime.isRuntimeAvailable() else {
            let reason = LocalModelFailure(code: .unsupportedRuntime, message: "Local Cohere runtime is unavailable on this Mac.")
            currentStatus = .unsupported(modelID: manifest.modelID, reason: reason)
            return currentStatus
        }
        do {
            // Once verified, skip re-hashing on later probes: status() sits on
            // record-start, popover-open, and Settings paths, and a full
            // SHA-256 of the 4 GB weights blocks them for seconds. Existence +
            // byte-size revalidation still catches deletion and truncation;
            // the full hash runs on first verification, after clearCache(),
            // and whenever the quick check fails.
            let wasVerified: Bool
            if case .verified = currentStatus { wasVerified = true } else { wasVerified = false }
            if try verifyCachedArtifacts(fullHash: !wasVerified) {
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
        try? layout.removePartialArtifacts()
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

    func modelCacheURL() -> URL {
        layout.modelCacheURL()
    }

    static func cacheDirectoryName(for modelID: String) -> String {
        modelID.replacingOccurrences(of: "/", with: "--")
    }

    private func setStatus(_ status: LocalModelCacheStatus) {
        currentStatus = status
    }

    private func hasPartialArtifacts() -> Bool {
        manifest.artifacts.contains { fileManager.fileExists(atPath: layout.partialURL($0).path) }
    }

    private func verifyCachedArtifacts(fullHash: Bool = true) throws -> Bool {
        for artifact in manifest.artifacts {
            let url = layout.artifactURL(artifact)
            guard fileManager.fileExists(atPath: url.path) else { return false }
            try layout.verify(artifact: artifact, at: url, fullHash: fullHash)
        }
        return true
    }

    private func cacheInfo() throws -> LocalModelCacheInfo {
        LocalModelCacheInfo(modelID: manifest.modelID, cacheURL: modelCacheURL(), diskUsageBytes: try layout.diskUsage(of: modelCacheURL()))
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

    private var layout: LocalModelCacheLayout {
        LocalModelCacheLayout(cacheRoot: cacheRoot, manifest: manifest, fileManager: fileManager)
    }

    func run() async -> LocalModelCacheStatus {
        do {
            guard LocalModelManifest.pinned(modelID: manifest.modelID) != nil else {
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
            try fileManager.createDirectory(at: layout.modelCacheURL(), withIntermediateDirectories: true)
            try layout.removePartialArtifacts()

            var completedBeforeCurrent: Int64 = 0
            let totalBytes = manifest.artifacts.reduce(Int64(0)) { $0 + $1.byteCount }
            for artifact in manifest.artifacts {
                let final = layout.artifactURL(artifact)
                let partial = layout.partialURL(artifact)
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
                try layout.verify(artifact: artifact, at: partial)
                if fileManager.fileExists(atPath: final.path) {
                    try fileManager.removeItem(at: final)
                }
                try fileManager.moveItem(at: partial, to: final)
                completedBeforeCurrent += artifact.byteCount
            }
            let info = LocalModelCacheInfo(modelID: manifest.modelID, cacheURL: layout.modelCacheURL(), diskUsageBytes: try layout.diskUsage(of: layout.modelCacheURL()))
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
}
