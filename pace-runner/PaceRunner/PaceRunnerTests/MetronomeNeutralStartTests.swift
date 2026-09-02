import XCTest
@testable import PaceRunnerShared

/// Tests for the signal behind the metronome's neutral start.
///
/// At the beginning of a run the metronome used to start directing faster/slower
/// within seconds, because a window reports a pace as soon as it has `minSamples`
/// (3) samples — long before the window is actually full. `movingTimeSpan` is the
/// separate "how much running data do we really have" signal the gate uses.
final class MetronomeNeutralStartTests: XCTestCase {

    private let paceSecondsPerMile = 480.0            // 8:00/mile
    private var speedMps: Double { 1609.34 / paceSecondsPerMile }

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

    /// Feeds `count` one-second samples at a steady pace, returning the wall
    /// clock time after the last one.
    @discardableResult
    private func feedSteadySamples(
        count: Int,
        startingAt start: Date,
        cumulativeDistance: inout Double
    ) -> Date {
        var time = start
        for _ in 0..<count {
            time = time.addingTimeInterval(1.0)
            cumulativeDistance += speedMps
            calculator.addSample(distance: cumulativeDistance, timestamp: time)
        }
        return time
    }

    func testMovingTimeSpanIsZeroBeforeAnySamples() {
        XCTAssertEqual(calculator.movingTimeSpan, 0)
    }

    func testMovingTimeSpanGrowsWithSampleHistory() {
        let start = Date()
        var distance = 0.0
        feedSteadySamples(count: 61, startingAt: start, cumulativeDistance: &distance)

        // The first sample only sets a baseline and is not retained, so the span
        // covers one interval less than the samples fed.
        XCTAssertEqual(calculator.movingTimeSpan, 59.0, accuracy: 1.5)
    }

    /// The root cause of the reported behavior: a usable pace exists almost
    /// immediately, so "pace is non-nil" cannot mean "window is full".
    func testWindowReportsAPaceLongBeforeItIsFull() {
        let start = Date()
        var distance = 0.0
        feedSteadySamples(count: 5, startingAt: start, cumulativeDistance: &distance)

        XCTAssertNotNil(calculator.fastPace,
                        "A few samples are enough for a pace — that is why the gate exists")
        XCTAssertLessThan(calculator.movingTimeSpan, 120.0,
                          "The 120s fast window is nowhere near full yet")
    }

    /// The gate the metronome uses: neutral below the shortest window, directing
    /// at or above it.
    func testShortestWindowFillsOnlyAfterItsFullDuration() {
        let shortestWindow = 120.0
        let start = Date()
        var distance = 0.0

        feedSteadySamples(count: 100, startingAt: start, cumulativeDistance: &distance)
        XCTAssertLessThan(calculator.movingTimeSpan, shortestWindow,
                          "Still inside the neutral hold at ~99s of data")

        let resumeAt = start.addingTimeInterval(100.0)
        feedSteadySamples(count: 30, startingAt: resumeAt, cumulativeDistance: &distance)
        XCTAssertGreaterThanOrEqual(calculator.movingTimeSpan, shortestWindow,
                                    "Neutral hold should be over past the full window")
    }

    /// Paused time must not count toward the hold, or a runner who pauses at the
    /// start gets directed off data the windows do not have.
    func testMovingTimeSpanExcludesPausedTime() {
        let start = Date()
        var distance = 0.0
        let beforePause = feedSteadySamples(count: 31, startingAt: start, cumulativeDistance: &distance)
        let spanBefore = calculator.movingTimeSpan

        // 5 minutes paused, no distance accrued, then running resumes.
        let pauseDuration: TimeInterval = 300
        calculator.notePauseGap(pauseDuration)

        let resumeAt = beforePause.addingTimeInterval(pauseDuration)
        feedSteadySamples(count: 30, startingAt: resumeAt, cumulativeDistance: &distance)

        let spanAfter = calculator.movingTimeSpan
        XCTAssertEqual(spanAfter, spanBefore + 30.0, accuracy: 3.0,
                       "Span must advance by running time only, not by the 300s pause")
        XCTAssertLessThan(spanAfter, 120.0,
                          "A 5-minute pause must not satisfy the 120s neutral hold")
    }
}
