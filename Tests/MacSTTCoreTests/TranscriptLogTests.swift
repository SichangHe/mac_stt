import MacSTTCore
import XCTest

final class TranscriptLogTests: XCTestCase {
    private func piece(_ speaker: String, _ start: Double, _ end: Double, _ text: String) -> TranscriptLine {
        TranscriptLine(speaker: speaker, startSeconds: start, endSeconds: end, text: text)
    }

    func testCopyReturnsOnlyTextSinceThePreviousCopy() {
        var log = TranscriptLog()
        let take = log.beginTake()
        log.update(take: take, pieces: [piece("1", 0, 8, "hello"), piece("1", 8, 12, "there")])
        log.setTail(take: take, "unfinished words")
        XCTAssertEqual(log.copyNew(), "Speaker 1: hello there")
        XCTAssertEqual(log.copyNew(), "")
        log.update(take: take, pieces: [piece("1", 0, 8, "hello"), piece("1", 8, 12, "there"), piece("2", 12, 20, "hi")])
        XCTAssertEqual(log.copyNew(), "Speaker 2: hi")
    }

    func testFinalPiecesAfterALiveCopyAreNotRepeated() {
        var log = TranscriptLog()
        let take = log.beginTake()
        log.update(take: take, pieces: [piece(TranscriptLine.pending, 0, 10, "first segment")])
        XCTAssertEqual(log.copyNew(), "…: first segment")
        // Final labeling splits the copied segment by speaker and adds the last segment.
        log.finish(take: take, pieces: [piece("1", 0, 6, "first"), piece("2", 6, 10, "segment"), piece("2", 10, 14, "last")])
        XCTAssertEqual(log.copyNew(), "Speaker 2: last")
    }

    func testOverlappingTakesKeepTheirOwnMarks() {
        var log = TranscriptLog()
        let a = log.beginTake()
        log.update(take: a, pieces: [piece("", 0, 8, "a one")])
        let b = log.beginTake()
        log.update(take: b, pieces: [piece("", 0, 8, "b one")])
        XCTAssertEqual(log.copyNew(), "a one\n\nb one")
        log.finish(take: a, pieces: [piece("", 0, 8, "a one"), piece("", 8, 9, "a two")])
        XCTAssertEqual(log.copyNew(), "a two")
    }

    func testCopyKeyParsing() throws {
        guard case .serve(let defaults) = try CLIParser.parse(["serve"]) else { return XCTFail("wrong command") }
        XCTAssertEqual(defaults.copyKey?.spec, "ctrl+opt+cmd+c")
        guard case .serve(let none) = try CLIParser.parse(["serve", "--copy-key", "none", "--diarize"]) else {
            return XCTFail("wrong command")
        }
        XCTAssertNil(none.copyKey)
        XCTAssertTrue(none.model.diarize)
        XCTAssertEqual(try CLIParser.parse(["window"]), .control(.show))
        XCTAssertEqual(try CLIParser.parse(["copy"]), .control(.copy))
        XCTAssertThrowsError(try CLIParser.parse(["serve", "--copy-key", "c"]))
    }
}
