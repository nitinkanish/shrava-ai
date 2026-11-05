import XCTest
@testable import ShravaCore

final class TranscriptChunkingTests: XCTestCase {
    func testShortTextSingleChunk() {
        let chunks = TranscriptChunking.chunk("hello", maxChars: 100)
        XCTAssertEqual(chunks, ["hello"])
    }

    func testSplitsOnParagraph() {
        let a = String(repeating: "a", count: 50)
        let b = String(repeating: "b", count: 50)
        let text = a + "\n\n" + b
        let chunks = TranscriptChunking.chunk(text, maxChars: 60)
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 60 || $0 == chunks.last })
    }

    func testMergeRoundTripLength() {
        let text = (0..<200).map { "Sentence number \($0). " }.joined()
        let chunks = TranscriptChunking.chunk(text, maxChars: 180)
        XCTAssertGreaterThan(chunks.count, 1)
        let rejoined = chunks.joined()
        XCTAssertEqual(rejoined.replacingOccurrences(of: " ", with: "").count,
                       text.replacingOccurrences(of: " ", with: "").count)
    }

    func testSchedulerChunkCount() {
        XCTAssertEqual(TranscriptChunkScheduler.chunkCount(durationSeconds: 90, chunkSeconds: 30), 3)
        XCTAssertEqual(TranscriptChunkScheduler.chunkCount(durationSeconds: 1, chunkSeconds: 30), 1)
    }

    func testSchedulerFrameRanges() {
        let ranges = TranscriptChunkScheduler.frameRanges(totalFrames: 48_000, sampleRate: 16_000, chunkSeconds: 1)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges.map(\.count).reduce(0, +), 48_000)
    }

    func testOverlappingWindowsStep() {
        // 16 kHz, 30s window, 5s overlap → step 25s. 70s audio = 70*16000 frames.
        let total: Int64 = 70 * 16_000
        let ranges = TranscriptChunkScheduler.overlappingFrameRanges(
            totalFrames: total,
            sampleRate: 16_000,
            windowSeconds: 30,
            overlapSeconds: 5
        )
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges[0].start, 0)
        XCTAssertEqual(ranges[0].count, 30 * 16_000)
        XCTAssertEqual(ranges[1].start, 25 * 16_000)
        XCTAssertEqual(ranges.last!.start + ranges.last!.count, total)
    }

    func testStitchDropsOverlapWords() {
        let a = "one two three four five six"
        let b = "four five six seven eight"
        let joined = TranscriptChunkScheduler.stitchChunkTexts([a, b], overlapWordHint: 8)
        XCTAssertEqual(joined, "one two three four five six seven eight")
    }

    func testLongMeetingThreshold() {
        XCTAssertGreaterThan(TranscriptChunkScheduler.longMeetingThresholdSeconds, 60)
        XCTAssertGreaterThan(TranscriptChunkScheduler.longMeetingWindowSeconds, 60)
    }
}

