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
}
