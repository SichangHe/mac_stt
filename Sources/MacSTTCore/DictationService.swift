import FluidAudio
import Foundation

/// State machine behind `mac-stt serve`. Starting a take never waits for an earlier take's
/// transcription: `stop` clears the active take before it awaits any model work.
public actor DictationService {
    private let options: ServeOptions
    private let engine: Task<any Qwen3Engine, Error>
    private var diarizer: Task<DiarizerModels, Error>?
    private var take: DictationTake?
    /// The server exits after this long with no recording and no command, to free memory and the models.
    static let idleExitSeconds: TimeInterval = 600
    private var lastActivity = Date()
    /// `transcribe`/`record` jobs from other mac-stt commands now running here.
    private var jobs = 0

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
        guard take == nil, jobs == 0, Date().timeIntervalSince(lastActivity) >= Self.idleExitSeconds else { return }
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

    private func diarizerTask() -> Task<DiarizerModels, Error> {
        if let diarizer { return diarizer }
        let task = Qwen3Runtime.diarizerTask(compute: options.model.compute)
        diarizer = task
        return task
    }

    private func jobStarted() { jobs += 1; lastActivity = Date() }
    private func jobEnded() { jobs -= 1; lastActivity = Date() }

    /// Runs a `transcribe` or `record` job for another mac-stt command on this server's models.
    public nonisolated func job(_ body: Data, fd: Int32) async {
        let connection = JobConnection(fd: fd)
        await jobStarted()
        do {
            let request = try JSONDecoder().decode(JobRequest.self, from: body)
            let result = try await run(request, connection: connection)
            connection.send("D", result)
        } catch {
            Self.log("job error: \(error.localizedDescription)")
            connection.send("E", JobText(text: error.localizedDescription))
        }
        await jobEnded()
    }

    private func run(_ request: JobRequest, connection: JobConnection) async throws -> JobResult {
        let model = options.model
        guard request.variant == model.variant.rawValue, request.compute == model.compute.rawValue else {
            throw ControlError.serverFailed(
                "mac-stt serve runs --model \(model.variant.rawValue) --compute \(model.compute.rawValue); "
                    + "use those, or `mac-stt quit` first so it restarts with yours")
        }
        let diarizer = request.diarize ? diarizerTask() : nil
        let engine = self.engine
        switch request.kind {
        case .transcribe:
            let models = try await diarizer?.value
            let documents = try await ConcurrentProcessor.map(request.paths) { path in
                try await Qwen3Runtime.transcribeFile(
                    path: path, engineTask: engine, diarizer: models, language: request.language)
            }
            var result = JobResult()
            result.files = zip(request.paths, documents).map {
                JobFile(path: $0, rendered: $1.rendered, seconds: $1.processingSeconds)
            }
            return result
        case .record:
            let input: AudioInput
            if let path = request.input {
                input = .file(path: path, speed: request.speed)
            } else {
                try await MicrophonePermission.require()
                input = .microphone
            }
            // P: whole partial text; T: unfinished segment; L: finished segments labeled so far.
            let take = try DictationTake(
                input: input, engine: engine, diarizer: diarizer, language: request.language,
                onPartial: { connection.send("P", JobText(text: $0)) },
                onTail: { connection.send("T", JobText(text: $0)) },
                onPieces: { connection.send("L", $0) })
            // Stop when the client sends a byte or disconnects, or when a file input ends.
            let (signal, trigger) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            Thread.detachNewThread {
                var byte: UInt8 = 0
                _ = read(connection.fd, &byte, 1)
                trigger.yield()
            }
            let inputEnd = request.input == nil ? nil : Task {
                try? await take.waitForInputEnd()
                trigger.yield()
            }
            for await _ in signal { break }
            inputEnd?.cancel()
            let finished = try await take.stop()
            var result = JobResult()
            result.pieces = finished.pieces
            result.rendered = finished.document.rendered
            result.speechSeconds = finished.speechSeconds
            result.finalizeSeconds = finished.finalizeSeconds
            return result
        }
    }


}
