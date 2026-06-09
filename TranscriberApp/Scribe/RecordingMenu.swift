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
        $0.status == .failed && $0.hasSavedAudio && $0.engineIdentifier?.lowercased() == "cohere"
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

@MainActor
final class RecordingMenuModel: ObservableObject {
  static let recentsLimit = 5

  @Published var status: SessionStatus
  @Published var setupNeedsAttention: Bool = false
  @Published var pendingPrompt: PendingPromptRecovery? = nil
  @Published var queuedNextMeeting: RecordingMenuQueuedMeeting? = nil
  @Published var endPrompt: RecordingMenuEndPrompt? = nil
  @Published var recents: [SessionFolderEnumerator.Entry] = []
  @Published var elapsedSeconds: Int = 0
  @Published var micLevel: Float = 0
  @Published var systemLevel: Float = 0
  /// Right-aligned status text inside the live indicator on the
  /// recording surface. Pattern: `"Zoom · Acme Q3 sync"` when source
  /// and meeting title are both known; falls back to `"Recording"`.
  @Published var recordingSourceLabel: String = "Recording"
  /// Where the saved transcript will land (folder name only, e.g.
  /// `2026-04-30 14:02 - Acme Q3 sync`). Nil hides the outcome
  /// strip below the waveform.
  @Published var outcomeFolderName: String? = nil
  @Published var outcomeFolderURL: URL? = nil
  @Published var appearanceTheme: AppearanceTheme = .system
  @Published var sessionEngineMode: EngineMode = .cloud
  @Published var localModelReadyForRetry: Bool? = nil

  init(status: SessionStatus) {
    self.status = status
  }

  func refreshRecents(under root: URL?) {
    guard let root else {
      recents = []
      return
    }
    recents = SessionFolderEnumerator.recents(under: root, limit: Self.recentsLimit)
  }
}

private struct RecordingPopoverContent: View {
  @ObservedObject var model: RecordingMenuModel
  let onAction: (RecordingMenu.Action) -> Void
  let animatesAppearance: Bool

  private let menuWidth: CGFloat = 420
  @SwiftUI.State private var didAppear: Bool = false
  @Environment(\.colorScheme) private var colorScheme
  private let menuHeadingFont = SwiftUI.Font.custom(DS.sansFamily, size: 16).weight(.semibold)

  init(
    model: RecordingMenuModel,
    animatesAppearance: Bool = true,
    onAction: @escaping (RecordingMenu.Action) -> Void
  ) {
    self.model = model
    self.animatesAppearance = animatesAppearance
    self.onAction = onAction
  }

