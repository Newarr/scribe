import AppKit
import SwiftUI
import TranscriberCore

/// Maps a `PreflightReason` to a label, an explainer, and (where
/// applicable) the System Settings deep-link URL that lets the user fix
/// it. Phase α surfaces the typed reasons; Phase η renders them as a
/// popover so the user can act on each one without leaving the app.
enum PermissionRemediation {
    /// Inline action a step can offer in addition to (or in place of) a
    /// "Open system settings" deep-link. These are productive paths that
    /// don't require the user to leave the app: they trigger the macOS
    /// permission prompt directly, or open in-app Settings to the field
    /// they need.
    enum PrimaryAction: Hashable {
        case requestMicrophone
        case requestScreenRecording
        case requestCalendar
        case openInAppSettings
    }

    struct Step: Identifiable, Hashable {
        let id: String
        let title: String
        let detail: String
        /// Deep-link to a System Settings pane. Rendered as the secondary
        /// "Open system settings" button. Used for `denied` states where
        /// the user must toggle the app on manually.
        let openURL: URL?
        /// Inline action that doesn't leave the app. Rendered as the
        /// primary "Grant access" / "Open settings" button. Used for
        /// `notDetermined` states (request the permission directly) and
        /// for engine misconfiguration (jump to Settings → Engine).
        let primaryAction: PrimaryAction?
        let kind: Kind

        enum Kind: String, Hashable {
            case blocker
            case warning
        }
    }

    static func steps(from report: PreflightReport) -> [Step] {
        var out: [Step] = []
        for r in report.blockers {
            out.append(stepFor(r, kind: .blocker))
        }
        for r in report.warnings {
            out.append(stepFor(r, kind: .warning))
        }
        return out
    }

    private static func stepFor(_ reason: PreflightReason, kind: Step.Kind) -> Step {
        switch reason {
        case .microphoneDenied:
            return Step(
                id: "mic.denied",
                title: "Microphone access denied",
                detail: "Scribe can't capture your voice without microphone permission. Enable it in System Settings → Privacy & Security → Microphone.",
                openURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"),
                primaryAction: nil,
                kind: kind
            )
        case .microphoneNotDetermined:
            return Step(
                id: "mic.undetermined",
                title: "Microphone permission not granted yet",
                detail: "Scribe needs microphone access to capture your voice. Grant it now without leaving the app.",
                openURL: nil,
                primaryAction: .requestMicrophone,
                kind: kind
            )
        case .screenRecordingDenied:
            // Codex P2.4: macOS 15+ labels this pane "Screen & System
            // Audio Recording" rather than "Screen Recording." Update
            // the user-facing copy to match what they'll actually see.
            //
            // CGRequestScreenCaptureAccess is a no-op once the user has
            // explicitly denied, so we offer both: the inline request
            // (works for first-run / not-yet-prompted), and the deep-link
            // (works once denied and re-grant requires the toggle).
            return Step(
                id: "screen.denied",
                title: "Screen & System Audio Recording access denied",
                detail: "Scribe needs Screen & System Audio Recording permission to capture other apps' audio (Zoom, Meet, etc). Try Grant access; if macOS won't prompt, enable Scribe in Privacy & Security → Screen & System Audio Recording and restart the app.",
                openURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
                primaryAction: .requestScreenRecording,
                kind: kind
            )
        case .outputFolderUnwritable(let url):
            return Step(
                id: "output.unwritable",
                title: "Output folder isn't writable",
                detail: "Scribe can't write to \(url.path). Pick a different folder under Settings → Output, or fix the permissions on this one.",
                openURL: nil,
                primaryAction: .openInAppSettings,
                kind: kind
            )
        case .outputFolderInSyncedStorage(let url, let provider):
            return Step(
                id: "output.synced",
                title: "Output folder is in \(provider)",
                detail: "Recording into \(provider) at \(url.path) can race the cloud sync (truncated audio mid-write). Move the folder to local storage, or accept the risk.",
                openURL: nil,
                primaryAction: .openInAppSettings,
                kind: kind
            )
        case .missingCloudAPIKey:
            return Step(
                id: "cloud.api-key",
                title: "ElevenLabs API key missing",
                detail: "Cloud mode needs an API key in your Keychain. Open Settings → Engine and paste the key there.",
                openURL: nil,
                primaryAction: .openInAppSettings,
                kind: kind
            )
        case .localModelNotVerified(let modelID):
            return Step(
                id: "local.model.not-verified",
                title: "Cohere local model not ready",
                detail: "Local mode needs the verified Cohere model \(modelID). Open Settings → Engine to download, verify, or retry setup.",
                openURL: nil,
                primaryAction: .openInAppSettings,
                kind: kind
            )
        case .localRuntimeUnavailable:
            return Step(
                id: "local.runtime.unavailable",
                title: "Cohere local runtime unavailable",
                detail: "Local mode requires native MLX support on Apple Silicon. Open Settings → Engine for repair options or explicitly choose Cloud.",
                openURL: nil,
                primaryAction: .openInAppSettings,
                kind: kind
            )
        case .calendarDeniedOptional:
            return Step(
                id: "calendar.denied",
                title: "Calendar access denied (optional)",
                detail: "Without calendar access, sessions won't be tagged with the meeting title or attendees. Recording still works. Enable in System Settings → Privacy & Security → Calendars.",
                openURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"),
                primaryAction: nil,
                kind: kind
            )
        case .calendarNotDetermined:
            return Step(
                id: "calendar.undetermined",
                title: "Calendar permission not granted yet (optional)",
                detail: "Granting calendar access lets Scribe tag sessions with meeting titles and attendees. Recording works without it.",
                openURL: nil,
                primaryAction: .requestCalendar,
                kind: kind
            )
        case .notificationsDeniedOptional:
            return Step(
                id: "notifications.denied",
                title: "Notifications denied (optional)",
                detail: "Without notifications, Scribe can still record manually, but meeting prompts lose their backup notification channel. Enable notifications in System Settings → Notifications.",
                openURL: URL(string: "x-apple.systempreferences:com.apple.preference.notifications"),
                primaryAction: nil,
                kind: kind
            )
        case .notificationsNotDetermined:
            return Step(
                id: "notifications.undetermined",
                title: "Notifications not enabled yet (optional)",
                detail: "Notifications help Scribe remind you about meeting prompts. Manual recording still works without them.",
                openURL: URL(string: "x-apple.systempreferences:com.apple.preference.notifications"),
                primaryAction: nil,
                kind: kind
            )
        }
    }
}

