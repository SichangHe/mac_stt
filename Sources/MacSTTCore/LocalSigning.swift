import Foundation

/// Gives mac-stt a stable macOS identity so Accessibility / Input Monitoring / Microphone grants survive updates.
///
/// macOS keys those grants to the program's code signature. The release binary is ad-hoc signed, whose
/// identity is its own hash, so every update looks like a new program and the grants are lost. Here a
/// self-signed certificate is created once on this Mac (private key never leaves it) in a dedicated
/// keychain, and every installed copy is signed with it under one bundle identifier. No Apple developer
/// account is involved. The grants then name the certificate plus identifier, which does not change.
public enum LocalSigning {
    public static let identityName = "mac-stt local signing"
    public static let bundleID = "io.github.sichanghe.mac-stt"

    public static var defaultKeychain: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/mac-stt-signing.keychain-db").path
    }
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
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func hasIdentity(_ keychain: String) -> Bool {
        guard FileManager.default.fileExists(atPath: keychain) else { return false }
        return exec(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning", keychain]).output.contains(identityName)
    }

    /// Creates the keychain and certificate if missing. Returns an error text on failure.
    static func ensureIdentity(keychain: String) -> String? {
        if hasIdentity(keychain) {
            exec(["/usr/bin/security", "unlock-keychain", "-p", "", keychain])
            return nil
        }
        let fm = FileManager.default
        try? fm.removeItem(atPath: keychain)
        let tmp = NSTemporaryDirectory() + "mac-stt-sign-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmp) }
        let config = """
            [req]
            distinguished_name = dn
            x509_extensions = ext
            prompt = no
            [dn]
            CN = \(identityName)
            [ext]
            basicConstraints = critical,CA:false
            keyUsage = critical,digitalSignature
            extendedKeyUsage = critical,codeSigning
            """
        do { try config.write(toFile: tmp + "/ssl.cnf", atomically: true, encoding: .utf8) } catch { return "\(error)" }
        let steps: [[String]] = [
            ["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-config", tmp + "/ssl.cnf",
                "-keyout", tmp + "/key.pem", "-out", tmp + "/cert.pem"],
            ["/usr/bin/openssl", "pkcs12", "-export", "-inkey", tmp + "/key.pem", "-in", tmp + "/cert.pem",
                "-out", tmp + "/id.p12", "-passout", "pass:mac-stt"],
            ["/usr/bin/security", "create-keychain", "-p", "", keychain],
            ["/usr/bin/security", "set-keychain-settings", keychain],
            ["/usr/bin/security", "unlock-keychain", "-p", "", keychain],
            ["/usr/bin/security", "import", tmp + "/id.p12", "-k", keychain, "-P", "mac-stt", "-T", "/usr/bin/codesign"],
            // codesign only uses identities macOS considers valid, so the new certificate must be trusted for
            // code signing. This may show one system password dialog.
            ["/usr/bin/security", "add-trusted-cert", "-p", "codeSign", "-k", keychain, tmp + "/cert.pem"],
            ["/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", "", keychain],
        ]
        for step in steps {
            let r = exec(step)
            if r.status != 0 { return "\(step[0..<min(3, step.count)].joined(separator: " ")) failed: \(r.output)" }
        }
        return hasIdentity(keychain) ? nil : "identity not found in new keychain"
    }

    static func codesign(_ path: String, keychain: String?) -> String? {
        var args = ["/usr/bin/codesign", "--force", "--identifier", bundleID]
        if let keychain { args += ["--sign", identityName, "--keychain", keychain] } else { args += ["--sign", "-"] }
        args.append(path)
        let r = exec(args)
        return r.status == 0 ? nil : r.output
    }

    /// Designated requirement text, e.g. `identifier "x" and certificate leaf = H"..."` (stable) or `cdhash H"..."`.
    public static func requirement(of path: String) -> String {
        exec(["/usr/bin/codesign", "-d", "-r-", path]).output
            .split(separator: "\n").first { $0.hasPrefix("designated") }.map(String.init) ?? "unknown"
    }

    /// Signs `cli` with the stable identity and (re)builds a signed app bundle that wraps a copy of it.
    /// The bundle is what `mac-stt app` runs, so macOS lists it in Accessibility and Input Monitoring.
    public static func setUpApp(cli: String, app: URL = defaultAppURL, keychain: String = defaultKeychain) -> String {
        var notes: [String] = []
        var useKeychain: String? = keychain
        if let problem = ensureIdentity(keychain: keychain) {
            notes.append("could not create the local signing identity (\(problem)); falling back to ad-hoc signing, so macOS permission grants will be lost on each update")
            useKeychain = nil
        }
        if let problem = codesign(cli, keychain: useKeychain) { notes.append("signing \(cli) failed: \(problem)") }
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
        if let problem = codesign(app.path, keychain: useKeychain) { notes.append("signing the app failed: \(problem)") }
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
