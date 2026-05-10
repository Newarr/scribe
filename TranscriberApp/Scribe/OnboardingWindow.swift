import AppKit
import SwiftUI
import TranscriberCore

@MainActor
final class OnboardingWindowController: PrivacyAcknowledgementController {
    typealias SnapshotProvider = @MainActor () async -> OnboardingResumeSnapshot

    private var window: NSWindow?
    private let flowController: OnboardingFlowController
    private let snapshotProvider: SnapshotProvider
    private let cloudKeyAvailable: @MainActor () async -> Bool
    private let requestMicrophone: @MainActor () async -> PermissionStatus
    private let requestCalendar: @MainActor () async -> PermissionStatus
    private let requestNotifications: @MainActor () async -> PermissionStatus
    private let requestScreenRecording: @MainActor () async -> PermissionStatus
    private let selectEngine: @MainActor (EngineMode) async -> Void
    private let saveOutputFolder: @MainActor (URL) async -> Void
    private let runTestRecording: @MainActor () async -> Bool
    private let onAcknowledged: @MainActor () -> Void

    init(
        flowController: OnboardingFlowController,
        snapshotProvider: @escaping SnapshotProvider,
        cloudKeyAvailable: @escaping @MainActor () async -> Bool,
        requestMicrophone: @escaping @MainActor () async -> PermissionStatus,
        requestCalendar: @escaping @MainActor () async -> PermissionStatus,
        requestNotifications: @escaping @MainActor () async -> PermissionStatus,
        requestScreenRecording: @escaping @MainActor () async -> PermissionStatus,
        selectEngine: @escaping @MainActor (EngineMode) async -> Void,
        saveOutputFolder: @escaping @MainActor (URL) async -> Void,
        runTestRecording: @escaping @MainActor () async -> Bool,
        onAcknowledged: @escaping @MainActor () -> Void
    ) {
        self.flowController = flowController
        self.snapshotProvider = snapshotProvider
        self.cloudKeyAvailable = cloudKeyAvailable
        self.requestMicrophone = requestMicrophone
        self.requestCalendar = requestCalendar
        self.requestNotifications = requestNotifications
        self.requestScreenRecording = requestScreenRecording
        self.selectEngine = selectEngine
        self.saveOutputFolder = saveOutputFolder
        self.runTestRecording = runTestRecording
        self.onAcknowledged = onAcknowledged
        super.init(onAcknowledged: onAcknowledged)
    }

    override var isPending: Bool { window != nil }

    override func bringFront() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    override func present() {
        let viewModel = OnboardingWindowViewModel(
            flowController: flowController,
            snapshotProvider: snapshotProvider,
            cloudKeyAvailable: cloudKeyAvailable,
            requestMicrophone: requestMicrophone,
            requestCalendar: requestCalendar,
            requestNotifications: requestNotifications,
            requestScreenRecording: requestScreenRecording,
            selectEngine: selectEngine,
            saveOutputFolder: saveOutputFolder,
            runTestRecording: runTestRecording,
            onFinished: { [weak self] in
                guard let self else { return }
                self.window?.close()
                self.window = nil
                self.onAcknowledged()
            }
        )
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        host.title = "Welcome to Scribe"
        host.center()
        host.isReleasedWhenClosed = false
        host.sharingType = WindowChromeSharing.confidential
        host.contentView = NSHostingView(rootView: OnboardingWindowView(model: viewModel))
        WindowChrome.installGlass(on: host, material: .hudWindow)
        host.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = host
        Task { await viewModel.load() }
    }
}

@MainActor
private final class OnboardingWindowViewModel: ObservableObject {
    @Published var step: OnboardingFlowStep = .welcome
    @Published var chooseEngineState = OnboardingFlowPresenter.chooseEngineState(cloudKeyAvailable: false, localModelStatus: .notDownloaded(modelID: CohereMLXBackend.modelID))
    @Published var testRecordingState = OnboardingTestRecordingState(isEnabled: false, waitingCopy: nil)
    @Published var permissionResult: PermissionStatus?
    @Published var isBusy = false

    private let flowController: OnboardingFlowController
    private let snapshotProvider: OnboardingWindowController.SnapshotProvider
    private let cloudKeyAvailable: @MainActor () async -> Bool
    private let requestMicrophone: @MainActor () async -> PermissionStatus
    private let requestCalendar: @MainActor () async -> PermissionStatus
    private let requestNotifications: @MainActor () async -> PermissionStatus
    private let requestScreenRecording: @MainActor () async -> PermissionStatus
    private let selectEngine: @MainActor (EngineMode) async -> Void
    private let saveOutputFolder: @MainActor (URL) async -> Void
    private let runTestRecording: @MainActor () async -> Bool
    private let onFinished: @MainActor () -> Void

