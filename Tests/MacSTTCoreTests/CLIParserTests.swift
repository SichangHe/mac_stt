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

final class AppParserTests: XCTestCase {
    func testAppDefaultsAndInstall() throws {
        XCTAssertEqual(try CLIParser.parse(["app"]), .app(hotkey: try Hotkey(Hotkey.defaultSpec), foreground: false))
        XCTAssertEqual(
            try CLIParser.parse(["app", "install", "--hotkey", "cmd+shift+space"]),
            .appInstall(hotkey: try Hotkey("cmd+shift+space")))
        XCTAssertEqual(try CLIParser.parse(["app", "--foreground", "--hotkey", "ctrl+f5"]), .app(hotkey: try Hotkey("ctrl+f5"), foreground: true))
        XCTAssertTrue(try Hotkey("dictation").isDictationKey)
        XCTAssertEqual(try CLIParser.parse(["app", "uninstall"]), .appUninstall)
    }

    func testBadHotkeys() {
        for bad in ["d", "shift+d", "ctrl+", "foo+d", "ctrl+opt+nope"] {
            XCTAssertThrowsError(try Hotkey(bad))
        }
    }
}

final class LogPruneTests: XCTestCase {
    func testRotatesAndDropsOld() throws {
        let path = NSTemporaryDirectory() + "prune-\(UUID().uuidString).log"
        defer { for s in ["", ".1", ".tmp"] { try? FileManager.default.removeItem(atPath: path + s) } }
        for i in 0..<200 { LogPrune.append("line \(i)", to: path, maxBytes: 1000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".1"))
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        XCTAssertLessThanOrEqual(size, 1100)
        let old = "[2000-01-01T00:00:00Z] ancient\ncontinuation\n[\(ISO8601DateFormatter().string(from: Date()))] fresh\n"
        try old.write(toFile: path, atomically: true, encoding: .utf8)
        LogPrune.dropOld(path)
        let kept = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(kept.contains("ancient"))
        XCTAssertFalse(kept.contains("continuation"))
        XCTAssertTrue(kept.contains("fresh"))
    }
}
