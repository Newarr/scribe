import Foundation

/// Testable app-routing state for recovery notices, failed-session retry errors,
/// and failed Recents actions. Keeps Cohere repair payloads tied to the
/// affected session instead of relying on the current Settings engine.
public enum SessionRepairRouting {
    public struct LocalRepairPayload: Sendable, Equatable {
        public let sessionDirectory: URL
        public let modelID: String
        public let reason: String

        public init(sessionDirectory: URL, modelID: String = CohereMLXBackend.modelID, reason: String) {
            self.sessionDirectory = sessionDirectory
            self.modelID = modelID
            self.reason = reason
        }
    }

    public struct RecoveryNotice: Sendable, Equatable {
        public let title: String
        public let message: String
        public let transcribingStarted: Bool
        public let localRepairPayloads: [LocalRepairPayload]
    }

    public enum RetryRoute: Sendable, Equatable {
        case startRetry(sessionDirectory: URL)
        case localSetupRequired(LocalRepairPayload)
        case unavailable(String)
    }

    public enum RecentAction: Sendable, Equatable {
        case retry(sessionDirectory: URL)
        case repair(LocalRepairPayload)
        case loading(sessionDirectory: URL)
        case none
    }


    public static func engineSettingsFocus(for payload: LocalRepairPayload?) -> EngineSettingsCardFocus? {
        payload == nil ? nil : .local
    }

    public static func setupReport(for payload: LocalRepairPayload) -> PreflightReport {
        PreflightReport(
            blockers: [.localModelNotVerified(modelID: payload.modelID)],
            warnings: []
        )
    }

    public static func recoveryNotice(for result: SessionSupervisor.ScanResult) -> RecoveryNotice? {
        let activelyTranscribing = result.resumed
        let rescuedForRepair = result.localSetupRequiredSessions.count
        let recovered = activelyTranscribing + result.rescued
        guard recovered > 0 || rescuedForRepair > 0 else { return nil }

        let payloads = result.localSetupRequiredSessions.map {
            LocalRepairPayload(sessionDirectory: $0, reason: "Cohere setup is required before this recovered Local session can be transcribed.")
        }

        if activelyTranscribing == 0, !payloads.isEmpty {
            let count = payloads.count
            return RecoveryNotice(
                title: count == 1 ? "Recovered 1 recording from before the last quit" : "Recovered \(count) recordings from before the last quit",
                message: count == 1
                    ? "Audio was rescued. Cohere setup is required before this Local recording can be transcribed."
                    : "Audio was rescued. Cohere setup is required before these Local recordings can be transcribed.",
                transcribingStarted: false,
                localRepairPayloads: payloads
            )
        }

        let title = activelyTranscribing == 1
            ? "Recovered 1 recording from before the last quit"
            : "Recovered \(activelyTranscribing) recordings from before the last quit"
        let message = activelyTranscribing == 1
            ? (result.rescued > rescuedForRepair ? "Audio was rescued and is being transcribed now." : "Transcription is resuming now.")
            : "They're being transcribed in the background."
        return RecoveryNotice(title: title, message: message, transcribingStarted: true, localRepairPayloads: payloads)
    }

    public static func routeRetry(
        sessionDirectory: URL?,
        error: FailedSessionRetryCoordinator.RetryError?,
        savedAudioExists: Bool,
        persistedEngine: String? = nil
    ) -> RetryRoute {
        guard let sessionDirectory else { return .unavailable("No failed session is selected.") }
        if error == .localSetupRequired || (persistedEngine?.lowercased() == "cohere" && !savedAudioExists) {
            return .localSetupRequired(LocalRepairPayload(
                sessionDirectory: sessionDirectory,
                reason: "Cohere setup is required before retrying this Local session."
            ))
        }
        guard savedAudioExists else { return .unavailable("Saved audio is missing for this failed session.") }
        if let error {
            switch error {
            case .localSetupRequired:
                return .localSetupRequired(LocalRepairPayload(sessionDirectory: sessionDirectory, reason: "Cohere setup is required before retrying this Local session."))
            default:
                return .unavailable("This failed session cannot be retried until its artifacts are repaired.")
            }
        }
        return .startRetry(sessionDirectory: sessionDirectory)
    }

    public static func recentAction(
        for entry: SessionFolderEnumerator.Entry,
        localModelReady: Bool? = true
    ) -> RecentAction {
        guard entry.status == .failed else { return .none }
        if entry.hasSavedAudio {
            guard entry.engineIdentifier?.lowercased() == "cohere" else {
                return .retry(sessionDirectory: entry.directory)
            }
            guard let localModelReady else {
                return .loading(sessionDirectory: entry.directory)
            }
            return localModelReady
                ? .retry(sessionDirectory: entry.directory)
                : .repair(LocalRepairPayload(
                    sessionDirectory: entry.directory,
                    reason: "Cohere setup is required before retrying this Local session."
                ))
        }
        return .repair(LocalRepairPayload(
            sessionDirectory: entry.directory,
            reason: "Saved audio is missing; open setup to repair this failed session before retrying."
        ))
    }
}