  var body: some View {
    let resolvedColorScheme = model.appearanceTheme.preferredColorScheme ?? colorScheme
    let palette = RecordingPopoverPalette(colorScheme: resolvedColorScheme)
    VStack(spacing: 0) {
      header(palette: palette)
      Rectangle()
        .fill(palette.dividerLine)
        .frame(height: 1)
      content(palette: palette)
    }
    .frame(width: menuWidth, alignment: .top)
    .frame(minHeight: minimumSurfaceHeight, alignment: .top)
    .fixedSize(horizontal: false, vertical: true)
    .background(PopoverSurfaceBackground(palette: palette))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(palette.outerStroke, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .shadow(color: palette.shadow, radius: palette.shadowRadius, x: 0, y: palette.shadowYOffset)
    .opacity(animatesAppearance ? (didAppear ? 1 : 0) : 1)
    .offset(y: animatesAppearance ? (didAppear ? 0 : -6) : 0)
    .animation(animatesAppearance ? .easeOut(duration: 0.18) : nil, value: didAppear)
    .onAppear {
      if animatesAppearance {
        didAppear = true
      }
    }
    .environment(\.colorScheme, resolvedColorScheme)
    .preferredColorScheme(model.appearanceTheme.preferredColorScheme)
  }

  private var minimumSurfaceHeight: CGFloat? {
    switch model.status {
    case .idle:
      if model.pendingPrompt != nil { return 244 }
      if model.setupNeedsAttention { return 167 }
      return model.recents.isEmpty ? nil : 336
    case .starting:
      return 365
    case .recording:
      if model.endPrompt != nil { return model.queuedNextMeeting == nil ? 440 : 476 }
      return model.queuedNextMeeting == nil ? 356 : 392
    case .stopping:
      return model.queuedNextMeeting == nil ? 386 : 422
    case .finalized:
      return model.queuedNextMeeting == nil ? 340 : 376
    case .failed:
      return 196
    }
  }

  private func header(palette: RecordingPopoverPalette) -> some View {
    HStack(spacing: 6) {
      MenuHeaderMark()
        .fill(palette.text)
        .frame(width: 18, height: 18)
      Text("scribe")
        .font(DS.Font.subheading)
        .foregroundStyle(palette.text)
      Spacer()
      StatusBadge(
        text: headerStatusText,
        color: headerStatusColor(palette: palette)
      )
    }
    .padding(.horizontal, 20)
    .frame(height: 46)
  }

  @ViewBuilder
  private func content(palette: RecordingPopoverPalette) -> some View {
    switch model.status {
    case .recording, .stopping, .starting, .finalized:
      recordingLayout(palette: palette)
    case .failed:
      failedLayout(palette: palette)
    case .idle:
      if model.pendingPrompt != nil {
        pendingPromptLayout(palette: palette)
      } else {
        idleLayout(palette: palette)
      }
    }
  }

  private func pendingPromptLayout(palette: RecordingPopoverPalette) -> some View {
    let prompt = model.pendingPrompt
    return VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Meeting detected")
          .font(menuHeadingFont)
          .foregroundStyle(palette.text)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(prompt?.subtitle ?? "Scribe detected an active call. Choose whether to record.")
          .font(DS.Font.bodySmall)
          .foregroundStyle(palette.secondaryText)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 8) {
        LucideIcon(glyph: .info)
          .frame(width: 12, height: 12)
          .foregroundStyle(palette.warning)
        Text(prompt?.title ?? "Pending meeting")
          .font(DS.Font.monoSmall)
          .foregroundStyle(palette.metaText)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.horizontal, 10)
      .frame(height: 30)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(palette.controlFill)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(palette.controlStroke, lineWidth: 1)
      )
      VStack(alignment: .leading, spacing: 6) {
        DisclosureGroup("More options ▾") {
          Button("Stop detecting \(prompt?.appDisplayName ?? "this app") for 30 minutes") {
            onAction(.promptSuppressApp)
          }
          .buttonStyle(GhostPopoverButtonStyle(palette: palette))
        }
        .font(DS.Font.bodySmall)
        .foregroundStyle(palette.secondaryText)
      }
      HStack(spacing: 8) {
        settingsGear(palette: palette)
        Spacer()
        Button("Not now") { onAction(.promptNotNow) }
          .buttonStyle(SecondaryPopoverButtonStyle(palette: palette))
        Button("Start Recording") { onAction(.promptStartRecording) }
          .keyboardShortcut("r", modifiers: [.command])
          .buttonStyle(PrimaryPopoverButtonStyle(palette: palette))
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 16)
  }

  private func idleLayout(palette: RecordingPopoverPalette) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Text(model.setupNeedsAttention ? "Setup needs attention" : "Ready to record")
          .font(menuHeadingFont)
          .foregroundStyle(palette.text)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(
          model.setupNeedsAttention
            ? "Open setup to finish permissions. The setup window will reopen even if you closed it."
            : "Scribe will prompt for meetings, or you can start now."
        )
        .font(DS.Font.bodySmall)
        .foregroundStyle(palette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if model.setupNeedsAttention {
        HStack(spacing: 8) {
          LucideIcon(glyph: .alertTriangle)
            .frame(width: 13, height: 13)
            .foregroundStyle(palette.warning)
          Text("Microphone, System Audio Recording, Calendar, or Notifications may need attention.")
            .font(DS.Font.monoSmall)
            .foregroundStyle(palette.metaText)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(palette.controlFill)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(palette.controlStroke, lineWidth: 1)
        )
      } else if model.recents.isEmpty {
        EmptyView()
      } else {
        VStack(spacing: 1) {
          ForEach(model.recents, id: \.directory) { entry in
            MenuRow(
              entry: entry,
              onRetry: { sessionURL in
                onAction(.retryRecentFailedSession(sessionURL))
              },
              onRepair: { sessionURL in
                onAction(.repairRecentFailedSession(sessionURL))
              },
              localModelReadyForRetry: model.localModelReadyForRetry
            )
          }
        }
        .padding(6)
        .background(palette.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(palette.controlStroke, lineWidth: 1)
        )
      }
      HStack(spacing: 8) {
        settingsGear(palette: palette)
        Spacer()
        if model.setupNeedsAttention {
          Button("Record now") { onAction(.record) }
            .keyboardShortcut("r", modifiers: [.command])
            .buttonStyle(SecondaryPopoverButtonStyle(palette: palette))
          Button("Open setup") { onAction(.openSetupRequired) }
            .keyboardShortcut("s", modifiers: [.command])
            .buttonStyle(PrimaryPopoverButtonStyle(palette: palette))
        } else {
          Button("Record now") { onAction(.record) }
            .keyboardShortcut("r", modifiers: [.command])
            .buttonStyle(PrimaryPopoverButtonStyle(palette: palette))
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 16)
  }

  private func recordingLayout(palette: RecordingPopoverPalette) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Circle().fill(model.endPrompt == nil ? palette.live : palette.warning).frame(
          width: 8, height: 8)
        Text(model.recordingSourceLabel)
          .font(menuHeadingFont)
          .foregroundStyle(palette.text)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer()
        Text(timeString(model.elapsedSeconds))
          .font(SwiftUI.Font.custom(DS.monoFamily, size: 17).weight(.regular))
          .foregroundStyle(palette.text)
          .monospacedDigit()
      }
      AnimatedWaveform(
        palette: palette,
        isAnimating: shouldAnimateWaveform,
        isActive: shouldAnimateWaveform
      )
      .frame(height: 68)
      .accessibilityHidden(true)
      HStack(alignment: .center, spacing: 10) {
        Text(activeStatusCopy)
          .font(activeStatusFont)
          .foregroundStyle(palette.secondaryText)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        CompactAudioActivity(
          micLevel: model.micLevel,
          systemLevel: model.systemLevel,
          palette: palette
        )
      }
      .accessibilityElement(children: .contain)
      privacyStatusBlock(palette: palette)
      if let endPrompt = model.endPrompt {
        endPromptBlock(endPrompt, palette: palette)
      }
      if let queued = model.queuedNextMeeting {
        HStack(spacing: 8) {
          LucideIcon(glyph: .calendar)
            .frame(width: 12, height: 12)
          Text("Next: '\(queued.title)' at \(queued.time)")
            .font(DS.Font.monoSmall)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .foregroundStyle(palette.metaText)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(palette.controlFill)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(palette.controlStroke, lineWidth: 1)
        )
      }
      HStack(spacing: 8) {
        settingsGear(palette: palette)
        Spacer()
        if let endPrompt = model.endPrompt {
          Button("Stop now") { onAction(.endPromptStopNow(generation: endPrompt.generation)) }
            .buttonStyle(SecondaryPopoverButtonStyle(palette: palette))
          Button("Keep recording") {
            onAction(.endPromptKeepRecording(generation: endPrompt.generation))
          }
          .keyboardShortcut("k", modifiers: [.command])
          .buttonStyle(PrimaryPopoverButtonStyle(palette: palette))
        } else if activeActionIsPrimary {
          Button(activeActionTitle) {
            if !activeActionIsDisabled { onAction(.stop) }
          }
          .keyboardShortcut("s", modifiers: [.command])
          .buttonStyle(
            PrimaryPopoverButtonStyle(palette: palette, textColor: palette.activePrimaryButtonText))
        } else {
          Button(activeActionTitle) {
            if !activeActionIsDisabled { onAction(.stop) }
          }
          .keyboardShortcut("s", modifiers: [.command])
          .buttonStyle(SecondaryPopoverButtonStyle(palette: palette))
          .allowsHitTesting(!activeActionIsDisabled)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 16)
  }

  private func endPromptBlock(_ prompt: RecordingMenuEndPrompt, palette: RecordingPopoverPalette)
    -> some View
  {
    HStack(spacing: 10) {
      Text("\(max(0, prompt.secondsRemaining))")
        .font(SwiftUI.Font.custom(DS.monoFamily, size: 32).weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(palette.warning)
        .frame(width: 48, alignment: .leading)
      VStack(alignment: .leading, spacing: 3) {
        Text("Call seems over")
          .font(SwiftUI.Font.custom(DS.sansFamily, size: 14).weight(.semibold))
          .foregroundStyle(palette.text)
        Text("Scribe will stop unless you keep recording.")
          .font(DS.Font.monoSmall)
          .foregroundStyle(palette.metaText)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer()
    }
    .padding(.horizontal, 10)
    .frame(height: 54)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(palette.controlFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(palette.controlStroke, lineWidth: 1)
    )
    .accessibilityLabel(
      "Stopping soon, \(max(0, prompt.secondsRemaining)) seconds remaining, \(prompt.reason)")
  }

  private func privacyStatusBlock(palette: RecordingPopoverPalette) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Audio: local · \(model.outcomeFolderName ?? "Scribe session")")
      Text("Captured: mic + system audio · no video, no screenshots")
      Text("Engine: \(activeEngineLabel)")
    }
    .font(DS.Font.monoSmall)
    .foregroundStyle(palette.metaText)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(palette.controlFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(palette.controlStroke, lineWidth: 1)
    )
  }

  private var activeEngineLabel: String {
    switch model.sessionEngineMode {
    case .local: return "Cohere (local)"
    case .cloud: return "ElevenLabs (cloud)"
    }
  }

  private var activeStatusCopy: String {
    if let endPrompt = model.endPrompt {
      return "Stopping soon · \(endPrompt.reason). Capture is still live."
    }
    switch (model.status, model.sessionEngineMode) {
    case (.stopping, _):
      return "Saving into \(outputTargetName)"
    case (.finalized, _):
      return "Transcribing into \(outputTargetName)"
    case (_, .local):
      return "Recording into \(outputTargetName) · Cohere stays on this Mac"
    case (_, .cloud):
      return "Recording into \(outputTargetName) · ElevenLabs after stop"
    }
  }

  private var outputTargetName: String {
    guard let folder = model.outcomeFolderName, !folder.isEmpty else {
      return "transcript.md"
    }
    return "\(folder)/transcript.md"
  }

  private var audioCaptureIsActive: Bool {
    channelIsActive(model.micLevel) && channelIsActive(model.systemLevel)
  }

  private var shouldAnimateWaveform: Bool {
    model.status == .recording && audioCaptureIsActive
  }

  private func channelIsActive(_ level: Float) -> Bool {
    level > 0.01
  }

  private var activeStatusFont: SwiftUI.Font {
    if model.endPrompt != nil {
      return DS.Font.body
    }
    switch model.status {
    case .recording, .starting:
      return SwiftUI.Font.custom(DS.sansFamily, size: 13).weight(.regular)
    case .stopping, .finalized, .idle, .failed:
      return DS.Font.body
    }
  }

  private var activeActionTitle: String {
    switch model.status {
    case .stopping:
      return "Stopping…"
    default:
      return "Stop now"
    }
  }

  private var activeActionIsPrimary: Bool {
    switch model.status {
    case .recording, .starting:
      return true
    case .stopping, .finalized, .failed, .idle:
      return false
    }
  }

  private var activeActionIsDisabled: Bool {
    switch model.status {
    case .stopping, .finalized:
      return true
    case .idle, .starting, .recording, .failed:
      return false
    }
  }

  private func settingsGear(palette: RecordingPopoverPalette) -> some View {
    Button {
      onAction(.openSettings)
    } label: {
      LucideIcon(glyph: .settings)
        .frame(width: 16, height: 16)
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
    }
    .buttonStyle(IconButtonStyle(palette: palette))
    .help("Open Settings")
  }

  private func failedLayout(palette: RecordingPopoverPalette) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        LucideIcon(glyph: .alertTriangle)
          .frame(width: 16, height: 16)
          .foregroundStyle(palette.warning)
        Text("Transcription failed")
          .font(menuHeadingFont)
          .foregroundStyle(palette.text)
      }
      Text("Transcription failed, but the recording remains on disk and can be retried.")
        .font(DS.Font.bodySmall)
        .foregroundStyle(palette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 8) {
        settingsGear(palette: palette)
        Spacer()
        Button("Retry") { onAction(.retryFailedSession) }
          .buttonStyle(PrimaryPopoverButtonStyle(palette: palette))
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 16)
  }

  private var headerStatusText: String {
    if let endPrompt = model.endPrompt {
      return "STOPPING \(max(0, endPrompt.secondsRemaining))"
    }
    switch model.status {
    case .recording, .stopping: return "LIVE"
    case .starting: return "STARTING"
    case .finalized: return "TRANSCRIBING"
    case .failed: return "FAILED"
    case .idle:
      if model.pendingPrompt != nil { return "DETECTED" }
      return model.setupNeedsAttention ? "SETUP" : "READY"
    }
  }

  private func headerStatusColor(palette: RecordingPopoverPalette) -> SwiftUI.Color {
    if model.endPrompt != nil {
      return palette.warning
    }
    switch model.status {
    case .recording, .stopping: return palette.live
    case .failed: return palette.warning
    case .idle:
      return (model.pendingPrompt != nil || model.setupNeedsAttention)
        ? palette.warning : palette.ready
    default: return palette.neutralStatus
    }
  }

  private func timeString(_ seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%02d:%02d", m, s)
  }
}

