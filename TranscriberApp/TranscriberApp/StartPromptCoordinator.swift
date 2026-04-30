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
        // Codex PM-review UX-22: ask about the meeting, not the app.
        // "Start recording 'Acme Weekly'?" reads like the meeting,
        // not "Start recording Zoom" which sounds like a screen
        // recording.
        if let event {
            alert.messageText = "Record '\(event.title)'?"
            alert.informativeText = "\(app.displayName) is running during this calendar event. (Closes in \(Int(Self.autoDismissAfter))s.)"
        } else {
            alert.messageText = "Record this \(app.displayName) call?"
            alert.informativeText = "No matching calendar event. The transcript will be saved as a manual recording. (Closes in \(Int(Self.autoDismissAfter))s.)"
        }
        alert.alertStyle = .informational
        // Codex PM-review UX-21: two clear primary buttons. "Not a
        // meeting" reads like "this isn't actually a meeting at
        // all" which is the wrong mental model — the user is
        // saying "not now, stop bugging me about this app." Make
        // that explicit with sentence case + plain language.
        alert.addButton(withTitle: "Start recording")
        alert.addButton(withTitle: "Not now")
        alert.addButton(withTitle: "Stop detecting \(app.displayName) for 30 min")

        NSApp.activate(ignoringOtherApps: true)
        // Codex PM-review UX-4: confidential UI. NSAlert's underlying
        // window must opt out of screen-share captures so a meeting
        // detection prompt doesn't appear in the user's own
        // shared-screen video.
        alert.window.sharingType = .none

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
        // Codex PM-review UX-21: button order swapped. The 30-min
        // suppress is the rare-power-user choice; "Not now" is the
        // common "skip this prompt" path.
        case .alertSecondButtonReturn: return .skipForNow
        case .alertThirdButtonReturn:  return .notAMeeting
        case Self.autoDismissModalResponse:
            Log.lifecycle.info("Start prompt auto-dismissed after \(Int(Self.autoDismissAfter), privacy: .public)s; treating as skip")
            return .skipForNow
        default:                       return .skipForNow
        }
    }
}
