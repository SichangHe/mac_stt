import Foundation

public final class BackgroundStreamWorker<Element: Sendable, Output: Sendable>: @unchecked Sendable {
    private let queue: BoundedAsyncStream<Element>
    private let task: Task<Output, Error>

    public init(
        capacity: Int,
        overflowError: any Error,
        operation: @escaping @Sendable (AsyncThrowingStream<Element, Error>) async throws -> Output
    ) {
        let queue = BoundedAsyncStream<Element>(capacity: capacity, overflowError: overflowError)
        self.queue = queue
        let stream = queue.stream
        task = Task.detached(priority: .userInitiated) {
            try await operation(stream)
        }
    }

    public func send(_ element: sending Element) -> BoundedYieldResult {
        queue.yield(element)
    }

    public func finish() async throws -> Output {
        queue.finish()
        return try await task.value
    }
}