private struct RecordingPopoverPalette {
  let colorScheme: ColorScheme

  var isDark: Bool { colorScheme == .dark }

  var surfaceBase: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 7 / 255, green: 1 / 255, blue: 3 / 255)
      : SwiftUI.Color(red: 245 / 255, green: 247 / 255, blue: 250 / 255)
  }

  var surfaceCoolTint: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 77 / 255, green: 13 / 255, blue: 26 / 255).opacity(0.50)
      : SwiftUI.Color(red: 220 / 255, green: 234 / 255, blue: 251 / 255).opacity(0.50)
  }

  var surfaceWarmTint: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 92 / 255, green: 28 / 255, blue: 18 / 255).opacity(0.40)
      : SwiftUI.Color(red: 255 / 255, green: 224 / 255, blue: 214 / 255).opacity(0.40)
  }

  var controlFill: SwiftUI.Color {
    isDark
      ? SwiftUI.Color.white.opacity(11 / 255)
      : SwiftUI.Color.white.opacity(102 / 255)
  }

  var controlStroke: SwiftUI.Color {
    isDark
      ? SwiftUI.Color.white.opacity(26 / 255)
      : SwiftUI.Color.black.opacity(16 / 255)
  }

  var badgeFill: SwiftUI.Color {
    isDark
      ? SwiftUI.Color.white.opacity(18 / 255)
      : SwiftUI.Color.black.opacity(8 / 255)
  }

  var hoverFill: SwiftUI.Color {
    isDark
      ? SwiftUI.Color.white.opacity(0.055)
      : SwiftUI.Color.black.opacity(0.055)
  }

  var outerStroke: SwiftUI.Color {
    isDark
      ? SwiftUI.Color.white.opacity(26 / 255)
      : SwiftUI.Color.black.opacity(18 / 255)
  }

  var buttonStroke: SwiftUI.Color {
    isDark
      ? SwiftUI.Color.white.opacity(26 / 255)
      : SwiftUI.Color.black.opacity(31 / 255)
  }

  var dividerLine: SwiftUI.Color {
    isDark
      ? SwiftUI.Color.white.opacity(15 / 255)
      : SwiftUI.Color.black.opacity(10 / 255)
  }

  var line: SwiftUI.Color {
    isDark
      ? SwiftUI.Color.white.opacity(24 / 255)
      : SwiftUI.Color.black.opacity(20 / 255)
  }

  var text: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255)
      : SwiftUI.Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)
  }

  var secondaryText: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 184 / 255, green: 184 / 255, blue: 184 / 255)
      : SwiftUI.Color(red: 71 / 255, green: 71 / 255, blue: 71 / 255)
  }

  var tertiaryText: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 122 / 255, green: 122 / 255, blue: 122 / 255)
      : SwiftUI.Color(red: 107 / 255, green: 107 / 255, blue: 107 / 255)
  }

  var metaText: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 122 / 255, green: 122 / 255, blue: 122 / 255)
      : SwiftUI.Color(red: 140 / 255, green: 135 / 255, blue: 129 / 255)
  }

  var badgeText: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 184 / 255, green: 184 / 255, blue: 184 / 255)
      : SwiftUI.Color(red: 117 / 255, green: 111 / 255, blue: 104 / 255)
  }

  var live: SwiftUI.Color { SwiftUI.Color(red: 235 / 255, green: 94 / 255, blue: 69 / 255) }
  var ready: SwiftUI.Color { SwiftUI.Color(red: 89 / 255, green: 196 / 255, blue: 117 / 255) }
  var warning: SwiftUI.Color { SwiftUI.Color(red: 247 / 255, green: 184 / 255, blue: 61 / 255) }
  var neutralStatus: SwiftUI.Color {
    isDark
      ? SwiftUI.Color(red: 122 / 255, green: 122 / 255, blue: 122 / 255)
      : SwiftUI.Color(red: 128 / 255, green: 122 / 255, blue: 117 / 255)
  }
  var shadow: SwiftUI.Color { SwiftUI.Color.black.opacity(isDark ? 89 / 255 : 20 / 255) }
  var shadowRadius: CGFloat { isDark ? 18 : 16 }
  var shadowYOffset: CGFloat { isDark ? 8 : 6 }
  var waveformBar: SwiftUI.Color { isDark ? SwiftUI.Color.white : SwiftUI.Color.black }
  var primaryButtonFill: SwiftUI.Color { text }
  var primaryButtonText: SwiftUI.Color {
    isDark ? SwiftUI.Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255) : SwiftUI.Color.white
  }
  var activePrimaryButtonText: SwiftUI.Color {
    isDark ? SwiftUI.Color(red: 18 / 255, green: 18 / 255, blue: 19 / 255) : SwiftUI.Color.white
  }
}

