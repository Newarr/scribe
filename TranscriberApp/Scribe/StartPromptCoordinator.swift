import AppKit
import TranscriberCore
import UserNotifications

/// Owns the Notification Center backup channel for the EndGuard stop
/// prompt: Keep Recording / Stop Now actions on a "Call seems over"
/// notification, generation-scoped so stale taps cannot stop the wrong
/// session. The pre-call start prompt machinery was removed with the
/// auto-record cutover (plans/auto-record.md).
@MainActor
final class StartPromptCoordinator: NSObject, UNUserNotificationCenterDelegate {

    private static let endCategoryIdentifier = "scribe.recording.end-prompt"
    private enum EndAction {
        static let keepRecording = "scribe.end-prompt.action.keep-recording"
        static let stopNow = "scribe.end-prompt.action.stop-now"
    }

    private final class PendingEndPrompt {
        let identifier: String
        let generation: Int
        let onKeep: @MainActor @Sendable (Int) async -> Void
        let onStopNow: @MainActor @Sendable (Int) async -> Void
        var notificationIdentifiers: Set<String> = []

        init(
            identifier: String,
            generation: Int,
            onKeep: @escaping @MainActor @Sendable (Int) async -> Void,
            onStopNow: @escaping @MainActor @Sendable (Int) async -> Void
        ) {
            self.identifier = identifier
            self.generation = generation
            self.onKeep = onKeep
            self.onStopNow = onStopNow
        }
    }

    private var pendingEndPrompts: [String: PendingEndPrompt] = [:]
    private var registeredCategories = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    @discardableResult
    func postEndPromptNotificationIfPossible(
        promptID: String,
        generation: Int,
        reason: EndGuard.Reason,
        secondsRemaining: Int,
        onKeep: @escaping @MainActor @Sendable (Int) async -> Void,
        onStopNow: @escaping @MainActor @Sendable (Int) async -> Void
    ) async -> Bool {
        await ensureRegistered()
        pendingEndPrompts[promptID] = PendingEndPrompt(
            identifier: promptID,
            generation: generation,
            onKeep: onKeep,
            onStopNow: onStopNow
        )

        guard await ensureAuthorization() else {
            Log.lifecycle.info("End prompt notification unavailable: authorization missing; HUD/menu recovery remain active (id=\(promptID, privacy: .public))")
            return false
        }
        guard pendingEndPrompts[promptID] != nil else {
            Log.lifecycle.info("Skipping stale end prompt notification after authorization completed (id=\(promptID, privacy: .public))")
            return false
        }

        let notificationID = "\(promptID).end"
        let content = UNMutableNotificationContent()
        content.title = "Call seems over"
        content.subtitle = Self.endPromptSubtitle(for: reason)
        content.body = "Scribe will stop in \(max(0, secondsRemaining)) seconds unless you keep recording."
        content.categoryIdentifier = Self.endCategoryIdentifier
        content.userInfo = [
            "promptID": promptID,
            "generation": generation,
            "reason": Self.endPromptReasonPayload(reason)
        ]
        content.sound = nil

        let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            pendingEndPrompts[promptID]?.notificationIdentifiers.insert(notificationID)
            Log.lifecycle.info("End prompt notification posted: \(Self.endPromptReasonPayload(reason), privacy: .public) (id=\(promptID, privacy: .public), generation=\(generation, privacy: .public))")
            return true
        } catch {
            Log.lifecycle.error("End prompt notification failed: \(error.localizedDescription, privacy: .public); HUD/menu recovery remain active (id=\(promptID, privacy: .public))")
            return false
        }
    }

    func clearEndPromptNotification(promptID: String) {
        guard let entry = pendingEndPrompts.removeValue(forKey: promptID) else { return }
        let ids = Array(entry.notificationIdentifiers)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func ensureAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        // Re-query every time instead of caching process-lifetime denial or
        // grant. Users can flip notification permission in System Settings
        // while Scribe is running, and the end-prompt channel must
        // immediately reflect denied -> granted and granted -> denied changes.
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Log.lifecycle.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        @unknown default:
            return false
        }
    }

    private func ensureRegistered() async {
        guard !registeredCategories else { return }
        let endCategory = UNNotificationCategory(
            identifier: Self.endCategoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: EndAction.keepRecording,
                    title: "Keep Recording",
                    options: []
                ),
                UNNotificationAction(
                    identifier: EndAction.stopNow,
                    title: "Stop Now",
                    options: [.destructive]
                )
            ],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([endCategory])
        registeredCategories = true
    }

    private func resolveEndPromptNotification(
        promptID: String,
        generation: Int?,
        actionID: String
    ) async {
        guard let entry = pendingEndPrompts[promptID],
              generation == entry.generation else {
            Log.lifecycle.info("Ignoring stale end prompt notification action (id=\(promptID, privacy: .public))")
            return
        }

        switch actionID {
        case EndAction.keepRecording:
            clearEndPromptNotification(promptID: promptID)
            await entry.onKeep(entry.generation)
        case EndAction.stopNow:
            clearEndPromptNotification(promptID: promptID)
            await entry.onStopNow(entry.generation)
        case UNNotificationDismissActionIdentifier:
            Log.lifecycle.info("End prompt notification dismissed without decision (id=\(promptID, privacy: .public)); HUD/menu recovery remains active")
        default:
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static func endPromptSubtitle(for reason: EndGuard.Reason) -> String {
        switch reason {
        case .bidirectionalSilence:
            return "Audio has been quiet"
        case .callEnded:
            return "Call ended"
        case .maxSessionDurationReached:
            return "Session reached 4 hours"
        }
    }

    private static func endPromptReasonPayload(_ reason: EndGuard.Reason) -> String {
        switch reason {
        case .bidirectionalSilence: return "bidirectional_silence"
        case .callEnded: return "call_ended"
        case .maxSessionDurationReached: return "max_session_duration"
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let categoryIdentifier = response.notification.request.content.categoryIdentifier
        let promptID = response.notification.request.content.userInfo["promptID"] as? String
        let actionID = response.actionIdentifier
        let generation = response.notification.request.content.userInfo["generation"] as? Int
        completionHandler()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard categoryIdentifier == Self.endCategoryIdentifier, let promptID else {
                if actionID == UNNotificationDismissActionIdentifier { return }
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            await self.resolveEndPromptNotification(
                promptID: promptID,
                generation: generation,
                actionID: actionID
            )
        }
    }
}
