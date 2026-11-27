import AppKit
import Darwin
import Foundation

/// `mac-stt transcribe` with no files: a full-screen terminal view of the live transcript, one line per
/// speaker turn. Recording runs in `serve` (the shared models); each unpaused stretch is one take.
/// Keys: space pauses/resumes, c copies the text since the last copy, a copies everything, q quits.
public enum LiveTranscript {
    public static func run(model: ModelOptions) async throws {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw ControlError.serverFailed("live `mac-stt transcribe` needs a terminal; give files to transcribe them")
        }
        let view = LiveView(model: model)
        try await view.run()
    }
}

final class LiveView: @unchecked Sendable {
    private let model: ModelOptions
    private let lock = NSLock()
    private var log = TranscriptLog()
    private var recording = false
    private var status = "starting…"
    private var lastCopy: Date?
    private var stopCurrent: (() -> Void)?
    private var running: [Task<Void, Never>] = []
    private var quitting = false
    private let redrawQueue = DispatchQueue(label: "mac-stt.live.redraw")
    private var redrawQueued = false
    private var saved = termios()

    init(model: ModelOptions) { self.model = model }

    func run() async throws {
        enterScreen()
        defer { leaveScreen() }
        let (keys, keyInput) = AsyncStream<UInt8>.makeStream()
        Thread.detachNewThread {
            var byte: UInt8 = 0
            while read(STDIN_FILENO, &byte, 1) == 1 { keyInput.yield(byte) }
            keyInput.finish()
        }
        let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: redrawQueue)
        signal(SIGWINCH, SIG_IGN)
        resize.setEventHandler { [self] in draw() }
        resize.resume()
        startTake()
        for await key in keys {
            switch key {
            case UInt8(ascii: " "): togglePause()
            case UInt8(ascii: "c"), UInt8(ascii: "C"): copy(all: false)
            case UInt8(ascii: "a"), UInt8(ascii: "A"): copy(all: true)
            case UInt8(ascii: "q"), UInt8(ascii: "Q"), 3, 4: quitting = true
            default: break
            }
            if quitting { break }
        }
        resize.cancel()
        // Finish the takes so the last words are kept.
        let tasks = locked { () -> [Task<Void, Never>] in
            stopCurrent?()
            stopCurrent = nil
            recording = false
            status = "finishing the last words…"
            return running
        }
        scheduleDraw()
        for task in tasks { await task.value }
        let all = locked { log.takes.map { TranscriptLog.render($0.pieces) }.filter { !$0.isEmpty }.joined(separator: "\n\n") }
        leaveScreen()
        if !all.isEmpty { print(all) }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: takes

    private func startTake() {
        let (stopSignal, stopper) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let index = locked { () -> Int in
            recording = true
            status = "recording"
            stopCurrent = {
                stopper.yield()
                stopper.finish()
            }
            return log.beginTake()
        }
        var request = JobRequest(kind: .record, model: model)
        request.diarize = model.diarize
        let task = Task { [self] in
            do {
                let result = try await JobClient.run(
                    request,
                    stop: { for await _ in stopSignal { return } },
                    onPartial: { _ in },
                    onTail: { [self] tail in
                        locked { log.setTail(take: index, tail) }
                        scheduleDraw()
                    },
                    onPieces: { [self] pieces in
                        locked { log.update(take: index, pieces: pieces) }
                        scheduleDraw()
                    })
                locked { log.finish(take: index, pieces: result.pieces) }
            } catch {
                locked {
                    log.finish(take: index, pieces: log.takes[index].pieces)
                    if recording, log.takes.count - 1 == index {
                        recording = false
                        stopCurrent = nil
                    }
                    status = "error: \(error.localizedDescription)"
                }
            }
            scheduleDraw()
        }
        locked { running.append(task) }
        scheduleDraw()
    }

    private func togglePause() {
        let resume = locked { () -> Bool in
            if recording {
                stopCurrent?()
                stopCurrent = nil
                recording = false
                status = "paused"
                return false
            }
            return true
        }
        if resume { startTake() } else { scheduleDraw() }
    }

