import Foundation

public enum ConcurrentProcessor {
    public static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        operation: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            for (index, input) in inputs.enumerated() {
                group.addTask { (index, try await operation(input)) }
            }
            var ordered = [Output?](repeating: nil, count: inputs.count)
            for try await (index, output) in group { ordered[index] = output }
            return ordered.compactMap { $0 }
        }
    }
}