    init(
        flowController: OnboardingFlowController,
        snapshotProvider: @escaping OnboardingWindowController.SnapshotProvider,
        cloudKeyAvailable: @escaping @MainActor () async -> Bool,
        requestMicrophone: @escaping @MainActor () async -> PermissionStatus,
        requestCalendar: @escaping @MainActor () async -> PermissionStatus,
        requestNotifications: @escaping @MainActor () async -> PermissionStatus,
        requestScreenRecording: @escaping @MainActor () async -> PermissionStatus,
        selectEngine: @escaping @MainActor (EngineMode) async -> Void,
        saveOutputFolder: @escaping @MainActor (URL) async -> Void,
        runTestRecording: @escaping @MainActor () async -> Bool,
        onFinished: @escaping @MainActor () -> Void
    ) {
        self.flowController = flowController
        self.snapshotProvider = snapshotProvider
        self.cloudKeyAvailable = cloudKeyAvailable
        self.requestMicrophone = requestMicrophone
        self.requestCalendar = requestCalendar
        self.requestNotifications = requestNotifications
        self.requestScreenRecording = requestScreenRecording
        self.selectEngine = selectEngine
        self.saveOutputFolder = saveOutputFolder
        self.runTestRecording = runTestRecording
        self.onFinished = onFinished
    }

    func load() async {
        let snapshot = await snapshotProvider()
        if isCleanFirstRun(snapshot) {
            step = .welcome
        } else {
            step = snapshot.testRecordingComplete ? .welcome : OnboardingFlowPresenter.resumeStep(from: snapshot)
        }
        await refreshDerivedState(from: snapshot)
        await enterCurrentStep()
    }

    private func isCleanFirstRun(_ snapshot: OnboardingResumeSnapshot) -> Bool {
        snapshot.microphone == .notDetermined
            && snapshot.calendar == .notDetermined
            && snapshot.notifications == .notDetermined
            && snapshot.screenRecording == .notDetermined
    }

    func continueTapped() {
        Task { await continueAsync() }
    }

    func skipTapped() {
        guard step.canSkip else { return }
        advance()
    }

    func choose(_ engine: EngineMode) {
        Task {
            await selectEngine(engine)
            await load()
            if OnboardingFlowStep.ordered.firstIndex(of: step)! <= OnboardingFlowStep.ordered.firstIndex(of: .chooseEngine)! {
                step = .outputFolder
            }
        }
    }

    func retryLocalModel() {
        Task {
            isBusy = true
            _ = await flowController.retryLocalModelDownload()
            isBusy = false
            await load()
        }
    }

