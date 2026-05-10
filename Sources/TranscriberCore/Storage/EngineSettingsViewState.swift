import Foundation

public enum EngineSettingsCardFocus: String, Sendable, Equatable {
    case cloud
    case local
}

public enum EngineSettingsLocalAction: String, Sendable, Equatable {
    case retry
    case remove
}

public enum EngineSettingsAction: Sendable, Equatable {
    case retryLocalSetup
    case requestRemoveLocalModel
    case cancelRemoveLocalModel
    case confirmRemoveLocalModel
}

public enum EngineSettingsEffect: Sendable, Equatable {
    case none
    case startLocalRetry
    case confirmRemoveLocalModel(modelName: String)
    case clearLocalModelCache
}

public struct EngineSettingsViewState: Sendable, Equatable {
    public struct CloudCard: Sendable, Equatable {
        public let isSelected: Bool
        public let isReady: Bool
        public let isSelectionEnabled: Bool
        public let statusText: String
        public let detailText: String
        public let rawAPIKey: String?
    }

    public struct LocalCard: Sendable, Equatable {
        public let isSelected: Bool
        public let isReady: Bool
        public let isSelectionEnabled: Bool
        public let modelName: String
        public let modelID: String
        public let diskUsageText: String
        public let statusText: String
        public let privacyCopy: String
        public let availableActions: [EngineSettingsLocalAction]
    }

    public let selectedEngine: EngineMode
    public let cloud: CloudCard
    public let local: LocalCard

    public static let localModelName = "Cohere Transcribe 03-2026"
    public static let localPrivacyCopy = "Local keeps audio on this Mac."

    public static func make(
        selectedEngine: EngineMode,
        readiness: EngineReadinessProbing
    ) async -> EngineSettingsViewState {
        async let cloudReady = readiness.cloudKeyAvailable()
        async let localStatus = readiness.localModelStatus()
        let cloud = await cloudReady
        let local = await localStatus
        return make(selectedEngine: selectedEngine, cloudKeyAvailable: cloud, localStatus: local, modelID: readiness.localModelID())
    }

    public static func make(
        selectedEngine: EngineMode,
        cloudKeyAvailable: Bool,
        localStatus: LocalModelCacheStatus,
        modelID: String = CohereMLXBackend.modelID
    ) -> EngineSettingsViewState {
        EngineSettingsViewState(
            selectedEngine: selectedEngine,
            cloud: CloudCard(
                isSelected: selectedEngine == .cloud,
                isReady: cloudKeyAvailable,
                isSelectionEnabled: cloudKeyAvailable,
                statusText: cloudKeyAvailable ? "Ready" : "API key required",
                detailText: cloudKeyAvailable
                    ? "ElevenLabs key is saved in Keychain."
                    : "Cloud mode needs an ElevenLabs API key saved in Keychain.",
                rawAPIKey: nil
            ),
            local: localCard(selectedEngine: selectedEngine, status: localStatus, modelID: modelID)
        )
    }

    private static func localCard(selectedEngine: EngineMode, status: LocalModelCacheStatus, modelID: String) -> LocalCard {
        LocalCard(
            isSelected: selectedEngine == .local,
            isReady: status.isReady,
            isSelectionEnabled: status.isReady,
            modelName: localModelName,
            modelID: modelID,
            diskUsageText: diskUsageText(for: status),
            statusText: statusText(for: status),
            privacyCopy: localPrivacyCopy,
            availableActions: actions(for: status)
        )
    }

    private static func statusText(for status: LocalModelCacheStatus) -> String {
        switch status {
        case .notDownloaded:
            return "Setup required"
        case .downloading(_, let progress):
            if let total = progress.totalBytes, total > 0 {
                let pct = Int((Double(progress.completedBytes) / Double(total) * 100).rounded())
                return "Downloading \(min(max(pct, 0), 100))%"
            }
            return "Downloading"
        case .verifying:
            return "Verifying"
        case .verified:
            return "Ready"
        case .failed:
            return "Setup failed"
        case .unsupported:
            return "Unsupported on this Mac"
        }
    }

    private static func diskUsageText(for status: LocalModelCacheStatus) -> String {
        switch status {
        case .verified(let info):
            return ByteCountFormatter.string(fromByteCount: info.diskUsageBytes, countStyle: .file) + " on disk"
        default:
            return "Waiting for verified cache"
        }
    }

    private static func actions(for status: LocalModelCacheStatus) -> [EngineSettingsLocalAction] {
        switch status {
        case .verified:
            return [.remove]
        case .failed(_, _, let retryAvailable):
            return retryAvailable ? [.retry] : []
        case .notDownloaded:
            return [.retry]
        default:
            return []
        }
    }
}

public struct EngineSettingsActionReducer: Sendable, Equatable {
    public private(set) var selectedEngine: EngineMode
    public let localModelName: String

    public init(selectedEngine: EngineMode, localModelName: String = EngineSettingsViewState.localModelName) {
        self.selectedEngine = selectedEngine
        self.localModelName = localModelName
    }

    public mutating func handle(_ action: EngineSettingsAction) -> EngineSettingsEffect {
        switch action {
        case .retryLocalSetup:
            return .startLocalRetry
        case .requestRemoveLocalModel:
            return .confirmRemoveLocalModel(modelName: localModelName)
        case .cancelRemoveLocalModel:
            return .none
        case .confirmRemoveLocalModel:
            return .clearLocalModelCache
        }
    }
}

public enum EngineSettingsNavigation {
    public static func focus(for reason: PreflightReason) -> EngineSettingsCardFocus? {
        switch reason {
        case .missingCloudAPIKey:
            return .cloud
        case .localModelNotVerified, .localRuntimeUnavailable:
            return .local
        default:
            return nil
        }
    }
}
