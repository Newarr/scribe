import AppKit
import SwiftUI
import TranscriberCore

/// Phase η Settings window. Hosts a SwiftUI form bound to a snapshot of
/// `SessionSettings`; Save commits the snapshot back through
/// `SettingsStore.commit(_:)` (atomic multi-key write per Phase ζ P1.4).
@MainActor
final class SettingsWindowController {
  private let store: SettingsStore
  private let fallback: SettingsStore.Defaults
  private let keychainService: String
  private let keychainAccount: String
  private let engineReadiness: EngineReadinessProbing
  private let onRetryLocalModel: @MainActor () async -> LocalModelCacheStatus
  private let onClearLocalModelCache: @MainActor () async throws -> Void
  private let onShowInMenuBarChange: @MainActor (Bool) -> Void
  private let onShortcutChange: @MainActor (KeyboardShortcutSetting) -> Void
  private let onAppearanceThemeChange: @MainActor (AppearanceTheme) -> Void
  private var window: NSWindow?

  init(
    store: SettingsStore,
    fallback: SettingsStore.Defaults,
    keychainService: String,
    keychainAccount: String,
    engineReadiness: EngineReadinessProbing,
    onRetryLocalModel: @escaping @MainActor () async -> LocalModelCacheStatus = {
      .notDownloaded(modelID: CohereMLXBackend.modelID)
    },
    onClearLocalModelCache: @escaping @MainActor () async throws -> Void = {},
    onShowInMenuBarChange: @escaping @MainActor (Bool) -> Void = { _ in },
    onShortcutChange: @escaping @MainActor (KeyboardShortcutSetting) -> Void = { _ in },
    onAppearanceThemeChange: @escaping @MainActor (AppearanceTheme) -> Void = { _ in }
  ) {
    self.store = store
    self.fallback = fallback
    self.keychainService = keychainService
    self.keychainAccount = keychainAccount
    self.engineReadiness = engineReadiness
    self.onRetryLocalModel = onRetryLocalModel
    self.onClearLocalModelCache = onClearLocalModelCache
    self.onShowInMenuBarChange = onShowInMenuBarChange
    self.onShortcutChange = onShortcutChange
    self.onAppearanceThemeChange = onAppearanceThemeChange
  }

  func show(focus: EngineSettingsCardFocus? = nil) {
    if let window = self.window {
      if let focus {
        NotificationCenter.default.post(name: .settingsEngineFocusRequested, object: focus.rawValue)
      }
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let initial = SettingsSnapshotReader.read(fallback: fallback)
    let model = SettingsFormModel(
      initial: initial,
      keychainService: keychainService,
      keychainAccount: keychainAccount,
      engineReadiness: engineReadiness,
      onRetryLocalModel: onRetryLocalModel,
      onClearLocalModelCache: onClearLocalModelCache
    )

    let host = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    host.title = "Scribe Settings"
    host.titleVisibility = .hidden
    host.titlebarAppearsTransparent = true
    host.minSize = NSSize(width: 880, height: 600)
    host.maxSize = NSSize(width: 880, height: 600)
    host.center()
    host.isOpaque = false
    host.backgroundColor = .clear
    host.isMovableByWindowBackground = true
    host.isReleasedWhenClosed = false
    // Codex PM-review UX-4: confidential UI.
    host.sharingType = WindowChromeSharing.confidential
    host.contentView = NSHostingView(
      rootView: SettingsForm(
        model: model,
        onAppearanceThemeChange: { [weak self] theme in
          AppearanceApplier.apply(theme)
          self?.onAppearanceThemeChange(theme)
          Task { await self?.store.setAppearanceTheme(theme) }
        },
        onLaunchAtLoginChange: { [weak self] enabled in
          do {
            try LaunchAtLoginController.setEnabled(enabled)
            Task { await self?.store.setLaunchAtLogin(enabled) }
            model.saveError = nil
          } catch {
            model.launchAtLogin = !enabled
            model.saveError = "Failed to update launch at login: \(error.localizedDescription)"
          }
        },
        onShowInMenuBarChange: { [weak self] visible in
          self?.onShowInMenuBarChange(visible)
          Task { await self?.store.setShowInMenuBar(visible) }
          model.saveError = nil
        },
        onShortcutChange: { [weak self] shortcut in
          self?.onShortcutChange(shortcut)
          Task { await self?.store.setStartStopShortcut(shortcut) }
        },
        onSettingsChange: { [weak self] settings in
          do {
            try await self?.store.commit(settings)
          } catch {
            model.saveError = "Failed to save settings: \(error.localizedDescription)"
          }
        },
        onSave: { [weak self, weak host] settings in
          guard let self else { return }
          // Keychain persistence must complete before settings commit,
          // readiness refresh, or closing. If Keychain fails, the
          // window stays open with a non-secret error and Cloud
          // readiness is not marked ready from the typed value.
          guard await model.persistAPIKeyIfChanged() else { return }
          do {
            try await self.store.commit(settings)
            await model.refreshEngineViewState()
            host?.close()
            self.window = nil
          } catch {
            model.saveError = "Failed to save settings: \(error.localizedDescription)"
          }
        },
        onCancel: { [weak self, weak host] in
          guard model.canCloseOrSurfaceUnsavedCloudKeyWarning() else { return }
          host?.close()
          self?.window = nil
        },
        initialEngineFocus: focus
      ))

    // Codex Phase η P1.3: a title-bar close should behave like
    // Cancel (drop the in-flight model + clear the window pointer
    // so the next open re-reads the on-disk snapshot fresh).
    let delegate = SettingsWindowDelegate(
      shouldClose: {
        model.canCloseOrSurfaceUnsavedCloudKeyWarning()
      },
      onClose: { [weak self] in
        self?.window = nil
      }
    )
    host.delegate = delegate
    objc_setAssociatedObject(
      host, &settingsWindowDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

    WindowChrome.installGlass(on: host, material: .hudWindow)
    SettingsWindowChrome.makeCornersTransparent(on: host)

    self.window = host
    host.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func close() {
    window?.close()
    window = nil
  }
}

/// Codex Phase η P1.3: NSWindowDelegate that fires when the title-bar
/// close button is hit. The closure resets the controller's window
/// pointer so a fresh `show()` re-loads the on-disk snapshot rather
/// than re-presenting the stale form.
private final class SettingsWindowDelegate: NSObject, NSWindowDelegate, @unchecked Sendable {
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

/// Associated-object key for retaining the SettingsWindowDelegate
/// alongside the host window without adding a stored property to
/// SettingsWindowController (which is constructed lazily).
nonisolated(unsafe) private var settingsWindowDelegateKey: UInt8 = 0

@MainActor
private enum SettingsWindowChrome {
  static let cornerRadius: CGFloat = 14

  static func makeCornersTransparent(on window: NSWindow) {
    window.isOpaque = false
    window.backgroundColor = .clear

    guard let contentView = window.contentView else { return }
    contentView.wantsLayer = true
    contentView.layer?.backgroundColor = NSColor.clear.cgColor
    contentView.layer?.cornerRadius = cornerRadius
    contentView.layer?.cornerCurve = .continuous
    contentView.layer?.masksToBounds = true
  }
}
