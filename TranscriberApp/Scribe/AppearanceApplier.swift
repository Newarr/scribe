import AppKit
import TranscriberCore

@MainActor
enum AppearanceApplier {
  static func apply(_ theme: AppearanceTheme) {
    NSApp.appearance = theme.nsAppearance
  }
}