private struct PopoverSurfaceBackground: View {
  let palette: RecordingPopoverPalette

  var body: some View {
    ZStack {
      palette.surfaceBase
      RadialGradient(
        colors: [palette.surfaceCoolTint, SwiftUI.Color.clear],
        center: UnitPoint(x: 0.75, y: 0.06),
        startRadius: 0,
        endRadius: 440
      )
      RadialGradient(
        colors: [palette.surfaceWarmTint, SwiftUI.Color.clear],
        center: UnitPoint(x: 0.03, y: 0.01),
        startRadius: 0,
        endRadius: 380
      )
    }
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

private struct StatusBadge: View {
  let text: String
  let color: SwiftUI.Color
  var body: some View {
    HStack(spacing: 7) {
      Circle().fill(color).frame(width: 8, height: 8)
      Text(text)
        .font(SwiftUI.Font.custom(DS.monoFamily, size: 13).weight(.medium))
        .tracking(1.5)
        .foregroundStyle(color)
    }
  }
}

struct MenuHeaderMark: Shape {
  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / 18
    let xOffset = rect.midX - 9 * scale
    let yOffset = rect.midY - 9 * scale

    func scaledRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
      CGRect(
        x: xOffset + x * scale,
        y: yOffset + y * scale,
        width: width * scale,
        height: height * scale
      )
    }

    var path = Path()
    let corner = CGSize(width: 0.8 * scale, height: 0.8 * scale)
    path.addRoundedRect(in: scaledRect(x: 3.0, y: 6.0, width: 2.0, height: 6.0), cornerSize: corner)
    path.addRoundedRect(
      in: scaledRect(x: 6.5, y: 3.0, width: 2.0, height: 12.0), cornerSize: corner)
    path.addRoundedRect(
      in: scaledRect(x: 10.0, y: 5.0, width: 2.0, height: 8.0), cornerSize: corner)
    path.addRoundedRect(
      in: scaledRect(x: 13.0, y: 7.0, width: 2.0, height: 4.0), cornerSize: corner)
    return path
  }
}

