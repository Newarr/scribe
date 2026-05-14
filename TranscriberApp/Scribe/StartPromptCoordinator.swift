import AppKit
import CoreGraphics
import TranscriberCore
import UserNotifications

/// Presents meeting detections through the spec's redundant-channel start
/// prompt: a modal AppKit decision surface first, plus a recoverable
/// Notification Center backup when notifications are available.
@MainActor
final class StartPromptCoordinator: NSObject, UNUserNotificationCenterDelegate {

    enum Choice {
        case start
        /// App-level 30-minute suppression, exposed only behind More options.
        case notAMeeting
        /// Current prompt declined with Not now.
        case skipForNow
    }

    private static let categoryIdentifier = "scribe.detection.candidate"
    private enum Action {
        static let start = "scribe.detection.action.start"
        static let notNow = "scribe.detection.action.not-now"
    }

    private struct Pending {
        let continuation: CheckedContinuation<Choice, Never>
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
        let identifier = UUID().uuidString
        await ensureRegistered()
        let backupNotificationPosted = await postBackupNotificationIfPossible(
            identifier: identifier,
            app: app,
            event: event
        )

        return await withCheckedContinuation { continuation in
            pending[identifier] = Pending(continuation: continuation)
            presentModalPrompt(
                identifier: identifier,
                app: app,
                event: event,
                backupNotificationPosted: backupNotificationPosted
            )
        }
    }

    private func postBackupNotificationIfPossible(
        identifier: String,
        app: MeetingApp,
        event: CalendarEvent?
    ) async -> Bool {
        guard await ensureAuthorization() else {
            Log.lifecycle.info("Start prompt backup notification unavailable for \(app.bundleID, privacy: .public): authorization missing; modal prompt will still be shown")
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = promptTitle(for: app, event: event)
        content.subtitle = event == nil ? "Detected in \(app.displayName)" : "From Apple Calendar · \(app.displayName)"
        content.body = "Start recording?"
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = ["promptID": identifier, "bundleID": app.bundleID, "displayName": app.displayName]
        content.sound = nil

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            Log.lifecycle.info("Start prompt backup notification posted for \(app.bundleID, privacy: .public) (id=\(identifier, privacy: .public))")
            return true
        } catch {
            Log.lifecycle.error("Start prompt backup notification failed for \(app.bundleID, privacy: .public): \(error.localizedDescription, privacy: .public); modal prompt remains active")
            return false
        }
    }

    private func presentModalPrompt(
        identifier: String,
        app: MeetingApp,
        event: CalendarEvent?,
        backupNotificationPosted: Bool
    ) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = promptTitle(for: app, event: event)
        alert.informativeText = promptSubtitle(for: app, event: event)
        alert.addButton(withTitle: "Start Recording")
        alert.addButton(withTitle: "Not now")
        alert.window.sharingType = WindowChromeSharing.confidential

        let accessory = MoreOptionsAccessory(appDisplayName: app.displayName) { [weak self] in
            self?.resolve(identifier: identifier, with: .notAMeeting, removeNotification: true)
            NSApp.stopModal(withCode: NSApplication.ModalResponse.abort)
        }
        alert.accessoryView = accessory.view

