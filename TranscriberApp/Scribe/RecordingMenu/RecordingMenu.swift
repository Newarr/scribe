import AppKit
import SwiftUI
import TranscriberCore

/// F-6: scribe-design-system custom popover replacing the previous
/// `NSMenu`. The popover anchors to the menu-bar status item and
/// presents one of two layouts based on the live `SessionStatus`:
///
///   - **Idle / last:** header with brand mark + state badge, body
///     with a setup prompt or recent sessions, footer with setup,
///     settings, and record actions.
///   - **Recording:** header with brand mark + state badge, body with
///     the source label, elapsed time, waveform, status copy, and
///     destination strip; footer with settings and stop/finalizing
///     action.
///
/// The previous `NSMenu`-driven API (a `RecordingMenu` exposing
/// `menu: NSMenu` and an `Action` enum) is preserved as the public
/// surface so AppDelegate's call sites don't change. The popover hosts
/// a SwiftUI body backed by `RecordingMenuModel`.
struct PendingPromptRecovery: Equatable {
  let title: String
  let subtitle: String
  let appDisplayName: String
}

struct RecordingMenuQueuedMeeting: Equatable {
  let title: String
  let time: String
}

struct RecordingMenuEndPrompt: Equatable {
  let generation: Int
  let reason: String
  let secondsRemaining: Int
}

@MainActor
final class RecordingMenu: NSObject, NSPopoverDelegate {
  enum Action {
    case record
    case retryFailedSession
    case retryRecentFailedSession(URL)
    case repairRecentFailedSession(URL)
    case stop
    case quit
    case openSettings
    case openSetupRequired
    case openDiagnostics
    case promptStartRecording
    case promptNotNow
    case promptSuppressApp
    case endPromptKeepRecording(generation: Int)
    case endPromptStopNow(generation: Int)
  }

  /// Codex PM-review UX-7 (preserved): "Setup Required…" vs
  /// "Check setup…". AppDelegate flips this; the popover header
  /// now folds it into a single SETUP indicator.
  var setupNeedsAttention: Bool = false {
    didSet { model.setupNeedsAttention = setupNeedsAttention }
  }

  var pendingPrompt: PendingPromptRecovery? {
    didSet { model.pendingPrompt = pendingPrompt }
  }

  var queuedNextMeeting: RecordingMenuQueuedMeeting? {
    didSet { model.queuedNextMeeting = queuedNextMeeting }
  }

  var endPrompt: RecordingMenuEndPrompt? {
    didSet { model.endPrompt = endPrompt }
  }

  /// `outputRoot` powers the recents enumerator. Updated by
  /// AppDelegate before each popover open so the list reflects
  /// any settings change.
  var outputRoot: URL? {
    didSet { model.refreshRecents(under: outputRoot) }
  }

  /// Elapsed seconds since recording started. AppDelegate ticks
  /// this once per second from a `Timer` while in the recording
  /// state so the popover header + capture card show a live timer
  /// instead of a frozen `0:00`. The popover uses
  /// `font: monospaced digit` so per-tick width changes don't
  /// jitter the surface.
  var elapsedSeconds: Int = 0 {
    didSet { model.elapsedSeconds = elapsedSeconds }
  }

  /// Right-side label inside the live indicator on the recording
  /// surface. AppDelegate sets this to the matched calendar event
  /// title (preferred), the detection candidate's display name,
  /// or `Recording` when neither is known.
  var recordingSourceLabel: String = "Recording" {
    didSet { model.recordingSourceLabel = recordingSourceLabel }
  }

  var micLevel: Float = 0 {
    didSet { model.micLevel = micLevel }
  }

  var systemLevel: Float = 0 {
    didSet { model.systemLevel = systemLevel }
  }

  /// Where the saved transcript will land. AppDelegate sets this
  /// when a session starts so the recording surface's outcome
  /// strip can show the user the destination folder name. Nil
  /// hides the strip.
  var outcomeFolderName: String? {
    didSet { model.outcomeFolderName = outcomeFolderName }
  }

  var outcomeFolderURL: URL? {
    didSet { model.outcomeFolderURL = outcomeFolderURL }
  }

  var appearanceTheme: AppearanceTheme = .system {
    didSet { model.appearanceTheme = appearanceTheme }
  }

