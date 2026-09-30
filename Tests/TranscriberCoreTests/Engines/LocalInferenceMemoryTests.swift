import XCTest
import MLX
@testable import TranscriberCore

final class LocalInferenceMemoryTests: XCTestCase {
    func testSuccessfulInferenceReleasesBuffersAndPreservesResult() {
        let activeMemoryBefore = Memory.activeMemory

        let result = LocalInferenceMemory.withReleasedCache {
            let audio = MLXArray.ones([1_048_576], dtype: .float32)
            audio.eval()
            XCTAssertGreaterThan(Memory.activeMemory, activeMemoryBefore)
            return audio[0].item(Float.self)
        }

        XCTAssertEqual(result, 1)
        XCTAssertEqual(Memory.cacheMemory, 0)
        XCTAssertLessThanOrEqual(Memory.activeMemory, activeMemoryBefore)
    }

    func testCancelledInferenceReleasesBuffersAndPreservesError() {
        let activeMemoryBefore = Memory.activeMemory

        XCTAssertThrowsError(try LocalInferenceMemory.withReleasedCache {
            let audio = MLXArray.ones([1_048_576], dtype: .float32)
            audio.eval()
            XCTAssertGreaterThan(Memory.activeMemory, activeMemoryBefore)
            throw CancellationError()
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(Memory.cacheMemory, 0)
        XCTAssertLessThanOrEqual(Memory.activeMemory, activeMemoryBefore)
    }
}
