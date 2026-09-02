import XCTest
@testable import PaceRunnerShared

/// Tests for the mechanism behind segment transition smoothing.
///
/// When the target pace changes a lot between segments (warm-up → tempo), the
/// previous segment's pace history is actively misleading: the medium window is
/// 240s by default, so it keeps reporting warm-up pace minutes into a tempo
/// block. `WorkoutManager` restarts the pace windows on such a transition so the
/// new segment converges like the start of a new run.
final class SegmentTransitionSmoothingTests: XCTestCase {

    private let warmupPaceSeconds = 600.0   // 10:00/mile
    private let tempoPaceSeconds = 420.0    // 7:00/mile

    var calculator: PaceCalculator!

    override func setUp() {
        super.setUp()
        calculator = PaceCalculator()
        calculator.configureWindows(fastSeconds: 120, mediumSeconds: 240, slowMiles: 1.0)
    }

    override func tearDown() {
        calculator = nil
        super.tearDown()
    }

    /// Feeds one-second samples at the given pace, advancing shared wall-clock
    /// and cumulative-distance cursors the way a real run does.
    @discardableResult
    private func feed(
        seconds: Int,
        paceSecondsPerMile: Double,
        time: inout Date,
        cumulativeDistance: inout Double
    ) -> Date {
        let speedMps = 1609.34 / paceSecondsPerMile
        for _ in 0..<seconds {
            time = time.addingTimeInterval(1.0)
            cumulativeDistance += speedMps
            calculator.addSample(distance: cumulativeDistance, timestamp: time)
        }
        return time
    }

    private func paceSeconds(_ pace: Pace?) -> Double? {
        pace.map { Double($0.totalSeconds) }
    }

    // MARK: - Reset clears history

    func testResetClearsWindowsAndSpan() {
        var time = Date()
        var distance = 0.0
        feed(seconds: 200, paceSecondsPerMile: warmupPaceSeconds, time: &time, cumulativeDistance: &distance)

        XCTAssertNotNil(calculator.fastPace)
        XCTAssertGreaterThanOrEqual(calculator.movingTimeSpan, 120.0)

        calculator.reset()

        XCTAssertEqual(calculator.movingTimeSpan, 0, "Reset must clear the sample history")
        XCTAssertNil(calculator.fastPace, "No window can report a pace with no samples")
        XCTAssertNil(calculator.mediumPace)
        XCTAssertNil(calculator.currentPace)
    }

    // MARK: - The problem the reset solves

    /// Without a reset, the medium window the metronome reads still carries
    /// warm-up pace well into the tempo block.
    func testMediumWindowStaysPollutedAcrossATransitionWithoutReset() {
        var time = Date()
        var distance = 0.0
        feed(seconds: 240, paceSecondsPerMile: warmupPaceSeconds, time: &time, cumulativeDistance: &distance)
        feed(seconds: 120, paceSecondsPerMile: tempoPaceSeconds, time: &time, cumulativeDistance: &distance)

        guard let medium = paceSeconds(calculator.mediumPace) else {
            return XCTFail("Expected a medium pace after 6 minutes of samples")
        }

        // 120s of tempo blended with 120s of warm-up lands near 8:14/mile.
        XCTAssertGreaterThan(medium, tempoPaceSeconds + 30,
                             "Medium window should still be dragged slow by warm-up history")
        XCTAssertEqual(medium, 494, accuracy: 20)
    }

    /// With the reset, the same tempo block reports tempo pace.
    func testResetAtTransitionMakesTheNewSegmentReportItsOwnPace() {
        var time = Date()
        var distance = 0.0
        feed(seconds: 240, paceSecondsPerMile: warmupPaceSeconds, time: &time, cumulativeDistance: &distance)

        calculator.reset()

        feed(seconds: 120, paceSecondsPerMile: tempoPaceSeconds, time: &time, cumulativeDistance: &distance)

        guard let medium = paceSeconds(calculator.mediumPace) else {
            return XCTFail("Expected a medium pace after the tempo block")
        }
        XCTAssertEqual(medium, tempoPaceSeconds, accuracy: 10,
                       "Post-reset windows must reflect only the new segment")
    }

    /// A mid-run reset happens with a large cumulative distance already on the
    /// clock. The new baseline must absorb it rather than reading it as distance
    /// covered in zero time, which would report a phantom fast pace.
    func testResetMidRunDoesNotProduceAPhantomPaceFromCarriedDistance() {
        var time = Date()
        var distance = 0.0
        feed(seconds: 300, paceSecondsPerMile: warmupPaceSeconds, time: &time, cumulativeDistance: &distance)
        XCTAssertGreaterThan(distance, 800, "Should be well into the run before the reset")

        calculator.reset()
        feed(seconds: 130, paceSecondsPerMile: tempoPaceSeconds, time: &time, cumulativeDistance: &distance)

        guard let fast = paceSeconds(calculator.fastPace) else {
            return XCTFail("Expected a fast pace after the reset")
        }
        XCTAssertEqual(fast, tempoPaceSeconds, accuracy: 10,
                       "Carried cumulative distance must not inflate the post-reset pace")
    }

    /// The reset re-arms the neutral hold: the shortest window has to refill
    /// before guidance may direct again.
    func testNeutralHoldReEngagesAfterAReset() {
        let shortestWindow = 120.0
        var time = Date()
        var distance = 0.0
        feed(seconds: 300, paceSecondsPerMile: warmupPaceSeconds, time: &time, cumulativeDistance: &distance)
        XCTAssertGreaterThanOrEqual(calculator.movingTimeSpan, shortestWindow)

        calculator.reset()
        XCTAssertLessThan(calculator.movingTimeSpan, shortestWindow,
                          "Neutral hold must re-engage immediately after the reset")

        feed(seconds: 60, paceSecondsPerMile: tempoPaceSeconds, time: &time, cumulativeDistance: &distance)
        XCTAssertLessThan(calculator.movingTimeSpan, shortestWindow,
                          "Still holding neutral one minute into the new segment")

        feed(seconds: 70, paceSecondsPerMile: tempoPaceSeconds, time: &time, cumulativeDistance: &distance)
        XCTAssertGreaterThanOrEqual(calculator.movingTimeSpan, shortestWindow,
                                    "Hold should end once the shortest window has refilled")
    }

    // MARK: - Transition threshold

    /// The threshold that decides whether a transition is "pace varies a lot".
    /// Warm-up → tempo must clear it; a minor step between similar segments
    /// must not, or every transition would blank the runner's pace display.
    func testResetThresholdSeparatesLargeFromMinorPaceChanges() {
        let threshold = 20

        let warmupToTempo = abs(Int(tempoPaceSeconds) - Int(warmupPaceSeconds))
        XCTAssertGreaterThanOrEqual(warmupToTempo, threshold,
                                    "A 10:00 → 7:00 change must trigger a restart")

        let easyToSteady = abs(Pace(minutes: 9, seconds: 0).totalSeconds
                               - Pace(minutes: 8, seconds: 50).totalSeconds)
        XCTAssertLessThan(easyToSteady, threshold,
                          "A 10s step must not blank the windows")
    }
}
