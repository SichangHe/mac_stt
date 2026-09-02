@preconcurrency import CoreML
import Foundation

public enum HardwareError: Error, LocalizedError {
    case requiresAppleSilicon
    case requiresMacOS144ForPlan
    case noOperations(String)

    public var errorDescription: String? {
        switch self {
        case .requiresAppleSilicon: "mac-stt requires an Apple Silicon Mac"
        case .requiresMacOS144ForPlan: "model placement inspection requires macOS 14.4 or newer"
        case .noOperations(let model): "Core ML returned no scheduled operations for \(model)"
        }
    }
}

public enum Hardware {
    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    public static func requireAppleSilicon() throws {
        guard isAppleSilicon else { throw HardwareError.requiresAppleSilicon }
    }
}

public struct PlacementReport: Equatable, Sendable {
    public let model: String
    public let neuralEngineOperations: Int
    public let gpuOperations: Int
    public let cpuOperations: Int
    public let otherOperations: Int

    public var totalOperations: Int {
        neuralEngineOperations + gpuOperations + cpuOperations + otherOperations
    }

    public var rendered: String {
        "\(model): plan ANE \(percent(neuralEngineOperations)), GPU \(percent(gpuOperations)), CPU \(percent(cpuOperations)); \(totalOperations) operations"
    }

    private func percent(_ count: Int) -> String {
        guard totalOperations > 0 else { return "n/a" }
        return String(format: "%.1f%%", 100 * Double(count) / Double(totalOperations))
    }
}

public enum ModelProfiler {
    public static func profile(paths: [String], compute: ComputePolicy) async throws -> [PlacementReport] {
        try Hardware.requireAppleSilicon()
        guard #available(macOS 14.4, *) else { throw HardwareError.requiresMacOS144ForPlan }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = compute.mlComputeUnits
        var reports: [PlacementReport] = []
        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
            let counts = countDevices(in: plan.modelStructure, plan: plan)
            guard counts.total > 0 else { throw HardwareError.noOperations(url.lastPathComponent) }
            reports.append(
                PlacementReport(
                    model: url.lastPathComponent,
                    neuralEngineOperations: counts.ane,
                    gpuOperations: counts.gpu,
                    cpuOperations: counts.cpu,
                    otherOperations: counts.other
                ))
        }
        return reports
    }

    @available(macOS 14.4, *)
    private static func countDevices(
        in structure: MLModelStructure,
        plan: MLComputePlan
    ) -> DeviceCounts {
        var counts = DeviceCounts()
        switch structure {
        case .program(let program):
            for function in program.functions.values {
                countOperations(function.block.operations, plan: plan, counts: &counts)
            }
        case .neuralNetwork(let network):
            for layer in network.layers {
                if let device = plan.deviceUsage(for: layer)?.preferred {
                    counts.add(device)
                }
            }
        case .pipeline(let pipeline):
            for model in pipeline.subModels {
                counts += countDevices(in: model, plan: plan)
            }
        case .unsupported:
            break
        @unknown default:
            break
        }
        return counts
    }

    @available(macOS 14.4, *)
    private static func countOperations(
        _ operations: [MLModelStructure.Program.Operation],
        plan: MLComputePlan,
        counts: inout DeviceCounts
    ) {
        for operation in operations {
            if let device = plan.deviceUsage(for: operation)?.preferred {
                counts.add(device)
            }
            for block in operation.blocks {
                countOperations(block.operations, plan: plan, counts: &counts)
            }
        }
    }
}

private struct DeviceCounts {
    var ane = 0
    var gpu = 0
    var cpu = 0
    var other = 0
    var total: Int { ane + gpu + cpu + other }

    mutating func add(_ device: MLComputeDevice) {
        switch device {
        case .neuralEngine: ane += 1
        case .gpu: gpu += 1
        case .cpu: cpu += 1
        @unknown default: other += 1
        }
    }

    static func += (left: inout DeviceCounts, right: DeviceCounts) {
        left.ane += right.ane
        left.gpu += right.gpu
        left.cpu += right.cpu
        left.other += right.other
    }
}

extension ComputePolicy {
    public var mlComputeUnits: MLComputeUnits {
        switch self {
        case .ane: .cpuAndNeuralEngine
        case .gpu: .cpuAndGPU
        case .cpu: .cpuOnly
        case .all: .all
        }
    }
}
