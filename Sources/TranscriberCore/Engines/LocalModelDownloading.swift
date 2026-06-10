import Foundation

public protocol LocalModelDownloading: Sendable {
    func download(
        artifact: LocalModelArtifact,
        modelID: String,
        to partialURL: URL,
        progress: @Sendable @escaping (Int64, Int64?) async -> Void
    ) async throws
}


public struct HuggingFaceLocalModelDownloader: LocalModelDownloading {
    let baseURL: URL

    public init(baseURL: URL = URL(string: "https://huggingface.co")!) {
        self.baseURL = baseURL
    }

    public func download(
        artifact: LocalModelArtifact,
        modelID: String,
        to partialURL: URL,
        progress: @Sendable @escaping (Int64, Int64?) async -> Void
    ) async throws {
        guard let manifest = LocalModelManifest.pinned(modelID: modelID) else {
            throw LocalModelManagerError.unpinnedModel(modelID)
        }
        guard manifest.artifacts.contains(where: { $0.relativePath == artifact.relativePath }) else {
            throw LocalModelManagerError.downloadFailed("Unexpected model artifact requested.")
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
