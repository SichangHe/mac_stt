import Foundation

public enum ComputePolicy: String, CaseIterable, Sendable {
    case ane
    case gpu
    case cpu
    case all

    public var explanation: String {
        switch self {
        case .ane: "CPU and Neural Engine are eligible; GPU is excluded"
        case .gpu: "CPU and GPU are eligible; Neural Engine is excluded"
        case .cpu: "only CPU is eligible"
        case .all: "Core ML may choose CPU, GPU, or Neural Engine"
        }
    }
}

public struct OutputOptions: Equatable, Sendable {
    // 🧑 “Results should be placed into the clipboard by default”
    public var copyToClipboard = true
    public var outputPath: String?

    public init(copyToClipboard: Bool = true, outputPath: String? = nil) {
        self.copyToClipboard = copyToClipboard
        self.outputPath = outputPath
    }
}

public struct ModelOptions: Equatable, Sendable {
    public var variant = Qwen3Variant.large
    public var language: String?
    public var compute = ComputePolicy.ane
    public var diarize = false
}

public struct TranscribeOptions: Equatable, Sendable {
    public let paths: [String]
    public let model: ModelOptions
    public let output: OutputOptions
    public var diarize: Bool { model.diarize }
    public var compute: ComputePolicy { model.compute }
}

public struct RecordOptions: Equatable, Sendable {
    public let inputPath: String?
    public let inputSpeed: Double
    public let model: ModelOptions
    public let output: OutputOptions
    public var diarize: Bool { model.diarize }
    public var compute: ComputePolicy { model.compute }
}

public struct ServeOptions: Equatable, Sendable {
    public let model: ModelOptions
    public let output: OutputOptions
}

public enum ControlVerb: String, CaseIterable, Sendable {
    case toggle, start, stop, status, quit
}

public enum Command: Equatable, Sendable {
    case help
    case doctor
    case report
    case setup(ModelOptions)
    case serve(ServeOptions)
    case control(ControlVerb)
    case app(hotkey: Hotkey, foreground: Bool)
    case appInstall(hotkey: Hotkey)
    case appUninstall
    case appSetup
    case transcribe(TranscribeOptions)
    case record(RecordOptions)
    case profileModels(paths: [String], compute: ComputePolicy)
}

public enum CLIError: Error, LocalizedError, Equatable {
    case missingCommand
    case missingValue(String)
    case missingInput(String)
    case unknownCommand(String)
    case unknownOption(String)
    case invalidCompute(String)
    case invalidValue(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingCommand: "missing command"
        case .missingValue(let option): "missing value for \(option)"
        case .missingInput(let command): "\(command) needs at least one input path"
        case .unknownCommand(let command): "unknown command: \(command)"
        case .unknownOption(let option): "unknown option: \(option)"
        case .invalidCompute(let value): "invalid compute policy \(value); use ane, gpu, cpu, or all"
        case .invalidValue(let option, let value): "invalid value \(value) for \(option)"
        }
    }
}

public enum CLIParser {
    public static func parse(_ arguments: [String]) throws -> Command {
        guard let name = arguments.first else { throw CLIError.missingCommand }
        let rest = Array(arguments.dropFirst())
        switch name {
        case "help", "--help", "-h": return .help
        case "report":
            guard rest.isEmpty else { throw CLIError.unknownOption(rest[0]) }
            return .report
        case "doctor":
            guard rest.isEmpty else { throw CLIError.unknownOption(rest[0]) }
            return .doctor
        case "setup":
            let parsed = try parseShared(rest, allowsDiarization: true, allowsInput: false)
            guard parsed.paths.isEmpty else { throw CLIError.unknownOption(parsed.paths[0]) }
            return .setup(parsed.model)
        case "serve":
            let parsed = try parseShared(rest, allowsDiarization: true, allowsInput: false)
            guard parsed.paths.isEmpty else { throw CLIError.unknownOption(parsed.paths[0]) }
            return .serve(ServeOptions(model: parsed.model, output: parsed.output))
        case "app":
            var rest = rest
            var mode = "run"
            if let first = rest.first, first == "install" || first == "uninstall" || first == "setup" {
                mode = first
                rest.removeFirst()
            }
            var spec = Hotkey.defaultSpec
            var foreground = false
            var i = 0
            while i < rest.count {
                switch rest[i] {
                case "--hotkey":
                    guard i + 1 < rest.count else { throw CLIError.missingValue("--hotkey") }
                    spec = rest[i + 1]
                    i += 1
                case "--foreground": foreground = true
                default: throw CLIError.unknownOption(rest[i])
                }
                i += 1
            }
            let key = try Hotkey(spec)
            switch mode {
            case "install": return .appInstall(hotkey: key)
            case "uninstall": return .appUninstall
            case "setup": return .appSetup
            default: return .app(hotkey: key, foreground: foreground)
            }
        case "toggle", "start", "stop", "status", "quit":
            guard rest.isEmpty else { throw CLIError.unknownOption(rest[0]) }
            return .control(ControlVerb(rawValue: name)!)
        case "transcribe":
            let parsed = try parseShared(rest, allowsDiarization: true, allowsInput: false)
            guard !parsed.paths.isEmpty else { throw CLIError.missingInput(name) }
            return .transcribe(
                TranscribeOptions(
                    paths: parsed.paths,
                    model: parsed.model,
                    output: parsed.output
                ))
        case "record":
            let parsed = try parseShared(rest, allowsDiarization: true, allowsInput: true)
            guard parsed.paths.isEmpty else { throw CLIError.unknownOption(parsed.paths[0]) }
            return .record(
                RecordOptions(
                    inputPath: parsed.inputPath,
                    inputSpeed: parsed.speed,
                    model: parsed.model,
                    output: parsed.output
                ))
        case "profile-model":
            let parsed = try parseShared(rest, allowsDiarization: false, allowsInput: false)
            guard !parsed.paths.isEmpty else { throw CLIError.missingInput(name) }
            guard parsed.output == OutputOptions() else {
                throw CLIError.unknownOption("output option")
            }
            return .profileModels(paths: parsed.paths, compute: parsed.model.compute)
        default: throw CLIError.unknownCommand(name)
        }
    }

