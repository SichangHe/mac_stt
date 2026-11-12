import FluidAudio
import Foundation

/// State machine behind `mac-stt serve`. Starting a take never waits for an earlier take's
/// transcription: `stop` clears the active take before it awaits any model work.
public actor DictationService {
    private let options: ServeOptions
    private let engine: Task<any Qwen3Engine, Error>
    private let diarizer: Task<DiarizerModels, Error>?
    private var take: DictationTake?

    public init(options: ServeOptions) {
        self.options = options
        let engine = Qwen3Runtime.engineTask(variant: options.model.variant, compute: options.model.compute)
        self.engine = engine
        diarizer = options.model.diarize ? Qwen3Runtime.diarizerTask(compute: options.model.compute) : nil
        Task.detached {
            let started = Date()
            do {
                _ = try await engine.value.transcribe([Float](repeating: 0, count: 16_000))
                Self.log("models ready in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            } catch {
                Self.log("model load failed: \(error.localizedDescription)")
            }
        }
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n".utf8))
    }

    public func handle(_ verb: ControlVerb) async -> String {
        do {
            switch verb {
            case .toggle: return take == nil ? try await start() : try await stop()
            case .start: return take == nil ? try await start() : "already recording"
            case .stop: return take == nil ? "not recording" : try await stop()
            case .status: return take == nil ? "idle" : "recording"
            case .quit:
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(200))
                    exit(0)
                }
                return "bye"
            }
        } catch {
            Self.log("error: \(error.localizedDescription)")
            return "ERR \(error.localizedDescription)"
        }
    }

    private func start() async throws -> String {
        let input: AudioInput
        if let fake = ProcessInfo.processInfo.environment["MAC_STT_FAKE_MIC"] {
            let speed = Double(ProcessInfo.processInfo.environment["MAC_STT_FAKE_MIC_SPEED"] ?? "") ?? 1
            input = .file(path: fake, speed: speed)
        } else {
            try await MicrophonePermission.require()
            input = .microphone
        }
        take = try DictationTake(
            input: input, engine: engine, diarizer: diarizer, language: options.model.language,
            onPartial: { text in
                Self.log("partial: \(text)")
                PartialWindow.update(text)
            })
        PartialWindow.update("")
        Self.log("recording started")
        Earcon.start.play()
        return "recording"
    }

    private func stop() async throws -> String {
        guard let active = take else { return "not recording" }
        take = nil
        defer { PartialWindow.update(nil) }
        let result = try await active.stop()
        Self.log(
            String(
                format: "speech_seconds=%.1f finalize_seconds=%.3f", result.speechSeconds, result.finalizeSeconds))
        try ResultWriter.write(result.document, options: options.output)
        Earcon.end.play()
        return result.document.rendered
    }

}