        place(window: alert.window, nearActiveWindowFor: app)
        alert.window.makeKeyAndOrderFront(nil)
        alert.window.orderFrontRegardless()

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            resolve(identifier: identifier, with: .start, removeNotification: true)
        case .alertSecondButtonReturn:
            resolve(identifier: identifier, with: .skipForNow, removeNotification: true)
        default:
            // A close/Esc/dismissal is not an implicit decline. When a
            // notification was delivered, leave the prompt session pending so
            // the backup remains recoverable until the prompt-session feature
            // adds menu-bar recovery. If notification delivery was unavailable,
            // there is no secondary channel to resolve later, so avoid hanging
            // the detection task indefinitely.
            if backupNotificationPosted {
                Log.lifecycle.info("Start prompt modal dismissed without decision for \(app.bundleID, privacy: .public); backup notification remains recoverable")
            } else {
                Log.lifecycle.info("Start prompt modal dismissed without backup notification for \(app.bundleID, privacy: .public); clearing current prompt")
                resolve(identifier: identifier, with: .skipForNow, removeNotification: false)
            }
        }
    }

    private func promptTitle(for app: MeetingApp, event: CalendarEvent?) -> String {
        if let event {
            return "Start recording '\(event.title)'?"
        }
        return "Start recording \(app.displayName)?"
    }

    private func promptSubtitle(for app: MeetingApp, event: CalendarEvent?) -> String {
        if event != nil {
            return "From Apple Calendar. Detected in \(app.displayName)."
        }
        return "Scribe detected an active call in \(app.displayName)."
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

    private func ensureRegistered() async {
        guard !registeredCategories else { return }
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: Action.start,
                    title: "Start Recording",
                    options: [.foreground]
                ),
                UNNotificationAction(
                    identifier: Action.notNow,
                    title: "Not now",
                    options: []
                )
            ],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        registeredCategories = true
    }

    @MainActor
    private func resolve(identifier: String, with choice: Choice, removeNotification: Bool) {
        guard let entry = pending.removeValue(forKey: identifier) else {
            Log.lifecycle.info("Ignoring stale start-prompt action (id=\(identifier, privacy: .public))")
            return
        }
        if removeNotification {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        }
        entry.continuation.resume(returning: choice)
    }

    private func place(window: NSWindow, nearActiveWindowFor app: MeetingApp) {
        guard let targetScreen = activeScreen(for: app) else {
            window.center()
            return
        }
        let frame = targetScreen.visibleFrame
        let size = window.frame.size
        let origin = CGPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
        window.setFrameOrigin(origin)
    }

    private func activeScreen(for app: MeetingApp) -> NSScreen? {
        guard let windowBounds = frontmostWindowBounds(forBundleID: app.bundleID) else { return nil }
        return NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(windowBounds).area < rhs.frame.intersection(windowBounds).area
        }
    }

    private func frontmostWindowBounds(forBundleID bundleID: String) -> CGRect? {
        let runningPIDs = Set(NSWorkspace.shared.runningApplications.compactMap { running -> pid_t? in
            running.bundleIdentifier == bundleID ? running.processIdentifier : nil
        })
        guard !runningPIDs.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in windows {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  runningPIDs.contains(pid),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any] else {
                continue
            }
            var bounds = CGRect.null
            if CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &bounds), !bounds.isNull, !bounds.isEmpty {
                return bounds
            }
        }
        return nil
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
        let identifier = response.notification.request.identifier
        let actionID = response.actionIdentifier
        completionHandler()
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch actionID {
            case Action.start:
                self.resolve(identifier: identifier, with: .start, removeNotification: true)
            case Action.notNow:
                self.resolve(identifier: identifier, with: .skipForNow, removeNotification: true)
            case UNNotificationDismissActionIdentifier:
                Log.lifecycle.info("Start prompt backup notification dismissed without decision (id=\(identifier, privacy: .public)); clearing current prompt")
                self.resolve(identifier: identifier, with: .skipForNow, removeNotification: false)
            default:
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

@MainActor
private final class MoreOptionsAccessory: NSObject {
    let view = NSStackView()
    private let suppressButton: NSButton
    private let onSuppress: @MainActor () -> Void

    init(appDisplayName: String, onSuppress: @escaping @MainActor () -> Void) {
        self.onSuppress = onSuppress
        self.suppressButton = NSButton(title: "Stop detecting \(appDisplayName) for 30 minutes", target: nil, action: nil)
        super.init()

        let disclosure = NSButton(title: "More options ▾", target: self, action: #selector(toggleMoreOptions(_:)))
        disclosure.bezelStyle = .inline
        disclosure.setButtonType(.momentaryPushIn)
        disclosure.alignment = .left

        suppressButton.target = self
        suppressButton.action = #selector(suppressApp(_:))
        suppressButton.bezelStyle = .inline
        suppressButton.alignment = .left
        suppressButton.isHidden = true

        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 6
        view.addArrangedSubview(disclosure)
        view.addArrangedSubview(suppressButton)
    }

    @objc private func toggleMoreOptions(_ sender: NSButton) {
        suppressButton.isHidden.toggle()
        sender.title = suppressButton.isHidden ? "More options ▾" : "More options ▴"
        view.layoutSubtreeIfNeeded()
    }

    @objc private func suppressApp(_ sender: NSButton) {
        onSuppress()
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}
