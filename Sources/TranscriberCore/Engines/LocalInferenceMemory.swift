import Foundation
import MLX

enum LocalInferenceMemory {
    static func withReleasedCache<Result>(_ inference: () throws -> Result) rethrows -> Result {
        defer { Memory.clearCache() }
        return try autoreleasepool {
            defer { Stream.gpu.synchronize() }
            return try inference()
        }
    }
}
