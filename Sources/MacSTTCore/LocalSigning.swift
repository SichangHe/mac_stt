import Foundation

/// Builds `~/Applications/mac-stt.app`, a signed wrapper around a copy of the binary, so that macOS lists
/// mac-stt under Accessibility and Input Monitoring as an app with a fixed bundle identifier.
///
/// Limit, found by trying it in CI: a self-signed identity cannot be used by `codesign` unless the user
/// trusts the certificate (a password dialog), so the bundle is ad-hoc signed. macOS ties an ad-hoc grant
/// to the binary's hash, so after an update the user must re-grant (remove the old entry, add it again).
public enum LocalSigning {
    public static let identityName = "mac-stt local signing"
    public static let bundleID = "io.github.sichanghe.mac-stt"

    public static var defaultAppURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/mac-stt.app")
    }
    public static var appExecutable: String { defaultAppURL.appendingPathComponent("Contents/MacOS/mac-stt").path }

    @discardableResult
    static func exec(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "cannot run \(args[0])") }
        // A command that waits for a GUI dialog must not hang us forever.
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 60)
        timer.setEventHandler { if p.isRunning { p.terminate() } }
        timer.resume()
        defer { timer.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func codesign(_ path: String) -> String? {
        let r = exec(["/usr/bin/codesign", "--force", "--identifier", bundleID, "--sign", "-", path])
        return r.status == 0 ? nil : r.output
    }

    /// Designated requirement text, e.g. `identifier "x" and certificate leaf = H"..."` (stable) or `cdhash H"..."`.
    public static func requirement(of path: String) -> String {
        let raw = exec(["/usr/bin/codesign", "-d", "-r-", path]).output
        // Ad-hoc signatures print the line as "# designated => cdhash H..." with a leading "# ".
        return raw.split(separator: "\n").map { $0.drop(while: { $0 == "#" || $0 == " " }) }
            .first { $0.hasPrefix("designated") }.map(String.init) ?? "unknown: \(raw)"
    }

    /// (Re)builds a signed app bundle that wraps a copy of it.
    /// The bundle is what `mac-stt app` runs, so macOS lists it in Accessibility and Input Monitoring.
    public static func setUpApp(cli: String, app: URL = defaultAppURL) -> String {
        var notes: [String] = []
        let fm = FileManager.default
        try? fm.removeItem(at: app)
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let resources = app.appendingPathComponent("Contents/Resources")
        do {
            try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            try fm.copyItem(atPath: cli, toPath: macOS.appendingPathComponent("mac-stt").path)
            let plist: [String: Any] = [
                "CFBundleIdentifier": bundleID, "CFBundleName": "mac-stt", "CFBundleExecutable": "mac-stt",
                "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSUIElement": true,
                "LSMinimumSystemVersion": "14.0",
                "NSMicrophoneUsageDescription": "mac-stt records your voice on this Mac to transcribe it. Audio never leaves the device.",
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            // The app wraps only the identity; models run in `serve`, started from the real binary.
            try cli.write(to: resources.appendingPathComponent("cli"), atomically: true, encoding: .utf8)
        } catch {
            return "could not build \(app.path): \(error.localizedDescription)"
        }
        if let problem = codesign(app.path) { notes.append("signing the app failed: \(problem)") }
        notes.insert("app: \(app.path)\nidentity: \(requirement(of: app.path))", at: 0)
        return notes.joined(separator: "\n")
    }

    /// The real binary that `serve` must run from when this process is the app bundle copy.
    public static func serveExecutable() -> String {
        let own = Bundle.main.executablePath ?? CommandLine.arguments[0]
        if own.contains(".app/Contents/MacOS/"),
            let cli = try? String(contentsOf: URL(fileURLWithPath: own).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/cli"), encoding: .utf8),
            FileManager.default.isExecutableFile(atPath: cli)
        { return cli }
        return own
    }
}
