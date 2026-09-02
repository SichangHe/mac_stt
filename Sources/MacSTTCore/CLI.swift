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

public struct TranscribeOptions: Equatable, Sendable {
    public let paths: [String]
    public let diarize: Bool
    public let compute: ComputePolicy
    public let output: OutputOptions
}

public struct RecordOptions: Equatable, Sendable {
    public let inputPath: String?
    public let diarize: Bool
    public let compute: ComputePolicy
    public let output: OutputOptions
}

public enum Command: Equatable, Sendable {
    case help
    case doctor
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

    public var errorDescription: String? {
        switch self {
        case .missingCommand: "missing command"
        case .missingValue(let option): "missing value for \(option)"
        case .missingInput(let command): "\(command) needs at least one input path"
        case .unknownCommand(let command): "unknown command: \(command)"
        case .unknownOption(let option): "unknown option: \(option)"
        case .invalidCompute(let value): "invalid compute policy \(value); use ane, gpu, cpu, or all"
        }
    }
}

public enum CLIParser {
    public static func parse(_ arguments: [String]) throws -> Command {
        guard let name = arguments.first else { throw CLIError.missingCommand }
        let rest = Array(arguments.dropFirst())
        switch name {
        case "help", "--help", "-h": return .help
        case "doctor":
            guard rest.isEmpty else { throw CLIError.unknownOption(rest[0]) }
            return .doctor
        case "transcribe":
            let parsed = try parseShared(rest, allowsDiarization: true, allowsInput: false)
            guard !parsed.paths.isEmpty else { throw CLIError.missingInput(name) }
            return .transcribe(
                TranscribeOptions(
                    paths: parsed.paths,
                    diarize: parsed.diarize,
                    compute: parsed.compute,
                    output: parsed.output
                ))
        case "record":
            let parsed = try parseShared(rest, allowsDiarization: true, allowsInput: true)
            guard parsed.paths.isEmpty else { throw CLIError.unknownOption(parsed.paths[0]) }
            return .record(
                RecordOptions(
                    inputPath: parsed.inputPath,
                    diarize: parsed.diarize,
                    compute: parsed.compute,
                    output: parsed.output
                ))
        case "profile-model":
            let parsed = try parseShared(rest, allowsDiarization: false, allowsInput: false)
            guard !parsed.paths.isEmpty else { throw CLIError.missingInput(name) }
            guard parsed.output == OutputOptions() else {
                throw CLIError.unknownOption("output option")
            }
            return .profileModels(paths: parsed.paths, compute: parsed.compute)
        default: throw CLIError.unknownCommand(name)
        }
    }

    private static func parseShared(
        _ arguments: [String],
        allowsDiarization: Bool,
        allowsInput: Bool
    ) throws -> (
        paths: [String], inputPath: String?, diarize: Bool,
        compute: ComputePolicy, output: OutputOptions
    ) {
        var paths: [String] = []
        var inputPath: String?
        var diarize = false
        var compute = ComputePolicy.ane
        var output = OutputOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--diarize" where allowsDiarization:
                diarize = true
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
                compute = value
            case let value where value.hasPrefix("-"):
                throw CLIError.unknownOption(value)
            default:
                paths.append(argument)
            }
            index += 1
        }
        return (paths, inputPath, diarize, compute, output)
    }
}

public let usage = """
mac-stt — local Parakeet speech-to-text for Apple Silicon

usage:
  mac-stt record [--input FILE] [--diarize] [--compute ane|gpu|cpu|all] [--no-clipboard] [-o PATH]
  mac-stt transcribe FILE... [--diarize] [--compute ane|gpu|cpu|all] [--no-clipboard] [-o PATH]
  mac-stt profile-model MODEL.mlmodelc... [--compute ane|gpu|cpu|all]
  mac-stt doctor

record prints changing partial text while the microphone is live; press Control-C to finish.
With --input, record feeds a finite audio file through the same Unified streaming pipeline.
The default `ane` policy permits CPU and Neural Engine but cannot by itself prove ANE execution.
Use `profile-model` for the Core ML placement plan and `powermetrics` for runtime confirmation.
"""
