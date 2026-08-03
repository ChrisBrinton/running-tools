import XCTest
import CoreLocation
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

    /// A mid-workout pause must not be counted as running time by the rolling
    /// pace windows. Regression test for the "moving average included the
    /// 5-minute pause" bug: feed a steady ~8:00 pace, pause 5 minutes, resume
    /// at the same pace, and confirm the master pace stays ~8:00 rather than
    /// being dragged toward a crawl.
    func testPauseIsNotCountedInMovingAverage() {
        let start = Date()
        var distance = 0.0
        var elapsed = 0.0

        // ~8:00/mi: 10 m every 3 s (3.33 m/s).
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
        // post-resume timestamps are 300 s later in wall-clock, as on the watch.
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

    /// Several pauses in one run must all be excluded from the moving average.
    /// Exercises the moving-time offset accumulating across more than one gap.
    func testMultiplePausesAllExcludedFromMovingAverage() {
        let start = Date()
        var distance = 0.0
        var elapsed = 0.0
        var wallOffset = 0.0  // accumulated pause time added to wall-clock stamps

        // ~8:00/mi: 10 m every 3 s.
        calculator.addSample(distance: 0, timestamp: start)
        func runFor(samples: Int) {
            for _ in 0..<samples {
                distance += 10
                elapsed += 3
                calculator.addSample(distance: distance,
                                     timestamp: start.addingTimeInterval(elapsed + wallOffset))
            }
        }
        func pause(_ seconds: Double) {
            calculator.notePauseGap(seconds)
            wallOffset += seconds
        }

        runFor(samples: 15)
        guard let before = calculator.slowPace else { return XCTFail("no pace before pauses") }

        pause(180)          // restroom break
        runFor(samples: 15)
        pause(45)           // quick water stop
        runFor(samples: 15)

        guard let after = calculator.slowPace else { return XCTFail("no pace after pauses") }

        XCTAssertLessThan(after.totalSeconds, 600,
                          "Master pace must exclude both pauses (got \(after.formatted))")
        XCTAssertEqual(after.totalSeconds, before.totalSeconds, accuracy: 45,
                       "Master pace should hold ~steady across multiple pauses (before \(before.formatted), after \(after.formatted))")
    }

    /// A distance calculator must not draw a chord across a pause. After
    /// `breakContinuity()`, the next fix contributes zero distance (it only
    /// re-establishes the reference point) and the accumulated total is kept.
    /// This is what prevents a restroom-break relocation from injecting phantom
    /// distance that would spike every moving-average window straddling the pause.
    func testBreakContinuityDropsChordButKeepsTotal() {
        let calc = ChordDistanceCalculator()

        let a = CLLocation(latitude: 37.3300, longitude: -122.0300)
        let b = CLLocation(latitude: 37.3300, longitude: -122.0299) // ~9 m east of a

        XCTAssertEqual(calc.addLocation(a), 0, accuracy: 0.001, "first fix has no baseline")
        let abDelta = calc.addLocation(b)
        XCTAssertGreaterThan(abDelta, 1, "normal step should accumulate")
        let totalBeforePause = calc.totalDistance

        // Pause boundary: runner walks away and resumes ~150 m down the road.
        calc.breakContinuity()
        let c = CLLocation(latitude: 37.3313, longitude: -122.0299) // ~145 m north of b

        let jumpDelta = calc.addLocation(c)
        XCTAssertEqual(jumpDelta, 0, accuracy: 0.001,
                       "the fix right after a break must add no distance (no chord across the pause)")
        XCTAssertEqual(calc.totalDistance, totalBeforePause, accuracy: 0.001,
                       "accumulated distance is preserved across breakContinuity")

        // Normal accumulation resumes on the next fix.
        let d = CLLocation(latitude: 37.3313, longitude: -122.0298) // ~9 m east of c
        XCTAssertGreaterThan(calc.addLocation(d), 1, "accumulation resumes after the break")
    }

    /// Reproduces the 7/26 long-run bug: a ~13-min pause during which the
    /// distance source (HealthKit) keeps counting ~150 m of walking. That
    /// pause-distance must not be attributed to post-resume moving time, or the
    /// distance-based master window reports a phantom fast pace that lingers for
    /// ~1 mile. Feed >1 mile before and after so the master (1-mile) window
    /// spans the resume boundary.
    func testPauseDistanceGainDoesNotSpikeMasterPace() {
        let start = Date()
        var distance = 0.0
        var elapsed = 0.0

        // ~10:40/mi = 2.5 m/s: 10 m every 4 s.
        calculator.addSample(distance: 0, timestamp: start)
        for _ in 1...200 {                 // 2000 m over 800 s (>1 mile)
            distance += 10; elapsed += 4
            calculator.addSample(distance: distance, timestamp: start.addingTimeInterval(elapsed))
        }
        guard let before = calculator.slowPace else { return XCTFail("no pace before pause") }

        // 13-minute pause; HealthKit counts 150 m of restroom walking during it.
        let pause = 780.0
        calculator.notePauseGap(pause)
        distance += 150   // distance that accrued while paused

        for _ in 1...200 {                 // resume, same 2.5 m/s
            distance += 10; elapsed += 4
            calculator.addSample(distance: distance, timestamp: start.addingTimeInterval(elapsed + pause))
        }
        guard let after = calculator.slowPace else { return XCTFail("no pace after resume") }

        XCTAssertGreaterThan(after.totalSeconds, 520,
            "master pace must not spike fast from pause-time distance (got \(after.formatted))")
        XCTAssertEqual(after.totalSeconds, before.totalSeconds, accuracy: 45,
            "master pace should hold ~10:40 across the pause (before \(before.formatted), after \(after.formatted))")
    }

    /// The 7/26 failure mode in full: HealthKit keeps DELIVERING distance
    /// samples during the pause (walking to the restroom), stamped in
    /// wall-clock time and accepted before `notePauseGap` advances the
    /// moving-time offset. After resume every fresh sample then lands
    /// ~pauseDuration BEHIND those pause-era samples in moving time. Without
    /// self-healing the calculator rejects everything until wall clock catches
    /// up — on the road that froze every window for ~5 minutes — and the
    /// walking distance stays in the master window as a phantom-fast spike.
    func testWindowsRecoverWhenSamplesWereAcceptedDuringPause() {
        let start = Date()
        var distance = 0.0
        var elapsed = 0.0   // wall-clock seconds since start

        // ~10:40/mi = 2.5 m/s: 10 m every 4 s for >1 mile.
        calculator.addSample(distance: 0, timestamp: start)
        for _ in 1...200 {
            distance += 10; elapsed += 4
            calculator.addSample(distance: distance, timestamp: start.addingTimeInterval(elapsed))
        }
        guard let before = calculator.slowPace else { return XCTFail("no pace before pause") }

        // 13-minute pause. For the first 5 minutes the pedometer keeps
        // delivering walking samples (~1.4 m/s) that the calculator accepts —
        // the pause offset hasn't advanced yet. Then 8 minutes standing still.
        for _ in 1...60 {
            distance += 7; elapsed += 5
            calculator.addSample(distance: distance, timestamp: start.addingTimeInterval(elapsed))
        }
        elapsed += 480
        calculator.notePauseGap(780)

        // Resume at the same 2.5 m/s. With the freeze bug, every sample in the
        // first ~5 minutes here was rejected and the windows never moved.
        for i in 1...200 {
            distance += 10; elapsed += 4
            calculator.addSample(distance: distance, timestamp: start.addingTimeInterval(elapsed))

            if i == 30 {   // 2 minutes back in — a full fast window of fresh data
                guard let fast = calculator.fastPace else { return XCTFail("fast window still frozen 2 min after resume") }
                XCTAssertEqual(fast.totalSeconds, 644, accuracy: 60,
                    "fast pace must reflect live running ~2 min after resume, not walking-era history (got \(fast.formatted))")
            }
        }

        guard let after = calculator.slowPace else { return XCTFail("no master pace after resume") }
        XCTAssertGreaterThan(after.totalSeconds, 520,
            "walking distance accepted during the pause must not read as a fast spike (got \(after.formatted))")
        XCTAssertEqual(after.totalSeconds, before.totalSeconds, accuracy: 45,
            "master pace should hold ~10:40 across the pause (before \(before.formatted), after \(after.formatted))")
    }
}

