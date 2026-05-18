import Foundation
import CoreMedia
@testable import TranscriberCore

final class FakeAudioCaptureSource: AudioCaptureSource, @unchecked Sendable {
    struct StartError: Error {}

    private var handler: ((CMSampleBuffer) -> Void)?
    private(set) var started = false
    private(set) var stopped = false
    var startError: Error?
    var suspendStart = false
    var startContinuation: CheckedContinuation<Void, Never>?

    func setHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func start() async throws {
        if let startError { throw startError }
        if suspendStart, startContinuation == nil {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        started = true
    }

    func resumeStart() {
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume()
    }

    func stop() async { stopped = true }

    func emit(_ buffer: CMSampleBuffer) { handler?(buffer) }
}
