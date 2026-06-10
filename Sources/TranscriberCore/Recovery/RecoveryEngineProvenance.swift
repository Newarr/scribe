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
        switch EngineMode(persistedIdentifier: sessionEngineIdentifier) {
        case .cloud:
            return .cloud
        case .local:
            return localModelStatus.isReady ? .localReady : .localSetupRequired
        case nil:
            return .missingOrInvalid
        }
    }
}
