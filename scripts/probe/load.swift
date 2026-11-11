import CoreML
import Metal
import Foundation
print("os:", ProcessInfo.processInfo.operatingSystemVersionString)
print("metal devices:", MTLCopyAllDevices().map { $0.name })
let url = URL(fileURLWithPath: CommandLine.arguments[1])
for (name, units) in [("cpuAndGPU", MLComputeUnits.cpuAndGPU), ("cpuAndNeuralEngine", .cpuAndNeuralEngine)] {
    let c = MLModelConfiguration(); c.computeUnits = units
    let t = Date()
    do { _ = try MLModel(contentsOf: url, configuration: c); print("\(name): loaded in \(Date().timeIntervalSince(t)) s") }
    catch { print("\(name): load failed: \(error)") }
}
