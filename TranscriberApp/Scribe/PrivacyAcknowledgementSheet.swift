import AppKit
import SwiftUI
import TranscriberCore

/// Spec line 348: the user must acknowledge what data leaves the device
/// before the first recording. Presented as a modal-style window at app
/// launch when `privacyAcknowledged == false`. Recording is gated on
/// this flag; see AppDelegate.startRecording.
///
/// Codex Phase η P1.4: the window is intentionally NOT closable from
/// the title bar; the user must either click "I understand" or quit
/// the app via cmd-q. Spec consent UI shouldn't be silently dismissable.
@MainActor
final class PrivacyAcknowledgementController {
    private var window: NSWindow?
    private let onAcknowledged: @MainActor () -> Void

    init(onAcknowledged: @escaping @MainActor () -> Void) {
        self.onAcknowledged = onAcknowledged
    }

    /// True when the consent window is currently on screen (built but
    /// not yet acknowledged). AppDelegate consults this on menu bar
    /// clicks so a buried welcome window can be raised before the
    /// recents popover takes the click.
    var isPending: Bool { window != nil }

    /// Raises the existing welcome window to front + key. No-op if the
    /// window doesn't exist (already acknowledged or never presented).
    @MainActor
    func bringFront() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Builds and presents the sheet. Returns immediately; the
    /// `onAcknowledged` callback fires when the user clicks the button.
    func present() {
        // Use a real window so the sheet is keyed and front-of-screen
        // even though the app is menu-bar-only (no main window).
        // No `.closable`; see class-level note (codex P1.4).
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Title kept for VoiceOver / window-list copy; the titlebar
        // itself is hidden by `WindowChrome.installGlass`, so the brand
        // wordmark inside the SwiftUI body carries the visual title.
        host.title = "Welcome to Scribe"
        host.center()
        host.isReleasedWhenClosed = false
        // Codex PM-review UX-4: confidential UI. Spec § Design
        // Principles: Scribe-owned windows must not appear in
        // screen-shared video. .none excludes the window from
        // ScreenCaptureKit captures + screen-share video frames.
        host.sharingType = WindowChromeSharing.confidential
        host.contentView = NSHostingView(rootView: PrivacyAcknowledgementView(
            onAcknowledged: { [weak self] in
                guard let self else { return }
                // Codex P2.1: weak capture of the controller through
                // self avoids the host/contentView/closure retain cycle
                // that would have leaked the window after dismissal.
                self.window?.close()
                self.window = nil
                self.onAcknowledged()
            }
        ))
        WindowChrome.installGlass(on: host, material: .hudWindow)
        // Codex P1.5: use a normal window level (not .floating) so a
        // launch-time presentation while the user is screen-sharing
        // doesn't push the consent text above the share. Activate only
        // if the user is actually focused on the app (no `ignoringOtherApps`).
        host.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = host
    }
}

private struct PrivacyAcknowledgementView: View {
    let onAcknowledged: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Mono eyebrow + brand wordmark.
            VStack(alignment: .leading, spacing: 12) {
                Text("WELCOME")
                    .font(DS.Font.eyebrow)
                    .tracking(0.8)
                    .foregroundStyle(DS.Color.foregroundTertiary)
                BrandWordmark(height: 28)
                    .foregroundStyle(DS.Color.foreground)
            }
            .padding(.bottom, 32)

            // Headline. Declarative, confident, the product promise.
            Text("For your most important calls.")
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.foreground)
                .padding(.bottom, 28)

            // Three benefit-led rows. The voice is product-first, not
            // compliance-first: each row tells the user something
            // good Scribe does for them. The one decision they own
            // (cloud vs local) shows up as a feature, not a warning.
            VStack(alignment: .leading, spacing: 18) {
                privacyRow(
                    state: .ready,
                    label: "CAPTURE",
                    title: "Every meeting, transcribed",
                    detail: "Sits in your menu bar. Captures audio and writes a clean transcript to your Scribe folder. The files always stay on your Mac."
                )
                privacyRow(
                    state: .ready,
                    label: "MARKDOWN",
                    title: "Transcripts your agents already understand",
                    detail: "Each session is plain Markdown with frontmatter. Drop the folder into Obsidian, Cursor, Claude, or any tool that reads a directory."
                )
                privacyRow(
                    state: .ready,
                    label: "YOUR CALL",
                    title: "Cloud fidelity or local privacy",
                    detail: "Pick ElevenLabs for top-tier transcripts, or a local model that keeps every byte on your Mac. Switch any time in Settings."
                )
            }

            Spacer(minLength: 24)

            HStack {
                Button("Read full privacy details") {
                    if let url = URL(string: "https://github.com/Newarr/scribe/blob/main/docs/user/PRIVACY.md") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(DSLinkButtonStyle())
                Spacer()
                Button(action: onAcknowledged) {
                    Text("Start using Scribe")
                        .frame(minWidth: 180)
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(PrimaryButtonStyle())
                .hoverSheen()
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 44)
        .padding(.bottom, 32)
        .frame(width: 600, height: 560)
        .glassBackground()
    }

    private func privacyRow(
        state: Indicator.State,
        label: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Indicator(state: state, label: label)
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.foreground)
                Text(detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.foregroundSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