private struct CompactAudioActivity: View {
  let micLevel: Float
  let systemLevel: Float
  let palette: RecordingPopoverPalette

  var body: some View {
    HStack(spacing: 8) {
      ChannelActivityMark(
        label: "MIC",
        accessibilityLabel: "Microphone level",
        level: micLevel,
        palette: palette
      )
      ChannelActivityMark(
        label: "SYS",
        accessibilityLabel: "System audio level",
        level: systemLevel,
        palette: palette
      )
    }
    .padding(.horizontal, 9)
    .frame(height: 28)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(palette.controlFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(palette.controlStroke, lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
  }
}

private struct ChannelActivityMark: View {
  let label: String
  let accessibilityLabel: String
  let level: Float
  let palette: RecordingPopoverPalette

  private var normalizedLevel: Double {
    min(1, max(0, Double(level)))
  }

  private var isSilent: Bool {
    normalizedLevel <= 0.01
  }

  private var stateText: String {
    isSilent ? "silent" : "active"
  }

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(isSilent ? palette.warning : palette.ready)
        .frame(width: 6, height: 6)
      Text(label)
        .font(SwiftUI.Font.custom(DS.monoFamily, size: 10).weight(.semibold))
        .tracking(1.0)
        .foregroundStyle(isSilent ? palette.warning : palette.metaText)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue("\(stateText), \(Int((normalizedLevel * 100).rounded())) percent")
    .help("\(label) \(stateText)")
  }
}

private struct AnimatedWaveform: View {
  let palette: RecordingPopoverPalette
  let isAnimating: Bool
  let isActive: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let barHeights: [CGFloat] = [
    18, 22, 28, 24, 34, 46, 58, 66, 54, 88,
    108, 78, 68, 76, 56, 38, 34, 38, 54, 46,
    32, 36, 46, 60, 78, 58, 74, 64, 60, 66,
    96, 88, 80, 56, 48, 42, 34, 30, 24, 18,
  ]

