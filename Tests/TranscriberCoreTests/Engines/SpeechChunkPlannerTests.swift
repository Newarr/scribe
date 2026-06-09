import XCTest
@testable import TranscriberCore

final class SpeechChunkPlannerTests: XCTestCase {
    private let rate = 16_000

    private func seconds(_ s: Double) -> Int { Int(s * Double(rate)) }

    func testEmptyTimestampsProduceNoChunks() {
        let chunks = SpeechChunkPlanner.plan(spans: [], sampleCount: seconds(60), sampleRate: rate)
        XCTAssertTrue(chunks.isEmpty)
    }

    func testSingleShortSpanIsOneChunk() {
        let spans = [SpeechSpan(start: seconds(2), end: seconds(10))]
        let chunks = SpeechChunkPlanner.plan(spans: spans, sampleCount: seconds(60), sampleRate: rate)
        XCTAssertEqual(chunks, [SpeechChunk(startSample: seconds(2), endSample: seconds(10))])
    }

    func testDenseSpeechPacksIntoChunksWithoutCuttingSpans() {
        // Ten 5s spans separated by 0.5s gaps: 0-5, 5.5-10.5, 11-16, ...
        var spans: [SpeechSpan] = []
        for i in 0..<10 {
            let start = Double(i) * 5.5
            spans.append(SpeechSpan(start: seconds(start), end: seconds(start + 5)))
        }
        let chunks = SpeechChunkPlanner.plan(spans: spans, sampleCount: seconds(120), sampleRate: rate)

        XCTAssertGreaterThan(chunks.count, 1, "55s of near-continuous speech cannot fit one 30s chunk")
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.endSample - chunk.startSample, seconds(30))
            // Boundaries must land on span starts/ends, never inside a span.
            XCTAssertTrue(spans.contains { $0.start == chunk.startSample })
            XCTAssertTrue(spans.contains { $0.end == chunk.endSample })
        }
        // Monotonic, non-overlapping coverage in original-audio time.
        for pair in zip(chunks, chunks.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.endSample, pair.1.startSample)
        }
    }

    func testLongSilenceGapIsNeverIncludedInAChunk() {
        // Two short spans separated by 4 minutes of silence — must become
        // two chunks even though their merged length would fit in 30s of
        // chunk budget if silence were dropped (it is not; slices are
        // contiguous source audio).
        let spans = [
            SpeechSpan(start: seconds(0), end: seconds(8)),
            SpeechSpan(start: seconds(248), end: seconds(255)),
        ]
        let chunks = SpeechChunkPlanner.plan(spans: spans, sampleCount: seconds(300), sampleRate: rate)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0], SpeechChunk(startSample: seconds(0), endSample: seconds(8)))
        XCTAssertEqual(chunks[1], SpeechChunk(startSample: seconds(248), endSample: seconds(255)))
    }

    func testShortGapMergesIntoOneChunk() {
        let spans = [
            SpeechSpan(start: seconds(0), end: seconds(8)),
            SpeechSpan(start: seconds(8.5), end: seconds(16)),
        ]
        let chunks = SpeechChunkPlanner.plan(spans: spans, sampleCount: seconds(60), sampleRate: rate)
        XCTAssertEqual(chunks, [SpeechChunk(startSample: seconds(0), endSample: seconds(16))])
    }

    func testOversizedSingleSpanIsSplitAtProvidedPoint() {
        // 70s of continuous speech with a designated quiet point at 33s.
        let quiet = seconds(33)
        let spans = [SpeechSpan(start: 0, end: seconds(70))]
        let chunks = SpeechChunkPlanner.plan(
            spans: spans,
            sampleCount: seconds(70),
            sampleRate: rate,
            splitPoint: { range in range.contains(quiet) ? quiet : range.lowerBound + range.count / 2 }
        )
        XCTAssertGreaterThanOrEqual(chunks.count, 3, "70s must split into at least three ≤30s chunks")
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.endSample - chunk.startSample, seconds(30))
        }
        XCTAssertEqual(chunks.first?.startSample, 0)
        XCTAssertEqual(chunks.last?.endSample, seconds(70))
        XCTAssertTrue(chunks.contains { $0.endSample == quiet || $0.startSample == quiet },
                      "the provided quiet point must be used as a boundary")
        // Full coverage: pieces of a split span are contiguous.
        for pair in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(pair.0.endSample, pair.1.startSample)
        }
    }

    func testSpanSpanningExactly30SecondBoundaryIsNotSplit() {
        let spans = [SpeechSpan(start: seconds(10), end: seconds(40))]
        let chunks = SpeechChunkPlanner.plan(spans: spans, sampleCount: seconds(60), sampleRate: rate)
        XCTAssertEqual(chunks, [SpeechChunk(startSample: seconds(10), endSample: seconds(40))])
    }

    func testDegenerateSplitPointStillTerminates() {
        // A splitPoint that always returns an out-of-range value must be
        // clamped and still make progress (no infinite recursion).
        let spans = [SpeechSpan(start: 0, end: seconds(90))]
        let chunks = SpeechChunkPlanner.plan(
            spans: spans,
            sampleCount: seconds(90),
            sampleRate: rate,
            splitPoint: { _ in Int.max }
        )
        XCTAssertFalse(chunks.isEmpty)
        for chunk in chunks {
            XCTAssertGreaterThan(chunk.endSample, chunk.startSample)
        }
        XCTAssertEqual(chunks.last?.endSample, seconds(90))
    }

    func testSpansOutsideAudioAreClamped() {
        let spans = [SpeechSpan(start: seconds(-1), end: seconds(5)),
                     SpeechSpan(start: seconds(55), end: seconds(99))]
        let chunks = SpeechChunkPlanner.plan(spans: spans, sampleCount: seconds(60), sampleRate: rate)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].startSample, 0)
        XCTAssertEqual(chunks[1].endSample, seconds(60))
    }
}
