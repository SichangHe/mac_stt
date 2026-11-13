import AppKit
import Foundation

public enum OutputError: Error, LocalizedError {
    case clipboardUnavailable

    public var errorDescription: String? { "could not write the macOS clipboard" }
}

public enum ResultWriter {
    /// `echo: false` keeps the transcript out of stdout; `serve`'s stdout is its log file.
    public static func write(_ document: TranscriptDocument, options: OutputOptions, echo: Bool = true) throws {
        let rendered = document.rendered
        if echo { print(rendered) }
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
