import AppKit
import TranscriberCore

extension AppDelegate {
  /// User-triggered Setup Required popover. Re-runs the audit so the
  /// UI reflects whichever permissions have been fixed since the last
  /// record attempt.
  @MainActor
  func presentSetupRequiredPopover() async {
    let report: PreflightReport
    let payload = sessionRepairPayload
    if let payload {
      report = SessionRepairRouting.setupReport(for: payload)
    } else {
      let snap = settings
      report = await preflightDoctor.audit(outputRoot: snap.outputRoot, engineMode: snap.engineMode)
    }
    // Route permission-only blockers to the polished onboarding
    // window. Session-repair payloads and engine/output blockers
    // stay on the deprecated popover path (it still handles those
    // remediation surfaces; replacement is out of scope for this
    // iteration).
    if payload == nil, Self.allBlockersArePermissions(report) {
      setupPopover?.close()
      permissionsOnboarding?.present()
      return
    }
    showSetupRequiredPopover(report: report, sessionRepairPayload: payload)
  }

  /// True only when every blocker is a permission-related reason.
  /// Used to decide whether the polished onboarding window can fully
  /// cover the remediation surface, or whether we need to fall back
  /// to the popover (engine config, output folder, etc.).
  static func allBlockersArePermissions(_ report: PreflightReport) -> Bool {
    guard !report.blockers.isEmpty else { return false }
    return report.blockers.allSatisfy { isPermissionReason($0) }
  }

  private static func isPermissionReason(_ reason: PreflightReason) -> Bool {
    switch reason {
    case .microphoneDenied, .microphoneNotDetermined,
      .screenRecordingDenied,
      .calendarDeniedOptional, .calendarNotDetermined,
      .notificationsDeniedOptional, .notificationsNotDetermined:
      return true
    case .outputFolderUnwritable, .outputFolderInSyncedStorage,
      .missingCloudAPIKey,
      .localModelNotVerified, .localRuntimeUnavailable:
      return false
    }
  }

  @MainActor
  func showSetupRequiredPopover(
    report: PreflightReport,
    sessionRepairPayload payload: SessionRepairRouting.LocalRepairPayload?
  ) {
    setupEngineFocus = setupRequiredEngineFocus(report: report, sessionRepairPayload: payload)
    let steps = PermissionRemediation.steps(from: report)
    guard let anchor = statusItem?.button, let popover = setupPopover else { return }
    popover.show(
      steps: steps,
      anchor: anchor,
      actions: makePopoverActions()
    ) { [weak self] in
      Task { await self?.presentSetupRequiredPopover() }
    }
  }

  @MainActor
  private func setupRequiredEngineFocus(
    report: PreflightReport,
    sessionRepairPayload payload: SessionRepairRouting.LocalRepairPayload?
  ) -> EngineSettingsCardFocus? {
    SessionRepairRouting.engineSettingsFocus(for: payload)
      ?? report.blockers.compactMap { EngineSettingsNavigation.focus(for: $0) }.first
  }

