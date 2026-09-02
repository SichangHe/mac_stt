import FluidAudio
import MacSTTCore
import XCTest

final class TranscriptTests: XCTestCase {
    func testWordsAreGroupedByDiarizedSpeaker() {
        let tokens = [
            TokenTiming(token: "▁Hello", tokenId: 1, startTime: 0, endTime: 0.4, confidence: 1),
            TokenTiming(token: "▁there", tokenId: 2, startTime: 0.5, endTime: 0.9, confidence: 1),
            TokenTiming(token: "▁General", tokenId: 3, startTime: 1.2, endTime: 1.6, confidence: 1),
            TokenTiming(token: "▁Kenobi", tokenId: 4, startTime: 1.7, endTime: 2.1, confidence: 1),
        ]
        let spans = [
            SpeakerSpan(speaker: "S1", startSeconds: 0, endSeconds: 1, quality: 0.8),
            SpeakerSpan(speaker: "S2", startSeconds: 1.1, endSeconds: 2.5, quality: 0.9),
        ]
        let result = TranscriptAssembler.assemble(
            text: "Hello there General Kenobi",
            tokenTimings: tokens,
            speakerSpans: spans
        )
        XCTAssertEqual(result.lines.map(\.speaker), ["S1", "S2"])
        XCTAssertEqual(result.lines.map(\.text), ["Hello there", "General Kenobi"])
        XCTAssertTrue(result.rendered.contains("S1: Hello there"))
    }

    func testNoTimingsPreservesPlainTranscript() {
        let result = TranscriptAssembler.assemble(
            text: "plain text",
            tokenTimings: [],
            speakerSpans: []
        )
        XCTAssertEqual(result.rendered, "plain text")
    }

    func testWordInSpeakerGapIsUnknown() {
        let token = TokenTiming(
            token: "▁gap", tokenId: 1, startTime: 2, endTime: 2.2, confidence: 1)
        let spans = [
            SpeakerSpan(speaker: "S1", startSeconds: 0, endSeconds: 1, quality: 1),
            SpeakerSpan(speaker: "S2", startSeconds: 3, endSeconds: 4, quality: 1),
        ]
        let result = TranscriptAssembler.assemble(
            text: "gap", tokenTimings: [token], speakerSpans: spans)
        XCTAssertEqual(result.lines.map(\.speaker), ["unknown"])
    }
}
