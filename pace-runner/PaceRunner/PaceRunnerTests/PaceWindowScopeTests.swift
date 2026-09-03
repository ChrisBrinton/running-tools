import XCTest
@testable import PaceRunnerShared

/// Tests for which data each pace window is allowed to see.
///
/// Two behaviors reported from real runs that existing coverage missed:
///
/// 1. The short (fast) moving average jumping to a much slower pace right after
///    resuming from a pause. Existing pause tests assert almost entirely on
///    `slowPace`; the one that checks `fastPace` deliberately waits two minutes
///    for a full window of fresh data, so the window straddling the pause
///    boundary — exactly when a jump would be visible — was untested.
///
/// 2. The mile split and the rolling mile reading the same value for a long
///    stretch. `testSplitAndTrailingMileMatchInFirstMile` asserts they match in
///    the first mile (correct — same data), but nothing asserted they diverge
///    afterwards.
final class PaceWindowScopeTests: XCTestCase {

    var calculator: PaceCalculator!

    /// 2.5 m/s ≈ 10:44/mi, the pace used throughout so expectations are stable.
    private let mps = 2.5
    private var expectedPaceSeconds: Double { 1609.34 / mps }

    override func setUp() {
        super.setUp()
        calculator = PaceCalculator()
        calculator.configureWindows(fastSeconds: 120, mediumSeconds: 240, slowMiles: 1.0)
    }

    override func tearDown() {
        calculator = nil
        super.tearDown()
    }

    /// Feeds steady running. `wallOffset` models paused wall-clock time that has
    /// elapsed but is not running time.
    private func run(
        seconds: Int,
        from start: Date,
        elapsed: inout Double,
        distance: inout Double,
        wallOffset: Double = 0
    ) {
        for _ in 0..<seconds {
            elapsed += 1
            distance += mps
            calculator.addSample(
                distance: distance,
                timestamp: start.addingTimeInterval(elapsed + wallOffset)
            )
        }
    }

    // MARK: - Fast window across a pause

    /// The gap the reported jump would live in: the fast window in the first
    /// seconds after resuming, while it still straddles the pause boundary.
    func testFastPaceDoesNotJumpImmediatelyAfterResume() {
        let start = Date()
        var elapsed = 0.0
        var distance = 0.0

        run(seconds: 300, from: start, elapsed: &elapsed, distance: &distance)
        guard let before = calculator.fastPace else {
            return XCTFail("expected a fast pace before the pause")
        }

        // A few minutes standing still. The runner is stopped, so no distance
        // accrues and no samples are accepted during the pause itself.
        let pause = 240.0
        calculator.notePauseGap(pause)

        // Ten seconds back into the run — the fast window is still almost
        // entirely pre-pause data, and must read as running, not as a stall.
        run(seconds: 10, from: start, elapsed: &elapsed, distance: &distance, wallOffset: pause)

        guard let after = calculator.fastPace else {
            return XCTFail("fast window went nil immediately after resume")
        }
        XCTAssertEqual(Double(after.totalSeconds), expectedPaceSeconds, accuracy: 60,
            "fast pace must not jump when the window straddles a pause "
            + "(before \(before.formatted), after \(after.formatted))")
    }

    /// The same check sampled continuously across the whole first fast window
    /// after resume — a transient spike anywhere in here is what a runner sees.
    func testFastPaceStaysStableThroughTheFirstWindowAfterResume() {
        let start = Date()
        var elapsed = 0.0
        var distance = 0.0

        run(seconds: 300, from: start, elapsed: &elapsed, distance: &distance)

        let pause = 240.0
        calculator.notePauseGap(pause)

        var worst: Pace?
        for _ in 0..<130 {
            run(seconds: 1, from: start, elapsed: &elapsed, distance: &distance, wallOffset: pause)
            if let fast = calculator.fastPace {
                if worst == nil || fast.totalSeconds > worst!.totalSeconds { worst = fast }
            }
        }

        guard let worstPace = worst else { return XCTFail("no fast pace after resume") }
        XCTAssertLessThan(Double(worstPace.totalSeconds), expectedPaceSeconds + 90,
            "fast pace spiked to \(worstPace.formatted) somewhere in the window after resume")
    }

