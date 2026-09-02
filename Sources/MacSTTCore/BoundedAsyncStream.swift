import Foundation

public enum BoundedYieldResult: Equatable, Sendable {
    case enqueued
    case dropped
    case terminated
}

public final class BoundedAsyncStream<Element>: @unchecked Sendable {
    public let stream: AsyncThrowingStream<Element, Error>
    private let continuation: AsyncThrowingStream<Element, Error>.Continuation
    private let overflowError: any Error

    public init(capacity: Int, overflowError: any Error) {
        let pair = AsyncThrowingStream<Element, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(max(1, capacity))
        )
        stream = pair.stream
        continuation = pair.continuation
        self.overflowError = overflowError
    }

    public func yield(_ element: sending Element) -> BoundedYieldResult {
        switch continuation.yield(element) {
        case .enqueued:
            return .enqueued
        case .dropped:
            continuation.finish(throwing: overflowError)
            return .dropped
        case .terminated:
            return .terminated
        @unknown default:
            continuation.finish(throwing: overflowError)
            return .dropped
        }
    }

    public func finish() {
        continuation.finish()
    }
}