  /// Builds the inline-action handler set the popover hands to its
  /// step rows. Each handler closes the popover before invoking the
  /// system-prompt API so the macOS sheet appears alone (the popover
  /// would otherwise occlude it on the menu bar anchor); the
  /// auto-recheck observers reopen it with refreshed state once the
  /// user responds.
  @MainActor
  private func makePopoverActions() -> PermissionRecoveryActions {
    PermissionRecoveryActions(
      onRequestMicrophone: { [weak self] in
        guard let self else { return }
        self.setupPopover?.close()
        Task { @MainActor [weak self] in
          guard let self else { return }
          _ = await self.permissions.requestMicrophone()
          await self.presentSetupRequiredPopover()
        }
      },
      onRequestScreenRecording: { [weak self] in
        guard let self else { return }
        self.setupPopover?.close()
        Task { @MainActor [weak self] in
          guard let self else { return }
          // CGRequestScreenCaptureAccess returns whether the
          // current process has access, not whether a prompt
          // was shown. CGPreflightScreenCaptureAccess can
          // disagree: after a fresh grant, the running process
          // may still see denied until relaunch. When that
          // happens, polling is futile — surface a restart
          // alert instead of reopening the popover forever.
          ScreenRecordingRelaunchAssist.arm()
          let requestGrant = await self.permissions.requestScreenRecording()
          let status = await self.permissions.screenRecordingStatus()
          // Grant visible in-process means no relaunch is needed; leaving
          // the assist armed would self-relaunch on a Cmd-Q within 10 min.
          if status == .granted {
            ScreenRecordingRelaunchAssist.disarm()
          }
          if requestGrant, status == .denied {
            self.presentScreenRecordingRestartRequiredAlert()
            return
          }
          if !requestGrant,
            status == .denied,
            let url = URL(
              string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
          {
            NSWorkspace.shared.open(url)
          }
          await self.presentSetupRequiredPopover()
        }
      },
      onRequestCalendar: { [weak self] in
        guard let self else { return }
        self.setupPopover?.close()
        Task { @MainActor [weak self] in
          guard let self else { return }
          _ = await self.permissions.requestCalendar()
          await self.presentSetupRequiredPopover()
        }
      },
      onOpenInAppSettings: { [weak self] in
        guard let self else { return }
        self.setupPopover?.close()
        self.settingsWindowController?.show(focus: self.setupEngineFocus)
      }
    )
  }

  /// Shown when the user has granted screen recording in System Settings
  /// (or this process's TCC bit has flipped to granted) but the running
  /// process's CGPreflightScreenCaptureAccess still reports denied. This
  /// is a macOS quirk: the grant doesn't propagate to a running process
  /// for screen recording — only relaunch picks it up. Loop-prompting
  /// the user is what produced the "popover flashing and can't close"
  /// failure mode.
  @MainActor
  func presentScreenRecordingRestartRequiredAlert() {
    setupPopover?.close()

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Restart Scribe to finish enabling System Audio Recording"
    alert.informativeText =
      "macOS has approved Screen & System Audio Recording in System Settings, but the running Scribe process can't see the new grant until it relaunches."
    alert.addButton(withTitle: "Quit & Reopen Scribe")
    alert.addButton(withTitle: "Later")
    alert.window.sharingType = WindowChromeSharing.confidential  // UX-4

    if alert.runModal() == .alertFirstButtonReturn {
      Self.relaunchAndTerminate()
    }
  }

  /// Spawns a detached `open -n` against our own bundle, then terminates
  /// ourselves. The child launches as a new instance immediately; the
  /// brief two-process overlap is harmless because the new instance's
  /// status item replaces ours after the old one exits.
  ///
  /// `NSApp.terminate(nil)` on its own does NOT relaunch — macOS only
  /// re-spawns crashed apps marked for relaunch, not normal quits. We
  /// need an external spawn so the user doesn't have to manually
  /// reopen Scribe after granting Screen Recording.
  nonisolated static func relaunchAndTerminate() {
    spawnRelaunchProcess()
    DispatchQueue.main.async {
      NSApp.terminate(nil)
    }
  }

  /// Spawned on the quit path when the relaunch assist is armed. A GCD
  /// asyncAfter delay would die with the terminating process before it
  /// fires, so the delay must live in a detached child: `sh` sleeps,
  /// then `open`s the bundle after the parent has fully exited. No `-n`
  /// here — by the time `open` runs the old instance is gone, and if
  /// macOS's own "Quit & Reopen" TCC flow (or the user) already
  /// relaunched Scribe, plain `open` activates that instance instead of
  /// spawning a duplicate.
  nonisolated static func spawnDelayedRelaunch() {
    let task = Process()
    task.launchPath = "/bin/sh"
    // Bundle path rides in as $0 so paths with spaces/quotes survive.
    task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
    do {
      try task.run()
    } catch {
      Log.lifecycle.error(
        "Delayed relaunch spawn failed: \(String(describing: error), privacy: .public). Quitting without relaunch; user must reopen manually."
      )
    }
  }

  nonisolated private static func spawnRelaunchProcess() {
    let task = Process()
    task.launchPath = "/usr/bin/open"
    task.arguments = ["-n", Bundle.main.bundlePath]
    do {
      try task.run()
    } catch {
      Log.lifecycle.error(
        "Relaunch spawn failed: \(String(describing: error), privacy: .public). Quitting without relaunch; user must reopen manually."
      )
    }
  }
}
