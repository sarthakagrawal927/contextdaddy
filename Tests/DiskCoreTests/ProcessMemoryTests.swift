import XCTest
@testable import DiskCore

final class ProcessMemoryTests: XCTestCase {
    func testReadCounterDeltaRejectsResetAndComputesMonotonicDifference() {
        XCTAssertEqual(DiskReadMetric.bytesRead(from: 40, to: 64), 24)
        XCTAssertEqual(DiskReadMetric.bytesRead(from: 64, to: 64), 0)
        XCTAssertNil(DiskReadMetric.bytesRead(from: 64, to: 40))
        XCTAssertNil(DiskReadMetric.bytesRead(from: nil, to: 64))
    }

    func testReadRateUsesDecimalMegabytesAndRequiresPositiveElapsedTime() {
        XCTAssertEqual(DiskReadMetric.megabytesPerSecond(bytesRead: 3_000_000, elapsed: 2), 1.5)
        XCTAssertEqual(DiskReadMetric.megabytesPerSecond(bytesRead: 0, elapsed: 2), 0)
        XCTAssertNil(DiskReadMetric.megabytesPerSecond(bytesRead: 1, elapsed: 0))
        XCTAssertNil(DiskReadMetric.megabytesPerSecond(bytesRead: 1, elapsed: .infinity))
    }

    func testOwnProcessDiskReadCounterIsAvailableAndMonotonic() throws {
        let first = try XCTUnwrap(ProcessMemory.diskReadBytes())
        let second = try XCTUnwrap(ProcessMemory.diskReadBytes())
        XCTAssertGreaterThanOrEqual(second, first)
    }
}
