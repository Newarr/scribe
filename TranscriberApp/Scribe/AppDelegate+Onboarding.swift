import TranscriberCore
import UserNotifications

extension AppDelegate {
  /// Spec line 348: first-launch privacy modal. Shown only when
  /// `privacyAcknowledged == false`; recording AND supervisor
  /// recovery stay gated until the user dismisses the sheet.
  @MainActor
  func presentPrivacyAcknowledgementIfNeeded() {
    guard !settings.privacyAcknowledged else { return }
    let flowController = OnboardingFlowController(
      downloadStarter: CompositeLocalModelDownloadStarter(
        primary: localModelManager,
        auxiliaries: [sileroVADModelManager, languageIDModelManager]
      ))
    self.onboardingFlowController = flowController
    let controller = OnboardingWindowController(
      flowController: flowController,
      snapshotProvider: { [weak self] in
        guard let self else { return await Self.emptyOnboardingSnapshot() }
        return await self.makeOnboardingResumeSnapshot()
      },
      cloudKeyAvailable: { [weak self] in
        guard let self else { return false }
        let keychain = KeychainStore(service: Self.keychainService, account: Self.keychainAccount)
        return Self.probeCloudKey(keychain: keychain) == .configured
      },
      saveCloudAPIKey: { [weak self] candidate in
        guard self != nil else { return false }
        let keychain = KeychainStore(
          service: Self.keychainService,
          account: Self.keychainAccount
        )
        do {
          try keychain.write(candidate)
          return true
        } catch {
          return false
        }
      },
      requestMicrophone: { [weak self] in
        guard let self else { return .notDetermined }
        _ = await self.permissions.requestMicrophone()
        return self.permissions.microphoneStatus()
      },
      requestCalendar: { [weak self] in
        guard let self else { return .notDetermined }
        _ = await self.permissions.requestCalendar()
        return await DefaultPermissionStatusProbe(permissions: self.permissions).calendar()
      },
      requestNotifications: {
        do {
          let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [
            .alert, .sound,
          ])
          return granted ? .granted : .denied
        } catch {
          return .denied
        }
      },
      requestScreenRecording: { [weak self] in
        guard let self else {
          return OnboardingScreenRecordingRequestResult(
            requestGranted: false, status: .notDetermined)
        }
        ScreenRecordingRelaunchAssist.arm()
        let requestGranted = await self.permissions.requestScreenRecording()
        let status = await self.permissions.screenRecordingStatus()
        // Grant visible in-process means no relaunch is needed; leaving
        // the assist armed would self-relaunch on a Cmd-Q within 10 min.
        if status == .granted {
          ScreenRecordingRelaunchAssist.disarm()
        }
        return OnboardingScreenRecordingRequestResult(
          requestGranted: requestGranted, status: status)
      },
      selectEngine: { [weak self] engine in
        guard let self else { return }
        await self.settingsStore.setEngineModeIfReady(
          engine, readiness: self.engineReadinessProbe())
      },
      saveOutputFolder: { [weak self] url in
        guard let self else { return }
        await self.settingsStore.setOutputRoot(url)
      },
      runTestRecording: { [weak self] in
        guard let self else { return false }
        return await self.runOnboardingTestRecording()
      },
      onAcknowledged: { [weak self] in
        guard let self else { return }
        Task {
          await self.settingsStore.setPrivacyAcknowledged(true)
          Log.lifecycle.info("Onboarding completed; releasing deferred supervisor scan")
          await MainActor.run {
            self.scheduleSupervisorRecovery()
          }
        }
        self.privacyController = nil
        self.onboardingController = nil
        self.onboardingFlowController = nil
      }
    )
    self.privacyController = controller
    self.onboardingController = controller
    controller.present()
  }

  private static func emptyOnboardingSnapshot() async -> OnboardingResumeSnapshot {
    OnboardingResumeSnapshot(
      microphone: .notDetermined,
      calendar: .notDetermined,
      notifications: .notDetermined,
      screenRecording: .notDetermined,
      cloudKeyAvailable: false,
      localModelStatus: .notDownloaded(modelID: CohereMLXBackend.modelID),
      selectedEngine: .cloud,
      outputFolderReady: false,
      testRecordingComplete: false
    )
  }

  @MainActor
  private func makeOnboardingResumeSnapshot() async -> OnboardingResumeSnapshot {
    let snap = settings
    let permissionProbe = DefaultPermissionStatusProbe(permissions: permissions)
    let keychain = KeychainStore(service: Self.keychainService, account: Self.keychainAccount)
    // The probes are independent; run them concurrently so the resume
    // snapshot costs max(probe latency), not the sum (the model status
    // probe alone can dominate).
    async let microphone = permissionProbe.microphone()
    async let calendar = permissionProbe.calendar()
    async let notifications = permissionProbe.notifications()
    async let screenRecording = permissionProbe.screenRecording()
    async let localModelStatus = localModelManager.status()
    async let outputFolderReady = DefaultOutputFolderProbe().isWritable(snap.outputRoot)
    return OnboardingResumeSnapshot(
      microphone: await microphone,
      calendar: await calendar,
      notifications: await notifications,
      screenRecording: await screenRecording,
      cloudKeyAvailable: Self.probeCloudKey(keychain: keychain) == .configured,
      localModelStatus: await localModelStatus,
      selectedEngine: snap.engineMode,
      outputFolderReady: await outputFolderReady,
      testRecordingComplete: false
    )
  }

  @MainActor
  private func runOnboardingTestRecording() async -> Bool {
    let route = OnboardingTestRecordingRoute(
      snapshot: { [weak self] in
        guard let self else { return await Self.emptyOnboardingSnapshot() }
        return await self.makeOnboardingResumeSnapshot()
      },
      starter: AppOnboardingTestRecordingStarter(start: {
        [weak self] allowPendingPrivacyAcknowledgementForOnboardingTest in
        guard let self else { return false }
        // Source-guard marker: await self.startRecording(allowPendingPrivacyAcknowledgementForOnboardingTest: allowPendingPrivacyAcknowledgementForOnboardingTest)
        await self.startRecording(
          allowPendingPrivacyAcknowledgementForOnboardingTest:
            allowPendingPrivacyAcknowledgementForOnboardingTest)
        guard self.status == .recording else { return false }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await self.stopRecording()
        return true
      })
    )
    return await route.run()
  }
}

private struct AppOnboardingTestRecordingStarter: OnboardingRecordingRouteStarting {
  let start: @MainActor @Sendable (Bool) async -> Bool

  func startRecording(allowPendingPrivacyAcknowledgementForOnboardingTest: Bool) async -> Bool {
    await start(allowPendingPrivacyAcknowledgementForOnboardingTest)
  }
}
