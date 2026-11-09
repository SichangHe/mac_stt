@preconcurrency import AVFoundation
import Darwin
import FluidAudio
import Foundation

public final class MicrophoneCapture: @unchecked Sendable {
    private static let bufferedFrames = 64
    private let engine = AVAudioEngine()
    private let buffers = BoundedAsyncStream<AVAudioPCMBuffer>(
        capacity: bufferedFrames,
        overflowError: RecorderError.captureOverrun
    )

    public init() {}

    public func start() throws -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let copy = buffer.detachedCopy() else { return }
            guard let result = self?.buffers.yield(copy) else { return }
            guard result != .terminated else { return }
            guard result == .enqueued else {
                FileHandle.standardError.write(
                    Data("\naudio overrun: inference could not keep up; stopping\n".utf8)
                )
                raise(SIGINT)
                return
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            buffers.finish()
            throw error
        }
        return buffers.stream
    }

    public func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        buffers.finish()
    }
}

public enum MicrophonePermission {
    public static func require() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw RecorderError.microphonePermissionDenied
            }
        case .denied, .restricted:
            throw RecorderError.microphonePermissionDenied
        @unknown default:
            throw RecorderError.microphonePermissionDenied
        }
    }
}

public enum TranscriberError: Error, LocalizedError {
    case fileMissing(String)

    public var errorDescription: String? {
        switch self {
        case .fileMissing(let path): "input file does not exist: \(path)"
        }
    }
}

public enum RecorderError: Error, LocalizedError {
    case fileMissing(String)
    case invalidAudioFile
    case microphonePermissionDenied
    case captureOverrun
    case diarizationOverrun
    case diarizationStopped

    public var errorDescription: String? {
        switch self {
        case .fileMissing(let path):
            "input file does not exist: \(path)"
        case .invalidAudioFile:
            "could not allocate an audio-file input buffer"
        case .microphonePermissionDenied:
            "microphone access is required; enable it in System Settings > Privacy & Security > Microphone"
        case .captureOverrun:
            "audio inference fell behind the bounded capture queue; use a faster compute policy or close competing workloads"
        case .diarizationOverrun:
            "live diarization fell more than 20 seconds behind; retry without --diarize or close competing workloads"
        case .diarizationStopped:
            "live diarization stopped before all audio was accepted"
        }
    }
}

public final class InterruptWaiter: @unchecked Sendable {
    private let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let source: DispatchSourceSignal

    public init() {
        signal(SIGINT, SIG_IGN)
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        continuation = pair.continuation
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler {
            pair.continuation.yield(())
            pair.continuation.finish()
            source.cancel()
        }
        self.source = source
        source.resume()
    }

    public func wait() async {
        for await _ in events { return }
    }

    public func trigger() {
        continuation.yield(())
        continuation.finish()
        source.cancel()
    }
}

final class AudioFileBufferReader: @unchecked Sendable {
    private static let bufferFrames: AVAudioFrameCount = 4096
    private let file: AVAudioFile
    private let speed: Double

    private init(path: String, speed: Double) throws {
        self.speed = max(speed, 0.1)
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw RecorderError.fileMissing(path)
        }
        file = try AVAudioFile(forReading: URL(fileURLWithPath: expanded))
    }

    static func stream(path: String, speed: Double = 1) throws -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let reader = try AudioFileBufferReader(path: path, speed: speed)
        return AsyncThrowingStream(unfolding: { try await reader.next() })
    }

    private func next() async throws -> AVAudioPCMBuffer? {
        guard file.framePosition < file.length else { return nil }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: Self.bufferFrames
        ) else {
            throw RecorderError.invalidAudioFile
        }
        try file.read(into: buffer)
        let seconds = Double(buffer.frameLength) / file.processingFormat.sampleRate
        try await Task.sleep(for: .seconds(seconds / speed))
        return buffer.frameLength == 0 ? nil : buffer
    }
}

private final class LiveDiarizationWorker: @unchecked Sendable {
    private let worker: BackgroundStreamWorker<[Float], [SpeakerSpan]>

    init(models: DiarizerModels) {
        worker = BackgroundStreamWorker(
            capacity: 2,
            overflowError: RecorderError.diarizationOverrun
        ) { stream in
            let diarizer = IncrementalDiarizer(models: models)
            for try await chunk in stream { try diarizer.process(chunk) }
            return diarizer.spans
        }
    }

    func send(_ chunk: [Float]) throws {
        switch worker.send(chunk) {
        case .enqueued:
            return
        case .dropped:
            throw RecorderError.diarizationOverrun
        case .terminated:
            throw RecorderError.diarizationStopped
        }
    }

    func finish() async throws -> [SpeakerSpan] {
        try await worker.finish()
    }
}

struct DiarizationChunker {
    private static let sampleRate = 16_000
    private static let chunkSamples = sampleRate * 10
    private var pending: [Float] = []

    mutating func append(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        var chunks: [[Float]] = []
        while pending.count >= Self.chunkSamples {
            chunks.append(Array(pending.prefix(Self.chunkSamples)))
            pending.removeFirst(Self.chunkSamples)
        }
        return chunks
    }

    mutating func finish() -> [Float]? {
        guard !pending.isEmpty else { return nil }
        let tail = pending
        pending.removeAll()
        return tail
    }
}

final class IncrementalDiarizer {
    private static let sampleRate = 16_000
    private let manager: DiarizerManager
    private var processedSamples = 0
    private(set) var spans: [SpeakerSpan] = []

    init(models: DiarizerModels) {
        manager = DiarizerManager()
        manager.initialize(models: models)
    }

    func process(_ samples: [Float]) throws {
        let offset = Double(processedSamples) / Double(Self.sampleRate)
        let result = try manager.performCompleteDiarization(samples, atTime: offset)
        spans.append(contentsOf: result.segments.map {
            SpeakerSpan(
                speaker: $0.speakerId,
                startSeconds: Double($0.startTimeSeconds),
                endSeconds: Double($0.endTimeSeconds),
                quality: $0.qualityScore
            )
        })
        processedSamples += samples.count
    }
}

private extension AVAudioPCMBuffer {
    func detachedCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, target.count) {
            guard let sourceData = source[index].mData, let targetData = target[index].mData else {
                continue
            }
            memcpy(targetData, sourceData, Int(source[index].mDataByteSize))
            target[index].mDataByteSize = source[index].mDataByteSize
        }
        return copy
    }
}
