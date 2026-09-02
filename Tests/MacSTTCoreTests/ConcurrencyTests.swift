import MacSTTCore
import XCTest

final class ConcurrencyTests: XCTestCase {
    func testJobsStartWithoutWaitingForEarlierJob() async throws {
        let starts = StartTimes()
        let values = try await ConcurrentProcessor.map([0, 1]) { value in
            await starts.mark(value)
            try await Task.sleep(for: .milliseconds(150))
            return value
        }
        let times = await starts.values
        XCTAssertEqual(values, [0, 1])
        XCTAssertLessThan(abs(times[0]! - times[1]!), 0.08)
    }
}

private actor StartTimes {
    var values: [Int: TimeInterval] = [:]

    func mark(_ value: Int) {
        values[value] = Date().timeIntervalSinceReferenceDate
    }
}