  /// Session-start engine snapshot for active recording/finalizing UI.
  /// Settings changes after start must not relabel the in-flight session.
  var sessionEngineMode: EngineMode = .cloud {
    didSet { model.sessionEngineMode = sessionEngineMode }
  }

  let popover: NSPopover
  private let onAction: (Action) -> Void
  private let localModelStatusProvider: () async -> LocalModelCacheStatus
  private let model: RecordingMenuModel
  private weak var anchorButton: NSStatusBarButton?
  private var localMouseDownMonitor: Any?
  private var globalMouseDownMonitor: Any?

  init(
    localModelStatusProvider: @escaping () async -> LocalModelCacheStatus = {
      .notDownloaded(modelID: CohereMLXBackend.modelID)
    },
    onAction: @escaping (Action) -> Void
  ) {
    self.localModelStatusProvider = localModelStatusProvider
    self.onAction = onAction
    let model = RecordingMenuModel(status: .idle)
    self.model = model
    let popover = NSPopover()
    self.popover = popover
    super.init()
    model.appearanceTheme = appearanceTheme
    popover.delegate = self
    popover.behavior = .transient
    // Size driven by the SwiftUI body's `.frame(width:)` +
    // `.fixedSize(horizontal: false, vertical: true)`. Leaving
    // `contentSize` unset lets NSPopover read NSHostingController's
    // intrinsic content size; empty state gets ~190pt, full
    // recents list scales up.
    // NSPopover already provides system vibrancy chrome; the
    // SwiftUI body uses `.glassBackground()` (Color.clear + the
    // 1px specular highlight) so the chrome shows through without
    // a manual NSVisualEffectView wrapper. An earlier attempt to
    // call `WindowChrome.wrapInGlass(controller:)` here broke the
    // popover layout because reassigning `NSHostingController.view`
    // disables its intrinsic SwiftUI sizing; the popover would
    // then refuse to present.
    let host = NSHostingController(
      rootView: RecordingPopoverContent(
        model: model,
        onAction: onAction
      ))
    popover.contentViewController = host
    rebuild(for: .idle)
  }

  deinit {
    MainActor.assumeIsolated {
      removeOutsideClickMonitors()
    }
  }

  /// Status update hook (preserves the old API).
  func rebuild(for status: SessionStatus) {
    model.status = status
    applyDebugMenuFixtureIfNeeded()
  }

  /// Presents the popover anchored to `button`. AppDelegate calls
  /// this in response to the status-item button click; the previous
  /// `NSStatusItem.menu` auto-presentation no longer applies.
  func show(from button: NSStatusBarButton) {
    if popover.isShown {
      close()
      return
    }
    // Refresh recents on each open. NSPopover caches the host
    // view so this stays cheap; the enumerator only touches
    // frontmatter, never bodies.
    model.refreshRecents(under: outputRoot)
    refreshRecentActionsReadiness()
    applyDebugMenuFixtureIfNeeded()
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    // Codex UX-4: confidential UI. NSPopover hosts a backing
    // window; opt it out of screen-share captures.
    popover.contentViewController?.view.window?.sharingType = WindowChromeSharing.confidential
    anchorButton = button
    installOutsideClickMonitors()
  }

  func close() {
    popover.performClose(nil)
    removeOutsideClickMonitors()
  }

  nonisolated func popoverDidClose(_ notification: Notification) {
    Task { @MainActor [weak self] in
      self?.removeOutsideClickMonitors()
    }
  }
  private func refreshRecentActionsReadiness() {
    let entries = model.recents
    guard
      entries.contains(where: {
        $0.status == .failed && $0.hasSavedAudio
          && EngineMode(persistedIdentifier: $0.engineIdentifier ?? "") == .local
      })
    else {
      model.localModelReadyForRetry = true
      return
    }
    model.localModelReadyForRetry = nil
    Task { @MainActor [weak self] in
      guard let self else { return }
      let status = await self.localModelStatusProvider()
      self.model.localModelReadyForRetry = status.isReady
    }
  }

