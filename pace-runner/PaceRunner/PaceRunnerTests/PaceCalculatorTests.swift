import XCTest
@testable import PaceRunnerShared

/// Tests for PaceCalculator with realistic noisy GPS data
final class PaceCalculatorTests: XCTestCase {

    var calculator: PaceCalculator!

    override func setUp() {
        super.setUp()
        calculator = PaceCalculator()
    }

    override func tearDown() {
        calculator = nil
        super.tearDown()
    }

    /// Test that 1-min and 3-min paces differ when using noisy GPS data
    /// They should NOT match because they use different time windows
    func testTimeWindowPacesDivergeWithNoisyData() {
        // Simulate 5 minutes of running at ~8:00/mile pace with realistic GPS noise
        // Distance variance: ±5% per sample
        // Speed variance: ±10% per sample
        let targetSpeedMPS = 3.35 // ~8:00/mile = 3.35 m/s
        var currentTime = Date()
        var totalDistance = 0.0

        // Generate 300 samples (5 minutes at 1Hz)
        for i in 0..<300 {
            // Add realistic GPS noise
            let speedVariance = Double.random(in: -0.35...0.35) // ±10% of 3.35
            let noisySpeed = targetSpeedMPS + speedVariance

            // Calculate distance increment (should be ~3.35m but with noise)
            let distanceIncrement = noisySpeed + Double.random(in: -0.2...0.2)
            totalDistance += max(0.1, distanceIncrement) // Ensure positive

            currentTime = currentTime.addingTimeInterval(1.0)
            calculator.addSample(distance: totalDistance, timestamp: currentTime)

            // After 3 minutes, check that 1-min and 3-min paces are different
            if i == 180 { // 3 minutes in
                let oneMin = calculator.oneMinutePace
                let threeMin = calculator.threeMinutePace

                XCTAssertNotNil(oneMin, "1-minute pace should be available after 3 minutes")
                XCTAssertNotNil(threeMin, "3-minute pace should be available after 3 minutes")

                if let oneMin = oneMin, let threeMin = threeMin {
                    // They should be different due to different time windows
                    // With noisy data, expect at least 1-2 seconds difference
                    let difference = abs(oneMin.totalSeconds - threeMin.totalSeconds)

                    print("At 3 minutes:")
                    print("  1-min pace: \(oneMin.formatted)")
                    print("  3-min pace: \(threeMin.formatted)")
                    print("  Difference: \(difference) seconds")

                    // They should NOT be identical (would indicate a bug)
                    XCTAssertNotEqual(oneMin.totalSeconds, threeMin.totalSeconds,
                                    "1-min and 3-min paces should differ with noisy GPS data")

                    // But they should be reasonably close (within 30 seconds for ~8:00 pace)
                    XCTAssertLessThan(difference, 30,
                                    "Paces should be within 30 seconds of each other")
                }
            }
        }

        // Final check: at 5 minutes, both should exist but differ
        let finalOneMin = calculator.oneMinutePace
        let finalThreeMin = calculator.threeMinutePace

        XCTAssertNotNil(finalOneMin, "1-minute pace should exist at end")
        XCTAssertNotNil(finalThreeMin, "3-minute pace should exist at end")

        if let oneMin = finalOneMin, let threeMin = finalThreeMin {
            print("\nAt 5 minutes:")
            print("  1-min pace: \(oneMin.formatted)")
            print("  3-min pace: \(threeMin.formatted)")
            print("  Difference: \(abs(oneMin.totalSeconds - threeMin.totalSeconds)) seconds")

            XCTAssertNotEqual(oneMin.totalSeconds, threeMin.totalSeconds,
                            "1-min and 3-min paces should differ at end of run")
        }
    }

