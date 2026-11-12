import Foundation

/// Bounds disk use of the background logs. Each log may grow to `maxBytes`; past that it is cut in place
/// to its newest half (the writer keeps its O_APPEND descriptor), so total use stays near 2 * maxBytes.
public enum LogPrune {
    /// Adjust here: cap per log file, and how many `report-*.txt` files to keep.
    public static let maxBytes = 1_000_000
    public static let reportsKept = 5

    public static func trim(_ path: String, maxBytes: Int = LogPrune.maxBytes) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > maxBytes,
            let handle = FileHandle(forUpdatingAtPath: path)
        else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(size - maxBytes / 2))
            var tail = try handle.readToEnd() ?? Data()
            if let newline = tail.firstIndex(of: 10) { tail = tail.suffix(from: tail.index(after: newline)) }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: tail)
        } catch {}
    }

    public static func trimAll() {
        trim(ControlSocket.logPath)
        trim(ControlSocket.appLogPath)
        let dir = ControlSocket.directory
        let reports = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("report-") && $0.hasSuffix(".txt") }.sorted()
        for old in reports.dropLast(reportsKept) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
    }
}
