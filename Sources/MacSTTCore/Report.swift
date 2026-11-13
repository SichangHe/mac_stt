import ApplicationServices
import AVFoundation
import Foundation

/// `mac-stt report`: collects diagnostics into one local file and opens a prefilled GitHub issue.
/// Nothing is uploaded; the user attaches the file themselves.
public enum Report {
    static let issueURL = "https://github.com/SichangHe/mac_stt/issues/new"

    static func run(_ args: [String]) -> String {
        let out = args.isEmpty ? ["/usr/bin/sw_vers"] : args
        let p = Process()
        p.executableURL = URL(fileURLWithPath: out[0])
        p.arguments = Array(out.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "(cannot run \(out[0]))" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Log lines we write start with `[ISO time]` or are known tool messages. Anything else could be dictated
    /// text, so it is redacted; so is anything after "partial: ".
    static let knownPrefixes = ["[", "mac-stt ", "using cached", "mlx device", "trace:", "downloading"]

    static func redact(_ text: String, lines: Int = 300) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).map { line -> String in
            if let range = line.range(of: "partial: ") {
                return String(line[..<range.upperBound]) + "<\(line[range.upperBound...].count) chars redacted>"
            }
            if line.isEmpty || knownPrefixes.contains(where: { line.hasPrefix($0) }) { return String(line) }
            return "<\(line.count) chars redacted>"
        }.joined(separator: "\n")
    }

    static func tail(_ path: String, lines: Int = 300) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "(no log at \(path))" }
        return redact(text, lines: lines)
    }

    /// Newest macOS crash reports for mac-stt (macOS writes them when a process crashes).
    static func crashReports() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("mac-stt") && ($0.hasSuffix(".ips") || $0.hasSuffix(".crash")) }
        let newest = names.compactMap { name -> (String, Date)? in
            guard let date = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.modificationDate] as? Date
            else { return nil }
            return (name, date)
        }.sorted { $0.1 > $1.1 }.prefix(3)
        if newest.isEmpty { return "(none in \(dir.path))" }
        return newest.map { name, _ in
            let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return "--- \(name)\n" + String(text.prefix(8000))
        }.joined(separator: "\n")
    }

    public static func build() -> String {
        let mic: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = "authorized"
        case .denied: mic = "denied"
        case .restricted: mic = "restricted"
        case .notDetermined: mic = "not determined"
        @unknown default: mic = "unknown"
        }
        var sections: [(String, String)] = []
        sections.append(("time", ISO8601DateFormatter().string(from: Date())))
        sections.append(("macOS", ProcessInfo.processInfo.operatingSystemVersionString + "\n" + run(["/usr/bin/sw_vers"])))
        sections.append(("hardware", run(["/usr/sbin/sysctl", "hw.model", "machdep.cpu.brand_string", "hw.memsize"])))
        sections.append(("binary", Bundle.main.executablePath ?? CommandLine.arguments[0]))
        var doctor = "platform: \(Hardware.isAppleSilicon ? "Apple Silicon" : "unsupported non-arm64")\nbackend: \(Qwen3Backend.current.rawValue)\n"
        for variant in Qwen3Variant.allCases {
            doctor += "model qwen3-asr-\(variant.rawValue): \(Qwen3Assets.isComplete(variant) ? "installed" : "not installed")\n"
        }
        sections.append(("doctor", doctor))
        sections.append((
            "permissions seen by this process",
            "microphone: \(mic)\naccessibility: \(AXIsProcessTrusted())\ninput monitoring: \(CGPreflightListenEventAccess())\n(run from a terminal these describe the terminal, not the background app)"))
        sections.append(("processes", run(["/bin/sh", "-c", "pgrep -fl 'mac-stt (serve|app)' || echo none"])))
        sections.append(("identity", "\(LocalSigning.requirement(of: Bundle.main.executablePath ?? CommandLine.arguments[0]))\napp bundle: \(FileManager.default.fileExists(atPath: LocalSigning.appExecutable) ? LocalSigning.requirement(of: LocalSigning.defaultAppURL.path) : "not installed")"))
        sections.append(("login item", FileManager.default.fileExists(atPath: LoginItem.plistURL.path) ? "installed" : "not installed"))
        sections.append(("serve log (last 300 lines, dictated text redacted)", tail(ControlSocket.logPath)))
        sections.append(("app log (last 300 lines)", tail(ControlSocket.appLogPath)))
        sections.append(("macOS crash reports for mac-stt (newest 3)", crashReports()))
        return sections.map { "=== \($0.0) ===\n\($0.1)\n" }.joined(separator: "\n")
    }

    public static func write() throws -> String {
        try FileManager.default.createDirectory(at: ControlSocket.directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let path = ControlSocket.directory.appendingPathComponent("report-\(stamp).txt").path
        LogPrune.pruneAll()
        try build().write(toFile: path, atomically: true, encoding: .utf8)
        let title = "Problem report"
        let body = "What happened:\n\n\nWhat I expected:\n\n\n(Attach the report file: \(path))\n"
        var comps = URLComponents(string: issueURL)!
        comps.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        _ = run(["/usr/bin/open", "-R", path])
        _ = run(["/usr/bin/open", comps.url!.absoluteString])
        return "wrote \(path)\nopened a prefilled GitHub issue in your browser; drag the file into it and submit.\nNothing was uploaded. Review the file first: it contains logs, but dictated partial text is redacted."
    }
}
