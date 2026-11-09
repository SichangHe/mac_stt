import Foundation

public struct SpeechSegment: Sendable, Equatable {
    public let startSample: Int
    public let endSample: Int
    public let text: String
    public var startSeconds: Double { Double(startSample) / 16_000 }
    public var endSeconds: Double { Double(endSample) / 16_000 }
}

/// Streaming front end. `append` never waits on inference: it only copies samples and starts
/// background work. Audio is committed as a segment at a pause (after 8 s) or by 30 s, so the
/// work left when recording stops is bounded by one segment regardless of total length.
@available(macOS 15.0, *)
public final class Qwen3Session: @unchecked Sendable {
    private static let rate = 16_000
    private static let maxSegment = 30 * rate
    private static let pauseMinimum = 8 * rate
    private static let partialInterval: TimeInterval = 1.5

    private let engine: Task<Qwen3Engine, Error>
    private let language: String?
    private let keepAudio: Bool
    private let onPartial: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var pending: [Float] = []
    private var pendingStart = 0
    private var all: [Float] = []
    private var tasks: [Task<SpeechSegment, Error>] = []
    private var finished: [Int: String] = [:]
    private var noiseFloor: Float = 0.05
    private var partialTask: Task<Void, Never>?
    private var lastPartial = Date.distantPast
    private var total = 0

    public init(
        engine: Task<Qwen3Engine, Error>, language: String?, keepAudio: Bool,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) {
        self.engine = engine
        self.language = language
        self.keepAudio = keepAudio
        self.onPartial = onPartial
    }

    public var samplesReceived: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    public func append(_ samples: [Float]) {
        lock.lock()
        pending.append(contentsOf: samples)
        total += samples.count
        if keepAudio { all.append(contentsOf: samples) }
        updateNoiseFloor(samples)
        while let cut = nextCut() { commit(upTo: cut) }
        let wantsPartial =
            onPartial != nil && partialTask == nil && pending.count >= Self.rate
            && Date().timeIntervalSince(lastPartial) >= Self.partialInterval
        if wantsPartial { startPartial() }
        lock.unlock()
    }

    /// Flushes the tail, waits for every segment, and returns them in order.
    public func finish() async throws -> [SpeechSegment] {
        lock.lock()
        let running = partialTask
        partialTask = nil
        running?.cancel()
        if pending.count >= Self.rate / 4 { commit(upTo: pending.count) }
        let work = tasks
        lock.unlock()
        var segments: [SpeechSegment] = []
        for task in work {
            let segment = try await task.value
            if !segment.text.isEmpty { segments.append(segment) }
        }
        return segments
    }

    public func recordedAudio() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }

    // MARK: locked helpers

    private func updateNoiseFloor(_ samples: [Float]) {
        let frame = Self.rate / 10
        var index = 0
        while index + frame <= samples.count {
            let rms = Self.rms(samples[index..<(index + frame)])
            noiseFloor = min(noiseFloor, max(rms, 1e-4))
            index += frame
        }
    }

    private static func rms(_ slice: ArraySlice<Float>) -> Float {
        guard !slice.isEmpty else { return 0 }
        var sum: Float = 0
        for value in slice { sum += value * value }
        return (sum / Float(slice.count)).squareRoot()
    }

    private func nextCut() -> Int? {
        if pending.count >= Self.maxSegment {
            // Quietest 50 ms frame in the last 8 s of a 30 s window.
            let frame = Self.rate / 20
            var best = Float.infinity
            var cut = Self.maxSegment
            var start = Self.maxSegment - 8 * Self.rate
            while start + frame <= Self.maxSegment {
                let value = Self.rms(pending[start..<(start + frame)])
                if value < best {
                    best = value
                    cut = start + frame / 2
                }
                start += frame
            }
            return cut
        }
        if pending.count >= Self.pauseMinimum {
            let tail = Self.rate / 2
            let threshold = max(0.006, noiseFloor * 3)
            if Self.rms(pending[(pending.count - tail)...]) < threshold { return pending.count }
        }
        return nil
    }

    private func commit(upTo cut: Int) {
        let audio = Array(pending[0..<cut])
        pending.removeFirst(cut)
        let start = pendingStart
        pendingStart += cut
        partialTask?.cancel()
        partialTask = nil
        let index = tasks.count
        let engine = self.engine
        let language = self.language
        tasks.append(
            Task.detached(priority: .userInitiated) { [weak self] in
                let text = try await engine.value.transcribe(audio, language: language)
                self?.recordFinished(index, text)
                return SpeechSegment(startSample: start, endSample: start + audio.count, text: text)
            })
    }

    private func recordFinished(_ index: Int, _ text: String) {
        lock.lock()
        finished[index] = text
        lock.unlock()
    }

    private func startPartial() {
        lastPartial = Date()
        let snapshot = pending
        let done = finished.keys.sorted().compactMap { finished[$0] }.filter { !$0.isEmpty }
        let engine = self.engine
        let language = self.language
        let callback = onPartial
        partialTask = Task.detached(priority: .utility) { [weak self] in
            if let text = try? await engine.value.transcribe(snapshot, language: language), !Task.isCancelled {
                callback?((done + [text]).joined(separator: " "))
            }
            self?.clearPartial()
        }
    }

    private func clearPartial() {
        lock.lock()
        partialTask = nil
        lock.unlock()
    }
}
