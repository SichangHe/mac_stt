@preconcurrency import CoreML
import Foundation
import MacSTTCore

@main
struct MacSTTMain {
    static func main() async {
        do {
            let command = try CLIParser.parse(Array(CommandLine.arguments.dropFirst()))
            try await run(command)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            FileHandle.standardError.write(Data("run `mac-stt help` for usage\n".utf8))
            exit(2)
        }
    }

    private static func run(_ command: Command) async throws {
        switch command {
        case .help:
            print(usage)
        case .doctor:
            print("platform: \(Hardware.isAppleSilicon ? "Apple Silicon" : "unsupported non-arm64")")
            print("default policy: \(ComputePolicy.ane.explanation)")
            print("configuration claim: ANE eligible, not observed")
            print("placement evidence: `mac-stt profile-model MODEL.mlmodelc` (preferred device per operation)")
            print("runtime evidence: `sudo powermetrics --samplers ane_power -i 200` during transcription")
            try Hardware.requireAppleSilicon()
        case .transcribe(let options):
            guard options.paths.count == 1 || options.output.outputPath == nil else {
                throw MainError.oneOutputForMultipleInputs
            }
            let models = try await TranscriptionModels.load(
                diarization: options.diarize,
                compute: options.compute
            )
            let documents = try await FileTranscriber.transcribe(paths: options.paths, models: models)
            let document: TranscriptDocument
            if documents.count == 1 {
                document = documents[0]
            } else {
                let text = zip(options.paths, documents).map { path, result in
                    "== \(path) ==\n\(result.rendered)"
                }.joined(separator: "\n\n")
                document = TranscriptDocument(text: text)
            }
            try ResultWriter.write(document, options: options.output)
        case .record(let options):
            let document = try await LiveRecorder.record(options: options)
            try ResultWriter.write(document, options: options.output)
        case .profileModels(let paths, let compute):
            print("policy: \(compute.explanation)")
            for report in try await ModelProfiler.profile(paths: paths, compute: compute) {
                print(report.rendered)
            }
            print("claim boundary: this is Core ML's preferred placement plan, not observed runtime execution")
        }
    }
}

private enum MainError: Error, LocalizedError {
    case oneOutputForMultipleInputs

    var errorDescription: String? {
        "--output accepts one input; omit it for a combined multi-file result"
    }
}
