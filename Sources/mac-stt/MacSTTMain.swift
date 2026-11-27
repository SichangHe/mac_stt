@preconcurrency import CoreML
import Foundation
import MacSTTCore

@main
struct MacSTTMain {
    static func main() async {
        do {
            let command = try CLIParser.parse(Array(CommandLine.arguments.dropFirst()))
            try await run(command)
            // Skip C++ static destructors: MLX's Metal state is torn down while its worker thread may still
            // finish a cancelled partial transcription, which segfaulted live dictation at exit on macOS 15.
            fflush(stdout)
            _exit(0)
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
            let server = ControlServer(
                handler: { verb in await service.handle(verb) },
                jobHandler: { body, fd in await service.job(body, fd: fd) })
            try server.start()
            FileHandle.standardError.write(Data("mac-stt serve listening on \(ControlSocket.path)\n".utf8))
            try await Task.sleep(for: .seconds(Double(Int32.max)))
        case .live(let model):
            try await LiveTranscript.run(model: model)
        case .control(let verb):
            print(try await ControlClient.send(verb))
        case .transcribe(let options):
            guard options.paths.count == 1 || options.output.outputPath == nil else {
                throw MainError.oneOutputForMultipleInputs
            }
            // Runs inside `serve` so every command shares one copy of the models.
            var request = JobRequest(kind: .transcribe, model: options.model)
            request.paths = options.paths.map { absolute($0) }
            let result = try await JobClient.run(request, onPartial: { _ in })
            for file in result.files {
                FileHandle.standardError.write(Data(String(format: "%@: processed in %.2f s\n", file.path, file.seconds).utf8))
            }
            let text = result.files.count == 1
                ? result.files[0].rendered
                : zip(options.paths, result.files).map { "== \($0) ==\n\($1.rendered)" }.joined(separator: "\n\n")
            try ResultWriter.write(TranscriptDocument(text: text), options: options.output)
        case .record(let options):
            var request = JobRequest(kind: .record, model: options.model)
            request.input = options.inputPath.map { absolute($0) }
            request.speed = options.inputSpeed
            let interrupt = InterruptWaiter()
            FileHandle.standardError.write(
                Data((options.inputPath == nil ? "recording; press Control-C to finish\n" : "streaming input\n").utf8))
            let result = try await JobClient.run(
                request, stop: { await interrupt.wait() },
                onPartial: { text in FileHandle.standardError.write(Data("\r\u{001B}[2K\(text)".utf8)) })
            FileHandle.standardError.write(
                Data(
                    String(
                        format: "\nspeech_seconds=%.1f finalize_seconds=%.3f\n", result.speechSeconds,
                        result.finalizeSeconds
                    ).utf8))
            try ResultWriter.write(TranscriptDocument(text: result.rendered), options: options.output)
        case .profileModels(let paths, let compute):
            print("policy: \(compute.explanation)")
            for report in try await ModelProfiler.profile(paths: paths, compute: compute) {
                print(report.rendered)
            }
            print("claim boundary: this is Core ML's preferred placement plan, not observed runtime execution")
        }
    }
}

/// `serve` runs from the home directory, so paths sent to it must be absolute.
private func absolute(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
}

private enum MainError: Error, LocalizedError {
    case oneOutputForMultipleInputs

    var errorDescription: String? {
        switch self {
        case .oneOutputForMultipleInputs: "--output accepts one input; omit it for a combined multi-file result"
        }
    }
}
