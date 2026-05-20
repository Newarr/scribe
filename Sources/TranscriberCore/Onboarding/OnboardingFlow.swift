import Foundation

public enum OnboardingFlowStep: String, Sendable, Equatable, Hashable, CaseIterable {
    case welcome
    case microphone
    case calendar
    case notifications
    case screenRecording
    case elevenLabsAPIKey
    case chooseEngine
    case outputFolder
    case testRecording
    case done

    public static let ordered: [OnboardingFlowStep] = [
        .welcome,
        .microphone,
        .calendar,
        .notifications,
        .screenRecording,
        .elevenLabsAPIKey,
        .chooseEngine,
        .outputFolder,
        .testRecording,
        .done
    ]

    public var canSkip: Bool {
        switch self {
        case .calendar, .notifications, .elevenLabsAPIKey:
            return true
        case .welcome, .microphone, .screenRecording, .chooseEngine, .outputFolder, .testRecording, .done:
            return false
        }
    }
}

public struct OnboardingResumeSnapshot: Sendable, Equatable {
    public let microphone: PermissionStatus
    public let calendar: PermissionStatus
    public let notifications: PermissionStatus
    public let screenRecording: PermissionStatus
    public let cloudKeyAvailable: Bool
    public let localModelStatus: LocalModelCacheStatus
    public let selectedEngine: EngineMode
    public let outputFolderReady: Bool
    public let testRecordingComplete: Bool

    public init(
        microphone: PermissionStatus,
        calendar: PermissionStatus,
        notifications: PermissionStatus,
        screenRecording: PermissionStatus,
        cloudKeyAvailable: Bool,
        localModelStatus: LocalModelCacheStatus,
        selectedEngine: EngineMode,
        outputFolderReady: Bool,
        testRecordingComplete: Bool
    ) {
        self.microphone = microphone
        self.calendar = calendar
        self.notifications = notifications
        self.screenRecording = screenRecording
        self.cloudKeyAvailable = cloudKeyAvailable
        self.localModelStatus = localModelStatus
        self.selectedEngine = selectedEngine
        self.outputFolderReady = outputFolderReady
        self.testRecordingComplete = testRecordingComplete
    }
}

public struct OnboardingEngineOptionState: Sendable, Equatable {
    public let engine: EngineMode
    public let title: String
    public let isReady: Bool
    public let statusText: String
    public let modelID: String?
    public let progress: LocalModelDownloadProgress?
    public let failureReason: LocalModelFailure?
    public let retryAvailable: Bool

    public init(
        engine: EngineMode,
        title: String,
        isReady: Bool,
        statusText: String,
        modelID: String? = nil,
        progress: LocalModelDownloadProgress? = nil,
        failureReason: LocalModelFailure? = nil,
        retryAvailable: Bool = false
    ) {
        self.engine = engine
        self.title = title
        self.isReady = isReady
        self.statusText = statusText
        self.modelID = modelID
        self.progress = progress
        self.failureReason = failureReason
        self.retryAvailable = retryAvailable
    }
}

public struct OnboardingChooseEngineState: Sendable, Equatable {
    public let cloud: OnboardingEngineOptionState
    public let local: OnboardingEngineOptionState

    public init(cloud: OnboardingEngineOptionState, local: OnboardingEngineOptionState) {
        self.cloud = cloud
        self.local = local
    }
}

public struct OnboardingTestRecordingState: Sendable, Equatable {
    public let isEnabled: Bool
    public let waitingCopy: String?

    public init(isEnabled: Bool, waitingCopy: String?) {
        self.isEnabled = isEnabled
        self.waitingCopy = waitingCopy
    }
}

public protocol OnboardingTestRecordingStarting: Sendable {
    func startTestRecording() async -> Bool
}

public struct OnboardingTestRecordingGate: Sendable {
    private let starter: any OnboardingTestRecordingStarting

    public init(starter: any OnboardingTestRecordingStarting) {
        self.starter = starter
    }

