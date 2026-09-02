import AppKit
import Foundation

public enum OutputError: Error, LocalizedError {
    case clipboardUnavailable

    public var errorDescription: String? { "could not write the macOS clipboard" }
}

public enum ResultWriter {
    public static func write(_ document: TranscriptDocument, options: OutputOptions) throws {
        let rendered = document.rendered
        print(rendered)
        if let path = options.outputPath {
            try Data((rendered + "\n").utf8).write(
                to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
                options: .atomic
            )
        }
        if options.copyToClipboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(rendered, forType: .string) else {
                throw OutputError.clipboardUnavailable
            }
        }
    }
}
