import XCTest
@testable import PaceRunnerShared

final class PaceCalculatorTests: XCTestCase {

    func testProducesSmoothedPaceForConsistentSamples() {
        let calculator = PaceCalculator()
        let start = Date()
        var distance: Double = 0

        calculator.addSample(distance: 0, timestamp: start)

        for index in 1...12 {
            distance += 10 // meters
            let timestamp = start.addingTimeInterval(Double(index) * 3.0)
            calculator.addSample(distance: distance, timestamp: timestamp)
        }

        guard let pace = calculator.currentPace else {
            XCTFail("Expected pace after feeding samples")
            return
        }

        // Each iteration represents roughly an 8:00-pace
        XCTAssertTrue(abs(pace.totalSeconds - 480) <= 10,
                      "Expected ~8:00 pace, got \(pace.formatted)")
    }

    func testIgnoresUnrealisticSamples() {
        let calculator = PaceCalculator()
        let start = Date()

        // First valid sample primes state
        calculator.addSample(distance: 0, timestamp: start)
        calculator.addSample(distance: 15, timestamp: start.addingTimeInterval(3))

        // Unrealistic jump (40m in 1s -> 40 m/s) should be ignored
        calculator.addSample(distance: 55, timestamp: start.addingTimeInterval(4))

        XCTAssertNotNil(calculator.currentPace, "Valid samples should still produce pace")
        let previous = calculator.currentPace

        // Feed another valid sample and ensure pace updates smoothly
        calculator.addSample(distance: 70, timestamp: start.addingTimeInterval(7))

        XCTAssertNotNil(calculator.currentPace)
        XCTAssertNotEqual(previous?.totalSeconds, calculator.currentPace?.totalSeconds)
    }

    func testPaceStatusCalculation() {
        let calculator = PaceCalculator()
        let start = Date()
        calculator.addSample(distance: 0, timestamp: start)

        // Feed enough samples for roughly 9:00/mile pace
        var distance: Double = 0
        for index in 1...10 {
            distance += 10
            let timestamp = start.addingTimeInterval(Double(index) * 3.5)
            calculator.addSample(distance: distance, timestamp: timestamp)
        }

        let target = Pace(minutes: 8, seconds: 30)

        let status = calculator.paceStatus(targetPace: target, tolerance: 5)
        switch status {
        case .tooSlow(let deviation):
            XCTAssertGreaterThan(deviation, 0)
        default:
            XCTFail("Expected slow status, got \(status)")
        }
    }

    func testResetClearsSamples() {
        let calculator = PaceCalculator()
        let now = Date()
        calculator.addSample(distance: 0, timestamp: now)
        calculator.addSample(distance: 15, timestamp: now.addingTimeInterval(3))
        XCTAssertNotNil(calculator.currentPace)

        calculator.reset()
        XCTAssertNil(calculator.currentPace)
    }

    /// A mid-workout pause must not be counted as running time by the rolling
    /// pace windows. Regression test for the "moving average included the
    /// 5-minute pause" bug: feed a steady ~8:00 pace, pause 5 minutes, resume
    /// at the same pace, and confirm the master pace is unchanged rather than
    /// dragged toward a crawl.
    func testPauseIsNotCountedInMovingAverage() {
        let calculator = PaceCalculator()
        let start = Date()
        var distance = 0.0
        var elapsed = 0.0

        // ~8:00/mi: 10 m every 3 s (3.33 m/s -> 8:03/mi).
        calculator.addSample(distance: 0, timestamp: start)
        for _ in 1...20 {
            distance += 10
            elapsed += 3
            calculator.addSample(distance: distance, timestamp: start.addingTimeInterval(elapsed))
        }
        guard let before = calculator.slowPace else {
            XCTFail("Expected master pace before pause")
            return
        }

        // Pause 5 minutes, then resume and keep running at the same pace. The
        // post-resume timestamps are 300 s later in wall-clock, as they would
        // be on the watch.
        let pause = 300.0
        calculator.notePauseGap(pause)
        for _ in 1...20 {
            distance += 10
            elapsed += 3
            calculator.addSample(distance: distance, timestamp: start.addingTimeInterval(elapsed + pause))
        }
        guard let after = calculator.slowPace else {
            XCTFail("Expected master pace after resume")
            return
        }

        // Without the fix, timeTaken would include the 300 s pause and pace
        // would balloon past 25:00/mi. It should instead stay ~8:00.
        XCTAssertLessThan(after.totalSeconds, 600,
                          "Master pace must exclude paused time (got \(after.formatted))")
        XCTAssertEqual(after.totalSeconds, before.totalSeconds, accuracy: 60,
                       "Master pace should be ~unchanged across a pause (before \(before.formatted), after \(after.formatted))")
    }
}
