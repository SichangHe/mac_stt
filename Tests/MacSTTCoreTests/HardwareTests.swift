import MacSTTCore
import XCTest

final class HardwareTests: XCTestCase {
    func testPlacementReportDoesNotCallPlanObservedRuntime() {
        let report = PlacementReport(
            model: "Encoder.mlmodelc",
            neuralEngineOperations: 9,
            gpuOperations: 0,
            cpuOperations: 1,
            otherOperations: 0
        )
        XCTAssertTrue(report.rendered.contains("plan ANE 90.0%"))
        XCTAssertFalse(report.rendered.lowercased().contains("observed"))
    }
}
