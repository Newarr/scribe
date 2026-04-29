import AppKit
import TranscriberCore

@MainActor
final class StartPromptCoordinator {
    enum Choice {
        case start
        case notAMeeting
        case skipForNow
    }

    func prompt(for app: MeetingApp, event: CalendarEvent? = nil) async -> Choice {
        let alert = NSAlert()
        if let event {
            // Calendar-enriched prompt per spec line 167. Showing the event
            // title makes the choice obvious — "Start recording 'Acme Weekly'?"
            // is clearly different from a stray Zoom window the user just
            // opened to test something.
            alert.messageText = "Start recording '\(event.title)'?"
            alert.informativeText = "Transcriber detected \(app.displayName) running during a calendar event. Click Start Recording to capture, or Not a meeting to suppress prompts for \(app.displayName) for 30 minutes."
        } else {
            alert.messageText = "Start recording \(app.displayName)?"
            alert.informativeText = "Transcriber detected \(app.displayName) is running. Click Start Recording to capture this call, or Not a meeting to suppress prompts for \(app.displayName) for 30 minutes."
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start Recording")
        alert.addButton(withTitle: "Not a meeting")
        alert.addButton(withTitle: "Skip for now")

        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:  return .start
        case .alertSecondButtonReturn: return .notAMeeting
        default:                       return .skipForNow
        }
    }
}
