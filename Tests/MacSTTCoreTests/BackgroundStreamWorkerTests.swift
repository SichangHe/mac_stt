import MacSTTCore
import XCTest

final class BackgroundStreamWorkerTests: XCTestCase {
    func testSlowBackgroundWorkDoesNotDelaySubmission() async throws {
        let worker = BackgroundStreamWorker<Int, [Int]>(
            capacity: 2,
            overflowError: WorkerError.overflow
        ) { stream in
            var values: [Int] = []
            for try await value in stream {
                try await Task.sleep(for: .milliseconds(250))
                values.append(value)
            }
            return values
        }
        let clock = ContinuousClock()
        let start = clock.now
        XCTAssertEqual(worker.send(1), .enqueued)
        XCTAssertEqual(worker.send(2), .enqueued)
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(50))
        XCTAssertEqual(try await worker.finish(), [1, 2])
    }
}

private enum WorkerError: Error {
    case overflow
}