    /// Test that split pace and trailing mile pace match during first mile
    func testSplitAndTrailingMileMatchInFirstMile() {
        let targetSpeedMPS = 3.35 // ~8:00/mile
        var currentTime = Date()
        var totalDistance = 0.0

        // Run for 0.5 miles (804m) with minimal noise
        let targetDistance = 804.0

        while totalDistance < targetDistance {
            let speedVariance = Double.random(in: -0.1...0.1) // Small variance
            let noisySpeed = targetSpeedMPS + speedVariance
            let distanceIncrement = noisySpeed + Double.random(in: -0.05...0.05)

            totalDistance += max(0.1, distanceIncrement)
            currentTime = currentTime.addingTimeInterval(1.0)
            calculator.addSample(distance: totalDistance, timestamp: currentTime)
        }

        // Get trailing mile pace
        let trailingMile = calculator.trailingMilePace
        XCTAssertNotNil(trailingMile, "Trailing mile pace should exist after 0.5 miles")

        // Calculate expected split pace manually (total distance / total time)
        let totalTime = currentTime.timeIntervalSince(Date())
        let expectedPace = (totalTime / totalDistance) * 1609.34 // seconds per mile

        if let trailing = trailingMile {
            let difference = abs(Double(trailing.totalSeconds) - expectedPace)
            print("\nFirst mile test:")
            print("  Trailing mile pace: \(trailing.formatted)")
            print("  Expected pace: \(Int(expectedPace)) seconds")
            print("  Difference: \(difference) seconds")

            // Should be very close (within 5 seconds due to sample timing)
            XCTAssertLessThan(difference, 5.0,
                            "Trailing mile should match expected pace in first mile")
        }
    }

    /// Test pace calculation with speed changes
    func testPaceAdjustsToSpeedChanges() {
        var currentTime = Date()
        var totalDistance = 0.0

        // Run at 8:00/mile pace (3.35 m/s) for 2 minutes
        let slowSpeed = 3.35
        for _ in 0..<120 {
            totalDistance += slowSpeed + Double.random(in: -0.1...0.1)
            currentTime = currentTime.addingTimeInterval(1.0)
            calculator.addSample(distance: totalDistance, timestamp: currentTime)
        }

        let paceAtSlow = calculator.oneMinutePace

        // Speed up to 7:00/mile pace (3.83 m/s) for 2 minutes
        let fastSpeed = 3.83
        for _ in 0..<120 {
            totalDistance += fastSpeed + Double.random(in: -0.1...0.1)
            currentTime = currentTime.addingTimeInterval(1.0)
            calculator.addSample(distance: totalDistance, timestamp: currentTime)
        }

        let paceAtFast = calculator.oneMinutePace

        XCTAssertNotNil(paceAtSlow, "Should have pace at slow speed")
        XCTAssertNotNil(paceAtFast, "Should have pace at fast speed")

        if let slow = paceAtSlow, let fast = paceAtFast {
            print("\nSpeed change test:")
            print("  Pace at slow speed (8:00): \(slow.formatted)")
            print("  Pace at fast speed (7:00): \(fast.formatted)")

            // Fast pace should be faster (lower seconds)
            XCTAssertLessThan(fast.totalSeconds, slow.totalSeconds,
                            "Pace should reflect speed increase")

            // Should show noticeable difference (at least 30 seconds)
            let difference = slow.totalSeconds - fast.totalSeconds
            XCTAssertGreaterThan(difference, 30,
                               "Should show significant pace improvement")
        }
    }

    /// Test that outliers are filtered
    func testOutlierFiltering() {
        var currentTime = Date()
        var totalDistance = 0.0
        let normalSpeed = 3.35 // 8:00/mile

        // Add 120 normal samples
        for _ in 0..<120 {
            totalDistance += normalSpeed + Double.random(in: -0.1...0.1)
            currentTime = currentTime.addingTimeInterval(1.0)
            calculator.addSample(distance: totalDistance, timestamp: currentTime)
        }

        let normalPace = calculator.oneMinutePace

        // Add some GPS spikes (very fast, like standing still then jumping)
        for _ in 0..<5 {
            totalDistance += 15.0 // Unrealistic spike (would be ~3:00/mile)
            currentTime = currentTime.addingTimeInterval(1.0)
            calculator.addSample(distance: totalDistance, timestamp: currentTime)
        }

        // Continue with normal data
        for _ in 0..<60 {
            totalDistance += normalSpeed + Double.random(in: -0.1...0.1)
            currentTime = currentTime.addingTimeInterval(1.0)
            calculator.addSample(distance: totalDistance, timestamp: currentTime)
        }

        let paceAfterSpikes = calculator.oneMinutePace

        XCTAssertNotNil(normalPace, "Should have pace before spikes")
        XCTAssertNotNil(paceAfterSpikes, "Should have pace after spikes")

        if let normal = normalPace, let after = paceAfterSpikes {
            let difference = abs(normal.totalSeconds - after.totalSeconds)

            print("\nOutlier filtering test:")
            print("  Normal pace: \(normal.formatted)")
            print("  Pace after spikes: \(after.formatted)")
            print("  Difference: \(difference) seconds")

            // Outlier filtering should prevent huge swings
            XCTAssertLessThan(difference, 20,
                            "Outlier filtering should prevent major pace swings")
        }
    }
}