    @discardableResult
    public func startIfReady(
        selectedEngine: EngineMode,
        cloudKeyAvailable: Bool,
        localModelStatus: LocalModelCacheStatus,
        requiredCaptureReady: Bool
    ) async -> Bool {
        let state = OnboardingFlowPresenter.testRecordingState(
            selectedEngine: selectedEngine,
            cloudKeyAvailable: cloudKeyAvailable,
            localModelStatus: localModelStatus,
            requiredCaptureReady: requiredCaptureReady
        )
        guard state.isEnabled else { return false }
        return await starter.startTestRecording()
    }
}

public protocol OnboardingRecordingRouteStarting: Sendable {
    func startRecording(allowPendingPrivacyAcknowledgementForOnboardingTest: Bool) async -> Bool
}

public struct OnboardingTestRecordingRoute: Sendable {
    private let snapshot: @Sendable () async -> OnboardingResumeSnapshot
    private let starter: any OnboardingRecordingRouteStarting

    public init(
        snapshot: @escaping @Sendable () async -> OnboardingResumeSnapshot,
        starter: any OnboardingRecordingRouteStarting
    ) {
        self.snapshot = snapshot
        self.starter = starter
    }

    @discardableResult
    public func run() async -> Bool {
        let snapshot = await snapshot()
        let requiredCaptureReady = snapshot.microphone == .granted
            && snapshot.screenRecording == .granted
            && snapshot.outputFolderReady
        let gate = OnboardingTestRecordingGate(starter: OnboardingRouteStarterAdapter(starter: starter))
        return await gate.startIfReady(
            selectedEngine: snapshot.selectedEngine,
            cloudKeyAvailable: snapshot.cloudKeyAvailable,
            localModelStatus: snapshot.localModelStatus,
            requiredCaptureReady: requiredCaptureReady
        )
    }
}

private struct OnboardingRouteStarterAdapter: OnboardingTestRecordingStarting {
    let starter: any OnboardingRecordingRouteStarting

    func startTestRecording() async -> Bool {
        await starter.startRecording(allowPendingPrivacyAcknowledgementForOnboardingTest: true)
    }
}

public struct OnboardingScreenRecordingCopy: Sendable, Equatable {
    public let whatIsCaptured: String
    public let whatIsNotCaptured: String
    public let tagline: String

    public init(whatIsCaptured: String, whatIsNotCaptured: String, tagline: String) {
        self.whatIsCaptured = whatIsCaptured
        self.whatIsNotCaptured = whatIsNotCaptured
        self.tagline = tagline
    }
}

public enum OnboardingFlowPresenter {
    public static let screenRecordingCopy = OnboardingScreenRecordingCopy(
        whatIsCaptured: "Scribe captures microphone audio and system audio so meeting voices are recorded together.",
        whatIsNotCaptured: "Scribe does not capture video, screenshots, keystrokes, browser history, or screen content.",
        tagline: "macOS calls this 'Screen Recording' for technical reasons, but no video or screen content ever leaves your machine."
    )

    public static func resumeStep(from snapshot: OnboardingResumeSnapshot) -> OnboardingFlowStep {
        guard snapshot.microphone == .granted else { return .microphone }
        guard snapshot.screenRecording == .granted else { return .screenRecording }
        if snapshot.selectedEngine == .cloud, snapshot.cloudKeyAvailable == false {
            return .elevenLabsAPIKey
        }
        if engineReady(selectedEngine: snapshot.selectedEngine, cloudKeyAvailable: snapshot.cloudKeyAvailable, localModelStatus: snapshot.localModelStatus) == false {
            return .chooseEngine
        }
        guard snapshot.outputFolderReady else { return .outputFolder }
        guard snapshot.testRecordingComplete else { return .testRecording }
        return .done
    }

