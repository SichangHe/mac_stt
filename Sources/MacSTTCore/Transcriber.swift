@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation

public enum TranscriberError: Error, LocalizedError {
    case fileMissing(String)

    public var errorDescription: String? {
        switch self {
        case .fileMissing(let path): "input file does not exist: \(path)"
        }
    }
}

public struct TranscriptionModels: Sendable {
    let asr: AsrModels
    let diarizer: DiarizerModels?

    public static func load(diarization: Bool, compute: ComputePolicy) async throws -> Self {
        try Hardware.requireAppleSilicon()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = compute.mlComputeUnits
        let diarizerConfiguration = MLModelConfiguration()
        diarizerConfiguration.computeUnits = compute.mlComputeUnits
        let asr = try await AsrModels.downloadAndLoad(
            configuration: configuration,
            version: .v3,
            encoderComputeUnits: compute.mlComputeUnits
        )
        if diarization {
            let diarizer = try await DiarizerModels.downloadIfNeeded(
                configuration: diarizerConfiguration
            )
            return TranscriptionModels(asr: asr, diarizer: diarizer)
        }
        return TranscriptionModels(asr: asr, diarizer: nil)
    }
}

public enum FileTranscriber {
    // 🧑 “processing one transcription must not block ... starting another”
    public static func transcribe(
        paths: [String],
        models: TranscriptionModels
    ) async throws -> [TranscriptDocument] {
        try await ConcurrentProcessor.map(paths) { path in
            try await transcribe(path: path, models: models)
        }
    }

    private static func transcribe(
        path: String,
        models: TranscriptionModels
    ) async throws -> TranscriptDocument {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw TranscriberError.fileMissing(path)
        }
        let url = URL(fileURLWithPath: expanded)
        let manager = AsrManager(config: .default, models: models.asr)
        var decoder = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(url, decoderState: &decoder)
        guard let diarizerModels = models.diarizer else {
            return TranscriptDocument(text: result.text, processingSeconds: result.processingTime)
        }
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(url)
        let diarizer = DiarizerManager()
        diarizer.initialize(models: diarizerModels)
        let diarization = try diarizer.performCompleteDiarization(samples)
        let spans = diarization.segments.map {
            SpeakerSpan(
                speaker: $0.speakerId,
                startSeconds: Double($0.startTimeSeconds),
                endSeconds: Double($0.endTimeSeconds),
                quality: $0.qualityScore
            )
        }
        return TranscriptAssembler.assemble(
            text: result.text,
            tokenTimings: result.tokenTimings ?? [],
            speakerSpans: spans,
            processingSeconds: result.processingTime
        )
    }
}
