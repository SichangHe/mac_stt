import MacSTTCore
import XCTest

final class BoundedAsyncStreamTests: XCTestCase {
    func testOverflowIsBoundedAndExplicit() async {
        let queue = BoundedAsyncStream<Int>(capacity: 1, overflowError: TestError.overflow)
        XCTAssertEqual(queue.yield(1), .enqueued)
        XCTAssertEqual(queue.yield(2), .dropped)
        do {
            for try await _ in queue.stream {}
            XCTFail("overflow should terminate with an error")
        } catch {
            XCTAssertEqual(error as? TestError, .overflow)
        }
    }

    func testFinishTerminatesAStreamWithNoElements() async throws {
        let queue = BoundedAsyncStream<Int>(capacity: 1, overflowError: TestError.overflow)
        queue.finish()
        XCTAssertEqual(queue.yield(1), .terminated)
        var values: [Int] = []
        for try await value in queue.stream { values.append(value) }
        XCTAssertTrue(values.isEmpty)
    }
}

private enum TestError: Error, Equatable {
    case overflow
}
