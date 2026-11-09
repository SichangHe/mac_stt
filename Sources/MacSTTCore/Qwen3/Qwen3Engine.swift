@preconcurrency import CoreML
import Foundation

public enum Qwen3Error: Error, LocalizedError {
    case badAsset(String)
    case unsupportedLanguage(String)
    case promptTooLong(Int)
    case badOutput(String)

    public var errorDescription: String? {
        switch self {
        case .badAsset(let what): "invalid Qwen3-ASR asset: \(what)"
        case .unsupportedLanguage(let code): "unsupported language code: \(code)"
        case .promptTooLong(let n): "audio segment too long for the decoder cache (\(n) rows)"
        case .badOutput(let what): "unexpected model output: \(what)"
        }
    }
}

struct Qwen3Config: Decodable, Sendable {
    struct Language: Decodable, Sendable {
        let name: String
        let ids: [Int]
    }
    let max: Int
    let windowFrames: Int
    let windowTokens: Int
    let chunkFrames: Int
    let hidden: Int
    let split: Int
    let vocab: Int
    let prefix: [Int]
    let suffix: [Int]
    let eos: [Int]
    let asrText: Int
    let languages: [String: Language]
}

/// Qwen3-ASR on Core ML: encoder on the Neural Engine, int8 decoder with Core ML state on the GPU.
/// The actor serializes use of the single shared KV-cache state.
@available(macOS 15.0, *)
public actor Qwen3Engine {
    private static let masked: Float16 = -1e4
    private let config: Qwen3Config
    private let tokenizer: Qwen3Tokenizer
    private let mel: Qwen3Mel
    private let encoder: MLModel
    private let prefill: MLModel
    private let stepModel: MLModel
    private let state: MLState
    private let embeddings: Data
    private let scales: [Float]
    private let invFrequency: [Double]

    public static func load(variant: Qwen3Variant = .large, compute: ComputePolicy = .ane) async throws -> Qwen3Engine {
        try Hardware.requireAppleSilicon()
        let root = try await Qwen3Assets.ensure(variant)
        return try Qwen3Engine(root: root, compute: compute)
    }

    private init(root: URL, compute: ComputePolicy) throws {
        let spec = try Data(contentsOf: root.appendingPathComponent("speakey.json"))
        config = try JSONDecoder().decode(Qwen3Config.self, from: spec)
        tokenizer = try Qwen3Tokenizer(vocabURL: root.appendingPathComponent("vocab.json"))
        mel = try Qwen3Mel(filterURL: root.appendingPathComponent("mel.bin"))
        embeddings = try Data(contentsOf: root.appendingPathComponent("embeddings.i8"), options: .alwaysMapped)
        let scaleData = try Data(contentsOf: root.appendingPathComponent("embeddings.scale"))
        scales = scaleData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard embeddings.count == config.vocab * config.hidden, scales.count == config.vocab else {
            throw Qwen3Error.badAsset("embedding table size")
        }
        func progress(_ message: String) {
            FileHandle.standardError.write(Data("[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n".utf8))
        }
        progress("loading encoder (\(compute.rawValue))")
        let encoderConfiguration = MLModelConfiguration()
        encoderConfiguration.computeUnits = compute.mlComputeUnits
        encoder = try MLModel(
            contentsOf: root.appendingPathComponent("encoder.mlmodelc"), configuration: encoderConfiguration)
        progress("encoder loaded; loading decoder")
        let decoderConfiguration = MLModelConfiguration()
        decoderConfiguration.computeUnits = compute == .ane ? .cpuAndGPU : compute.mlComputeUnits
        let decoderURL = root.appendingPathComponent("decoder.mlmodelc")
        decoderConfiguration.functionName = "main"
        prefill = try MLModel(contentsOf: decoderURL, configuration: decoderConfiguration)
        decoderConfiguration.functionName = "step"
        stepModel = try MLModel(contentsOf: decoderURL, configuration: decoderConfiguration)
        progress("decoder loaded")
        state = prefill.makeState()
        invFrequency = (0..<64).map { pow(1_000_000.0, -Double($0) / 64.0) }
    }

    public nonisolated static let sampleRate = 16_000

    /// Transcribes up to about 30 seconds of 16 kHz mono audio.
    public func transcribe(_ samples: [Float], language: String? = nil) throws -> String {
        let features = mel.logMel(samples)
        guard features.frames >= 20 else { return "" }
        let (audio, tokenCount) = try encode(features.values, frames: features.frames)
        let ids = try generate(audio: audio, tokenCount: tokenCount, language: language)
        let body: ArraySlice<Int>
        if let marker = ids.firstIndex(of: config.asrText) {
            body = ids[(marker + 1)...]
        } else {
            body = ids[...]
        }
        return tokenizer.decode(Array(body)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: encoder

    private func encode(_ values: [Float], frames: Int) throws -> ([Float16], Int) {
        let hidden = config.hidden
        var rows: [Float16] = []
        var total = 0
        for start in stride(from: 0, to: frames, by: config.windowFrames) {
            try Task.checkCancellation()
            let n = min(config.windowFrames, frames - start)
            let tokens = (n / config.chunkFrames) * 13 + (n % config.chunkFrames == 0 ? 0 : (n % config.chunkFrames + 7) / 8)
            let input = try MLMultiArray(shape: [1, 128, NSNumber(value: config.windowFrames)], dataType: .float16)
            let inputPointer = input.dataPointer.assumingMemoryBound(to: Float16.self)
            inputPointer.update(repeating: 0, count: 128 * config.windowFrames)
            for t in 0..<n {
                for m in 0..<128 { inputPointer[m * config.windowFrames + t] = Float16(values[(start + t) * 128 + m]) }
            }
            let mask = try MLMultiArray(shape: [1, 1, 1, NSNumber(value: config.windowTokens)], dataType: .float16)
            let maskPointer = mask.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<config.windowTokens { maskPointer[i] = i < tokens ? 0 : Self.masked }
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "mel": MLFeatureValue(multiArray: input), "mask": MLFeatureValue(multiArray: mask),
            ])
            let output = try encoder.prediction(from: provider)
            guard let audio = output.featureValue(for: "audio")?.multiArrayValue else {
                throw Qwen3Error.badOutput("encoder audio")
            }
            let pointer = audio.dataPointer.assumingMemoryBound(to: Float16.self)
            let rowStride = audio.strides[1].intValue
            let columnStride = audio.strides[2].intValue
            for t in 0..<tokens {
                for j in 0..<hidden { rows.append(pointer[t * rowStride + j * columnStride]) }
            }
            total += tokens
        }
        return (rows, total)
    }

    // MARK: decoder

    private func embed(_ token: Int, into destination: UnsafeMutablePointer<Float16>) {
        let hidden = config.hidden
        let scale = scales[token]
        embeddings.withUnsafeBytes { raw in
            let table = raw.bindMemory(to: Int8.self)
            for j in 0..<hidden { destination[j] = Float16(Float(table[token * hidden + j]) * scale) }
        }
    }

    private func rope(position: Int, cos cosine: UnsafeMutablePointer<Float16>, sin sine: UnsafeMutablePointer<Float16>) {
        for i in 0..<64 {
            let angle = Double(position) * invFrequency[i]
            let c = Float16(Foundation.cos(angle))
            let s = Float16(Foundation.sin(angle))
            cosine[i] = c
            cosine[i + 64] = c
            sine[i] = s
            sine[i + 64] = s
        }
    }

    private func pick(_ output: MLFeatureProvider) throws -> Int {
        guard let vals = output.featureValue(for: "vals")?.multiArrayValue,
            let idx = output.featureValue(for: "idx")?.multiArrayValue
        else { throw Qwen3Error.badOutput("decoder vals/idx") }
        var best = -Float.infinity
        var bestPart = 0
        for part in 0..<config.split {
            let key = [0, 0, NSNumber(value: part)] as [NSNumber]
            let value = vals[key].floatValue
            if value > best {
                best = value
                bestPart = part
            }
        }
        let local = idx[[0, 0, NSNumber(value: bestPart)] as [NSNumber]].intValue
        return local + bestPart * (config.vocab / config.split)
    }

    private func generate(audio: [Float16], tokenCount: Int, language: String?) throws -> [Int] {
        let hidden = config.hidden
        let cache = config.max
        var forced: [Int] = []
        if let language {
            guard let entry = config.languages[language] else { throw Qwen3Error.unsupportedLanguage(language) }
            forced = entry.ids
        }
        let length = config.prefix.count + tokenCount + config.suffix.count + forced.count
        guard length + 8 < cache else { throw Qwen3Error.promptTooLong(length) }

        let embeds = try MLMultiArray(shape: [1, NSNumber(value: length), NSNumber(value: hidden)], dataType: .float16)
        let embedPointer = embeds.dataPointer.assumingMemoryBound(to: Float16.self)
        var row = 0
        for token in config.prefix {
            embed(token, into: embedPointer + row * hidden)
            row += 1
        }
        audio.withUnsafeBufferPointer { source in
            (embedPointer + row * hidden).update(from: source.baseAddress!, count: tokenCount * hidden)
        }
        row += tokenCount
        for token in config.suffix + forced {
            embed(token, into: embedPointer + row * hidden)
            row += 1
        }
        let place = try MLMultiArray(shape: [1, 1, NSNumber(value: cache), NSNumber(value: length)], dataType: .float16)
        let placePointer = place.dataPointer.assumingMemoryBound(to: Float16.self)
        placePointer.update(repeating: 0, count: cache * length)
        let cosine = try MLMultiArray(shape: [1, NSNumber(value: length), 128], dataType: .float16)
        let sine = try MLMultiArray(shape: [1, NSNumber(value: length), 128], dataType: .float16)
        let mask = try MLMultiArray(shape: [1, 1, NSNumber(value: length), NSNumber(value: cache)], dataType: .float16)
        let maskPointer = mask.dataPointer.assumingMemoryBound(to: Float16.self)
        maskPointer.update(repeating: Self.masked, count: length * cache)
        for s in 0..<length {
            placePointer[s * length + s] = 1
            rope(
                position: s, cos: cosine.dataPointer.assumingMemoryBound(to: Float16.self) + s * 128,
                sin: sine.dataPointer.assumingMemoryBound(to: Float16.self) + s * 128)
            for r in 0...s { maskPointer[s * cache + r] = 0 }
        }
        let select = try MLMultiArray(shape: [1, 1, NSNumber(value: length)], dataType: .float16)
        let selectPointer = select.dataPointer.assumingMemoryBound(to: Float16.self)
        selectPointer.update(repeating: 0, count: length)
        selectPointer[length - 1] = 1
        let first = try MLDictionaryFeatureProvider(dictionary: [
            "embeds": MLFeatureValue(multiArray: embeds), "place": MLFeatureValue(multiArray: place),
            "cos": MLFeatureValue(multiArray: cosine), "sin": MLFeatureValue(multiArray: sine),
            "mask": MLFeatureValue(multiArray: mask), "sel": MLFeatureValue(multiArray: select),
        ])
        var token = try pick(try prefill.prediction(from: first, using: state))

        // Single-token step arrays are reused across steps.
        let stepEmbeds = try MLMultiArray(shape: [1, 1, NSNumber(value: hidden)], dataType: .float16)
        let stepPlace = try MLMultiArray(shape: [1, 1, NSNumber(value: cache), 1], dataType: .float16)
        let stepCos = try MLMultiArray(shape: [1, 1, 128], dataType: .float16)
        let stepSin = try MLMultiArray(shape: [1, 1, 128], dataType: .float16)
        let stepMask = try MLMultiArray(shape: [1, 1, 1, NSNumber(value: cache)], dataType: .float16)
        let stepSelect = try MLMultiArray(shape: [1, 1, 1], dataType: .float16)
        let placeStep = stepPlace.dataPointer.assumingMemoryBound(to: Float16.self)
        let maskStep = stepMask.dataPointer.assumingMemoryBound(to: Float16.self)
        placeStep.update(repeating: 0, count: cache)
        maskStep.update(repeating: Self.masked, count: cache)
        for r in 0..<length { maskStep[r] = 0 }
        stepSelect.dataPointer.assumingMemoryBound(to: Float16.self)[0] = 1
        let stepProvider = try MLDictionaryFeatureProvider(dictionary: [
            "embeds": MLFeatureValue(multiArray: stepEmbeds), "place": MLFeatureValue(multiArray: stepPlace),
            "cos": MLFeatureValue(multiArray: stepCos), "sin": MLFeatureValue(multiArray: stepSin),
            "mask": MLFeatureValue(multiArray: stepMask), "sel": MLFeatureValue(multiArray: stepSelect),
        ])
        var generated: [Int] = []
        var position = length
        while !config.eos.contains(token), position < cache - 1, generated.count < 600 {
            try Task.checkCancellation()
            generated.append(token)
            embed(token, into: stepEmbeds.dataPointer.assumingMemoryBound(to: Float16.self))
            if position > length { placeStep[position - 1] = 0 }
            placeStep[position] = 1
            maskStep[position] = 0
            rope(
                position: position, cos: stepCos.dataPointer.assumingMemoryBound(to: Float16.self),
                sin: stepSin.dataPointer.assumingMemoryBound(to: Float16.self))
            token = try pick(try stepModel.prediction(from: stepProvider, using: state))
            position += 1
        }
        return generated
    }
}
