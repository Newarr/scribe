import Foundation

public struct LocalModelArtifact: Sendable, Equatable, Hashable {
    let relativePath: String
    public let byteCount: Int64
    let sha256Hex: String

    public init(relativePath: String, byteCount: Int64, sha256Hex: String) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256Hex = sha256Hex.lowercased()
    }

    var partialRelativePath: String {
        relativePath + ".partial"
    }
}

public struct LocalModelDownloadProgress: Sendable, Equatable {
    let completedBytes: Int64
    let totalBytes: Int64?

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

public enum LocalModelManagerError: Error, Sendable, Equatable {
    case unsupportedRuntime
    case insufficientDiskSpace(required: Int64, available: Int64?)
    case downloadFailed(String)
    case verificationFailed(String)
    case ioFailure(String)
    case unpinnedModel(String)
}
