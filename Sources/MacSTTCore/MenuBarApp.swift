import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// `mac-stt app`: menu-bar icon and global hotkey. Loads no models; it drives `serve` through the
/// control socket and presses Command-V when a take finishes.
@MainActor
public final class MenuBarApp: NSObject {
    private let hotkey: Hotkey
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var busy = false
    private nonisolated(unsafe) static var instance: MenuBarApp?

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
        super.init()
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n".utf8))
    }

    /// Holds an exclusive lock for the life of the process; returns false if another app already has it.
    private static func takeLock() -> Bool {
        try? FileManager.default.createDirectory(at: ControlSocket.directory, withIntermediateDirectories: true)
        let fd = open(ControlSocket.appLockPath, O_CREAT | O_RDWR, 0o600)
        return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0  // fd intentionally stays open
    }

    /// Starts the app detached from this terminal unless one is already running.
    public static func launchDetached(hotkey: Hotkey) throws -> String {
        try FileManager.default.createDirectory(at: ControlSocket.directory, withIntermediateDirectories: true)
        let fd = open(ControlSocket.appLockPath, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 {
            defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 { return "mac-stt app is already running (log: \(ControlSocket.appLogPath))" }
        }
        try ControlClient.spawnDetached(
            arguments: ["app", "--foreground", "--hotkey", hotkey.spec], logPath: ControlSocket.appLogPath)
        return "mac-stt app started in the background (key: \(hotkey.spec); log: \(ControlSocket.appLogPath)); `mac-stt app install` starts it at login"
    }

    public static func run(hotkey: Hotkey) -> Never {
        guard takeLock() else {
            log("another mac-stt app is already running; exiting")
            exit(0)
        }
        log("app starting, key \(hotkey.spec), accessibility trusted: \(AXIsProcessTrusted())")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let me = MenuBarApp(hotkey: hotkey)
        instance = me
        me.setUp()
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptPrompt": true] as CFDictionary)
        app.run()
        exit(0)
    }

    private func setUp() {
        setIcon(recording: false)
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Start/stop dictation (\(hotkey.spec))", action: #selector(menuToggle), keyEquivalent: "")
        toggle.target = self
        let access = NSMenuItem(title: "Grant Accessibility (needed to paste)…", action: #selector(openAccessibility), keyEquivalent: "")
        access.target = self
        let quit = NSMenuItem(title: "Quit mac-stt app", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        for entry in [toggle, access, .separator(), quit] { menu.addItem(entry) }
        item.menu = menu
        if hotkey.isDictationKey { installTap() } else { registerHotkey() }
    }

    private func setIcon(recording: Bool) {
        let image = NSImage(systemSymbolName: recording ? "mic.fill" : "mic", accessibilityDescription: "mac-stt")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.contentTintColor = recording ? .systemRed : nil
    }

    private func registerHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                MenuBarApp.log("hotkey pressed")
                DispatchQueue.main.async { MainActor.assumeIsolated { MenuBarApp.instance?.fire() } }
                return noErr
            }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x6D_53_54_54), id: 1)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        Self.log(status == noErr ? "registered hotkey \(hotkey.spec)" : "cannot register hotkey \(hotkey.spec) (status \(status)); in use elsewhere?")
    }

    // The microphone key (F5 on recent Apple keyboards) arrives as an ordinary key event with key code 176.
    // Swallowing it needs an active event tap: macOS asks for Input Monitoring and Accessibility. Until both
    // are granted the tap cannot be created, so retry every 3 s.
    private var tap: CFMachPort?
    private var loggedTapWait = false

    private func installTap() {
        if tap == nil {
            let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
                | (1 << 14)  // NX_SYSDEFINED: logged so unknown media/mic keys can be diagnosed
            let callback: CGEventTapCallBack = { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MenuBarApp.log("event tap was disabled by macOS; re-enabling")
                    DispatchQueue.main.async { MainActor.assumeIsolated { MenuBarApp.instance?.enableTap() } }
                    return Unmanaged.passUnretained(event)
                }
                if type.rawValue == 14 {
                    if let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
                        MenuBarApp.log("system key event data1=\(String(ns.data1, radix: 16)) (not handled)")
                    }
                    return Unmanaged.passUnretained(event)
                }
                let code = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                guard code == Hotkey.dictationKeyCode else { return Unmanaged.passUnretained(event) }
                if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    MenuBarApp.log("dictation key pressed")
                    DispatchQueue.main.async { MainActor.assumeIsolated { MenuBarApp.instance?.fire() } }
                }
                return nil  // swallow so macOS does not also start its own Dictation
            }
            if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
            tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: callback, userInfo: nil)
            if let tap {
                CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
                Self.log("event tap installed; waiting for the dictation key")
            } else if !loggedTapWait {
                loggedTapWait = true
                Self.log("cannot create event tap yet: grant mac-stt Input Monitoring and Accessibility in System Settings > Privacy & Security (retrying)")
            }
        }
        if tap == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { MenuBarApp.instance?.installTap() } }
        }
    }

    private func enableTap() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    @objc private func menuToggle() { fire() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func fire() {
        Self.log("toggle requested")
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false; setIcon(recording: false) }
            do {
                let wasRecording = try await ControlClient.send(.status) == "recording"
                if !wasRecording { setIcon(recording: true) }
                let reply = try await ControlClient.send(.toggle)
                Self.log("toggle reply: \(wasRecording ? "transcript, \(reply.count) chars" : reply)")
                if wasRecording { paste(reply) }
            } catch {
                Self.log("error: \(error.localizedDescription)")
                NSSound.beep()
            }
        }
    }

    private func paste(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        guard AXIsProcessTrusted() else {
            Self.log("not pasting: Accessibility not granted")
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptPrompt": true] as CFDictionary)
            return  // text stays on the clipboard
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// Start `mac-stt app` at login through a per-user LaunchAgent.
public enum LoginItem {
    static let label = "io.github.sichanghe.mac-stt.app"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static func install(hotkey: Hotkey) throws -> String {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": label, "ProgramArguments": [exe, "app", "--foreground", "--hotkey", hotkey.spec],
            "RunAtLoad": true, "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL)
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        let status = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        return "installed \(plistURL.path) (hotkey \(hotkey.spec))" + (status == 0 ? "; started" : "; will start at next login")
    }

    public static func uninstall() -> String {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        return "removed \(plistURL.path)"
    }

    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