/// Handlers the popover invokes when a user clicks an inline primary
/// action. AppDelegate owns the side-effects (PermissionsService calls,
/// settings window presentation, audit re-runs).
struct PermissionRecoveryActions {
    let onRequestMicrophone: @MainActor @Sendable () -> Void
    let onRequestScreenRecording: @MainActor @Sendable () -> Void
    let onRequestCalendar: @MainActor @Sendable () -> Void
    let onOpenInAppSettings: @MainActor @Sendable () -> Void
}

/// Popover content showing a Setup Required summary plus per-reason
/// remediation buttons. Triggered from AppDelegate when preflight
/// returns `.deny`, also accessible from the menu bar so the user can
/// recheck after fixing things in System Settings.
struct PermissionRecoveryView: View {
    let steps: [PermissionRemediation.Step]
    let actions: PermissionRecoveryActions
    let onRecheck: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // scribe-design-system: mono eyebrow + sentence-case title
            // replaces the standalone filled SF Symbol. The badge state
            // is encoded by the per-step indicators below.
            VStack(alignment: .leading, spacing: 4) {
                Text(steps.isEmpty ? "READY" : "ATTENTION")
                    .font(DS.Font.eyebrow)
                    .tracking(0.8)
                    .foregroundStyle(steps.isEmpty ? DS.Color.success : DS.Color.warning)
                Text(steps.isEmpty ? "Everything looks good" : "Setup required")
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.foreground)
            }

            // Codex Phase η P1.7: wrap steps in a ScrollView so
            // pathological many-step cases (mic + screen + key +
            // unwritable output + calendar warning) don't overflow the
            // popover.
            if steps.isEmpty {
                Text("Try Record again.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.foregroundSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(steps, id: \.id) { step in
                            StepRow(step: step, actions: actions)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            Divider()

            HStack {
                Spacer()
                Button("Recheck now", action: onRecheck)
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(18)
        .frame(width: 460)
        .glassBackground()
    }
}

private struct StepRow: View {
    let step: PermissionRemediation.Step
    let actions: PermissionRecoveryActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Indicator(
                state: step.kind == .blocker ? .failed : .warning,
                label: step.kind == .blocker ? "Blocker" : "Warning"
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.foreground)
                Text(step.detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.foregroundTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Primary inline action (request permission, open in-app
            // Settings) takes precedence; deep-link to System Settings
            // is offered as a secondary path when available.
            if step.primaryAction != nil || step.openURL != nil {
                HStack {
                    Spacer()
                    if let url = step.openURL {
                        Button("Open system settings") {
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    if let primary = step.primaryAction {
                        Button(primaryButtonLabel(primary)) {
                            invoke(primary)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
        }
        .padding(12)
        .background(DS.Color.backgroundCard)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .stroke(DS.Color.borderCard, lineWidth: 1)
        )
        .cornerRadius(DS.Radius.lg)
    }

    private func primaryButtonLabel(_ action: PermissionRemediation.PrimaryAction) -> String {
        switch action {
        case .requestMicrophone, .requestScreenRecording, .requestCalendar:
            return "Grant access"
        case .openInAppSettings:
            return "Open Settings"
        }
    }

    private func invoke(_ action: PermissionRemediation.PrimaryAction) {
        switch action {
        case .requestMicrophone:       actions.onRequestMicrophone()
        case .requestScreenRecording:  actions.onRequestScreenRecording()
        case .requestCalendar:         actions.onRequestCalendar()
        case .openInAppSettings:       actions.onOpenInAppSettings()
        }
    }
}

/// Lightweight controller that hosts a `PermissionRecoveryView` inside
/// an `NSPopover` anchored to the menu bar status item. Centralized so
/// AppDelegate doesn't have to manage NSPopover lifecycle.
///
/// Adds two passive auto-recheck signals so the user doesn't have to
/// click Recheck after granting in System Settings:
///   * `NSApplication.didBecomeActiveNotification` (fires when the user
///     returns from System Settings).
///   * A 1.5s repeating timer while the popover is shown (TCC has no
///     change-notification API for our scopes; this is the cheap
///     fallback).
@MainActor
final class PermissionRecoveryPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private var recheck: (@MainActor () -> Void)?
    private var generation: Int = 0
    /// Steps currently rendered in the popover. Used to skip rebuild
    /// when the auto-recheck timer fires with an identical report
    /// (the underlying TCC bit can be stale forever, so re-rendering
    /// every 1.5s caused a visible close-and-reopen flash that
    /// also raced with user-dismissal).
    private var currentSteps: [PermissionRemediation.Step] = []
    /// Set on user-driven dismiss (transient click-outside or explicit
    /// close). Auto-rechecks queued before the dismiss must not
    /// resurrect the popover within this grace window.
    private var suppressedUntil: Date?
    nonisolated(unsafe) private var didBecomeActiveObserver: NSObjectProtocol?
    nonisolated(unsafe) private var pollTimer: Timer?

    override init() {
        super.init()
        popover.delegate = self
    }

    deinit {
        tearDownAutoRechecks()
    }

    func show(
        steps: [PermissionRemediation.Step],
        anchor: NSStatusBarButton,
        actions: PermissionRecoveryActions,
        onRecheck: @escaping @MainActor () -> Void
    ) {
        // If the user just dismissed the popover, don't let a queued
        // recheck Task spring it back open within the grace window.
        if let until = suppressedUntil, until > Date() {
            recheck = onRecheck
            return
        }
        suppressedUntil = nil

        // If the popover is already shown with the same report, refresh
        // the recheck callback and leave the UI alone. Prevents the
        // flash-on-poll-tick caused by tearing down and rebuilding the
        // NSPopover + NSHostingController on every 1.5s timer fire.
        if popover.isShown, steps == currentSteps {
            recheck = onRecheck
            return
        }

        tearDownAutoRechecks()
        // Codex Phase η P1.8: if a popover from a previous deny path
        // is still on screen, close it cleanly first so the new content
        // doesn't fight AppKit's existing presentation.
        if popover.isShown {
            recheck = nil
            popover.performClose(nil)
        }
        generation += 1
        let showGeneration = generation
        recheck = onRecheck
        currentSteps = steps
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PermissionRecoveryView(
                steps: steps,
                actions: actions,
                onRecheck: { [weak self] in
                    guard let self, self.generation == showGeneration else { return }
                    self.recheck?()
                }
            )
        )
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        // Codex PM-review UX-4: NSPopover hosts a backing window; set
        // its sharingType so the popover content (permission state +
        // deep-links) doesn't appear in screen-shared video.
        popover.contentViewController?.view.window?.sharingType = WindowChromeSharing.confidential
        installAutoRechecks(generation: showGeneration)
    }

    func close() {
        tearDownAutoRechecks()
        recheck = nil
        currentSteps = []
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    // MARK: - NSPopoverDelegate

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.tearDownAutoRechecks()
            self.recheck = nil
            self.currentSteps = []
            // 5s grace window: any queued recheck Task that lands after
            // dismiss is dropped, so click-outside actually dismisses
            // instead of being immediately resurrected by a timer-fired
            // Task enqueued before dismiss.
            self.suppressedUntil = Date().addingTimeInterval(5)
        }
    }

    // MARK: - Auto-recheck plumbing

    private func installAutoRechecks(generation installedGeneration: Int) {
        tearDownAutoRechecks()
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == installedGeneration else { return }
                self.recheck?()
            }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == installedGeneration else { return }
                self.recheck?()
            }
        }
    }

    private nonisolated func tearDownAutoRechecks() {
        if let token = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(token)
            didBecomeActiveObserver = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
