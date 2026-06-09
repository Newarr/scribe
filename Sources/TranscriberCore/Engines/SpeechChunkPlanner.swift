import Foundation

/// A half-open sample range `[start, end)` of detected speech, as produced
/// by the Silero VAD (`SileroVADTimestamp` start/end are sample indices).
public struct SpeechSpan: Sendable, Equatable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public var count: Int { max(0, end - start) }
}

/// One contiguous audio slice to send to the model, with its true offset
/// in the source recording so transcript segments carry real timestamps.
public struct SpeechChunk: Sendable, Equatable {
    public let startSample: Int
    public let endSample: Int

    public init(startSample: Int, endSample: Int) {
        self.startSample = startSample
        self.endSample = endSample
    }

    public func startSeconds(sampleRate: Int) -> Double {
        Double(startSample) / Double(sampleRate)
    }

    public func endSeconds(sampleRate: Int) -> Double {
        Double(endSample) / Double(sampleRate)
    }
}

/// Packs VAD speech spans into model-sized chunks. Pure and synchronous so
/// it is unit-testable without MLX.
///
/// Invariants:
/// - Chunks are contiguous slices of the ORIGINAL audio (never concatenated
///   across gaps), so segment timestamps stay linear in recording time.
/// - No chunk exceeds `maxChunkSeconds`.
/// - A chunk boundary never lands inside a speech span unless that single
///   span is itself longer than the cap, in which case it is split at
///   `splitPoint` (callers pass a lowest-energy search; default midpoint).
/// - Spans are merged into one chunk only when the silence gap between them
///   is at most `maxMergeGapSeconds` — long silences are excluded entirely,
///   which is the whole point (the model hallucinates on silence).
public enum SpeechChunkPlanner {
    public static func plan(
        spans: [SpeechSpan],
        sampleCount: Int,
        sampleRate: Int,
        maxChunkSeconds: Double = 30,
        maxMergeGapSeconds: Double = 1.0,
        splitPoint: (Range<Int>) -> Int = { $0.lowerBound + $0.count / 2 }
    ) -> [SpeechChunk] {
        let maxChunkSamples = Int(maxChunkSeconds * Double(sampleRate))
        let maxGapSamples = Int(maxMergeGapSeconds * Double(sampleRate))
        guard maxChunkSamples > 0 else { return [] }

        // Clamp to the audio, drop empties, keep ordering deterministic.
        let clamped = spans
            .map { SpeechSpan(start: max(0, $0.start), end: min(sampleCount, $0.end)) }
            .filter { $0.count > 0 }
            .sorted { $0.start < $1.start }
        guard !clamped.isEmpty else { return [] }

        // Oversized single spans must be split before packing so the packer
        // can assume every span fits in a chunk.
        var pieces: [SpeechSpan] = []
        for span in clamped {
            pieces.append(contentsOf: split(span, maxSamples: maxChunkSamples, splitPoint: splitPoint))
        }

        var chunks: [SpeechChunk] = []
        var chunkStart = pieces[0].start
        var chunkEnd = pieces[0].end
        for span in pieces.dropFirst() {
            let gap = span.start - chunkEnd
            let mergedLength = span.end - chunkStart
            if gap <= maxGapSamples && mergedLength <= maxChunkSamples {
                chunkEnd = span.end
            } else {
                chunks.append(SpeechChunk(startSample: chunkStart, endSample: chunkEnd))
                chunkStart = span.start
                chunkEnd = span.end
            }
        }
        chunks.append(SpeechChunk(startSample: chunkStart, endSample: chunkEnd))
        return chunks
    }

    /// Recursively halves a span at `splitPoint` until every piece fits.
    /// The split point is constrained to the middle 80% of the span so a
    /// degenerate splitPoint cannot produce empty pieces or fail to make
    /// progress.
    private static func split(
        _ span: SpeechSpan,
        maxSamples: Int,
        splitPoint: (Range<Int>) -> Int
    ) -> [SpeechSpan] {
        guard span.count > maxSamples else { return [span] }
        let margin = max(1, span.count / 10)
        let searchRange = (span.start + margin)..<(span.end - margin)
        let rawPoint = splitPoint(searchRange)
        let point = min(max(rawPoint, searchRange.lowerBound), searchRange.upperBound - 1)
        let left = SpeechSpan(start: span.start, end: point)
        let right = SpeechSpan(start: point, end: span.end)
        return split(left, maxSamples: maxSamples, splitPoint: splitPoint)
            + split(right, maxSamples: maxSamples, splitPoint: splitPoint)
    }
}
