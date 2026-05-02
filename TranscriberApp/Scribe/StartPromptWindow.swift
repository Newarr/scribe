import AppKit
import SwiftUI
import TranscriberCore

/// F-4: scribe-design-system replacement for the NSAlert that
/// `StartPromptCoordinator` used to drive. NSAlert can't render the
/// designer's mock (meeting title as the visual hero, mono eyebrow,
/// two large primary buttons, ghost suppress button below, mono
/// auto-dismiss timer); this window does, while preserving the modal
/// semantics the coordinator (and its in-flight coalescing + 60s
/// timeout sentinel) depends on.
///
/// Lifecycle:
/// 1. `presentModal(for:event:onChoice:)` builds the window, installs
///    a Liquid Glass chrome (F-3), and returns the underlying
///    `NSWindow` to the caller. The caller drives the modal loop via
///    `NSApp.runModal(for:)` so the existing 60s `stopModal(withCode:)`
///    sentinel keeps working.
/// 2. The user's choice flips `onChoice`; the closure is the bridge to
///    the coordinator's `runPrompt(...)` which translates the
///    `ModalResponse` into `StartPromptCoordinator.Choice`.
///
/// `host.sharingType = WindowChromeSharing.confidential` is set per codex UX-4 (confidential UI).
@MainActor
enum StartPromptWindow {

    /// Modal-response codes used to communicate the user's choice from
    /// the SwiftUI body back through `NSApp.runModal(for:)`. Kept in
    /// sync with the coordinator's `runPrompt` switch.
    enum ModalCode {
        static let start  = NSApplication.ModalResponse(rawValue: 1_001)
        static let skip   = NSApplication.ModalResponse(rawValue: 1_002)
        static let suppress = NSApplication.ModalResponse(rawValue: 1_003)
    }

    static func makeWindow(
        for app: MeetingApp,
        event: CalendarEvent?,
        autoDismissAfter: TimeInterval
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Meeting detected"
        window.center()
        window.level = .modalPanel
        window.isReleasedWhenClosed = false
        window.sharingType = WindowChromeSharing.confidential
        window.isMovableByWindowBackground = true

        window.contentView = NSHostingView(rootView: StartPromptView(
            app: app,
            event: event,
            autoDismissAfter: autoDismissAfter,
            onStart:    { NSApp.stopModal(withCode: ModalCode.start) },
            onSkip:     { NSApp.stopModal(withCode: ModalCode.skip) },
            onSuppress: { NSApp.stopModal(withCode: ModalCode.suppress) }
        ))
        WindowChrome.installGlass(on: window, material: .hudWindow)

        return window
    }
}

private struct StartPromptView: View {
    let app: MeetingApp
    let event: CalendarEvent?
    let autoDismissAfter: TimeInterval
    let onStart: @MainActor () -> Void
    let onSkip: @MainActor () -> Void
    let onSuppress: @MainActor () -> Void

    @State private var secondsRemaining: Int

    init(
        app: MeetingApp,
        event: CalendarEvent?,
        autoDismissAfter: TimeInterval,
        onStart: @escaping @MainActor () -> Void,
        onSkip: @escaping @MainActor () -> Void,
        onSuppress: @escaping @MainActor () -> Void
    ) {
        self.app = app
        self.event = event
        self.autoDismissAfter = autoDismissAfter
        self.onStart = onStart
        self.onSkip = onSkip
        self.onSuppress = onSuppress
        self._secondsRemaining = State(initialValue: Int(autoDismissAfter.rounded()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            // Mono eyebrow: "DETECTED · ZOOM"
            HStack(spacing: 8) {
                Indicator(state: .warning, label: "Detected")
                Text("· \(app.displayName.uppercased())")
                    .font(DS.Font.eyebrow)
                    .tracking(0.44)
                    .foregroundStyle(DS.Color.foregroundTertiary)
                Spacer()
            }

            // Title: the meeting name when there's an event match,
            // otherwise the app name as a fallback.
            VStack(alignment: .leading, spacing: 6) {
                Text(headlineTitle)
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.foreground)
                Text(secondaryLine)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.foregroundSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            // Two primary actions side by side. Cmd-Return starts;
            // Esc dismisses (skip).
            HStack(spacing: 10) {
                Button(action: onStart) {
                    Text("Start recording").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(PrimaryButtonStyle())

                Button(action: onSkip) {
                    Text("Not now").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(SecondaryButtonStyle())
            }

            // Tertiary suppress action below.
            Button(action: onSuppress) {
                Text("Stop detecting \(app.displayName) for 30 min")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GhostButtonStyle())

            // Auto-dismiss countdown in mono caption.
            HStack {
                Spacer()
                Text("Closes in \(secondsRemaining)s")
                    .font(DS.Font.monoSmall)
                    .foregroundStyle(DS.Color.foregroundTertiary)
            }
        }
        .padding(24)
        .frame(width: 460, height: 320)
        .glassBackground()
        .task { await tickCountdown() }
    }

    private var headlineTitle: String {
        if let event { return event.title }
        return "Record this \(app.displayName) call"
    }

    private var secondaryLine: String {
        if let event {
            // Time elapsed since the event started, when known.
            let elapsed = max(0, Int(Date().timeIntervalSince(event.startDate) / 60))
            return "\(app.displayName) · started \(elapsed) min ago"
        }
        return "No matching calendar event. The transcript will be saved as a manual recording."
    }

    private func tickCountdown() async {
        while secondsRemaining > 0 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            secondsRemaining = max(0, secondsRemaining - 1)
        }
    }
}
