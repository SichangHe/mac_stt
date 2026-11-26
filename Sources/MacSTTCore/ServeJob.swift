import Foundation

/// `transcribe` and `record` run inside `serve`, so every mac-stt command shares one copy of the models.
/// Protocol on the control socket: the client sends `JOB {request json}\n`; the server answers with lines
/// `P {"text":…}` (live partial), then one `D {result json}` or `E {"text":…}`. For `record`, the client
/// sends one byte (or closes) to stop.
public struct JobRequest: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case transcribe, record }
    public var kind: Kind
    public var paths: [String] = []
    public var input: String?
    public var speed: Double = 1
    public var diarize = false
    public var language: String?
    public var variant: String
    public var compute: String

    public init(kind: Kind, model: ModelOptions) {
        self.kind = kind
        diarize = model.diarize
        language = model.language
        variant = model.variant.rawValue
        compute = model.compute.rawValue
    }
}

public struct JobFile: Codable, Sendable {
    public let path: String
    public let rendered: String
    public let seconds: Double
}

public struct JobResult: Codable, Sendable {
    public var files: [JobFile] = []
    public var rendered = ""
    public var speechSeconds = 0.0
    public var finalizeSeconds = 0.0
}

struct JobText: Codable { let text: String }

/// Serializes writes to one client connection.
final class JobConnection: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    init(fd: Int32) { self.fd = fd }

    func send(_ tag: String, _ value: some Encodable) {
        guard let json = try? JSONEncoder().encode(value) else { return }
        let bytes = Array((tag + " ").utf8) + Array(json) + [10]
        lock.lock()
        defer { lock.unlock() }
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written <= 0 { return }
            offset += written
        }
    }
}

public enum JobClient {
    /// Runs the request in `serve`, starting it with the request's model if it is not running.
    /// `stop` is awaited for `record`; when it returns, the server is told to finish the take.
    public static func run(
        _ request: JobRequest, stop: (@Sendable () async -> Void)? = nil,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> JobResult {
        var fd = ControlSocket.connectClient()
        if fd == nil {
            fd = try await ControlClient.launchAndConnect(
                arguments: ["--model", request.variant, "--compute", request.compute])
        }
        guard let fd else { throw ControlError.notReachable }
        defer { close(fd) }
        let line = Array("JOB ".utf8) + Array(try JSONEncoder().encode(request)) + [10]
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let stopper = stop.map { stop in
            Task {
                await stop()
                var byte: UInt8 = 10
                _ = write(fd, &byte, 1)
            }
        }
        defer { stopper?.cancel() }
        var pending: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { throw ControlError.serverFailed("mac-stt serve closed the connection; see \(ControlSocket.logPath)") }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 10) {
                let message = Array(pending[..<newline])
                pending.removeSubrange(...newline)
                guard message.count >= 2 else { continue }
                let body = Data(message.dropFirst(2))
                switch message[0] {
                case UInt8(ascii: "P"): onPartial((try? JSONDecoder().decode(JobText.self, from: body))?.text ?? "")
                case UInt8(ascii: "D"): return try JSONDecoder().decode(JobResult.self, from: body)
                case UInt8(ascii: "E"):
                    throw ControlError.serverFailed((try? JSONDecoder().decode(JobText.self, from: body))?.text ?? "failed")
                default: continue
                }
            }
        }
    }
}
