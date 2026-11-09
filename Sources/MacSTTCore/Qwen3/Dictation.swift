@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation

public enum AudioInput: Sendable {
    case microphone
    case file(path: String, speed: Double)
}

public struct DictationResult: Sendable {
    public let document: TranscriptDocument
    public let speechSeconds: Double
    /// Time from the last captured sample to the final text.
    public let finalizeSeconds: Double
}

/// One dictation take: capture, 16 kHz conversion, streaming transcription, optional diarization.
/// The capture consumer only copies audio, so recording is never blocked by inference.
@available(macOS 15.0, *)
public final class DictationTake: @unchecked Sendable {
    private let engine: Task<Qwen3Engine, Error>
    private let session: Qwen3Session
    private let capture: MicrophoneCapture?
    private let consumer: Task<Void, Error>
    private let diarization: BackgroundStreamWorker<[Float], [SpeakerSpan]>?
    private let language: String?

    public init(
        input: AudioInput,
        engine: Task<Qwen3Engine, Error>,
        diarizer: Task<DiarizerModels, Error>?,
        language: String?,
        onPartial: (@Sendable (String) -> Void)?
    ) throws {
        self.engine = engine
        self.language = language
        session = Qwen3Session(
            engine: engine, language: language, keepAudio: diarizer != nil, onPartial: onPartial)
        let stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>
        switch input {
        case .microphone:
            let microphone = MicrophoneCapture()
            capture = microphone
            stream = try microphone.start()
        case .file(let path, let speed):
            capture = nil
            stream = try AudioFileBufferReader.stream(path: path, speed: speed)
        }
        let worker = diarizer.map { models in
            BackgroundStreamWorker<[Float], [SpeakerSpan]>(
                capacity: 360, overflowError: RecorderError.diarizationOverrun
            ) { chunks in
                let incremental = IncrementalDiarizer(models: try await models.value)
                for try await chunk in chunks { try incremental.process(chunk) }
                return incremental.spans
            }
        }
        diarization = worker
        let session = self.session
        consumer = Task {
            let converter = AudioConverter()
            var chunker = DiarizationChunker()
            for try await buffer in stream {
                let samples = try converter.resampleBuffer(buffer)
                session.append(samples)
                if let worker {
                    for chunk in chunker.append(samples) { _ = worker.send(chunk) }
                }
            }
            if let worker, let tail = chunker.finish() { _ = worker.send(tail) }
        }
    }

    /// Completes when a file input has been fully consumed (never for a live microphone).
    public func waitForInputEnd() async throws { try await consumer.value }

    public func stop() async throws -> DictationResult {
        capture?.stop()
        try await consumer.value
        let ended = Date()
        let speech = Double(session.samplesReceived) / 16_000
        let segments = try await session.finish()
        let document: TranscriptDocument
        if let diarization {
            let spans = try await diarization.finish()
            document = try await SpeakerLabeler.document(
                segments: segments, spans: spans, audio: session.recordedAudio(),
                engine: try await engine.value, language: language)
        } else {
            document = TranscriptDocument(text: segments.map(\.text).joined(separator: " "))
        }
        return DictationResult(
            document: document, speechSeconds: speech, finalizeSeconds: Date().timeIntervalSince(ended))
    }
}

@available(macOS 15.0, *)
public enum Qwen3Runtime {
    public static func engineTask(variant: Qwen3Variant, compute: ComputePolicy) -> Task<Qwen3Engine, Error> {
        Task.detached(priority: .userInitiated) { try await Qwen3Engine.load(variant: variant, compute: compute) }
    }

    public static func diarizerTask(compute: ComputePolicy) -> Task<DiarizerModels, Error> {
        Task.detached(priority: .userInitiated) {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = compute.mlComputeUnits
            return try await DiarizerModels.downloadIfNeeded(configuration: configuration)
        }
    }

    /// Offline path for files: the same segmenter, run as fast as the model allows.
    public static func transcribeFile(
        path: String, engineTask: Task<Qwen3Engine, Error>,
        diarizer: DiarizerModels?, language: String?
    ) async throws -> TranscriptDocument {
        let engine = try await engineTask.value
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw TranscriberError.fileMissing(path)
        }
        let started = Date()
        let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: expanded))
        let session = Qwen3Session(engine: engineTask, language: language, keepAudio: false)
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + 16_000)
            session.append(Array(samples[index..<end]))
            index = end
        }
        let segments = try await session.finish()
        var document: TranscriptDocument
        if let diarizer {
            let manager = DiarizerManager()
            manager.initialize(models: diarizer)
            let result = try manager.performCompleteDiarization(samples)
            let spans = result.segments.map {
                SpeakerSpan(
                    speaker: $0.speakerId, startSeconds: Double($0.startTimeSeconds),
                    endSeconds: Double($0.endTimeSeconds), quality: $0.qualityScore)
            }
            document = try await SpeakerLabeler.document(
                segments: segments, spans: spans, audio: samples, engine: engine, language: language)
        } else {
            document = TranscriptDocument(text: segments.map(\.text).joined(separator: " "))
        }
        document = TranscriptDocument(
            text: document.text, lines: document.lines, processingSeconds: Date().timeIntervalSince(started))
        return document
    }
}
