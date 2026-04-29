import Foundation
import CoreMedia
@testable import TranscriberCore

final class FakeAudioCaptureSource: AudioCaptureSource, @unchecked Sendable {
    private var handler: ((CMSampleBuffer) -> Void)?
    private(set) var started = false
    private(set) var stopped = false

    func setHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.handler = handler
    }
    func start() async throws { started = true }
    func stop() async { stopped = true }

    func emit(_ buffer: CMSampleBuffer) { handler?(buffer) }
}
