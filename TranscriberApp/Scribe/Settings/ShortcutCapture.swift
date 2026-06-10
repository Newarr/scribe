import AppKit
import TranscriberCore

@MainActor
enum ShortcutCapturePanel {
  static func present(
    current: KeyboardShortcutSetting,
    onCapture: @escaping @MainActor (KeyboardShortcutSetting) -> Void
  ) {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
      styleMask: [.titled, .closable, .utilityWindow],
      backing: .buffered,
      defer: false
    )
    panel.title = "Change Shortcut"
    panel.isReleasedWhenClosed = false
    panel.sharingType = WindowChromeSharing.confidential

    let view = ShortcutCaptureView(
      frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 360, height: 150))
    view.current = current
    view.onCancel = { panel.close() }
    view.onCapture = { shortcut in
      onCapture(shortcut)
      panel.close()
    }
    panel.contentView = view
    panel.center()
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    panel.makeFirstResponder(view)
  }
}

@MainActor
private final class ShortcutCaptureView: NSView {
  var current: KeyboardShortcutSetting = .defaultStartStop {
    didSet { currentLabel.stringValue = "Current: \(current.displayString)" }
  }
  var onCapture: (@MainActor (KeyboardShortcutSetting) -> Void)?
  var onCancel: (@MainActor () -> Void)?

  private let titleLabel = NSTextField(labelWithString: "Press the new start / stop shortcut")
  private let currentLabel = NSTextField(labelWithString: "")
  private let hintLabel = NSTextField(
    labelWithString: "Use Command, Shift, Option, or Control with a letter or number. Esc cancels.")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    [titleLabel, currentLabel, hintLabel].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      $0.alignment = .center
      addSubview($0)
    }
    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    currentLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    hintLabel.font = .systemFont(ofSize: 11)
    hintLabel.textColor = .secondaryLabelColor
    currentLabel.stringValue = "Current: \(current.displayString)"

    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 28),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
      currentLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
      currentLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
      currentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
      hintLabel.topAnchor.constraint(equalTo: currentLabel.bottomAnchor, constant: 18),
      hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
      hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      onCancel?()
      return
    }
    guard let key = event.charactersIgnoringModifiers?.uppercased(), key.count == 1 else {
      NSSound.beep()
      return
    }
    let modifiers = event.shortcutModifiers
    guard !modifiers.isEmpty else {
      NSSound.beep()
      return
    }
    onCapture?(KeyboardShortcutSetting(key: key, keyCode: event.keyCode, modifiers: modifiers))
  }
}

extension NSEvent {
  fileprivate var shortcutModifiers: [ShortcutModifier] {
    var result: [ShortcutModifier] = []
    if modifierFlags.contains(.command) { result.append(.command) }
    if modifierFlags.contains(.shift) { result.append(.shift) }
    if modifierFlags.contains(.option) { result.append(.option) }
    if modifierFlags.contains(.control) { result.append(.control) }
    return result
  }
}
