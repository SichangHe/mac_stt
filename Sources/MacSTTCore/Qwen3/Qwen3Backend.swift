import Foundation

/// Transcribes 16 kHz mono audio with Qwen3-ASR.
public protocol Qwen3Engine: Sendable {
    func transcribe(_ samples: [Float], language: String?) async throws -> String
}

extension Qwen3Engine {
    public func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribe(samples, language: nil)
    }
}

/// Which runtime executes the model.
/// Core ML has the best measured speed, but its int8 stateful decoder compiled for 7+ minutes without finishing
/// on a hosted macOS 15.8 runner, and needs macOS 15 at all. MLX runs on macOS 14 and 15 and uses the GPU.
public enum Qwen3Backend: String, Sendable {
    case coreml
    case mlx

    /// `MAC_STT_BACKEND=coreml|mlx` overrides; otherwise Core ML on macOS 26 or newer, MLX before.
    public static var current: Qwen3Backend {
        if let name = ProcessInfo.processInfo.environment["MAC_STT_BACKEND"], let forced = Qwen3Backend(rawValue: name) {
            return forced
        }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? .coreml : .mlx
    }
}
