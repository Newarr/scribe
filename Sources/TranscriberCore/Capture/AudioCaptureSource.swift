import CoreMedia
import Foundation

public protocol AudioCaptureSource: AnyObject, Sendable {
    func setHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void)
    func start() async throws
    func stop() async
}
