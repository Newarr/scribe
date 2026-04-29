import Foundation
import CoreMedia
@testable import TranscriberCore

final class FakeAudioCaptureSource: AudioCaptureSource, @unchecked Sendable {
    struct StartError: Error {}

    private var handler: ((CMSampleBuffer) -> Void)?
    private(set) var started = false
    private(set) var stopped = false
    var startError: Error?

    func setHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func start() async throws {
        if let startError { throw startError }
        started = true
    }

    func stop() async { stopped = true }

    func emit(_ buffer: CMSampleBuffer) { handler?(buffer) }
}
