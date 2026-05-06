import AppKit
import TranscriberCore
import UserNotifications

/// Surfaces detection candidates as **system notification banners**, not
/// focus-stealing modals.
///
/// Why the banner: dwell-only triggering produced false positives every
/// time the user opened Signal to read messages or opened Chrome with a
/// background music tab playing. Even with the per-PID input-device probe
/// gating ad-hoc fires, the prompt still appears for genuine ambiguous
/// cases (e.g., Chrome holding the mic for Whereby vs. Photo Booth). The
/// industry pattern (Granola, MacWhisper, Recall.ai Desktop SDK) is to
/// surface those as a banner notification with a 10-second auto-dismiss
/// rather than a modal that steals focus and binds Return to "Start" —
/// because that turned dictated newlines into accidental recordings.
///
/// The async API is preserved so AppDelegate's call site is unchanged.
@MainActor
final class StartPromptCoordinator: NSObject, UNUserNotificationCenterDelegate {

    enum Choice {
        case start
        case notAMeeting
        case skipForNow
    }

    /// Auto-dismissal sentinel. If the user neither taps the banner nor
    /// hits an action button within this many seconds, the prompt
    /// resolves as `.skipForNow` so the next detection candidate isn't
    /// blocked behind a stale continuation.
    static let autoDismissAfter: TimeInterval = 60

    /// Notification category that names this app's three actions.
    /// Registered once on init; macOS de-duplicates by identifier.
    private static let categoryIdentifier = "scribe.detection.candidate"
    private enum Action {
        static let start = "scribe.detection.action.start"
        static let suppress = "scribe.detection.action.suppress"
    }

    private struct Pending {
        let continuation: CheckedContinuation<Choice, Never>
        let timeoutTask: Task<Void, Never>
    }

    private var pending: [String: Pending] = [:]
    private var registeredCategories = false
    private var authorizationKnown = false
    private var authorizationGranted = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func prompt(for app: MeetingApp, event: CalendarEvent? = nil) async -> Choice {
        await ensureRegistered(for: app)

        let granted = await ensureAuthorization()
        guard granted else {
            // Notification permission missing or revoked: don't fall back
            // to a focus-stealing modal — that's the bug we're fixing.
            // Log and treat as skip; user can start manually from the
            // menu bar. The settings UI gates re-asking elsewhere.
            Log.lifecycle.info("Detection candidate \(app.bundleID, privacy: .public): notification authorization missing, skipping prompt")
            return .skipForNow
        }

        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                await deliver(for: app, event: event, continuation: continuation)
            }
        }
    }

    private func deliver(
        for app: MeetingApp,
        event: CalendarEvent?,
        continuation: CheckedContinuation<Choice, Never>
    ) async {
        let identifier = UUID().uuidString

        let content = UNMutableNotificationContent()
        if let event {
            content.title = event.title
            content.subtitle = "Detected in \(app.displayName)"
        } else {
            content.title = "\(app.displayName) call detected"
            content.subtitle = "No matching calendar event"
        }
        content.body = "Start recording? You can cancel anytime."
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = ["bundleID": app.bundleID, "displayName": app.displayName]
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoDismissAfter * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resolve(identifier: identifier, with: .skipForNow, removeNotification: true)
        }

        pending[identifier] = Pending(continuation: continuation, timeoutTask: timeoutTask)

        do {
            try await UNUserNotificationCenter.current().add(request)
            Log.lifecycle.info("Start prompt notification posted for \(app.bundleID, privacy: .public) (id=\(identifier, privacy: .public))")
        } catch {
            Log.lifecycle.error("Start prompt notification failed for \(app.bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            resolve(identifier: identifier, with: .skipForNow, removeNotification: false)
        }
    }

    private func ensureAuthorization() async -> Bool {
        if authorizationKnown { return authorizationGranted }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorizationKnown = true
            authorizationGranted = true
            return true
        case .denied:
            authorizationKnown = true
            authorizationGranted = false
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                authorizationKnown = true
                authorizationGranted = granted
                return granted
            } catch {
                Log.lifecycle.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
                authorizationKnown = true
                authorizationGranted = false
                return false
            }
        @unknown default:
            authorizationKnown = true
            authorizationGranted = false
            return false
        }
    }

    private func ensureRegistered(for app: MeetingApp) async {
        guard !registeredCategories else { return }
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: Action.start,
                    title: "Start recording",
                    options: [.foreground]
                ),
                UNNotificationAction(
                    identifier: Action.suppress,
                    title: "Stop detecting for 30 min",
                    options: []
                )
            ],
            intentIdentifiers: [],
            // .customDismissAction routes a user-issued dismiss through
            // didReceive (with UNNotificationDismissActionIdentifier).
            // Without it, the user closing the banner is silent and we
            // wait the full 60s before resolving as skipForNow.
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        registeredCategories = true
    }

    @MainActor
    private func resolve(identifier: String, with choice: Choice, removeNotification: Bool) {
        guard let entry = pending.removeValue(forKey: identifier) else { return }
        entry.timeoutTask.cancel()
        if removeNotification {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        }
        entry.continuation.resume(returning: choice)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // The app is menu-bar-only (LSUIElement), but notifications still
        // need to be told to show as a banner when the app is "frontmost"
        // in NSApp's view of the world (it never really is). .banner on
        // macOS 11+ replaces the deprecated .alert; including .alert too
        // for backward-compat on legacy delivery paths.
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let actionID = response.actionIdentifier
        // The completionHandler signals dispatch completion to the
        // system — it doesn't need to wait for our continuation routing.
        // Calling it synchronously here keeps strict concurrency happy
        // (no cross-actor capture) and lets us resolve the continuation
        // independently on the main actor.
        completionHandler()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let choice: Choice
            switch actionID {
            case Action.start:
                choice = .start
            case Action.suppress:
                choice = .notAMeeting
            case UNNotificationDefaultActionIdentifier:
                // User clicked the banner body (not an action button).
                // Treat as a soft "open the app" signal: bring our menu
                // bar visible and let the user start manually.
                choice = .skipForNow
            case UNNotificationDismissActionIdentifier:
                choice = .skipForNow
            default:
                choice = .skipForNow
            }
            // Terminal user response — clear the banner from Notification
            // Center too. Otherwise actioned prompts pile up there, since
            // willPresent includes .list to keep the banner around for
            // late-arriving clicks.
            self.resolve(identifier: identifier, with: choice, removeNotification: true)
        }
    }
}
