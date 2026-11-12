import Foundation

/// Start/end indicator sounds: two 0.14 s sine notes, rising for start and falling for end.
/// Synthesized once into the cache directory, so the release ships no sound files.
enum Earcon: String {
    case start, end

    private var notes: [Double] { self == .start ? [880, 1320] : [1320, 880] }

    func play() {
        guard let url = try? file() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [url.path]
        try? process.run()
    }

    private func file() throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mac-stt", isDirectory: true)
        let url = dir.appendingPathComponent("\(rawValue)-v1.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try wav().write(to: url, options: .atomic)
        return url
    }

    private func wav() -> Data {
        let rate = 24_000, noteSeconds = 0.14
        var pcm = Data()
        for f in notes {
            for i in 0..<Int(noteSeconds * Double(rate)) {
                let t = Double(i) / Double(rate)
                let envelope = min(1, t / 0.01, (noteSeconds - t) / 0.03)
                var s = Int16(sin(2 * .pi * f * t) * envelope * 0.45 * 32767).littleEndian
                withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
            }
        }
        var header = Data()
        func put<T: FixedWidthInteger>(_ v: T) { var le = v.littleEndian; withUnsafeBytes(of: &le) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        header.append(contentsOf: Array("data".utf8)); put(UInt32(pcm.count))
        return header + pcm
    }
}