/// Tests for the id-based configuration merge that replaced "replace-all"
/// config sync. These are the guarantee that a config created on one device
/// can't be wiped by a sync from the other.
final class ConfigurationMergeTests: XCTestCase {

    private func cfg(_ name: String) -> RunConfiguration {
        RunConfiguration(
            name: name,
            distance: Distance(miles: 5),
            targetPace: Pace(minutes: 8, seconds: 0),
            cadenceOffset: 0,
            paceTolerance: 5
        )
    }

    private var now: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    /// The core fix: a config on either side survives; nothing is dropped.
    func testMergeKeepsConfigsFromBothSides() {
        let a = cfg("Watch Run")
        let b = cfg("Phone Run")

        let result = ConfigurationMerge.merge(
            local: [a], localTombstones: [:],
            incoming: [b], incomingTombstones: [:],
            now: now
        )

        XCTAssertEqual(Set(result.configurations.map(\.id)), Set([a.id, b.id]))
    }

    /// The exact reported bug: an empty incoming set must not wipe local configs.
    func testEmptyIncomingDoesNotWipeLocal() {
        let a = cfg("A"); let b = cfg("B")

        let result = ConfigurationMerge.merge(
            local: [a, b], localTombstones: [:],
            incoming: [], incomingTombstones: [:],
            now: now
        )

        XCTAssertEqual(result.configurations.map(\.id), [a.id, b.id])
    }

