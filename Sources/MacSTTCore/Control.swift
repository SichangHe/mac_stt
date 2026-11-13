import Darwin
import Foundation

public enum ControlSocket {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mac-stt")
    }
    public static var path: String { directory.appendingPathComponent("control.sock").path }
    public static var logPath: String { directory.appendingPathComponent("serve.log").path }
    public static var appLogPath: String { directory.appendingPathComponent("app.log").path }
    public static var appLockPath: String { directory.appendingPathComponent("app.lock").path }

    static func address() -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(100)) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, byte) in bytes.enumerated() { buffer[i] = byte }
        }
        return address
    }

    static func connectClient() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = address()
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return fd }
        close(fd)
        return nil
    }
}

public enum ControlError: Error, LocalizedError {
    case serverFailed(String)
    case notReachable

    public var errorDescription: String? {
        switch self {
        case .serverFailed(let message): message
        case .notReachable: "could not reach mac-stt serve; see \(ControlSocket.logPath)"
        }
    }
}

public enum ControlClient {
    /// Sends one verb to the running server, starting it in the background for `toggle`/`start`.
    public static func send(_ verb: ControlVerb) async throws -> String {
        var fd = ControlSocket.connectClient()
        if fd == nil, verb == .toggle || verb == .start {
            try launchServer()
            for _ in 0..<300 {
                fd = ControlSocket.connectClient()
                if fd != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let fd else {
            if verb == .status { return "not running" }
            if verb == .quit { return "not running" }
            throw ControlError.notReachable
        }
        defer { close(fd) }
        let request = Array((verb.rawValue + "\n").utf8)
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, request.count) }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            reply.append(contentsOf: buffer[0..<count])
        }
        let text = String(decoding: reply, as: UTF8.self)
        if text.hasPrefix("ERR ") { throw ControlError.serverFailed(String(text.dropFirst(4))) }
        return text
    }

    /// Starts `serve` detached and as its own TCC "responsible process" (posix_spawn with the
    /// responsibility disclaim attribute). Otherwise macOS attributes microphone access to whatever
    /// launched `toggle` (Karabiner, a hotkey app), which has no microphone permission and cannot be
    /// added in System Settings; disclaimed, macOS asks once for mac-stt itself.
    private static func launchServer() throws {
        try spawnDetached(arguments: ["serve"], logPath: ControlSocket.logPath, executable: LocalSigning.serveExecutable())
    }

    /// Runs this executable with `arguments` detached (own session, own TCC identity), output appended to `logPath`.
    public static func spawnDetached(arguments: [String], logPath: String, executable: String? = nil) throws {
        try FileManager.default.createDirectory(at: ControlSocket.directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
        let executable = executable ?? Bundle.main.executablePath ?? CommandLine.arguments[0]
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // New session: the server survives the launcher exiting (what nohup did before).
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
            _ = unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1)
        }
        // Run from the home directory: hotkey tools start commands in the read-only "/".
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        posix_spawn_file_actions_addchdir_np(&actions, home)
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        guard status == 0 else {
            throw ControlError.serverFailed("cannot start mac-stt \(arguments[0]): \(String(cString: strerror(status)))")
        }
    }
}

/// Minimal blocking Unix-socket server; each connection carries one verb line.
public final class ControlServer: @unchecked Sendable {
    private let handler: @Sendable (ControlVerb) async -> String
    private var descriptor: Int32 = -1

    public init(handler: @escaping @Sendable (ControlVerb) async -> String) {
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: ControlSocket.directory, withIntermediateDirectories: true)
        if let existing = ControlSocket.connectClient() {
            close(existing)
            throw ControlError.serverFailed("mac-stt serve is already running")
        }
        unlink(ControlSocket.path)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = ControlSocket.address()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            throw ControlError.serverFailed("cannot listen on \(ControlSocket.path): \(String(cString: strerror(errno)))")
        }
        chmod(ControlSocket.path, 0o600)
        let listener = descriptor
        let handler = self.handler
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { continue }
                Task.detached {
                    var line: [UInt8] = []
                    var byte: UInt8 = 0
                    while line.count < 32, read(client, &byte, 1) == 1, byte != 10 { line.append(byte) }
                    let word = String(decoding: line, as: UTF8.self)
                    let reply: String
                    if let verb = ControlVerb(rawValue: word) {
                        reply = await handler(verb)
                    } else {
                        reply = "ERR unknown verb \(word)"
                    }
                    let bytes = Array(reply.utf8)
                    _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, bytes.count) }
                    close(client)
                }
            }
        }
    }
}
