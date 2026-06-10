import Carbon.HIToolbox
import TranscriberCore

extension KeyboardShortcutSetting {
  var carbonModifierFlags: UInt32 {
    modifiers.reduce(UInt32(0)) { flags, modifier in
      switch modifier {
      case .command:
        return flags | UInt32(cmdKey)
      case .shift:
        return flags | UInt32(shiftKey)
      case .option:
        return flags | UInt32(optionKey)
      case .control:
        return flags | UInt32(controlKey)
      }
    }
  }

  var displayString: String {
    var parts: [String] = []
    if modifiers.contains(.command) { parts.append("⌘") }
    if modifiers.contains(.shift) { parts.append("⇧") }
    if modifiers.contains(.option) { parts.append("⌥") }
    if modifiers.contains(.control) { parts.append("⌃") }
    parts.append(key.uppercased())
    return parts.joined()
  }
}