  var body: some View {
    if isAnimating && !reduceMotion {
      TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
        bars(time: timeline.date.timeIntervalSinceReferenceDate)
      }
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    } else {
      bars(time: nil)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
  }

  private func bars(time: TimeInterval?) -> some View {
    HStack(alignment: .center, spacing: 3) {
      ForEach(barHeights.indices, id: \.self) { i in
        Capsule()
          .fill(palette.waveformBar.opacity(barOpacity(at: i) * (isActive ? 1 : 0.42)))
          .frame(width: 4, height: barHeight(at: i, time: time))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func barHeight(at index: Int, time: TimeInterval?) -> CGFloat {
    let base = barHeights[index]
    guard let time else { return base }
    let phase = Double(index) * 0.23
    let wave = sin(time * 3.1 + phase)
    let scale = 1.03 + CGFloat(wave) * 0.17
    return min(118, max(10, base * scale))
  }

  private func barOpacity(at index: Int) -> Double {
    let edge = min(index, barHeights.count - 1 - index)
    return edge < 5 ? 0.16 + Double(edge) * 0.10 : 0.68
  }
}

private struct PrimaryPopoverButtonStyle: ButtonStyle {
  let palette: RecordingPopoverPalette
  var textColor: SwiftUI.Color?

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(DS.Font.button)
      .foregroundStyle(textColor ?? palette.primaryButtonText)
      .padding(.horizontal, 15)
      .frame(height: 32)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(
          palette.primaryButtonFill.opacity(configuration.isPressed ? 0.82 : 1)))
  }
}

private struct SecondaryPopoverButtonStyle: ButtonStyle {
  let palette: RecordingPopoverPalette

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(DS.Font.button)
      .foregroundStyle(palette.text)
      .padding(.horizontal, 15)
      .frame(height: 32)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(
          configuration.isPressed ? palette.hoverFill : SwiftUI.Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(
          palette.buttonStroke, lineWidth: 1))
  }
}

private struct GhostPopoverButtonStyle: ButtonStyle {
  let palette: RecordingPopoverPalette

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(DS.Font.button)
      .foregroundStyle(configuration.isPressed ? palette.text : palette.secondaryText)
      .padding(.horizontal, 16)
      .frame(height: 32)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(
          configuration.isPressed ? palette.hoverFill : SwiftUI.Color.clear))
  }
}

