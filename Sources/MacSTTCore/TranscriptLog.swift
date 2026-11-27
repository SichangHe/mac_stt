import Foundation

/// Every take `serve` has transcribed since it started, plus what was copied from each.
/// A piece is one transcribed stretch of audio with its speaker ("" = no diarization).
/// Each take has a copy mark, a time: pieces that end at or before it were copied already.
/// Piece boundaries are segment boundaries (or finer, after speaker splitting), so a mark set on live
/// pieces still falls on a boundary once the take's final pieces replace them.
public struct TranscriptLog: Equatable, Sendable {
    public struct Take: Equatable, Sendable {
        public var started: Date
        public var pieces: [TranscriptLine] = []
        /// Text of the unfinished segment while recording; nil once recording stopped.
        public var tail: String?
        public var finished = false
        public var copiedUpTo = -1.0
    }

    public private(set) var takes: [Take] = []

    public init() {}

    @discardableResult
    public mutating func beginTake(at date: Date = Date()) -> Int {
        takes.append(Take(started: date, tail: ""))
        return takes.count - 1
    }

    /// Live update: the take's finished segments so far, in time order.
    public mutating func update(take: Int, pieces: [TranscriptLine]) {
        guard takes.indices.contains(take), !takes[take].finished else { return }
        takes[take].pieces = pieces
    }

    /// The unfinished segment's text; nil when recording stopped.
    public mutating func setTail(take: Int, _ tail: String?) {
        guard takes.indices.contains(take), !takes[take].finished else { return }
        takes[take].tail = tail
    }

    public mutating func finish(take: Int, pieces: [TranscriptLine]) {
        guard takes.indices.contains(take) else { return }
        takes[take].pieces = pieces
        takes[take].tail = nil
        takes[take].finished = true
    }

    public func isCopied(take: Int, _ piece: TranscriptLine) -> Bool {
        piece.endSeconds <= takes[take].copiedUpTo + 0.001
    }

    /// Returns the transcribed text not copied yet and marks it copied. Tails are left out: their text
    /// can still change. Takes are separated by a blank line.
    public mutating func copyNew() -> String {
        var blocks: [String] = []
        for index in takes.indices {
            let fresh = takes[index].pieces.filter { !isCopied(take: index, $0) && !$0.text.isEmpty }
            guard let end = fresh.map(\.endSeconds).max() else { continue }
            blocks.append(Self.render(fresh))
            takes[index].copiedUpTo = end
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Returns all transcribed text and marks it copied.
    public mutating func copyAll() -> String {
        _ = copyNew()
        return takes.map { Self.render($0.pieces) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Consecutive pieces of one speaker become one line `Speaker: text`; with no speakers, plain text.
    public static func render(_ pieces: [TranscriptLine]) -> String {
        var lines: [(String, String)] = []
        for piece in pieces where !piece.text.isEmpty {
            if let last = lines.last, last.0 == piece.speaker {
                lines[lines.count - 1].1 += " " + piece.text
            } else {
                lines.append((piece.speaker, piece.text))
            }
        }
        return lines.map { speaker, text in speaker.isEmpty ? text : "\(displayName(speaker)): \(text)" }
            .joined(separator: "\n")
    }

    /// FluidAudio speaker IDs are bare numbers; show them as `Speaker N`.
    public static func displayName(_ speaker: String) -> String {
        if speaker == TranscriptLine.pending { return "…" }
        return Int(speaker) != nil ? "Speaker \(speaker)" : speaker
    }
}

extension TranscriptLine {
    /// Speaker placeholder for a live piece whose audio diarization has not reached yet.
    public static let pending = "…pending"

    public init(segment: SpeechSegment, speaker: String) {
        self.init(speaker: speaker, startSeconds: segment.startSeconds, endSeconds: segment.endSeconds, text: segment.text)
    }
}
