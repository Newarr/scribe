import AppKit
import TranscriberCore

@MainActor
final class StartPromptCoordinator {
    enum Choice {
        case start
        case notAMeeting
        case skipForNow
    }

    /// Phase π: spec § Detection. The prompt auto-dismisses after this
    /// many seconds with .skipForNow if the user doesn't pick anything,
    /// so a stale prompt left on screen during a real meeting doesn't
    /// block subsequent detection candidates.
    static let autoDismissAfter: TimeInterval = 60

    private static let autoDismissModalResponse = NSApplication.ModalResponse(rawValue: 9_999)

    /// Codex rc1-final P1.5: NSApp.stopModal targets WHATEVER modal is
    /// at the top of the stack when the timer fires. If a second
    /// detection candidate (or another modal — system permission
    /// prompt, settings sheet) opens between t=0 and t=60s, the timer
    /// would close the wrong modal. Gate concurrent prompts so only
    /// one is ever in flight; subsequent candidates are coalesced into
    /// .skipForNow without touching the modal stack.
    private var promptInFlight = false

    func prompt(for app: MeetingApp, event: CalendarEvent? = nil) async -> Choice {
        if promptInFlight {
            Log.lifecycle.info("Start prompt already in flight; coalescing detection candidate \(app.bundleID, privacy: .public) to .skipForNow")
            return .skipForNow
        }
        promptInFlight = true
        defer { promptInFlight = false }
        return await runPrompt(for: app, event: event)
    }

    private func runPrompt(for app: MeetingApp, event: CalendarEvent? = nil) async -> Choice {
        let alert = NSAlert()
        if let event {
            // Calendar-enriched prompt per spec line 167. Showing the event
            // title makes the choice obvious — "Start recording 'Acme Weekly'?"
            // is clearly different from a stray Zoom window the user just
            // opened to test something.
            alert.messageText = "Start recording '\(event.title)'?"
            alert.informativeText = "Transcriber detected \(app.displayName) running during a calendar event. Click Start Recording to capture, or Not a meeting to suppress prompts for \(app.displayName) for 30 minutes. (Auto-dismisses in \(Int(Self.autoDismissAfter))s.)"
        } else {
            alert.messageText = "Start recording \(app.displayName)?"
            alert.informativeText = "Transcriber detected \(app.displayName) is running. Click Start Recording to capture this call, or Not a meeting to suppress prompts for \(app.displayName) for 30 minutes. (Auto-dismisses in \(Int(Self.autoDismissAfter))s.)"
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start Recording")
        alert.addButton(withTitle: "Not a meeting")
        alert.addButton(withTitle: "Skip for now")

        NSApp.activate(ignoringOtherApps: true)

        // Phase π: 60s auto-dismiss timer. NSAlert.runModal() blocks
        // until the user picks; we stopModal(withCode:) from a
        // background task to make it return our sentinel response.
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoDismissAfter * 1_000_000_000))
            if !Task.isCancelled {
                NSApp.stopModal(withCode: Self.autoDismissModalResponse)
            }
        }
        let response = alert.runModal()
        timeoutTask.cancel()

        switch response {
        case .alertFirstButtonReturn:  return .start
        case .alertSecondButtonReturn: return .notAMeeting
        case Self.autoDismissModalResponse:
            Log.lifecycle.info("Start prompt auto-dismissed after \(Int(Self.autoDismissAfter), privacy: .public)s; treating as skip")
            return .skipForNow
        default:                       return .skipForNow
        }
    }
}
