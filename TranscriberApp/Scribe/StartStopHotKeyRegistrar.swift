import Carbon.HIToolbox
import TranscriberCore

@MainActor
final class StartStopHotKeyRegistrar {
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?
  private let onFire: @MainActor () -> Void

  init(onFire: @escaping @MainActor () -> Void) {
    self.onFire = onFire
    var eventSpec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      StartStopHotKeyRegistrar.handleEvent,
      1,
      &eventSpec,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandler
    )
  }

  deinit {
    MainActor.assumeIsolated {
      if let hotKeyRef {
        UnregisterEventHotKey(hotKeyRef)
      }
      if let eventHandler {
        RemoveEventHandler(eventHandler)
      }
    }
  }

  func register(_ shortcut: KeyboardShortcutSetting) {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }

    var ref: EventHotKeyRef?
    let identifier = EventHotKeyID(signature: Self.fourCC("Scrb"), id: 1)
    let status = RegisterEventHotKey(
      UInt32(shortcut.keyCode),
      shortcut.carbonModifierFlags,
      identifier,
      GetApplicationEventTarget(),
      0,
      &ref
    )
    if status == noErr {
      hotKeyRef = ref
    }
  }

  private func fire() {
    onFire()
  }

  private static let handleEvent: EventHandlerUPP = { _, _, userData in
    guard let userData else { return noErr }
    let registrar = Unmanaged<StartStopHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in registrar.fire() }
    return noErr
  }

  private static func fourCC(_ string: String) -> OSType {
    var result: OSType = 0
    for scalar in string.unicodeScalars.prefix(4) {
      result = (result << 8) + OSType(scalar.value)
    }
    return result
  }
}
