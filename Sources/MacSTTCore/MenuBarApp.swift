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

    public static func run(hotkey: Hotkey) -> Never {
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
        registerHotkey()
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
                DispatchQueue.main.async { MainActor.assumeIsolated { MenuBarApp.instance?.fire() } }
                return noErr
            }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x6D_53_54_54), id: 1)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            FileHandle.standardError.write(Data("cannot register hotkey \(hotkey.spec) (status \(status)); in use elsewhere?\n".utf8))
        }
    }

    @objc private func menuToggle() { fire() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func fire() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false; setIcon(recording: false) }
            do {
                let wasRecording = try await ControlClient.send(.status) == "recording"
                if !wasRecording { setIcon(recording: true) }
                let reply = try await ControlClient.send(.toggle)
                if wasRecording { paste(reply) }
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
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
            "Label": label, "ProgramArguments": [exe, "app", "--hotkey", hotkey.spec],
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
