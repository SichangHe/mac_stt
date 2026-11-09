import Foundation

/// Decode-only byte-level BPE tokenizer: the model's prompt tokens come from speakey.json,
/// so only token ids to text is needed.
struct Qwen3Tokenizer: Sendable {
    private let pieces: [Int: [UInt8]]
    static let firstSpecialToken = 151_643

    init(vocabURL: URL) throws {
        let table = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: vocabURL))
        let reverse = Self.unicodeToByte()
        var pieces: [Int: [UInt8]] = [:]
        pieces.reserveCapacity(table.count)
        for (token, id) in table {
            pieces[id] = token.unicodeScalars.compactMap { reverse[$0] }
        }
        self.pieces = pieces
    }

    func decode(_ ids: [Int]) -> String {
        var bytes: [UInt8] = []
        for id in ids where id < Self.firstSpecialToken {
            bytes.append(contentsOf: pieces[id] ?? [])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func unicodeToByte() -> [Unicode.Scalar: UInt8] {
        var printable = Array(33...126) + Array(161...172) + Array(174...255)
        var mapping: [Unicode.Scalar: UInt8] = [:]
        for byte in printable { mapping[Unicode.Scalar(UInt32(byte))!] = UInt8(byte) }
        var extra: UInt32 = 0
        for byte in 0..<256 where !printable.contains(byte) {
            mapping[Unicode.Scalar(256 + extra)!] = UInt8(byte)
            extra += 1
        }
        printable.removeAll()
        return mapping
    }
}
