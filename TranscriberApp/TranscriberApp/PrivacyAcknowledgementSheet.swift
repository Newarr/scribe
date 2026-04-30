import AppKit
import SwiftUI
import TranscriberCore

/// Spec line 348: the user must acknowledge what data leaves the device
/// before the first recording. Presented as a modal-style window at app
/// launch when `privacyAcknowledged == false`. Recording is gated on
/// this flag — see AppDelegate.startRecording.
///
/// Codex Phase η P1.4: the window is intentionally NOT closable from
/// the title bar — the user must either click "I understand" or quit
/// the app via cmd-q. Spec consent UI shouldn't be silently dismissable.
@MainActor
final class PrivacyAcknowledgementController {
    private var window: NSWindow?
    private let onAcknowledged: @MainActor () -> Void

    init(onAcknowledged: @escaping @MainActor () -> Void) {
        self.onAcknowledged = onAcknowledged
    }

    /// Builds and presents the sheet. Returns immediately; the
    /// `onAcknowledged` callback fires when the user clicks the button.
    func present() {
        // Use a real window so the sheet is keyed and front-of-screen
        // even though the app is menu-bar-only (no main window).
        // No `.closable` — see class-level note (codex P1.4).
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        host.title = "Welcome to Transcriber"
        host.center()
        host.isReleasedWhenClosed = false
        // Codex PM-review UX-4: confidential UI. Spec § Design
        // Principles: Transcriber-owned windows must not appear in
        // screen-shared video. .none excludes the window from
        // ScreenCaptureKit captures + screen-share video frames.
        host.sharingType = .none
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Transcriber")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Before your first recording, here's what to know.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recordings go to ElevenLabs for transcription").bold()
                        Text("Each meeting's audio is sent to ElevenLabs to produce the transcript. Audio is deleted from ElevenLabs after processing.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "icloud.and.arrow.up")
                }

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Meeting names and attendees may be sent as hints").bold()
                        Text("Calendar event titles and attendee display names are sent as transcription hints. Notes, links, emails, dial-in codes, and passwords are never sent.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "calendar.badge.clock")
                }

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transcripts stay on your Mac").bold()
                        Text("Each meeting saves a Markdown transcript and the original audio in your Transcriber folder. Nothing else leaves your Mac.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "folder")
                }

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Calendar access is optional").bold()
                        Text("Calendar lets Transcriber tag recordings with meeting titles. Denying it never blocks a recording.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            }

            Spacer()

            HStack {
                // Codex PM-review UX-2: link to the full privacy doc
                // for users who want details.
                Button("Read full privacy details") {
                    if let url = URL(string: "https://github.com/Newarr/transcriber/blob/main/docs/PRIVACY.md") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                Spacer()
                Button(action: onAcknowledged) {
                    Text("Start using Transcriber").frame(minWidth: 180)
                }
                .keyboardShortcut(.return, modifiers: [])
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 560, height: 420)
    }
}
