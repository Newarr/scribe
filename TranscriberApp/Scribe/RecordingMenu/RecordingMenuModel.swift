import SwiftUI
import TranscriberCore

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
