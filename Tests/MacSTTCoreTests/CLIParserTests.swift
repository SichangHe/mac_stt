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

final class ReportRedactionTests: XCTestCase {
    func testUnknownAndPartialLinesAreRedacted() {
        let log = "[2026-01-01T00:00:00Z] recording started\n[2026-01-01T00:00:01Z] partial: secret words\nsecret transcript line\nmac-stt serve listening"
        let out = Report.redact(log)
        XCTAssertFalse(out.contains("secret"))
        XCTAssertTrue(out.contains("recording started"))
        XCTAssertTrue(out.contains("mac-stt serve listening"))
    }
}

final class LocalSigningTests: XCTestCase {
    func testBuildsSignedBundleWithFixedIdentifier() throws {
        let dir = NSTemporaryDirectory() + "sign-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let copy = dir + "/mac-stt"
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: copy)
        let app = URL(fileURLWithPath: dir + "/mac-stt.app")
        let report = LocalSigning.setUpApp(cli: copy, app: app)
        XCTAssertFalse(report.contains("failed"), report)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: app.path + "/Contents/MacOS/mac-stt"))
        // Prints the facts for the log: what identity macOS would record for this ad-hoc signed app.
        print("DR-CHECK raw: \(LocalSigning.exec(["/usr/bin/codesign", "-d", "-r-", app.path]).output)")
        print("DR-CHECK verbose: \(LocalSigning.exec(["/usr/bin/codesign", "-dvv", app.path]).output)")
        let requirement = LocalSigning.requirement(of: app.path)
        XCTAssertTrue(requirement.contains("cdhash"), requirement)  // ad-hoc: the requirement is the code hash, not the identifier
    }
}
