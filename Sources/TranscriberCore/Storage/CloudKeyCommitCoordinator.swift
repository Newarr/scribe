import Foundation

/// Outcome of a Cloud API key save or clear action.
enum CloudKeyCommitOutcome: Sendable, Equatable {
    /// Keychain write/delete succeeded. Readiness has been refreshed.
    case success
    /// Keychain write/delete failed. A non-secret error message is provided.
    /// Non-secret settings were NOT committed and close-guard is preserved.
    case keychainFailure(String)
}

/// Encapsulates the commit-ordering contract for Cloud API key actions:
///
///   1. Persist the Keychain change (write or delete).
///   2. On success only: commit non-secret Settings edits.
///   3. On success only: refresh engine readiness state.
///
/// The three-step ordering ensures:
/// - Keychain failure keeps Settings open with a non-secret error.
/// - Non-secret Settings are never committed if the key change failed.
/// - Close-guard remains active until the key change succeeds.
///
/// Tested via `CloudKeyCommitCoordinatorTests` with a fake `KeychainPersisting`.
struct CloudKeyCommitCoordinator: Sendable {
    let keychain: any KeychainPersisting
    let settingsCommit: @Sendable (SessionSettings) async -> Void
    let readinessRefresh: @Sendable () async -> Void

    init(
        keychain: any KeychainPersisting,
        settingsCommit: @escaping @Sendable (SessionSettings) async -> Void,
        readinessRefresh: @escaping @Sendable () async -> Void
    ) {
        self.keychain = keychain
        self.settingsCommit = settingsCommit
        self.readinessRefresh = readinessRefresh
    }

    /// Saves the trimmed `candidateKey` to Keychain. If the candidate is
    /// empty, deletes the Keychain item instead.
    ///
    /// - Returns: `.success` if Keychain write/delete succeeded (settings
    ///   commit and readiness refresh have run). `.keychainFailure` otherwise
    ///   (no settings commit, no readiness refresh).
    func saveKey(
        candidate candidateKey: String,
        currentSettings: SessionSettings
    ) async -> CloudKeyCommitOutcome {
        let trimmed = candidateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try keychain.delete()
            } else {
                try keychain.write(trimmed)
            }
        } catch {
            return .keychainFailure(
                "Could not update the ElevenLabs API key in Keychain. The key was not saved; try again from Settings."
            )
        }
        // Keychain succeeded — commit non-secret settings, then refresh.
        await settingsCommit(currentSettings)
        await readinessRefresh()
        return .success
    }

    /// Clears the Keychain item (same as `saveKey(candidate: "")`) and
    /// commits non-secret settings on success.
    func clearKey(currentSettings: SessionSettings) async -> CloudKeyCommitOutcome {
        await saveKey(candidate: "", currentSettings: currentSettings)
    }
}
