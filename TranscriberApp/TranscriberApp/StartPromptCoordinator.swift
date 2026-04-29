import AppKit
import TranscriberCore

@MainActor
final class StartPromptCoordinator {
    enum Choice {
        case start
        case notAMeeting
        case skipForNow
    }

    func prompt(for app: MeetingApp) async -> Choice {
        let alert = NSAlert()
        alert.messageText = "Start recording \(app.displayName)?"
        alert.informativeText = "Transcriber detected \(app.displayName) is running. Click Start Recording to capture this call, or Not a meeting to suppress prompts for \(app.displayName) for 30 minutes."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start Recording")
        alert.addButton(withTitle: "Not a meeting")
        alert.addButton(withTitle: "Skip for now")

        // Bring our process to front so the modal is actually visible — the
        // menu-bar-only LSUIElement app won't auto-foreground without this.
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:  return .start
        case .alertSecondButtonReturn: return .notAMeeting
        default:                       return .skipForNow
        }
    }
}
