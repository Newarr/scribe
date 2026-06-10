import AppKit
import TranscriberCore

extension AppDelegate {
  @MainActor
  func installStatusItemIfNeeded() {
    guard statusItem == nil else {
      applyTrustIcon()
      return
    }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let icon = NSImage(named: "MenuBarIcon") {
      icon.isTemplate = true
      icon.accessibilityDescription = "Scribe"
      item.button?.image = icon
      item.button?.imagePosition = .imageOnly
    } else {
      item.button?.title = "S"
    }
    item.button?.target = StatusItemClickTarget.shared
    item.button?.action = #selector(StatusItemClickTarget.statusItemClicked(_:))
    // Status buttons only deliver left clicks by default; without
    // rightMouseUp here the right-click context menu can never fire.
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusItem = item
    menu?.outputRoot = outputRoot
    applyTrustIcon()
  }

  @MainActor
  @objc func statusContextOpenSettings() {
    NSApp.activate(ignoringOtherApps: true)
    settingsWindowController?.show()
  }

  @MainActor
  @objc func statusContextOpenTranscripts() {
    NSWorkspace.shared.open(settings.outputRoot)
  }

  @MainActor
  func setMenuBarVisible(_ visible: Bool) {
    if visible {
      installStatusItemIfNeeded()
    } else if let item = statusItem {
      menu?.close()
      NSStatusBar.system.removeStatusItem(item)
      statusItem = nil
    }
  }

  /// scribe-design-system: full 8-state trust language on the menu
  /// bar. The shape encodes status (`SessionStatus`), setup blockers,
  /// in-flight detection prompts, and recent saved/failed outcomes;
  /// `TrustState.resolve` is the single source of truth. CALayer
  /// animations supply the pulse + spin for the two motion states.
  @MainActor
  func applyTrustIcon() {
    guard let button = statusItem?.button else { return }
    let trust = TrustState.resolve(currentTrustInputs())

    guard let icon = NSImage(named: trust.assetName) else {
      // Defensive: if a new trust state lands without a matching
      // asset the bare mark is the safe fallback.
      button.image = NSImage(named: "MenuBarIcon")
      return
    }
    icon.isTemplate = true
    icon.accessibilityDescription = trust.accessibilityLabel
    button.image = icon

    // Menu-bar animations are intentionally disabled. The previous
    // CABasicAnimation pulse (.detected) + rotation (.finalizing)
    // left the button's CALayer presentation in a stuck/clipped
    // state on transition (visible bug: a small frozen glyph
    // remained at the menu bar after a session finalized). Static
    // icon swaps still communicate the active state. A proper
    // animation system is a deferred design task — see vault note
    // `01-projects/scribe/menu-bar-animations.md`.
    button.wantsLayer = true
    button.layer?.removeAllAnimations()
    button.layer?.transform = CATransform3DIdentity
    button.layer?.opacity = 1.0
  }

  /// Snapshots the inputs `TrustState.resolve` needs. Centralized so
  /// every call site (status flips, flag flips, the saved-flash
  /// timer firing) goes through the same builder.
  @MainActor
  private func currentTrustInputs() -> TrustState.Inputs {
    TrustState.Inputs(
      status: status,
      setupNeedsAttention: setupNeedsAttention,
      detectionPromptActive: detectionPromptActive,
      endPromptActive: activeEndPromptGeneration != nil,
      lastSavedAt: lastSavedAt,
      lastFailureAt: lastFailureAt,
      now: Date(),
      savedFlashDuration: AppDelegate.savedFlashDuration
    )
  }

  /// Records a successful save and starts the 3s saved-flash window.
  /// Called from the stopRecording() success path.
  @MainActor
  func markSavedFlash() {
    lastSavedAt = Date()
    lastFailureAt = nil
    savedFlashTimer?.invalidate()
    savedFlashTimer = Timer.scheduledTimer(
      withTimeInterval: AppDelegate.savedFlashDuration,
      repeats: false
    ) { [weak self] _ in
      Task { @MainActor in self?.applyTrustIcon() }
    }
    applyTrustIcon()
  }

  /// Records a terminal failure. The icon stays in `.failed` until
  /// the next record attempt or recovery flow clears it.
  @MainActor
  func markFailureFlash() {
    lastFailureAt = Date()
    lastSavedAt = nil
    savedFlashTimer?.invalidate()
    applyTrustIcon()
  }

  /// Clears terminal-outcome flags. Called when the user triggers a
  /// new record attempt so a stale `.failed` doesn't survive past the
  /// next session start.
  @MainActor
  func clearTerminalFlash() {
    lastSavedAt = nil
    lastFailureAt = nil
    savedFlashTimer?.invalidate()
    applyTrustIcon()
  }
}
