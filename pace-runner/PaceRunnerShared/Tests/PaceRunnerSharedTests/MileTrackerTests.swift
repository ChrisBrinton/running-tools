import XCTest
@testable import PaceRunnerShared

final class MileTrackerTests: XCTestCase {

    func testDetectsCompletedMiles() {
        let tracker = MileTracker()

        // Half mile -> no completion
        XCTAssertNil(tracker.updateDistance(804.67))
        XCTAssertEqual(tracker.mileIndex, 0)

        // Cross first mile
        XCTAssertEqual(tracker.updateDistance(1610), 1)
        XCTAssertEqual(tracker.mileIndex, 1)

        // Advance another mile
        XCTAssertEqual(tracker.updateDistance(3219), 2)
    }

    func testProgressWithinCurrentMile() {
        let tracker = MileTracker()
        tracker.updateDistance(0)
        tracker.updateDistance(400)

        XCTAssertGreaterThan(tracker.progressInCurrentMile, 0)
        XCTAssertLessThan(tracker.progressInCurrentMile, 1)

        tracker.updateDistance(1610)
        XCTAssertEqual(tracker.progressInCurrentMile, 0, accuracy: 0.001)
    }

    func testResetClearsState() {
        let tracker = MileTracker()
        tracker.updateDistance(1610)
        tracker.reset()

        XCTAssertEqual(tracker.mileIndex, 0)
        XCTAssertEqual(tracker.progressInCurrentMile, 0)
    }
}
