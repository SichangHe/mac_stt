import Foundation

/// Background-process logs: timestamped lines, size rotation on append, age pruning hourly.
/// Total use is bounded: per log at most 2 files (`x.log`, `x.log.1`) of about `maxBytes` each.
public enum LogPrune {
    /// Adjust here.
    public static let maxBytes = 2 * 1024 * 1024
    public static let maxAge: TimeInterval = 14 * 24 * 3600
    public static let reportsKept = 5

    /// Appends one timestamped line; renames to `.1` (replacing the old one) when over the size limit.
    /// Opens the file on every write so rotation never strands a writer on the renamed file.
    public static func append(_ message: String, to path: String, maxBytes: Int = LogPrune.maxBytes) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > maxBytes {
            try? fm.removeItem(atPath: path + ".1")
            try? fm.moveItem(atPath: path, toPath: path + ".1")
        }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = Array(line.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Drops lines older than `maxAge` (lines without a leading `[ISO time]` follow the line above them),
    /// writing a temp file and renaming it over the log. Failure only logs; it never throws.
    public static func dropOld(_ path: String, now: Date = Date(), maxAge: TimeInterval = LogPrune.maxAge) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let formatter = ISO8601DateFormatter()
        var keep = true
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("["), let end = line.firstIndex(of: "]"),
                let time = formatter.date(from: String(line[line.index(after: line.startIndex)..<end]))
            {
                keep = now.timeIntervalSince(time) <= maxAge
            }
            if keep { kept.append(line) }
        }
        let result = kept.joined(separator: "\n")
        guard result != text else { return }
        let temp = path + ".tmp"
        do {
            try result.write(toFile: temp, atomically: false, encoding: .utf8)
            _ = rename(temp, path)
        } catch {
            append("log pruning failed: \(error.localizedDescription)", to: path)
        }
    }

    public static func pruneAll() {
        for path in [ControlSocket.logPath, ControlSocket.appLogPath] {
            dropOld(path)
            dropOld(path + ".1")
        }
        let dir = ControlSocket.directory
        let reports = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("report-") && $0.hasSuffix(".txt") }.sorted()
        for old in reports.dropLast(reportsKept) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
    }
}