    private func continueAsync() async {
        isBusy = true
        defer { isBusy = false }
        switch step {
        case .welcome:
            advance()
        case .microphone:
            permissionResult = await requestMicrophone()
            holdThenAdvanceIfGranted(permissionResult)
        case .calendar:
            permissionResult = await requestCalendar()
            holdThenAdvanceIfGranted(permissionResult, allowDenied: true)
        case .notifications:
            permissionResult = await requestNotifications()
            holdThenAdvanceIfGranted(permissionResult, allowDenied: true)
        case .screenRecording:
            await flowController.enter(.screenRecording)
            permissionResult = await requestScreenRecording()
            holdThenAdvanceIfGranted(permissionResult)
        case .elevenLabsAPIKey:
            advance()
        case .chooseEngine:
            let snapshot = await snapshotProvider()
            if let next = OnboardingFlowPresenter.defaultEngineAfterVerification(
                cloudKeyAvailable: snapshot.cloudKeyAvailable,
                localModelStatus: snapshot.localModelStatus,
                currentSelection: snapshot.selectedEngine
            ) {
                await selectEngine(next)
                advance()
            }
        case .outputFolder:
            await saveOutputFolder(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Scribe", isDirectory: true))
            advance()
        case .testRecording:
            if await runTestRecording() { advance() }
        case .done:
            onFinished()
        }
        await refreshDerivedState(from: await snapshotProvider())
        await enterCurrentStep()
    }

    private func holdThenAdvanceIfGranted(_ status: PermissionStatus?, allowDenied: Bool = false) {
        if status == .granted || allowDenied { advance() }
    }

    private func advance() {
        guard let index = OnboardingFlowStep.ordered.firstIndex(of: step), index + 1 < OnboardingFlowStep.ordered.count else {
            onFinished()
            return
        }
        permissionResult = nil
        step = OnboardingFlowStep.ordered[index + 1]
    }

    private func enterCurrentStep() async {
        await flowController.enter(step)
    }

    private func refreshDerivedState(from snapshot: OnboardingResumeSnapshot) async {
        chooseEngineState = OnboardingFlowPresenter.chooseEngineState(cloudKeyAvailable: snapshot.cloudKeyAvailable, localModelStatus: snapshot.localModelStatus)
        let requiredReady = snapshot.microphone == .granted && snapshot.screenRecording == .granted && snapshot.outputFolderReady
        testRecordingState = OnboardingFlowPresenter.testRecordingState(
            selectedEngine: snapshot.selectedEngine,
            cloudKeyAvailable: await cloudKeyAvailable(),
            localModelStatus: snapshot.localModelStatus,
            requiredCaptureReady: requiredReady
        )
    }
}

private struct OnboardingWindowView: View {
    @ObservedObject var model: OnboardingWindowViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Indicator(state: .ready, label: "ONBOARD")
                Spacer()
                Text("Step \(currentIndex + 1) of \(OnboardingFlowStep.ordered.count)")
                    .font(DS.Font.monoSmall)
                    .foregroundStyle(DS.Color.foregroundTertiary)
            }
            Text(title)
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.foreground)
            Text(detail)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.foregroundSecondary)
                .fixedSize(horizontal: false, vertical: true)
            stepBody
            Spacer()
            HStack {
                if model.step.canSkip {
                    Button("Skip") { model.skipTapped() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button(primaryTitle) { model.continueTapped() }
                    .disabled(model.isBusy || primaryDisabled)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(40)
        .frame(width: 720, height: 620)
        .glassBackground()
    }

    private var currentIndex: Int { OnboardingFlowStep.ordered.firstIndex(of: model.step) ?? 0 }

    @ViewBuilder private var stepBody: some View {
        switch model.step {
        case .screenRecording:
            let copy = OnboardingFlowPresenter.screenRecordingCopy
            VStack(alignment: .leading, spacing: 12) {
                Label(copy.whatIsCaptured, systemImage: "waveform")
                Label(copy.whatIsNotCaptured, systemImage: "eye.slash")
                Text(copy.tagline)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.foregroundSecondary)
            }
        case .chooseEngine:
            VStack(alignment: .leading, spacing: 12) {
                engineRow(model.chooseEngineState.cloud)
                engineRow(model.chooseEngineState.local)
                if model.chooseEngineState.local.retryAvailable {
                    Button("Retry Cohere download") { model.retryLocalModel() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        case .testRecording:
            if let copy = model.testRecordingState.waitingCopy {
                Text(copy).foregroundStyle(DS.Color.warning)
            } else {
                Text("Ready to make a short mic + system audio test recording.")
            }
        default:
            if let result = model.permissionResult {
                Text(result == .granted ? "Granted" : "Not granted yet")
                    .font(DS.Font.bodyEmphasis)
            }
        }
    }

    private func engineRow(_ option: OnboardingEngineOptionState) -> some View {
        Button { model.choose(option.engine) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title).font(DS.Font.bodyEmphasis)
                    Text(option.statusText).font(DS.Font.caption)
                    if let progress = option.progress {
                        Text("\(Int((progress.fractionCompleted ?? 0) * 100))% · \(option.modelID ?? "")").font(DS.Font.monoSmall)
                    } else if let modelID = option.modelID {
                        Text(modelID).font(DS.Font.monoSmall)
                    }
                }
                Spacer()
                Text(option.isReady ? "READY" : "WAIT")
                    .font(DS.Font.monoSmall)
            }
            .padding(12)
        }
        .disabled(!option.isReady)
        .buttonStyle(SecondaryButtonStyle())
    }

    private var title: String {
        switch model.step {
        case .welcome: return "Welcome to Scribe"
        case .microphone: return "Allow microphone audio"
        case .calendar: return "Add calendar context"
        case .notifications: return "Enable meeting prompts"
        case .screenRecording: return "Allow Screen & System Audio Recording"
        case .elevenLabsAPIKey: return "ElevenLabs API key"
        case .chooseEngine: return "Choose transcription engine"
        case .outputFolder: return "Choose output folder"
        case .testRecording: return "Test recording"
        case .done: return "Scribe is ready"
        }
    }

    private var detail: String {
        switch model.step {
        case .welcome: return "Scribe records mic + system audio and writes durable Markdown transcripts next to saved audio."
        case .microphone: return "Scribe needs your voice to capture both sides of a call."
        case .calendar: return "So Scribe can label your recordings with meeting context."
        case .notifications: return "So you don't miss meeting prompts."
        case .screenRecording: return "macOS uses this permission for system audio. Scribe captures audio only."
        case .elevenLabsAPIKey: return "Cloud transcription is optional. Skip this if you want Cohere local once it verifies."
        case .chooseEngine: return "Cloud is ready with a key. Local is ready only after the Cohere model verifies."
        case .outputFolder: return "Scribe saves one folder per meeting under ~/Scribe by default."
        case .testRecording: return "Scribe waits for required capture access and the selected engine before testing."
        case .done: return "The menu bar app is ready to record."
        }
    }

    private var primaryTitle: String {
        switch model.step {
        case .done: return "Start using Scribe"
        case .testRecording: return "Run test recording"
        case .elevenLabsAPIKey: return "Skip for now"
        default: return "Continue"
        }
    }

    private var primaryDisabled: Bool {
        model.step == .testRecording && !model.testRecordingState.isEnabled
    }
}
