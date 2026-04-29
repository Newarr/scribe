import AppKit
import TranscriberCore

@MainActor
final class RecordingMenu {
    enum Action {
        case record, stop, quit
    }

    private(set) var menu = NSMenu()
    private let onAction: (Action) -> Void

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
            let item = NSMenuItem(title: "Record Now", action: #selector(MenuTarget.record(_:)), keyEquivalent: "r")
            item.target = MenuTarget.shared
            MenuTarget.shared.delegate = self
            menu.addItem(item)
        case .recording:
            let item = NSMenuItem(title: "Stop", action: #selector(MenuTarget.stop(_:)), keyEquivalent: "s")
            item.target = MenuTarget.shared
            MenuTarget.shared.delegate = self
            menu.addItem(item)
        case .starting, .stopping:
            menu.addItem(NSMenuItem(title: status == .starting ? "Starting…" : "Stopping…", action: nil, keyEquivalent: ""))
        }

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
}