private struct IconButtonStyle: ButtonStyle {
  let palette: RecordingPopoverPalette

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(configuration.isPressed ? palette.text : palette.tertiaryText)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(configuration.isPressed ? palette.controlFill : SwiftUI.Color.clear)
      )
  }
}

/// Single row in the recents list. Matches the canonical menu-rows
/// preview: 24x24 mono initial badge, sentence-case title, mono
/// sub-label with separator dots, right-aligned mono duration and
/// relative time. Folder and transcript actions are visible inline.
/// Failed sessions expose inline retry/repair controls so recovery
/// stays visible without relying on Finder or a context menu.
private struct MenuRow: View {
  let entry: SessionFolderEnumerator.Entry
  let onRetry: (URL) -> Void
  let onRepair: (URL) -> Void
  let localModelReadyForRetry: Bool?
  @State private var hovering: Bool = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let palette = RecordingPopoverPalette(colorScheme: colorScheme)
    HStack(alignment: .center, spacing: 10) {
      badge(palette: palette)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title)
          .font(DS.Font.bodySmall)
          .foregroundStyle(palette.text)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(subline)
          .font(DS.Font.monoSmall)
          .tracking(0.1)
          .foregroundStyle(palette.metaText)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Text(relativeTime)
        .font(DS.Font.monoSmall)
        .tracking(0.25)
        .foregroundStyle(palette.metaText)

      recentIconButton(
        glyph: .folder,
        label: "Open Folder",
        palette: palette,
        action: openFolder
      )
      recentIconButton(
        glyph: .fileText,
        label: "Open Transcript",
        palette: palette,
        action: openTranscript
      )

      recentActionButton(palette: palette)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(hovering ? palette.hoverFill : SwiftUI.Color.clear)
    )
    .onHover { hovering = $0 }
  }

  private func recentIconButton(
    glyph: LucideGlyph,
    label: String,
    palette: RecordingPopoverPalette,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      LucideIcon(glyph: glyph)
        .frame(width: 14, height: 14)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(IconButtonStyle(palette: palette))
    .help(label)
    .accessibilityLabel(label)
  }

  @ViewBuilder
  private func recentActionButton(palette: RecordingPopoverPalette) -> some View {
    switch SessionRepairRouting.recentAction(for: entry, localModelReady: localModelReadyForRetry) {
    case .retry(let sessionDirectory):
      Button("Retry") { onRetry(sessionDirectory) }
        .buttonStyle(SecondaryPopoverButtonStyle(palette: palette))
    case .repair(let payload):
      Button("Repair") { onRepair(payload.sessionDirectory) }
        .buttonStyle(SecondaryPopoverButtonStyle(palette: palette))
    case .loading:
      Button("Checking…") {}
        .buttonStyle(SecondaryPopoverButtonStyle(palette: palette))
        .disabled(true)
    case .none:
      EmptyView()
    }
  }

  private func openTranscript() {
    NSWorkspace.shared.open(entry.transcript)
  }

  private func openFolder() {
    NSWorkspace.shared.open(entry.directory)
  }

  /// 24x24 rounded square with a single mono initial: Z for Zoom,
  /// M for Meet, etc. Inferred from the title's first letter (best
  /// effort; opaque enough for the empty / unknown case). Reference:
  /// `.integ-row .mark` is 24x24, 5pt radius, mono 11/600.
  private func badge(palette: RecordingPopoverPalette) -> some View {
    RoundedRectangle(cornerRadius: 5)
      .fill(palette.badgeFill)
      .overlay(
        Text(initial)
          .font(SwiftUI.Font.custom(DS.monoFamily, size: 11).weight(.semibold))
          .tracking(0.1)
          .foregroundStyle(palette.badgeText)
      )
      .frame(width: 24, height: 24)
  }

  private var initial: String {
    let trimmed = entry.title.trimmingCharacters(in: .whitespaces)
    return String(trimmed.first.map { Character($0.uppercased()) } ?? "S")
  }

  /// Mono sub-label with separator dots: status and duration if
  /// known. The design preview uses this slot for "zoom · 3
  /// speakers" but we don't capture per-meeting speaker counts yet,
  /// so stick to status for now.
  private var subline: String {
    switch entry.status {
    case .complete: return "saved"
    case .pending: return "pending"
    case .retrying: return "retrying"
    case .failed: return entry.hasSavedAudio ? "failed · audio saved" : "failed · repair needed"
    }
  }

  private var relativeTime: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return
      formatter
      .localizedString(for: entry.createdAt, relativeTo: Date())
      .replacingOccurrences(of: ".", with: "")
      .uppercased()
  }
}

