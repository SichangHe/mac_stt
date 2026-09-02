import FluidAudio
import Foundation

public struct SpeakerSpan: Equatable, Sendable {
    public let speaker: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let quality: Float

    public init(speaker: String, startSeconds: Double, endSeconds: Double, quality: Float) {
        self.speaker = speaker
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.quality = quality
    }
}

public struct TranscriptLine: Equatable, Sendable {
    public let speaker: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String
}

public struct TranscriptDocument: Equatable, Sendable {
    public let text: String
    public let lines: [TranscriptLine]
    public let processingSeconds: Double

    public init(text: String, lines: [TranscriptLine] = [], processingSeconds: Double = 0) {
        self.text = text
        self.lines = lines
        self.processingSeconds = processingSeconds
    }

    public var rendered: String {
        guard !lines.isEmpty else { return text }
        return lines.map { line in
            "[\(Self.timestamp(line.startSeconds))–\(Self.timestamp(line.endSeconds))] \(line.speaker): \(line.text)"
        }.joined(separator: "\n")
    }

    private static func timestamp(_ seconds: Double) -> String {
        let centiseconds = max(0, Int((seconds * 100).rounded()))
        return String(format: "%02d:%02d.%02d", centiseconds / 6000, (centiseconds / 100) % 60, centiseconds % 100)
    }
}

public enum TranscriptAssembler {
    public static func assemble(
        text: String,
        tokenTimings: [TokenTiming],
        speakerSpans: [SpeakerSpan],
        processingSeconds: Double = 0
    ) -> TranscriptDocument {
        let words = buildWordTimings(from: tokenTimings)
        guard !words.isEmpty, !speakerSpans.isEmpty else {
            return TranscriptDocument(text: text, processingSeconds: processingSeconds)
        }
        var lines: [TranscriptLine] = []
        for word in words {
            let middle = (word.startTime + word.endTime) / 2
            let span = bestSpan(at: middle, from: speakerSpans)
            let speaker = span?.speaker ?? "unknown"
            if let last = lines.last, last.speaker == speaker {
                lines[lines.count - 1] = TranscriptLine(
                    speaker: speaker,
                    startSeconds: last.startSeconds,
                    endSeconds: word.endTime,
                    text: join(last.text, word.word)
                )
            } else {
                lines.append(
                    TranscriptLine(
                        speaker: speaker,
                        startSeconds: word.startTime,
                        endSeconds: word.endTime,
                        text: word.word
                    ))
            }
        }
        return TranscriptDocument(text: text, lines: lines, processingSeconds: processingSeconds)
    }

    private static func bestSpan(at seconds: Double, from spans: [SpeakerSpan]) -> SpeakerSpan? {
        let containing = spans.filter { $0.startSeconds <= seconds && seconds <= $0.endSeconds }
        return containing.max { $0.quality < $1.quality }
    }

    private static func join(_ left: String, _ right: String) -> String {
        let punctuation = CharacterSet(charactersIn: ".,!?;:%)]}")
        guard let scalar = right.unicodeScalars.first, punctuation.contains(scalar) else {
            return left + " " + right
        }
        return left + right
    }
}