  private func installOutsideClickMonitors() {
    removeOutsideClickMonitors()
    let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) {
      [weak self] event in
      MainActor.assumeIsolated {
        self?.closeIfClickIsOutsidePopover(event)
      }
      return event
    }
    globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) {
      [weak self] _ in
      Task { @MainActor [weak self] in
        self?.close()
      }
    }
  }

  private func removeOutsideClickMonitors() {
    if let localMouseDownMonitor {
      NSEvent.removeMonitor(localMouseDownMonitor)
      self.localMouseDownMonitor = nil
    }
    if let globalMouseDownMonitor {
      NSEvent.removeMonitor(globalMouseDownMonitor)
      self.globalMouseDownMonitor = nil
    }
  }

  private func closeIfClickIsOutsidePopover(_ event: NSEvent) {
    guard popover.isShown else {
      removeOutsideClickMonitors()
      return
    }
    if event.window === popover.contentViewController?.view.window {
      return
    }
    if let button = anchorButton,
      event.window === button.window,
      button.bounds.contains(button.convert(event.locationInWindow, from: nil))
    {
      return
    }
    close()
  }

  private func applyDebugMenuFixtureIfNeeded() {
    #if DEBUG
      guard let raw = ProcessInfo.processInfo.environment["SCRIBE_DEBUG_MENU_STATE"]?.lowercased()
      else { return }
      switch raw {
      case "idle":
        model.status = .idle
      case "starting":
        model.status = .starting
        model.elapsedSeconds = 0
        model.recordingSourceLabel = "Recording"
        model.outcomeFolderName = nil
        model.outcomeFolderURL = nil
      case "recording":
        model.status = .recording
        model.elapsedSeconds = max(model.elapsedSeconds, 261)
        model.micLevel = max(model.micLevel, 0.72)
        model.systemLevel = max(model.systemLevel, 0.58)
        model.recordingSourceLabel =
          model.recordingSourceLabel == "Recording"
          ? "Zoom · Design review" : model.recordingSourceLabel
        model.outcomeFolderName = model.outcomeFolderName ?? "2026-05-07 09:41 - Design review"
      case "stopping":
        model.status = .stopping
        model.elapsedSeconds = max(model.elapsedSeconds, 2838)
        model.recordingSourceLabel = "Zoom · Design review"
        model.outcomeFolderName = model.outcomeFolderName ?? "2026-05-07 09:41 - Design review"
      case "finalized", "transcribing":
        model.status = .finalized
        model.elapsedSeconds = max(model.elapsedSeconds, 2838)
        model.recordingSourceLabel = "Zoom · Design review"
        model.outcomeFolderName = model.outcomeFolderName ?? "2026-05-07 09:41 - Design review"
      case "failed":
        model.status = .failed
        model.outcomeFolderURL = model.outcomeFolderURL ?? URL(fileURLWithPath: "/tmp")
      default:
        break
      }
    #endif
  }
}

/// `NSStatusItem.button` requires a plain `@objc` target/action pair;
/// it can't bind directly to a SwiftUI / Swift closure. This shared
/// singleton bridges from `button.action` to whatever `priorityHandler`
/// AppDelegate installs (e.g. raise a buried privacy welcome window
/// before falling through to the popover) and finally to the active
/// `RecordingMenu`'s `show(from:)`.
@MainActor
final class StatusItemClickTarget: NSObject {
  static let shared = StatusItemClickTarget()
  weak var delegate: RecordingMenu?

  /// AppDelegate sets this so a click can raise a pending privacy
  /// welcome window (or any future "modal-ish" surface) before the
  /// popover takes the click. Return `true` to consume the click.
  var priorityHandler: (@MainActor (NSStatusBarButton) -> Bool)?

  /// AppDelegate supplies the right-click system menu (Settings,
  /// transcripts folder, Quit). Built fresh per click so item state
  /// never goes stale.
  var contextMenuProvider: (@MainActor () -> NSMenu)?

  @objc func statusItemClicked(_ sender: Any?) {
    guard let button = sender as? NSStatusBarButton else { return }
    let event = NSApp.currentEvent
    let isRightClick = event?.type == .rightMouseUp || event?.type == .rightMouseDown
      || (event?.modifierFlags.contains(.control) ?? false)
    if isRightClick, let menu = contextMenuProvider?() {
      delegate?.close()
      menu.popUp(
        positioning: nil,
        at: NSPoint(x: 0, y: button.bounds.height + 4),
        in: button)
      return
    }
    if priorityHandler?(button) == true { return }
    delegate?.show(from: button)
  }
}
