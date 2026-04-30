import AppKit
import TranscriberCore

@MainActor
final class RecordingMenu {
    enum Action {
        case record, stop, quit, openSettings, openSetupRequired, openDiagnostics
    }

    private(set) var menu = NSMenu()
    private let onAction: (Action) -> Void
    /// Codex PM-review UX-7: setup label varies based on whether
    /// preflight is currently green. Defaults to "Check setup…"
    /// (neutral); flips to "Setup Required…" when the AppDelegate
    /// observes a deny-state.
    var setupNeedsAttention: Bool = false

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        rebuild(for: .idle)
    }

    func rebuild(for status: SessionStatus) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "\(BuildInfo.appName) \(BuildInfo.version)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        switch status {
        case .idle, .finalized, .failed:
            let item = NSMenuItem(title: "Record now", action: #selector(MenuTarget.record(_:)), keyEquivalent: "r")
            item.target = MenuTarget.shared
            MenuTarget.shared.delegate = self
            menu.addItem(item)
        case .recording:
            // Codex PM-review UX-19: "Stop" is too thin — does it
            // save? Be explicit.
            let item = NSMenuItem(title: "Stop and save", action: #selector(MenuTarget.stop(_:)), keyEquivalent: "s")
            item.target = MenuTarget.shared
            MenuTarget.shared.delegate = self
            menu.addItem(item)
        case .starting, .stopping:
            menu.addItem(NSMenuItem(title: status == .starting ? "Starting recording…" : "Saving recording…", action: nil, keyEquivalent: ""))
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(MenuTarget.openSettings(_:)), keyEquivalent: ",")
        settings.target = MenuTarget.shared
        menu.addItem(settings)
        // Codex PM-review UX-7: only call out "Setup Required…"
        // when there's actually something the user needs to fix.
        // Otherwise use the neutral "Check setup…" label so the
        // menu doesn't constantly imply the app is broken.
        let setupLabel = setupNeedsAttention ? "Setup Required…" : "Check setup…"
        let setup = NSMenuItem(title: setupLabel, action: #selector(MenuTarget.openSetupRequired(_:)), keyEquivalent: "")
        setup.target = MenuTarget.shared
        menu.addItem(setup)
        let diagnostics = NSMenuItem(title: "Diagnostics…", action: #selector(MenuTarget.openDiagnostics(_:)), keyEquivalent: "")
        diagnostics.target = MenuTarget.shared
        menu.addItem(diagnostics)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(MenuTarget.quit(_:)), keyEquivalent: "q")
        quit.target = MenuTarget.shared
        menu.addItem(quit)
    }

    fileprivate func dispatch(_ action: Action) { onAction(action) }
}

@MainActor
final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    weak var delegate: RecordingMenu?

    @objc func record(_ sender: Any?) { delegate?.dispatch(.record) }
    @objc func stop(_ sender: Any?)   { delegate?.dispatch(.stop) }
    @objc func quit(_ sender: Any?)   { delegate?.dispatch(.quit) }
    @objc func openSettings(_ sender: Any?) { delegate?.dispatch(.openSettings) }
    @objc func openSetupRequired(_ sender: Any?) { delegate?.dispatch(.openSetupRequired) }
    @objc func openDiagnostics(_ sender: Any?) { delegate?.dispatch(.openDiagnostics) }
}
