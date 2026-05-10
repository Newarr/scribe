import Foundation

public enum RecoveryEngineProvenance: Sendable, Equatable {
    case cloud
    case localReady
    case localSetupRequired
    case missingOrInvalid

    public var engineMode: EngineMode? {
        switch self {
        case .cloud: return .cloud
        case .localReady: return .local
        case .localSetupRequired, .missingOrInvalid: return nil
        }
    }

    public static func resolve(sessionEngineIdentifier: String, localModelStatus: LocalModelCacheStatus) -> RecoveryEngineProvenance {
        switch sessionEngineIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "elevenlabs":
            return .cloud
        case "cohere":
            return localModelStatus.isReady ? .localReady : .localSetupRequired
        default:
            return .missingOrInvalid
        }
    }
}
