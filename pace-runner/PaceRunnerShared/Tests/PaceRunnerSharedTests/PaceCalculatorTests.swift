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
}