#if DEBUG
  @MainActor
  enum RecordingMenuVisualSnapshotRenderer {
    static func renderAll(to directory: URL) throws {
      let recentsRoot = try makeRecentsRoot()
      let recents = SessionFolderEnumerator.recents(
        under: recentsRoot, limit: RecordingMenuModel.recentsLimit)
      let cases: [(name: String, theme: AppearanceTheme, model: RecordingMenuModel)] = [
        ("menu-setup-light", .light, idleModel(setupNeedsAttention: true, recents: [])),
        ("menu-ready-light", .light, idleModel(setupNeedsAttention: false, recents: recents)),
        (
          "menu-recording-light", .light,
          activeModel(status: .recording, elapsed: 261, source: "Zoom · Design review")
        ),
        (
          "menu-starting-light", .light,
          activeModel(status: .starting, elapsed: 0, source: "Recording", folderName: nil)
        ),
        (
          "menu-stopping-light", .light,
          activeModel(status: .stopping, elapsed: 2838, source: "Zoom · Design review")
        ),
        (
          "menu-finalized-light", .light,
          activeModel(status: .finalized, elapsed: 2838, source: "Zoom · Design review")
        ),
        ("menu-failed-light", .light, failedModel()),
        ("menu-setup-dark", .dark, idleModel(setupNeedsAttention: true, recents: [])),
        ("menu-ready-dark", .dark, idleModel(setupNeedsAttention: false, recents: recents)),
        (
          "menu-recording-dark", .dark,
          activeModel(status: .recording, elapsed: 261, source: "Zoom · Design review")
        ),
        (
          "menu-starting-dark", .dark,
          activeModel(status: .starting, elapsed: 0, source: "Recording", folderName: nil)
        ),
        (
          "menu-stopping-dark", .dark,
          activeModel(status: .stopping, elapsed: 2838, source: "Zoom · Design review")
        ),
        (
          "menu-finalized-dark", .dark,
          activeModel(status: .finalized, elapsed: 2838, source: "Zoom · Design review")
        ),
        ("menu-failed-dark", .dark, failedModel()),
      ]

      for item in cases {
        item.model.appearanceTheme = item.theme
        let view = RecordingPopoverContent(
          model: item.model,
          animatesAppearance: false,
          onAction: { _ in }
        )
        .padding(20)
        .background(Color.black)
        try DebugVisualSnapshotWriter.write(view, named: item.name, to: directory)
      }
    }

    private static func idleModel(
      setupNeedsAttention: Bool,
      recents: [SessionFolderEnumerator.Entry]
    ) -> RecordingMenuModel {
      let model = RecordingMenuModel(status: .idle)
      model.setupNeedsAttention = setupNeedsAttention
      model.recents = recents
      return model
    }

    private static func activeModel(
      status: SessionStatus,
      elapsed: Int,
      source: String,
      folderName: String? = "2026-05-07 09:41 - Design review"
    ) -> RecordingMenuModel {
      let model = RecordingMenuModel(status: status)
      model.recordingSourceLabel = source
      model.elapsedSeconds = elapsed
      model.sessionEngineMode = .cloud
      model.micLevel = 0.72
      model.systemLevel = 0.58
      model.outcomeFolderName = folderName
      if let folderName {
        model.outcomeFolderURL = URL(fileURLWithPath: "/tmp/\(folderName)", isDirectory: true)
      }
      return model
    }

    private static func failedModel() -> RecordingMenuModel {
      let model = RecordingMenuModel(status: .failed)
      model.outcomeFolderName = "2026-05-07 09:41 - Design review"
      model.outcomeFolderURL = URL(
        fileURLWithPath: "/tmp/2026-05-07 09:41 - Design review", isDirectory: true)
      return model
    }

    private static func makeRecentsRoot() throws -> URL {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("scribe-menu-visual-recents", isDirectory: true)
      try? FileManager.default.removeItem(at: root)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let now = Date()
      try writeSession(
        root: root,
        directoryName: "2026-05-11 09:00 - Acme Q3 sync",
        title: "Acme Q3 sync",
        modified: now.addingTimeInterval(-2 * 60 * 60)
      )
      try writeSession(
        root: root,
        directoryName: "2026-05-10 14:00 - Design review",
        title: "Design review",
        modified: now.addingTimeInterval(-24 * 60 * 60)
      )
      try writeSession(
        root: root,
        directoryName: "2026-05-08 10:30 - Karen 1:1",
        title: "Karen 1:1",
        modified: now.addingTimeInterval(-3 * 24 * 60 * 60)
      )
      return root
    }

    private static func writeSession(
      root: URL,
      directoryName: String,
      title: String,
      modified: Date
    ) throws {
      let directory = root.appendingPathComponent(directoryName, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let transcript = directory.appendingPathComponent("transcript.md")
      let body = """
        ---
        status: complete
        title: "\(title)"
        engine: elevenlabs
        ---

        body
        """
      try body.write(to: transcript, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.modificationDate: modified], ofItemAtPath: directory.path)
    }
  }
#endif

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

  @objc func statusItemClicked(_ sender: Any?) {
    guard let button = sender as? NSStatusBarButton else { return }
    if priorityHandler?(button) == true { return }
    delegate?.show(from: button)
  }
}
