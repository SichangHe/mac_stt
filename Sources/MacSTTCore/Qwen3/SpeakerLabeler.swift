import Foundation

/// Assigns speakers to Qwen3 segments. Segments that contain one speaker are labeled directly;
/// a segment that contains a speaker change is re-transcribed per speaker turn.
public enum SpeakerLabeler {
    private struct Piece {
        var speaker: String
        var start: Double
        var end: Double
    }

    public static func document(
        segments: [SpeechSegment],
        spans: [SpeakerSpan],
        audio: [Float],
        engine: any Qwen3Engine,
        language: String?
    ) async throws -> TranscriptDocument {
        document(pieces: try await pieces(segments: segments, spans: spans, audio: audio, engine: engine, language: language))
    }

    /// Merges consecutive pieces of one speaker into lines.
    public static func document(pieces: [TranscriptLine]) -> TranscriptDocument {
        var lines: [TranscriptLine] = []
        for piece in pieces where !piece.text.isEmpty {
            if let last = lines.last, last.speaker == piece.speaker {
                lines[lines.count - 1] = TranscriptLine(
                    speaker: piece.speaker, startSeconds: last.startSeconds, endSeconds: piece.endSeconds,
                    text: last.text + " " + piece.text)
            } else {
                lines.append(piece)
            }
        }
        let text = lines.map(\.text).joined(separator: " ")
        return TranscriptDocument(text: text, lines: lines)
    }

    /// One labeled piece per segment, or per speaker turn inside a segment with a speaker change.
    public static func pieces(
        segments: [SpeechSegment],
        spans: [SpeakerSpan],
        audio: [Float],
        engine: any Qwen3Engine,
        language: String?
    ) async throws -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        func add(_ speaker: String, _ start: Double, _ end: Double, _ text: String) {
            guard !text.isEmpty else { return }
            lines.append(TranscriptLine(speaker: speaker, startSeconds: start, endSeconds: end, text: text))
        }
        for segment in segments {
            let pieces = turns(in: segment, spans: spans)
            if pieces.count == 1 {
                add(pieces[0].speaker, segment.startSeconds, segment.endSeconds, segment.text)
                continue
            }
            for piece in pieces {
                let from = min(audio.count, max(0, Int(piece.start * 16_000)))
                let to = min(audio.count, max(from, Int(piece.end * 16_000)))
                let text = try await engine.transcribe(Array(audio[from..<to]), language: language)
                add(piece.speaker, piece.start, piece.end, text)
            }
        }
        return lines
    }

    /// Live label for a finished segment: the speaker overlapping it most, `TranscriptLine.pending`
    /// while diarization has not reached its end, "unknown" when no speaker overlaps it.
    public static func liveSpeaker(for segment: SpeechSegment, spans: [SpeakerSpan], coveredSeconds: Double) -> String {
        guard coveredSeconds >= segment.endSeconds else { return TranscriptLine.pending }
        var overlap: [String: Double] = [:]
        for span in spans {
            let amount = min(span.endSeconds, segment.endSeconds) - max(span.startSeconds, segment.startSeconds)
            if amount > 0 { overlap[span.speaker, default: 0] += amount }
        }
        return overlap.max { $0.value < $1.value }?.key ?? "unknown"
    }

    private static func turns(in segment: SpeechSegment, spans: [SpeakerSpan]) -> [Piece] {
        let s = segment.startSeconds
        let e = segment.endSeconds
        let overlapping = spans.filter { $0.endSeconds > s && $0.startSeconds < e }
            .sorted { $0.startSeconds < $1.startSeconds }
        var runs: [Piece] = []
        for span in overlapping {
            let start = max(s, span.startSeconds)
            let end = min(e, span.endSeconds)
            if let last = runs.last, last.speaker == span.speaker, start - last.end < 0.5 {
                runs[runs.count - 1].end = max(last.end, end)
            } else {
                runs.append(Piece(speaker: span.speaker, start: start, end: end))
            }
        }
        let substantial = runs.filter { $0.end - $0.start >= 0.6 }
        guard !runs.isEmpty else { return [Piece(speaker: "unknown", start: s, end: e)] }
        var kept = substantial.isEmpty
            ? [runs.max { $0.end - $0.start < $1.end - $1.start }!] : substantial
        // adjacent runs of one speaker after dropping short interjections
        var merged: [Piece] = []
        for run in kept {
            if let last = merged.last, last.speaker == run.speaker {
                merged[merged.count - 1].end = run.end
            } else {
                merged.append(run)
            }
        }
        kept = merged
        guard kept.count > 1 else { return [Piece(speaker: kept[0].speaker, start: s, end: e)] }
        kept[0].start = s
        kept[kept.count - 1].end = e
        for i in 0..<(kept.count - 1) {
            let boundary = (kept[i].end + kept[i + 1].start) / 2
            kept[i].end = boundary
            kept[i + 1].start = boundary
        }
        return kept
    }
}
