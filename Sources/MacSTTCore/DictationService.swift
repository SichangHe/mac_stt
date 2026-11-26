import AppKit
import FluidAudio
import Foundation

/// State machine behind `mac-stt serve`. Starting a take never waits for an earlier take's
/// transcription: `stop` clears the active take before it awaits any model work.
public actor DictationService {
    private let options: ServeOptions
    private let engine: Task<any Qwen3Engine, Error>
    private var diarizer: Task<DiarizerModels, Error>?
    private var take: DictationTake?
    private var takeIndex = 0
    private let transcript = SharedTranscript.shared
    /// The server exits after this long with no recording and no command, to free memory and the models.
    static let idleExitSeconds: TimeInterval = 600
    private var lastActivity = Date()

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
        Task.detached { [self] in
            while true {
                try? await Task.sleep(for: .seconds(30))
                await self.exitIfIdle()
            }
        }
    }

    private func exitIfIdle() {
        guard take == nil, !transcript.windowVisible, Date().timeIntervalSince(lastActivity) >= Self.idleExitSeconds else { return }
        Self.log("idle for \(Int(Self.idleExitSeconds)) s; exiting")
        exit(0)
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n".utf8))
    }

    public func handle(_ verb: ControlVerb) async -> String {
        lastActivity = Date()
        defer { lastActivity = Date() }
        do {
            switch verb {
            case .toggle: return take == nil ? try await start() : try await stop()
            case .start: return take == nil ? try await start() : "already recording"
            case .stop: return take == nil ? "not recording" : try await stop()
            case .status: return take == nil ? "idle" : "recording"
            case .show:
                // Per-speaker lines need the diarizer; load it once the window is used.
                if diarizer == nil { diarizer = Qwen3Runtime.diarizerTask(compute: options.model.compute) }
                await MainActor.run { TranscriptWindow.shared.show() }
                return "window shown"
            case .copy: return try copyNew()
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
        let index = transcript.mutate { $0.beginTake() }
        let transcript = self.transcript
        take = try DictationTake(
            input: input, engine: engine, diarizer: diarizer, language: options.model.language,
            onPartial: { text in
                Self.log("partial: \(text)")
                PartialWindow.update(text)
            },
            onTail: { tail in transcript.mutate { $0.setTail(take: index, tail) } },
            onPieces: { pieces in transcript.mutate { $0.update(take: index, pieces: pieces) } })
        takeIndex = index
        await MainActor.run { TranscriptWindow.shared.setRecording(true) }
        PartialWindow.update("")
        Self.log("recording started")
        Earcon.start.play()
        return "recording"
    }

    private func stop() async throws -> String {
        guard let active = take else { return "not recording" }
        take = nil
        let index = takeIndex
        transcript.mutate { $0.setTail(take: index, nil) }
        await MainActor.run { TranscriptWindow.shared.setRecording(false) }
        defer { PartialWindow.update(nil) }
        let result: DictationResult
        do {
            result = try await active.stop()
        } catch {
            transcript.mutate { $0.finish(take: index, pieces: $0.takes[index].pieces) }
            throw error
        }
        transcript.mutate { $0.finish(take: index, pieces: result.pieces) }
        Self.log(
            String(
                format: "speech_seconds=%.1f finalize_seconds=%.3f", result.speechSeconds, result.finalizeSeconds))
        try ResultWriter.write(result.document, options: options.output)
        Earcon.end.play()
        return result.document.rendered
    }

    /// Copies the transcript text not copied before to the clipboard and returns it.
    private func copyNew() throws -> String {
        let text = transcript.mutate { $0.copyNew() }
        guard !text.isEmpty else { return "" }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw OutputError.clipboardUnavailable }
        return text
    }

}