    /// On an id collision the incoming (peer) copy wins.
    func testIncomingWinsOnIdCollision() {
        let a = cfg("Original")
        var edited = a; edited.name = "Edited on peer"

        let result = ConfigurationMerge.merge(
            local: [a], localTombstones: [:],
            incoming: [edited], incomingTombstones: [:],
            now: now
        )

        XCTAssertEqual(result.configurations.count, 1)
        XCTAssertEqual(result.configurations.first?.name, "Edited on peer")
    }

    /// A tombstone from the peer deletes the config locally and is retained.
    func testIncomingTombstoneDeletesLocalConfig() {
        let a = cfg("Keep"); let b = cfg("Delete me")

        let result = ConfigurationMerge.merge(
            local: [a, b], localTombstones: [:],
            incoming: [], incomingTombstones: [b.id: now],
            now: now
        )

        XCTAssertEqual(result.configurations.map(\.id), [a.id])
        XCTAssertNotNil(result.tombstones[b.id])
    }

    /// Delete wins over a still-live copy the peer keeps sending.
    func testLocalTombstoneSuppressesResurrection() {
        let a = cfg("Zombie")

        let result = ConfigurationMerge.merge(
            local: [], localTombstones: [a.id: now],
            incoming: [a], incomingTombstones: [:],   // peer still has it live
            now: now
        )

        XCTAssertTrue(result.configurations.isEmpty, "a deleted config must not come back")
        XCTAssertNotNil(result.tombstones[a.id])
    }

    /// Tombstones past the TTL are pruned, so the set can't grow forever and a
    /// long-gone id could legitimately be re-created later.
    func testExpiredTombstoneIsPruned() {
        let a = cfg("Old delete")
        let stale = now.addingTimeInterval(-ConfigurationMerge.tombstoneTTL - 1)

        let result = ConfigurationMerge.merge(
            local: [a], localTombstones: [a.id: stale],
            incoming: [a], incomingTombstones: [:],
            now: now
        )

        // Tombstone expired → no longer suppresses, and it's dropped from the map.
        XCTAssertNil(result.tombstones[a.id])
        XCTAssertEqual(result.configurations.map(\.id), [a.id])
    }

    /// Order: local order preserved, peer-only configs appended.
    func testOrderLocalThenIncoming() {
        let a = cfg("A"); let b = cfg("B"); let c = cfg("C")

        let result = ConfigurationMerge.merge(
            local: [a, b], localTombstones: [:],
            incoming: [c], incomingTombstones: [:],
            now: now
        )

        XCTAssertEqual(result.configurations.map(\.id), [a.id, b.id, c.id])
    }
}
