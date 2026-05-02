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
    /// detection candidate (or another modal, like a system permission
    /// prompt or settings sheet) opens between t=0 and t=60s, the timer
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
        // F-4: SwiftUI window replaces NSAlert. Behavior preserved:
        // modal loop, 60s auto-dismiss sentinel, sharingType=.none,
        // identical Choice mapping. Visual fidelity: meeting title is
        // the hero, mono eyebrow + custom buttons match the design
        // mock exactly.
        let window = StartPromptWindow.makeWindow(
            for: app,
            event: event,
            autoDismissAfter: Self.autoDismissAfter
        )

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Phase π: 60s auto-dismiss timer. Same sentinel response code
        // pattern as the NSAlert version: when the timer fires,
        // `NSApp.stopModal(withCode:)` returns our sentinel out of
        // `runModal(for:)` and the switch below reads .skipForNow.
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoDismissAfter * 1_000_000_000))
            if !Task.isCancelled {
                NSApp.stopModal(withCode: Self.autoDismissModalResponse)
            }
        }
        let response = NSApp.runModal(for: window)
        timeoutTask.cancel()
        window.orderOut(nil)
        window.close()

        switch response {
        case StartPromptWindow.ModalCode.start:    return .start
        case StartPromptWindow.ModalCode.skip:     return .skipForNow
        case StartPromptWindow.ModalCode.suppress: return .notAMeeting
        case Self.autoDismissModalResponse:
            Log.lifecycle.info("Start prompt auto-dismissed after \(Int(Self.autoDismissAfter), privacy: .public)s; treating as skip")
            return .skipForNow
        default:                                   return .skipForNow
        }
    }
}