    private static func parseShared(
        _ arguments: [String],
        allowsDiarization: Bool,
        allowsInput: Bool
    ) throws -> (
        paths: [String], inputPath: String?, speed: Double,
        model: ModelOptions, output: OutputOptions
    ) {
        var paths: [String] = []
        var inputPath: String?
        var speed = 1.0
        var model = ModelOptions()
        var output = OutputOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--diarize" where allowsDiarization:
                model.diarize = true
            case "--model":
                index += 1
                guard index < arguments.count else { throw CLIError.missingValue(argument) }
                guard let value = Qwen3Variant(rawValue: arguments[index]) else {
                    throw CLIError.invalidValue(argument, arguments[index])
                }
                model.variant = value
            case "--language":
                index += 1
                guard index < arguments.count else { throw CLIError.missingValue(argument) }
                model.language = arguments[index]
            case "--input-speed" where allowsInput:
                index += 1
                guard index < arguments.count else { throw CLIError.missingValue(argument) }
                guard let value = Double(arguments[index]), value > 0 else {
                    throw CLIError.invalidValue(argument, arguments[index])
                }
                speed = value
            case "--input" where allowsInput:
                index += 1
                guard index < arguments.count else { throw CLIError.missingValue(argument) }
                inputPath = arguments[index]
            case "--no-clipboard":
                output.copyToClipboard = false
            case "--output", "-o":
                index += 1
                guard index < arguments.count else { throw CLIError.missingValue(argument) }
                output.outputPath = arguments[index]
            case "--compute":
                index += 1
                guard index < arguments.count else { throw CLIError.missingValue(argument) }
                guard let value = ComputePolicy(rawValue: arguments[index]) else {
                    throw CLIError.invalidCompute(arguments[index])
                }
                model.compute = value
            case let value where value.hasPrefix("-"):
                throw CLIError.unknownOption(value)
            default:
                paths.append(argument)
            }
            index += 1
        }
        return (paths, inputPath, speed, model, output)
    }
}

public let usage = """
mac-stt — on-device Qwen3-ASR speech-to-text for Apple Silicon

usage:
  mac-stt setup [--model 1.7b|0.6b]      download and verify models, warm the Neural Engine cache
  mac-stt serve [--diarize] [--no-clipboard]   keep models warm and wait for toggle commands
  mac-stt toggle                        start recording; run again to stop, transcribe, and copy
  mac-stt start | stop                  start or stop recording explicitly
  mac-stt status                        report whether `serve` is idle or recording
  mac-stt quit                          exit the background `serve` (it also exits after 10 min idle)
  mac-stt app [--hotkey KEY]            menu-bar icon + global key, runs in the background; pastes on finish
                                        KEY: dictation (mic key, default) or e.g. ctrl+opt+d, cmd+shift+space, ctrl+f5
  mac-stt app install | uninstall       start the app at login (LaunchAgent) or stop doing so
  mac-stt app setup                     (re)build ~/Applications/mac-stt.app, the signed app that
                                        macOS lists under Accessibility/Input Monitoring; the installer runs this
  mac-stt record [--input FILE] [--diarize]    one take in this terminal; Control-C finishes
  mac-stt transcribe FILE... [--diarize]
  mac-stt profile-model MODEL.mlmodelc... [--compute ane|gpu|cpu|all]
  mac-stt doctor
  mac-stt report                        save logs + system info to one file and open a prefilled GitHub issue
                                        (nothing is uploaded; background logs: ~/Library/Application Support/mac-stt/)

options: --model 1.7b|0.6b  --language CODE (default: detect)  --compute ane|gpu|cpu|all
         --no-clipboard  -o PATH  --input-speed N (record --input pacing, default 1)

`mac-stt app` needs no hotkey tool; pasting needs Accessibility permission (asked once).
Alternatively bind `mac-stt toggle` to a key with any hotkey tool (Shortcuts, skhd, Karabiner, Raycast). The first `toggle` starts `serve` in the background if it is not running.
Compute `ane` means the audio encoder may use CPU and Neural Engine and the decoder CPU and GPU.
That is a configuration, not proof of placement: use `profile-model` and `powermetrics`.
"""
