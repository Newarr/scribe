import AppKit
import SwiftUI
import TranscriberCore

/// Spec line 348: the user must acknowledge what data leaves the device
/// before the first recording. Presented as a modal sheet on top of an
/// invisible window at app launch when `privacyAcknowledged == false`.
/// Recording is gated on this flag — see AppDelegate.startRecording.
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
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        host.title = "Welcome to Transcriber"
        host.center()
        host.isReleasedWhenClosed = false
        host.contentView = NSHostingView(rootView: PrivacyAcknowledgementView(
            onAcknowledged: { [weak self] in
                guard let self else { return }
                host.close()
                self.window = nil
                self.onAcknowledged()
            }
        ))
        host.level = .floating
        host.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
                        Text("Transcriber's default engine sends your microphone and system audio to ElevenLabs for transcription. Switch to local mode in Settings to keep audio on-device once the local engine ships.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "icloud.and.arrow.up")
                }

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transcripts and audio are saved locally").bold()
                        Text("Each session writes a Markdown transcript and the original audio under your output folder. Nothing is uploaded except the audio sent to the engine.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "folder")
                }

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Calendar access is optional").bold()
                        Text("If you grant Calendar permission, Transcriber tags sessions with the matching event title and attendees. Denying it never blocks a recording.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "calendar")
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
        .frame(width: 520, height: 380)
    }
}
