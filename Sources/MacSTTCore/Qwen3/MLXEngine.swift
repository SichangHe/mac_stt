import Foundation
import MLX
import MLXAudioSTT

/// Qwen3-ASR on MLX (Metal GPU), for macOS versions whose Core ML cannot run the Core ML decoder.
/// `MAC_STT_MLX_DEVICE=cpu` forces the CPU, only to measure what the GPU saves.
public actor MLXEngine: Qwen3Engine {
    private static let trace = ProcessInfo.processInfo.environment["MAC_STT_TRACE"] == "1"
    private let model: Qwen3ASRModel

    public static func load(variant: Qwen3Variant) async throws -> MLXEngine {
        let root = try await Qwen3Assets.ensure(variant)
        if ProcessInfo.processInfo.environment["MAC_STT_MLX_DEVICE"] == "cpu" {
            Device.setDefault(device: Device(.cpu))
        }
        return try await MLXEngine(root: root)
    }

    private init(root: URL) async throws {
        model = try await Qwen3ASRModel.fromModelDirectory(root)
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
