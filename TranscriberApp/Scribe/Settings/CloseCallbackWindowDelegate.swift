import AppKit

/// Shared NSWindowDelegate for window controllers that need close-button
/// hooks: `shouldClose` gates the title-bar close (defaults to allow),
/// `onClose` fires after the window closes so the owning controller can
/// drop its window reference. Used by the Settings window, the
/// Permissions onboarding window, and the Diagnostics window.
///
/// Lives in Settings/ (not DesignSystem/) so the settings source-guard
/// tests keep `windowShouldClose` anchored to real code.
final class CloseCallbackWindowDelegate: NSObject, NSWindowDelegate, @unchecked Sendable {
  private let shouldClose: @MainActor () -> Bool
  private let onClose: @MainActor () -> Void

  init(
    shouldClose: @escaping @MainActor () -> Bool = { true },
    onClose: @escaping @MainActor () -> Void
  ) {
    self.shouldClose = shouldClose
    self.onClose = onClose
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    shouldClose()
  }

  func windowWillClose(_ notification: Notification) {
    Task { @MainActor in onClose() }
  }
}
