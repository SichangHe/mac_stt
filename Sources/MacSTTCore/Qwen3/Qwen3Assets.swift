import CryptoKit
import Foundation

/// Core ML conversion of Alibaba's Qwen3-ASR (Apache-2.0) by Raymond Chin, pinned by commit.
public enum Qwen3Variant: String, CaseIterable, Sendable {
    case large = "1.7b"
    case small = "0.6b"

    var repo: String { "raymondchins/qwen3-asr-\(rawValue)-coreml" }

    var revision: String {
        switch self {
        case .large: "09e2ce5602d570e9ffc97e45fb0d9c6dad33bafa"
        case .small: "d77134842e78a651cc01ab50bd8b39c2549f1737"
        }
    }
}

public enum Qwen3AssetError: Error, LocalizedError {
    case listing(Int)
    case download(String, Int)
    case checksum(String)

    public var errorDescription: String? {
        switch self {
        case .listing(let code): "could not list model files (HTTP \(code))"
        case .download(let path, let code): "could not download \(path) (HTTP \(code))"
        case .checksum(let path): "checksum mismatch for \(path); delete the model directory and retry"
        }
    }
}

public enum Qwen3Assets {
    public static func directory(for variant: Qwen3Variant) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mac-stt/models/qwen3-asr-\(variant.rawValue)")
    }

    public static func isComplete(_ variant: Qwen3Variant) -> Bool {
        let marker = directory(for: variant).appendingPathComponent(".complete")
        return (try? String(contentsOf: marker, encoding: .utf8)) == variant.revision
    }

    private struct Entry: Decodable {
        struct LFS: Decodable { let oid: String }
        let type: String
        let path: String
        let size: Int
        let lfs: LFS?
    }

    /// Downloads and verifies every runtime file; returns the model directory.
    public static func ensure(_ variant: Qwen3Variant) async throws -> URL {
        let root = directory(for: variant)
        if isComplete(variant) { return root }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let listURL = URL(
            string: "https://huggingface.co/api/models/\(variant.repo)/tree/\(variant.revision)?recursive=true")!
        let (data, response) = try await URLSession.shared.data(from: listURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Qwen3AssetError.listing(http.statusCode)
        }
        let skipped: Set<String> = [".gitattributes", "README.md"]
        let files = try JSONDecoder().decode([Entry].self, from: data)
            .filter { $0.type == "file" && !skipped.contains($0.path) }
            .sorted { $0.size > $1.size }
        let total = files.reduce(0) { $0 + $1.size }
        let counter = ByteCounter(total: total)
        FileHandle.standardError.write(
            Data("downloading Qwen3-ASR \(variant.rawValue) (\(total / 1_000_000) MB) to \(root.path)\n".utf8))
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = files.makeIterator()
            var running = 0
            while running < 4, let file = iterator.next() {
                group.addTask { try await fetch(file, variant: variant, root: root, counter: counter) }
                running += 1
            }
            while try await group.next() != nil {
                if let file = iterator.next() {
                    group.addTask { try await fetch(file, variant: variant, root: root, counter: counter) }
                }
            }
        }
        try variant.revision.write(
            to: root.appendingPathComponent(".complete"), atomically: true, encoding: .utf8)
        return root
    }

    private static func fetch(_ entry: Entry, variant: Qwen3Variant, root: URL, counter: ByteCounter) async throws {
        let destination = root.appendingPathComponent(entry.path)
        if let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int,
            size == entry.size
        {
            counter.add(entry.size)
            return
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let url = URL(string: "https://huggingface.co/\(variant.repo)/resolve/\(variant.revision)/\(entry.path)")!
        let (temporary, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Qwen3AssetError.download(entry.path, http.statusCode)
        }
        if let oid = entry.lfs?.oid, try sha256(of: temporary) != oid {
            throw Qwen3AssetError.checksum(entry.path)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        counter.add(entry.size)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int
    private var done = 0
    init(total: Int) { self.total = total }
    func add(_ bytes: Int) {
        lock.lock()
        done += bytes
        let percent = total == 0 ? 100 : done * 100 / total
        lock.unlock()
        FileHandle.standardError.write(Data("  \(percent)%\n".utf8))
    }
}
