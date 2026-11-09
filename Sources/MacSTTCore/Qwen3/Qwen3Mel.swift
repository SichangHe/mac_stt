import Accelerate
import Foundation

/// Whisper-style 128-bin log-mel front end (n_fft 400, hop 160), matched to the Core ML export.
final class Qwen3Mel: @unchecked Sendable {
    static let fft = 400
    static let hop = 160
    static let bins = 201
    static let mels = 128

    private let filters: [Float]  // [mel][bin]
    private let dft: [Float]  // [400][402]: windowed cos then windowed -sin

    init(filterURL: URL) throws {
        let data = try Data(contentsOf: filterURL)
        guard data.count == Self.mels * Self.bins * 4 else { throw Qwen3Error.badAsset("mel.bin size") }
        filters = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var matrix = [Float](repeating: 0, count: Self.fft * 2 * Self.bins)
        for n in 0..<Self.fft {
            let window = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(Self.fft)))
            for k in 0..<Self.bins {
                let angle = 2 * Double.pi * Double((k * n) % Self.fft) / Double(Self.fft)
                matrix[n * 2 * Self.bins + k] = window * Float(cos(angle))
                matrix[n * 2 * Self.bins + Self.bins + k] = -window * Float(sin(angle))
            }
        }
        dft = matrix
    }

    /// Returns row-major [frame][128] and the frame count (`samples.count / 160`).
    func logMel(_ samples: [Float]) -> (values: [Float], frames: Int) {
        let n = samples.count
        let frames = n / Self.hop
        guard frames > 0, n > 1 else { return ([], 0) }
        let pad = Self.fft / 2
        func sample(_ index: Int) -> Float {
            var i = index
            if i < 0 { i = -i }
            if i >= n { i = 2 * (n - 1) - i }
            return samples[min(max(i, 0), n - 1)]
        }
        var framed = [Float](repeating: 0, count: frames * Self.fft)
        for f in 0..<frames {
            let base = f * Self.hop - pad
            for j in 0..<Self.fft { framed[f * Self.fft + j] = sample(base + j) }
        }
        let width = 2 * Self.bins
        var spectrum = [Float](repeating: 0, count: frames * width)
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(frames), Int32(width), Int32(Self.fft),
            1, framed, Int32(Self.fft), dft, Int32(width), 0, &spectrum, Int32(width))
        var power = [Float](repeating: 0, count: frames * Self.bins)
        for f in 0..<frames {
            for k in 0..<Self.bins {
                let re = spectrum[f * width + k]
                let im = spectrum[f * width + Self.bins + k]
                power[f * Self.bins + k] = re * re + im * im
            }
        }
        var mel = [Float](repeating: 0, count: frames * Self.mels)
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasTrans, Int32(frames), Int32(Self.mels), Int32(Self.bins),
            1, power, Int32(Self.bins), filters, Int32(Self.bins), 0, &mel, Int32(Self.mels))
        var floorValue: Float = 1e-10
        vDSP_vthr(mel, 1, &floorValue, &mel, 1, vDSP_Length(mel.count))
        var count = Int32(mel.count)
        vvlog10f(&mel, mel, &count)
        var peak: Float = 0
        vDSP_maxv(mel, 1, &peak, vDSP_Length(mel.count))
        var lower = peak - 8
        vDSP_vthr(mel, 1, &lower, &mel, 1, vDSP_Length(mel.count))
        var four: Float = 4
        var quarter: Float = 0.25
        vDSP_vsadd(mel, 1, &four, &mel, 1, vDSP_Length(mel.count))
        vDSP_vsmul(mel, 1, &quarter, &mel, 1, vDSP_Length(mel.count))
        return (mel, frames)
    }
}