    private func copy(all: Bool) {
        let text = locked { all ? log.copyAll() : log.copyNew() }
        let message: String
        if text.isEmpty {
            message = "nothing new to copy"
        } else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if pasteboard.setString(text, forType: .string) {
                message = "copied \(all ? "everything" : "text since the last copy") (\(text.count) characters)"
                locked { lastCopy = Date() }
            } else {
                message = "could not write the clipboard"
            }
        }
        locked { status = (recording ? "recording · " : "paused · ") + message }
        scheduleDraw()
    }

    // MARK: drawing

    private func enterScreen() {
        tcgetattr(STDIN_FILENO, &saved)
        var raw = saved
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        write("\u{1B}[?1049h\u{1B}[?25l")
    }

    private var left = false
    private func leaveScreen() {
        guard !left else { return }
        left = true
        write("\u{1B}[?25h\u{1B}[?1049l")
        tcsetattr(STDIN_FILENO, TCSANOW, &saved)
    }

    private func write(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if count <= 0 { return }
            offset += count
        }
    }

    private func scheduleDraw() {
        redrawQueue.async { [self] in
            guard !redrawQueued else { return }
            redrawQueued = true
            // Coalesce bursts of updates into one frame.
            redrawQueue.asyncAfter(deadline: .now() + 0.05) { [self] in
                redrawQueued = false
                draw()
            }
        }
    }

    private static let dim = "\u{1B}[2m", bold = "\u{1B}[1m", reset = "\u{1B}[0m"
    private static let colors = ["\u{1B}[34m", "\u{1B}[33m", "\u{1B}[32m", "\u{1B}[35m", "\u{1B}[36m", "\u{1B}[31m"]

    private func color(_ speaker: String) -> String {
        Self.colors[speaker.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % Self.colors.count]
    }

    /// One logical line: styled text and its printed width.
    private typealias Line = (styled: String, width: Int)

    private func draw() {
        let (log, status, lastCopy, left) = locked { (self.log, self.status, self.lastCopy, self.left) }
        guard !left else { return }
        var size = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
        let columns = max(Int(size.ws_col), 20)
        let rows = max(Int(size.ws_row), 5)
        let clock = DateFormatter()
        clock.timeStyle = .medium

        var lines: [Line] = []
        var markerShown = false
        func plain(_ text: String, _ style: String = "") { lines.append((style + text + Self.reset, text.count)) }
        for (index, take) in log.takes.enumerated() {
            if index > 0 { plain("") }
            var turns: [(speaker: String, copied: Bool, text: String)] = []
            for piece in take.pieces where !piece.text.isEmpty {
                let copied = log.isCopied(take: index, piece)
                if let last = turns.last, last.speaker == piece.speaker, last.copied == copied {
                    turns[turns.count - 1].text += " " + piece.text
                } else {
                    turns.append((piece.speaker, copied, piece.text))
                }
            }
            for turn in turns {
                if !turn.copied, !markerShown, let lastCopy {
                    plain("=== last copy at \(clock.string(from: lastCopy)); new text below ===", Self.bold)
                    markerShown = true
                }
                let name = turn.speaker.isEmpty ? "" : TranscriptLog.displayName(turn.speaker) + ": "
                let body = (turn.copied ? Self.dim : "") + turn.text
                lines.append((color(turn.speaker) + Self.bold + name + Self.reset + body + Self.reset, name.count + turn.text.count))
            }
            if let tail = take.tail { plain(tail.isEmpty ? "listening…" : tail, Self.dim) }
        }
        if lines.isEmpty { plain("waiting for speech…", Self.dim) }
        if !markerShown, let lastCopy {
            plain("=== last copy at \(clock.string(from: lastCopy)); new text below ===", Self.bold)
        }

        // Keep the newest lines that fit above the two footer lines.
        var budget = rows - 3
        var shown: [Line] = []
        for line in lines.reversed() {
            let height = max(1, (line.width + columns - 1) / columns)
            if height > budget { break }
            budget -= height
            shown.insert(line, at: 0)
        }
        var frame = "\u{1B}[H\u{1B}[2J"
        frame += shown.map(\.styled).joined(separator: "\r\n")
        let help = "(Hit <space> to \(locked { recording } ? "pause" : "resume"), c to copy from last copy, a to copy all the transcript, q to quit)"
        frame += "\u{1B}[\(rows - 1);1H\u{1B}[2K" + Self.dim + String(status.prefix(columns)) + Self.reset
        frame += "\u{1B}[\(rows);1H\u{1B}[2K" + Self.bold + String(help.prefix(columns)) + Self.reset
        write(frame)
    }
}
