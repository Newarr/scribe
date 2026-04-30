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
            Text("Privacy and data handling")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Audio leaves your Mac in cloud mode").bold()
                        Text("Transcriber's default engine sends your microphone and system audio to ElevenLabs for transcription.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "icloud.and.arrow.up")
                }

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Calendar event names + attendees go alongside the audio").bold()
                        Text("If you grant Calendar permission, the matching event title and attendee names are sent to the engine as transcription hints (\"keyterms\"). Sessions started outside a meeting send no calendar data.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "calendar.badge.clock")
                }

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transcripts and audio are saved locally").bold()
                        Text("Each session writes a Markdown transcript and the original audio under your output folder. Nothing else leaves your Mac.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "folder")
                }

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local mode keeps audio on-device").bold()
                        Text("When the local engine ships, switching to local mode in Settings keeps audio entirely on your Mac. Until then, only cloud mode is available.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "laptopcomputer")
                }

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Calendar access is optional").bold()
                        Text("Denying Calendar permission disables session tagging but never blocks recording.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button(action: onAcknowledged) {
                    Text("I understand").frame(minWidth: 120)
                }
                .keyboardShortcut(.return, modifiers: [])
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 540, height: 460)
    }
}
