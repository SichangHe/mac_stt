import AppKit
import Carbon.HIToolbox
import Foundation

/// The transcript every take of this `serve` produced, shared by the recording callbacks, the control
/// socket, and the window. Every change schedules one window refresh.
public final class SharedTranscript: @unchecked Sendable {
    public static let shared = SharedTranscript()
    private let lock = NSLock()
    private var log = TranscriptLog()
    private var refreshQueued = false
    /// Set on the main thread by the window; read by the idle-exit check.
    private var visible = false

    public func mutate<T>(_ change: (inout TranscriptLog) -> T) -> T {
        lock.lock()
        let result = change(&log)
        let queue = !refreshQueued
        refreshQueued = true
        lock.unlock()
        if queue {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { TranscriptWindow.shared.refresh() }
            }
        }
        return result
    }

    func snapshot() -> TranscriptLog {
        lock.lock()
        defer { lock.unlock() }
        refreshQueued = false
        return log
    }

    public var windowVisible: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return visible
        }
        set {
            lock.lock()
            visible = newValue
            lock.unlock()
        }
    }
}

/// `mac-stt window`: a normal window inside `serve` (which holds the models) showing every take's
/// transcript live, one line per speaker turn, with buttons to start/stop and to copy new text.
@MainActor
public final class TranscriptWindow: NSObject, NSWindowDelegate {
    public static let shared = TranscriptWindow()

    /// Set by `serve`: what the buttons and the copy hotkey do.
    public var onToggle: (@Sendable () async -> String)?
    public var onCopy: (@Sendable () async -> String)?

    private var window: NSWindow?
    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let recordButton = NSButton(title: "Start recording", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy new text", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var recording = false
    private var copyKey: Hotkey?

    public var isVisible: Bool { window?.isVisible ?? false }

    public func show() {
        let window = self.window ?? make()
        self.window = window
        installMenu()
        NSApplication.shared.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        SharedTranscript.shared.windowVisible = true
        refresh()
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        SharedTranscript.shared.windowVisible = false
        NSApplication.shared.setActivationPolicy(.accessory)
        return false
    }

    public func setRecording(_ value: Bool) {
        recording = value
        recordButton.title = value ? "Stop recording" : "Start recording"
    }

    public func setStatus(_ text: String) { status.stringValue = text }

    private func make() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "mac-stt transcript"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 360, height: 200)
        window.center()
        window.setFrameAutosaveName("mac-stt transcript")

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        recordButton.target = self
        recordButton.action = #selector(toggleClicked)
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        if let copyKey { copyButton.title = "Copy new text (\(copyKey.spec))" }
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [recordButton, copyButton, status])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        return window
    }

    /// Edit menu so Command-C and Command-A work on selected text; Command-W closes the window.
    private func installMenu() {
        guard NSApplication.shared.mainMenu == nil else { return }
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit mac-stt serve", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(appItem)
        main.addItem(editItem)
        NSApplication.shared.mainMenu = main
    }

    @objc private func toggleClicked() {
        guard let onToggle else { return }
        Task { _ = await onToggle() }
    }

    @objc private func copyClicked() { copyNew() }

    func copyNew() {
        guard let onCopy else { return }
        Task {
            let text = await onCopy()
            setStatus(text.isEmpty ? "nothing new to copy" : "copied \(text.count) characters")
        }
    }

    func refresh() {
        let log = SharedTranscript.shared.snapshot()
        guard let window, window.isVisible else { return }
        let atBottom = scroll.documentVisibleRect.maxY >= textView.bounds.maxY - 20
        textView.textStorage?.setAttributedString(Self.render(log))
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }

    // MARK: rendering

    private static let palette: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink, .systemTeal, .systemBrown]

    private static func color(for speaker: String) -> NSColor {
        let sum = speaker.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }

    static func render(_ log: TranscriptLog) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 15)
        let small = NSFont.systemFont(ofSize: 11)
        let clock = DateFormatter()
        clock.timeStyle = .short
        if log.takes.isEmpty {
            out.append(NSAttributedString(
                string: "No takes yet. Press Start recording or run `mac-stt toggle`.\n",
                attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        for (index, take) in log.takes.enumerated() {
            out.append(NSAttributedString(
                string: "take \(index + 1) · \(clock.string(from: take.started))\n",
                attributes: [.font: small, .foregroundColor: NSColor.tertiaryLabelColor]))
            // Consecutive pieces of one speaker and one copied state form one line.
            var lines: [(speaker: String, copied: Bool, text: String)] = []
            for piece in take.pieces where !piece.text.isEmpty {
                let copied = log.isCopied(take: index, piece)
                if let last = lines.last, last.speaker == piece.speaker, last.copied == copied {
                    lines[lines.count - 1].text += " " + piece.text
                } else {
                    lines.append((piece.speaker, copied, piece.text))
                }
            }
            for line in lines {
                let textColor: NSColor = line.copied ? .secondaryLabelColor : .labelColor
                if !line.speaker.isEmpty {
                    out.append(NSAttributedString(
                        string: TranscriptLog.displayName(line.speaker) + ": ",
                        attributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: color(for: line.speaker)]))
                }
                out.append(NSAttributedString(string: line.text + "\n", attributes: [.font: body, .foregroundColor: textColor]))
            }
            if let tail = take.tail {
                out.append(NSAttributedString(
                    string: (tail.isEmpty ? "listening…" : tail) + "\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .light), .foregroundColor: NSColor.tertiaryLabelColor]))
            } else if !take.finished {
                out.append(NSAttributedString(
                    string: "finishing…\n", attributes: [.font: small, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: small]))
        }
        return out
    }

    // MARK: global copy key (Carbon hot keys need no Accessibility or Input Monitoring permission)

    public func registerCopyKey(_ key: Hotkey) {
        copyKey = key
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { TranscriptWindow.shared.copyNew() } }
                return noErr
            }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x6D_53_54_54), id: 1)
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        DictationService.log(
            status == noErr ? "copy key \(key.spec) registered" : "cannot register copy key \(key.spec) (status \(status)); in use elsewhere?")
    }
}
