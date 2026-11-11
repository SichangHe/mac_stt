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
            print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
            print("backend: \(Qwen3Backend.current.rawValue)")
            for variant in Qwen3Variant.allCases {
                print("model qwen3-asr-\(variant.rawValue): \(Qwen3Assets.isComplete(variant) ? "installed" : "not installed (run `mac-stt setup`)")")
            }
            print("control socket: \(ControlSocket.path)")
            print("default policy: \(ComputePolicy.ane.explanation)")
            print("configuration claim: ANE eligible, not observed")
            try Hardware.requireAppleSilicon()
        case .setup(let options):
            let started = Date()
            let engine = Qwen3Runtime.engineTask(variant: options.variant, compute: options.compute)
            let diarizer = Qwen3Runtime.diarizerTask(compute: options.compute)
            let loaded = try await engine.value
            _ = try await diarizer.value
            let load = Date().timeIntervalSince(started)
            let warm = Date()
            _ = try await loaded.transcribe([Float](repeating: 0, count: 16_000))
            print(String(format: "setup complete: models ready in %.1f s, first inference %.2f s", load, Date().timeIntervalSince(warm)))
        case .serve(let options):
            signal(SIGPIPE, SIG_IGN)
            let service = DictationService(options: options)
            let server = ControlServer { verb in await service.handle(verb) }
            try server.start()
            FileHandle.standardError.write(Data("mac-stt serve listening on \(ControlSocket.path)\n".utf8))
            try await Task.sleep(for: .seconds(Double(Int32.max)))
        case .control(let verb):
            print(try await ControlClient.send(verb))
        case .transcribe(let options):
            guard options.paths.count == 1 || options.output.outputPath == nil else {
                throw MainError.oneOutputForMultipleInputs
            }
            let model = options.model
            let engine = Qwen3Runtime.engineTask(variant: model.variant, compute: model.compute)
            let diarizer = model.diarize ? Qwen3Runtime.diarizerTask(compute: model.compute) : nil
            let diarizerModels = try await diarizer?.value
            let documents = try await ConcurrentProcessor.map(options.paths) { path in
                try await Qwen3Runtime.transcribeFile(
                    path: path, engineTask: engine, diarizer: diarizerModels, language: model.language)
            }
            let document: TranscriptDocument
            if documents.count == 1 {
                document = documents[0]
            } else {
                let text = zip(options.paths, documents).map { path, result in
                    "== \(path) ==\n\(result.rendered)"
                }.joined(separator: "\n\n")
                document = TranscriptDocument(text: text)
            }
            for (path, result) in zip(options.paths, documents) {
                FileHandle.standardError.write(
                    Data(String(format: "%@: processed in %.2f s\n", path, result.processingSeconds).utf8))
            }
            try ResultWriter.write(document, options: options.output)
        case .record(let options):
            let model = options.model
            let engine = Qwen3Runtime.engineTask(variant: model.variant, compute: model.compute)
            let diarizer = model.diarize ? Qwen3Runtime.diarizerTask(compute: model.compute) : nil
            let input: AudioInput
            if let path = options.inputPath {
                input = .file(path: path, speed: options.inputSpeed)
            } else {
                try await MicrophonePermission.require()
                input = .microphone
            }
            let interrupt = InterruptWaiter()
            let take = try DictationTake(
                input: input, engine: engine, diarizer: diarizer, language: model.language,
                onPartial: { text in
                    FileHandle.standardError.write(Data("\r\u{001B}[2K\(text)".utf8))
                })
            FileHandle.standardError.write(
                Data((options.inputPath == nil ? "recording; press Control-C to finish\n" : "streaming input\n").utf8))
            if options.inputPath != nil {
                Task {
                    try? await take.waitForInputEnd()
                    interrupt.trigger()
                }
            }
            await interrupt.wait()
            let result = try await take.stop()
            FileHandle.standardError.write(
                Data(
                    String(
                        format: "\nspeech_seconds=%.1f finalize_seconds=%.3f\n", result.speechSeconds,
                        result.finalizeSeconds
                    ).utf8))
            try ResultWriter.write(result.document, options: options.output)
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
        switch self {
        case .oneOutputForMultipleInputs: "--output accepts one input; omit it for a combined multi-file result"
        }
    }
}
