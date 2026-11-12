import AppKit

/// Small floating, click-through window showing the live partial transcript. It never takes focus:
/// a non-activating panel under an accessory-policy app, shown with `orderFrontRegardless`.
@MainActor
final class PartialWindow {
    static let shared = PartialWindow()
    private var panel: NSPanel?
    private var active = false
    private let label = NSTextField(wrappingLabelWithString: "")
    private static let width: CGFloat = 520

    nonisolated static var disabled: Bool { ProcessInfo.processInfo.environment["MAC_STT_NO_WINDOW"] != nil }

    private func makePanel() -> NSPanel {
        NSApplication.shared.setActivationPolicy(.accessory)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.8)
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        label.textColor = .white
        label.font = .systemFont(ofSize: 16)
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byTruncatingHead
        label.preferredMaxLayoutWidth = Self.width - 32
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 10
        panel.contentView?.addSubview(label)
        return panel
    }

    func show(_ text: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        label.stringValue = text.isEmpty ? "listening…" : text
        let size = label.sizeThatFits(NSSize(width: Self.width - 32, height: .greatestFiniteMagnitude))
        let height = min(max(size.height, 20), 100) + 24
        label.frame = NSRect(x: 16, y: 12, width: Self.width - 32, height: height - 24)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        panel.setFrame(
            NSRect(x: screen.midX - Self.width / 2, y: screen.minY + 80, width: Self.width, height: height),
            display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    nonisolated static func update(_ text: String?) {
        guard !disabled else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let text {
                    // A late partial from a finished take must not reopen the window.
                    if text.isEmpty { shared.active = true }
                    if shared.active { shared.show(text) }
                } else {
                    shared.active = false
                    shared.hide()
                }
            }
        }
    }
}