    /// A pause that never reaches the calculator does NOT read as a slow
    /// window, which is the opposite of what I first assumed.
    ///
    /// The gap is longer than the window itself, so every pre-gap sample falls
    /// outside it. The window is left with too few samples and reports nil until
    /// fresh running refills it — it never blends stopped time with running
    /// time. Worth pinning down: it means a mid-run stall cannot be explained by
    /// "the pause wasn't reported to the calculator".
    func testUnreportedPauseEvictsHistoryRatherThanReadingSlow() {
        let start = Date()
        var elapsed = 0.0
        var distance = 0.0

        run(seconds: 300, from: start, elapsed: &elapsed, distance: &distance)

        // Same 4-minute break, but notePauseGap is NOT called.
        let pause = 240.0
        run(seconds: 10, from: start, elapsed: &elapsed, distance: &distance, wallOffset: pause)

        if let after = calculator.fastPace {
            XCTAssertLessThan(Double(after.totalSeconds), expectedPaceSeconds + 90,
                "an unreported gap must not blend stopped time into the window "
                + "(got \(after.formatted))")
        }
        // Either outcome is acceptable; a slow reading is not.
    }

    // MARK: - Rolling mile vs. mile split

    /// The actual relationship between the two readouts, which explains when
    /// they legitimately read the same.
    ///
    /// At a mile boundary the trailing-mile window IS the mile just completed,
    /// so it equals that split by definition — not a bug. They diverge only
    /// mid-mile, where the trailing window still spans part of the previous
    /// mile. On a very steady run they therefore track each other closely
    /// everywhere, which can look like the two are locked together.
    func testRollingMileEqualsTheSplitAtAMileBoundaryButDivergesMidMile() {
        let start = Date()
        var elapsed = 0.0
        var distance = 0.0

        let slowMps = 2.2   // mile 1: ~12:12/mi
        let fastMps = 3.2   // mile 2: ~8:23/mi

        func cover(meters: Double, at speed: Double) {
            for _ in 0..<Int(meters / speed) {
                elapsed += 1
                distance += speed
                calculator.addSample(distance: distance, timestamp: start.addingTimeInterval(elapsed))
            }
        }

        cover(meters: 1609.34, at: slowMps)   // mile 1
        cover(meters: 1609.34, at: fastMps)   // mile 2

        let mileTwoSplit = 1609.34 / fastMps
        guard let atBoundary = calculator.slowPace else {
            return XCTFail("expected a rolling-mile pace at the mile-2 boundary")
        }
        XCTAssertEqual(Double(atBoundary.totalSeconds), mileTwoSplit, accuracy: 20,
            "at a mile boundary the trailing mile IS the completed split "
            + "(rolling \(atBoundary.formatted), split \(Int(mileTwoSplit))s)")

        // Half a mile into mile 3, run at the same fast pace. The trailing
        // window now spans the back half of mile 2 plus this half — still all
        // fast — so keep mile 3 slow to force a real difference.
        cover(meters: 804.67, at: slowMps)

        guard let midMile = calculator.slowPace else {
            return XCTFail("expected a rolling-mile pace mid-mile")
        }
        let currentSplitPace = 1609.34 / slowMps
        XCTAssertLessThan(Double(midMile.totalSeconds), currentSplitPace - 20,
            "mid-mile the trailing window still carries the faster previous mile "
            + "and must not collapse onto the current split "
            + "(rolling \(midMile.formatted), split \(Int(currentSplitPace))s)")
    }

    /// The regression: restarting the pace windows at a segment transition must
    /// not blank the distance-based rolling mile.
    ///
    /// The transition in a "1mi Easy + 4mi Tempo" config lands on the mile-1
    /// boundary, the same point the mile split restarts. If the restart discards
    /// the sample history, the rolling mile is then computed over exactly the
    /// data the current split covers and the two read identically for a full
    /// mile — which is what showed up on the watch.
    func testSegmentRestartKeepsTheRollingMileIntact() {
        let start = Date()
        var elapsed = 0.0
        var distance = 0.0

        // Mile 1 easy.
        let easyMps = 2.2
        for _ in 0..<Int(1609.34 / easyMps) {
            elapsed += 1
            distance += easyMps
            calculator.addSample(distance: distance, timestamp: start.addingTimeInterval(elapsed))
        }

        // Segment transition into tempo: the time-based windows must forget the
        // warm-up, the distance-based rolling mile must not.
        calculator.restartTimeWindows()

        // Half a mile of tempo.
        let tempoMps = 3.2
        for _ in 0..<Int(804.0 / tempoMps) {
            elapsed += 1
            distance += tempoMps
            calculator.addSample(distance: distance, timestamp: start.addingTimeInterval(elapsed))
        }

        guard let rollingMile = calculator.slowPace else {
            return XCTFail("rolling mile went nil after the segment restart")
        }
        // Half a mile of tempo blended with half a mile of warm-up sits well
        // slower than the tempo split alone.
        let tempoSplit = 1609.34 / tempoMps
        XCTAssertGreaterThan(Double(rollingMile.totalSeconds), tempoSplit + 20,
            "the rolling mile must still span the warm-up, not collapse onto the "
            + "current segment (rolling \(rollingMile.formatted), tempo split "
            + "\(Int(tempoSplit))s)")
    }

