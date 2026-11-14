import MacSTTCore
import XCTest

final class CLIParserTests: XCTestCase {
    func testClipboardDefaultsOnAndANEIsDefault() throws {
        let command = try CLIParser.parse(["transcribe", "speech.wav"])
        guard case .transcribe(let options) = command else { return XCTFail("wrong command") }
        XCTAssertTrue(options.output.copyToClipboard)
        XCTAssertEqual(options.compute, .ane)
        XCTAssertFalse(options.diarize)
    }

    func testOptOutDiarizationAndComputeAreParsed() throws {
        let command = try CLIParser.parse([
            "transcribe", "one.wav", "two.m4a", "--diarize", "--no-clipboard",
            "--compute", "gpu",
        ])
        guard case .transcribe(let options) = command else { return XCTFail("wrong command") }
        XCTAssertEqual(options.paths, ["one.wav", "two.m4a"])
        XCTAssertTrue(options.diarize)
        XCTAssertFalse(options.output.copyToClipboard)
        XCTAssertEqual(options.compute, .gpu)
    }

    func testUnknownOptionFailsClosed() {
        XCTAssertThrowsError(try CLIParser.parse(["record", "--magic"])) { error in
            XCTAssertEqual(error as? CLIError, .unknownOption("--magic"))
        }
    }

    func testRecordAcceptsFiniteStreamingInput() throws {
        let command = try CLIParser.parse([
            "record", "--input", "two-speaker.wav", "--diarize", "--no-clipboard",
            "--compute", "cpu",
        ])
        guard case .record(let options) = command else { return XCTFail("wrong command") }
        XCTAssertEqual(options.inputPath, "two-speaker.wav")
        XCTAssertTrue(options.diarize)
        XCTAssertFalse(options.output.copyToClipboard)
        XCTAssertEqual(options.compute, .cpu)
    }

    func testRecordInputNeedsAPath() {
        XCTAssertThrowsError(try CLIParser.parse(["record", "--input"])) { error in
            XCTAssertEqual(error as? CLIError, .missingValue("--input"))
        }
    }
}
