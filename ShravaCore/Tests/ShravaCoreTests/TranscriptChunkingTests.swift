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
}
