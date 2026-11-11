import Foundation
import MLX
import MLXAudioSTT

/// Qwen3-ASR on MLX (Metal GPU), for macOS versions whose Core ML cannot run the Core ML decoder.
/// `MAC_STT_MLX_DEVICE=cpu` forces the CPU, only to measure what the GPU saves.
/// All MLX work runs on one dedicated thread: Metal command buffers in MLX are per thread, and evaluating from
/// the different threads a plain actor hops between aborted live dictation on macOS 15 with
/// `failed assertion _status < MTLCommandBufferStatusCommitted`.
public actor MLXEngine: Qwen3Engine {
    nonisolated public var unownedExecutor: UnownedSerialExecutor { MLXThread.shared.asUnownedSerialExecutor() }
    private static let trace = ProcessInfo.processInfo.environment["MAC_STT_TRACE"] == "1"

    public static func load(variant: Qwen3Variant) async throws -> MLXEngine {
        let root = try await Qwen3Assets.ensure(variant)
        if ProcessInfo.processInfo.environment["MAC_STT_MLX_DEVICE"] == "cpu" {
            Device.setDefault(device: Device(.cpu))
        }
        let engine = MLXEngine()
        try await engine.loadModel(root: root)
        return engine
    }

    private var loaded: Qwen3ASRModel?
    private var model: Qwen3ASRModel { loaded! }

    private func loadModel(root: URL) async throws {
        loaded = try await Qwen3ASRModel.fromModelDirectory(root)
        FileHandle.standardError.write(Data("mlx device: \(Device.defaultDevice())\n".utf8))
    }

    /// Transcribes 16 kHz mono audio of up to about 30 seconds.
    public func transcribe(_ samples: [Float], language: String?) throws -> String {
        guard samples.count >= 3_200 else { return "" }
        let started = Date()
        let output = model.generate(
            audio: MLXArray(samples), generationParameters: STTGenerateParameters(language: language))
        if Self.trace {
            FileHandle.standardError.write(
                Data(
                    String(
                        format: "trace: mlx %@ audio %.1fs took %.0f ms, peak memory %d MB\n",
                        "\(Device.defaultDevice())", Double(samples.count) / 16_000,
                        Date().timeIntervalSince(started) * 1000, Memory.peakMemory / 1_000_000
                    ).utf8))
        }
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A serial executor that runs every job on the same thread.
final class MLXThread: Thread, SerialExecutor, @unchecked Sendable {
    static let shared: MLXThread = {
        let thread = MLXThread()
        thread.name = "mac-stt.mlx"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 16 << 20
        thread.start()
        return thread
    }()

    private let condition = NSCondition()
    private var jobs: [UnownedJob] = []

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        condition.lock()
        jobs.append(unowned)
        condition.signal()
        condition.unlock()
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }

    override func main() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            job.runSynchronously(on: asUnownedSerialExecutor())
        }
    }
}