    public static func chooseEngineState(cloudKeyAvailable: Bool, localModelStatus: LocalModelCacheStatus) -> OnboardingChooseEngineState {
        let cloud = OnboardingEngineOptionState(
            engine: .cloud,
            title: "ElevenLabs (cloud)",
            isReady: cloudKeyAvailable,
            statusText: cloudKeyAvailable ? "ElevenLabs ready" : "ElevenLabs API key required"
        )
        let local: OnboardingEngineOptionState
        switch localModelStatus {
        case .notDownloaded(let modelID):
            local = .init(engine: .local, title: "Cohere (local)", isReady: false, statusText: "Cohere model not downloaded", modelID: modelID, retryAvailable: true)
        case .downloading(let modelID, let progress):
            local = .init(engine: .local, title: "Cohere (local)", isReady: false, statusText: "Downloading Cohere model", modelID: modelID, progress: progress)
        case .verifying(let modelID):
            local = .init(engine: .local, title: "Cohere (local)", isReady: false, statusText: "Verifying Cohere model", modelID: modelID)
        case .verified(let info):
            local = .init(engine: .local, title: "Cohere (local)", isReady: true, statusText: "Cohere ready", modelID: info.modelID)
        case .failed(let modelID, let reason, let retryAvailable):
            local = .init(engine: .local, title: "Cohere (local)", isReady: false, statusText: "Cohere download failed", modelID: modelID, failureReason: reason, retryAvailable: retryAvailable)
        case .unsupported(let modelID, let reason):
            local = .init(engine: .local, title: "Cohere (local)", isReady: false, statusText: "Cohere unsupported on this Mac", modelID: modelID, failureReason: reason)
        }
        return OnboardingChooseEngineState(cloud: cloud, local: local)
    }

    public static func defaultEngineAfterVerification(
        cloudKeyAvailable: Bool,
        localModelStatus: LocalModelCacheStatus,
        currentSelection: EngineMode
    ) -> EngineMode? {
        if cloudKeyAvailable {
            return currentSelection == .cloud ? .cloud : currentSelection
        }
        return localModelStatus.isReady ? .local : nil
    }

    public static func testRecordingState(
        selectedEngine: EngineMode,
        cloudKeyAvailable: Bool,
        localModelStatus: LocalModelCacheStatus,
        requiredCaptureReady: Bool
    ) -> OnboardingTestRecordingState {
        guard requiredCaptureReady else {
            return .init(isEnabled: false, waitingCopy: "Grant Microphone and Screen Recording before the test recording.")
        }
        switch selectedEngine {
        case .cloud:
            if cloudKeyAvailable {
                return .init(isEnabled: true, waitingCopy: nil)
            }
            return .init(isEnabled: false, waitingCopy: "Enter an ElevenLabs API key or choose Cohere (local) before the test recording.")
        case .local:
            switch localModelStatus {
            case .verified:
                return .init(isEnabled: true, waitingCopy: nil)
            case .notDownloaded, .downloading, .verifying:
                return .init(isEnabled: false, waitingCopy: "Waiting for Cohere to finish downloading before the test recording.")
            case .failed:
                return .init(isEnabled: false, waitingCopy: "Cohere download failed. Retry Local setup before the test recording.")
            case .unsupported:
                return .init(isEnabled: false, waitingCopy: "Cohere local transcription is not supported on this Mac.")
            }
        }
    }

    private static func engineReady(selectedEngine: EngineMode, cloudKeyAvailable: Bool, localModelStatus: LocalModelCacheStatus) -> Bool {
        switch selectedEngine {
        case .cloud:
            return cloudKeyAvailable
        case .local:
            return localModelStatus.isReady
        }
    }
}

public protocol LocalModelDownloadStarting: Sendable {
    @discardableResult
    func startDownload() async -> LocalModelCacheStatus
    @discardableResult
    func retryDownload() async -> LocalModelCacheStatus
}

extension LocalModelManager: LocalModelDownloadStarting {}

public actor OnboardingFlowController {
    private let downloadStarter: any LocalModelDownloadStarting
    private var hasStartedScreenRecordingDownload = false
    private var screenRecordingDownloadTask: Task<LocalModelCacheStatus, Never>?

    public init(downloadStarter: any LocalModelDownloadStarting) {
        self.downloadStarter = downloadStarter
    }

    public func enter(_ step: OnboardingFlowStep) async {
        guard step == .screenRecording else { return }
        guard hasStartedScreenRecordingDownload == false else { return }
        hasStartedScreenRecordingDownload = true
        let starter = downloadStarter
        screenRecordingDownloadTask = Task {
            await starter.startDownload()
        }
        await Task.yield()
    }

    @discardableResult
    public func retryLocalModelDownload() async -> LocalModelCacheStatus {
        hasStartedScreenRecordingDownload = true
        screenRecordingDownloadTask?.cancel()
        screenRecordingDownloadTask = nil
        return await downloadStarter.retryDownload()
    }
}