    /// The other half of the contract: the restart DOES clear the time-based
    /// windows, so the neutral hold re-arms and fast/medium stop reporting the
    /// previous segment's pace.
    func testSegmentRestartStillClearsTheTimeBasedWindows() {
        let start = Date()
        var elapsed = 0.0
        var distance = 0.0

        run(seconds: 300, from: start, elapsed: &elapsed, distance: &distance)
        XCTAssertGreaterThanOrEqual(calculator.movingTimeSpan, 120)

        calculator.restartTimeWindows()

        XCTAssertLessThan(calculator.movingTimeSpan, 120,
            "the neutral hold must re-arm at a segment restart")
        XCTAssertNil(calculator.fastPace,
            "the fast window must not report the previous segment's pace")
    }

    // MARK: - Window diagnostics

    /// The field that separates the two explanations for a locked-looking
    /// rolling mile: if the master window has not filled, it is computing over
    /// the same data as the current split.
    func testMasterWindowSpanReportsAPartiallyFilledWindow() {
        let start = Date()
        var elapsed = 0.0
        var distance = 0.0

        // Half a mile in — the rolling mile cannot have filled yet.
        for _ in 0..<Int(804.0 / mps) {
            elapsed += 1
            distance += mps
            calculator.addSample(distance: distance, timestamp: start.addingTimeInterval(elapsed))
        }

        let d = calculator.windowDiagnostics
        XCTAssertEqual(d.masterWindowMeters, 804, accuracy: 40,
            "a half-mile-in window should report ~0.5 mi, got \(d.masterWindowMeters)m")
        XCTAssertLessThan(d.masterWindowMeters, 1609.34,
            "the master window must not claim to span a full mile before it has")
        XCTAssertGreaterThan(d.sampleCount, 0)
    }

    func testMasterWindowSpanReportsAFullWindowOnceFilled() {
        let start = Date()
        var elapsed = 0.0
        var distance = 0.0

        // Two miles in — the trailing window should be pinned at ~1 mile.
        for _ in 0..<Int(3218.0 / mps) {
            elapsed += 1
            distance += mps
            calculator.addSample(distance: distance, timestamp: start.addingTimeInterval(elapsed))
        }

        let d = calculator.windowDiagnostics
        XCTAssertEqual(d.masterWindowMeters, 1609.34, accuracy: 40,
            "a filled master window should span ~1 mi, got \(d.masterWindowMeters)m")
        XCTAssertEqual(d.masterWindowSeconds, 1609.34 / mps, accuracy: 20)
    }

    /// Diagnostics must survive a segment restart the same way the pace does —
    /// the master window keeps its span, the fast window is cut back.
    func testDiagnosticsReflectTheSegmentRestartAsymmetry() {
        let start = Date()
        var elapsed = 0.0
        var distance = 0.0

        for _ in 0..<Int(3218.0 / mps) {
            elapsed += 1
            distance += mps
            calculator.addSample(distance: distance, timestamp: start.addingTimeInterval(elapsed))
        }
        let before = calculator.windowDiagnostics
        XCTAssertGreaterThan(before.fastWindowSamples, 100)

        calculator.restartTimeWindows()
        let after = calculator.windowDiagnostics

        XCTAssertEqual(after.masterWindowMeters, before.masterWindowMeters, accuracy: 1,
            "the rolling-mile window must be untouched by a segment restart")
        XCTAssertLessThanOrEqual(after.fastWindowSamples, 1,
            "the fast window must be cut back to the restart anchor")
    }
}
