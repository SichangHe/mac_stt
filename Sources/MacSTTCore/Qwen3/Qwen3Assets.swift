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
        case .checksum(let path): "checksum mismatch for \(path); delete the model cache directory and retry"
        }
    }
}

public enum Qwen3Assets {
    /// 🧑 "store and look up the models in the standard Hugging Face hub cache layout".
    /// Hub cache root: `$HF_HUB_CACHE`, else `$HF_HOME/hub`, else `$XDG_CACHE_HOME/huggingface/hub`, else `~/.cache/huggingface/hub`.
    static func hubCache() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["HF_HUB_CACHE"], !path.isEmpty { return URL(fileURLWithPath: path) }
        if let path = env["HF_HOME"], !path.isEmpty { return URL(fileURLWithPath: path).appendingPathComponent("hub") }
        let base = env["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return base.appendingPathComponent("huggingface/hub")
    }

    /// `models--org--name` directory holding `blobs`, `snapshots/<commit>` and `refs`.
    static func repoDirectory(for variant: Qwen3Variant) -> URL {
        hubCache().appendingPathComponent("models--" + variant.repo.replacingOccurrences(of: "/", with: "--"))
    }

    /// The pinned snapshot directory; it only exists once every file is verified and linked.
    public static func directory(for variant: Qwen3Variant) -> URL {
        repoDirectory(for: variant).appendingPathComponent("snapshots/\(variant.revision)")
    }

    public static func isComplete(_ variant: Qwen3Variant) -> Bool {
        let names = try? FileManager.default.contentsOfDirectory(atPath: directory(for: variant).path)
        return !(names ?? []).isEmpty
    }

    private struct Entry: Decodable {
        struct LFS: Decodable { let oid: String }
        let type: String
        let path: String
        let size: Int
        let oid: String
        let lfs: LFS?
        /// Blob file name in the cache: SHA-256 for LFS files, git blob SHA-1 otherwise.
        var blob: String { lfs?.oid ?? oid }
    }

    /// Reuses a cached snapshot or downloads and verifies every runtime file; returns the snapshot directory.
    public static func ensure(_ variant: Qwen3Variant) async throws -> URL {
        let root = directory(for: variant)
        let repo = repoDirectory(for: variant)
        let blobs = repo.appendingPathComponent("blobs")
        let listURL = URL(
            string: "https://huggingface.co/api/models/\(variant.repo)/tree/\(variant.revision)?recursive=true")!
        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(from: listURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw Qwen3AssetError.listing(http.statusCode)
            }
            data = body
        } catch {
            if isComplete(variant) { return root }
            throw error
        }
        let skipped: Set<String> = [".gitattributes", "README.md"]
        let files = try JSONDecoder().decode([Entry].self, from: data)
            .filter { $0.type == "file" && !skipped.contains($0.path) }
            .sorted { $0.size > $1.size }
        let fm = FileManager.default
        let missing = files.filter { file in
            let size = (try? fm.attributesOfItem(atPath: blobs.appendingPathComponent(file.blob).path))?[.size] as? Int
            return size != file.size
        }
        if missing.isEmpty && isComplete(variant) {
            log("using cached Qwen3-ASR \(variant.rawValue) in \(root.path)")
            return root
        }
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        let total = missing.reduce(0) { $0 + $1.size }
        let counter = ByteCounter(total: total)
        log("downloading Qwen3-ASR \(variant.rawValue) (\(total / 1_000_000) MB) to \(root.path)")
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = missing.makeIterator()
            var running = 0
            while running < 4, let file = iterator.next() {
                group.addTask { try await fetch(file, variant: variant, blobs: blobs, counter: counter) }
                running += 1
            }
            while try await group.next() != nil {
                if let file = iterator.next() {
                    group.addTask { try await fetch(file, variant: variant, blobs: blobs, counter: counter) }
                }
            }
        }
        for file in files {
            let link = root.appendingPathComponent(file.path)
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            let depth = file.path.split(separator: "/").count + 1
            let target = String(repeating: "../", count: depth) + "blobs/" + file.blob
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        }
        let refs = repo.appendingPathComponent("refs")
        try fm.createDirectory(at: refs, withIntermediateDirectories: true)
        try variant.revision.write(to: refs.appendingPathComponent("main"), atomically: true, encoding: .utf8)
        return root
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func fetch(_ entry: Entry, variant: Qwen3Variant, blobs: URL, counter: ByteCounter) async throws {
        let destination = blobs.appendingPathComponent(entry.blob)
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
