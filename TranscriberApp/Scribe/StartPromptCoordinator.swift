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

    private final class Pending {
        let identifier: String
        let app: MeetingApp
        let event: CalendarEvent?
        let continuation: CheckedContinuation<Choice, Never>
        var notificationIdentifiers: Set<String> = []
        var reminderTimer: Timer?
        var expiryTimer: Timer?

        init(
            identifier: String,
            app: MeetingApp,
            event: CalendarEvent?,
            continuation: CheckedContinuation<Choice, Never>
        ) {
            self.identifier = identifier
            self.app = app
            self.event = event
            self.continuation = continuation
        }
    }

    private enum NotificationKind: String {
        case backup
        case reminder
    }

    private var pending: [String: Pending] = [:]
    private var activePromptIdentifier: String?
    private var registeredCategories = false
    private var authorizationKnown = false
    private var authorizationGranted = false

    /// Test/configuration seam. Production follows the spec: one fresh
    /// reminder at ~60s, then safe expiry around the 3-minute policy.
    var reminderDelay: TimeInterval = 60
    var expiryDelay: TimeInterval = 180

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func prompt(for app: MeetingApp, event: CalendarEvent? = nil) async -> Choice {
        let identifier = UUID().uuidString
        await ensureRegistered()

        return await withCheckedContinuation { continuation in
            let entry = Pending(
                identifier: identifier,
                app: app,
                event: event,
                continuation: continuation
            )
            pending[identifier] = entry
            activePromptIdentifier = identifier
            scheduleRecoveryTimers(for: entry)
            Task { @MainActor [weak self] in
                await self?.postNotificationIfPossible(
                    promptID: identifier,
                    kind: .backup,
                    app: app,
                    event: event
                )
            }
            presentModalPrompt(identifier: identifier, app: app, event: event)
        }
    }

    func chooseStartFromRecovery() {
        guard let identifier = activePromptIdentifier else {
            Log.lifecycle.info("Ignoring stale start-prompt menu recovery start: no active prompt")
            return
        }
        resolve(identifier: identifier, with: .start, removeNotifications: true)
    }

    func chooseNotNowFromRecovery() {
        guard let identifier = activePromptIdentifier else {
            Log.lifecycle.info("Ignoring stale start-prompt menu recovery Not now: no active prompt")
            return
        }
        resolve(identifier: identifier, with: .skipForNow, removeNotifications: true)
    }

    func chooseSuppressAppFromRecovery() {
        guard let identifier = activePromptIdentifier else {
            Log.lifecycle.info("Ignoring stale start-prompt menu recovery suppression: no active prompt")
            return
        }
        resolve(identifier: identifier, with: .notAMeeting, removeNotifications: true)
    }

    private func scheduleRecoveryTimers(for entry: Pending) {
        let promptID = entry.identifier
        entry.reminderTimer = Timer.scheduledTimer(withTimeInterval: reminderDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let entry = self.pending[promptID] else { return }
                Log.lifecycle.info("Start prompt reminder firing for \(entry.app.bundleID, privacy: .public) (id=\(promptID, privacy: .public))")
                await self.postNotificationIfPossible(
                    promptID: promptID,
                    kind: .reminder,
                    app: entry.app,
                    event: entry.event
                )
            }
        }
        entry.expiryTimer = Timer.scheduledTimer(withTimeInterval: expiryDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let entry = self.pending[promptID] else { return }
                Log.lifecycle.info("Start prompt expired without decision for \(entry.app.bundleID, privacy: .public) (id=\(promptID, privacy: .public))")
                self.resolve(identifier: promptID, with: .skipForNow, removeNotifications: true)
            }
        }
    }

    @discardableResult
    private func postNotificationIfPossible(
        promptID: String,
        kind: NotificationKind,
        app: MeetingApp,
        event: CalendarEvent?
    ) async -> Bool {
        guard await ensureAuthorization() else {
            Log.lifecycle.info("Start prompt \(kind.rawValue, privacy: .public) notification unavailable for \(app.bundleID, privacy: .public): authorization missing; modal/menu recovery remain active")
            return false
        }

        let notificationID = "\(promptID).\(kind.rawValue)"
        let content = UNMutableNotificationContent()
        content.title = promptTitle(for: app, event: event)
        content.subtitle = event == nil ? "Detected in \(app.displayName)" : "From Apple Calendar · \(app.displayName)"
        content.body = kind == .reminder ? "Still want to start recording?" : "Start recording?"
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [
            "promptID": promptID,
            "bundleID": app.bundleID,
            "displayName": app.displayName,
            "kind": kind.rawValue
        ]
        content.sound = nil

        let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            pending[promptID]?.notificationIdentifiers.insert(notificationID)
            Log.lifecycle.info("Start prompt \(kind.rawValue, privacy: .public) notification posted for \(app.bundleID, privacy: .public) (id=\(promptID, privacy: .public))")
            return true
        } catch {
            Log.lifecycle.error("Start prompt \(kind.rawValue, privacy: .public) notification failed for \(app.bundleID, privacy: .public): \(error.localizedDescription, privacy: .public); modal/menu recovery remain active")
            return false
        }
    }

    private func presentModalPrompt(
        identifier: String,
        app: MeetingApp,
        event: CalendarEvent?
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
            self?.resolve(identifier: identifier, with: .notAMeeting, removeNotifications: true)
            NSApp.stopModal(withCode: NSApplication.ModalResponse.abort)
        }
        alert.accessoryView = accessory.view

        place(window: alert.window, nearActiveWindowFor: app)
        alert.window.makeKeyAndOrderFront(nil)
        alert.window.orderFrontRegardless()

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            resolve(identifier: identifier, with: .start, removeNotifications: true)
        case .alertSecondButtonReturn:
            resolve(identifier: identifier, with: .skipForNow, removeNotifications: true)
        default:
            // A close/Esc/dismissal is not an implicit decline. Leave the
            // prompt session pending so menu-bar recovery and reminder
            // notifications stay available until explicit resolution or expiry.
            Log.lifecycle.info("Start prompt modal dismissed without decision for \(app.bundleID, privacy: .public); menu recovery remains active (id=\(identifier, privacy: .public))")
        }
    }

    private func promptTitle(for app: MeetingApp, event: CalendarEvent?) -> String {
        if let event {
            if event.startDate < Date(), event.endDate.timeIntervalSince(Date()) >= 10 * 60 {
                return "Record '\(event.title)'? This event started \(elapsedMinutesSinceStart(of: event)) minutes ago. Recording will capture from now onward."
            }
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

    private func elapsedMinutesSinceStart(of event: CalendarEvent) -> Int {
        max(1, Int(Date().timeIntervalSince(event.startDate) / 60))
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
    private func resolve(identifier: String, with choice: Choice, removeNotifications: Bool) {
        guard let entry = pending.removeValue(forKey: identifier) else {
            Log.lifecycle.info("Ignoring stale start-prompt action (id=\(identifier, privacy: .public))")
            return
        }
        if activePromptIdentifier == identifier {
            activePromptIdentifier = nil
        }
        entry.reminderTimer?.invalidate()
        entry.expiryTimer?.invalidate()
        if removeNotifications {
            let ids = Array(entry.notificationIdentifiers)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
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
        let notificationIdentifier = response.notification.request.identifier
        let promptID = response.notification.request.content.userInfo["promptID"] as? String
        let identifier = promptID
            ?? notificationIdentifier
                .replacingOccurrences(of: ".backup", with: "")
                .replacingOccurrences(of: ".reminder", with: "")
        let actionID = response.actionIdentifier
        completionHandler()
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch actionID {
            case Action.start:
                self.resolve(identifier: identifier, with: .start, removeNotifications: true)
            case Action.notNow:
                self.resolve(identifier: identifier, with: .skipForNow, removeNotifications: true)
            case UNNotificationDismissActionIdentifier:
                Log.lifecycle.info("Start prompt notification dismissed without decision (id=\(identifier, privacy: .public)); menu recovery remains active")
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
