import XCTest
@testable import PaceRunnerShared

/// Regression tests for the current-mile-split readout.
///
/// On the watch and the phone the "Spt" / "Split" field was bound to
/// `PaceWindows.splitPace`, which was a legacy alias returning `slowPace` — the
/// trailing-mile window — under a doc comment claiming it was "distance/time
/// since last mile marker". Both readouts therefore rendered the same number,
/// always and exactly, no matter how the current mile was actually being run.
///
/// Caught from a run: a sprint just after the mile-2 boundary moved the real
/// split hard (13:26 → 11:36 → 11:06 in the debug log) while the on-screen
/// split stayed pinned to the trailing mile.
final class SplitPaceDisplayTests: XCTestCase {

    private func state(
        distanceMeters: Double,
        elapsed: TimeInterval,
        mileStartMeters: Double,
        mileStartTime: TimeInterval,
        windows: PaceWindows
    ) -> WorkoutState {
        let config = RunConfiguration(
            name: "6mi Recovery",
            distance: Distance(miles: 6),
            targetPace: Pace(minutes: 11, seconds: 15),
            cadenceOffset: 0,
            paceTolerance: 10
        )
        var s = WorkoutState(configuration: config)
        s.distanceCovered = distanceMeters
        s.elapsedTime = elapsed
        s.currentMileSplitStart = mileStartMeters
        s.currentMileSplitStartTime = mileStartTime
        s.paceWindows = windows
        return s
    }

    /// The split must reflect only the current mile, not the trailing window.
    func testSplitPaceIsIndependentOfTheTrailingMileWindow() {
        // Two miles done at ~11:00, then 0.1 mi of the third at ~7:00 pace.
        let mileStart = 2.0 * 1609.34
        let sprintMeters = 0.1 * 1609.34
        let sprintSeconds = 0.1 * 420.0

        let windows = PaceWindows(
            slowPace: Pace(minutes: 11, seconds: 0),
            mediumPace: Pace(minutes: 10, seconds: 55),
            fastPace: Pace(minutes: 7, seconds: 5),
            lastMilePace: nil
        )
        let s = state(
            distanceMeters: mileStart + sprintMeters,
            elapsed: 1321 + sprintSeconds,
            mileStartMeters: mileStart,
            mileStartTime: 1321,
            windows: windows
        )

        guard let split = s.splitPace else { return XCTFail("expected a split pace") }
        XCTAssertEqual(split.totalSeconds, 420, accuracy: 15,
            "split must reflect the current mile's ~7:00 running, got \(split.formatted)")
        XCTAssertNotEqual(split, windows.slowPace,
            "split must not be the trailing-mile window")
    }

    /// A hard effort right after a mile boundary should push the split toward
    /// the short window, not leave it pinned to the trailing mile.
    func testSplitTracksTheShortWindowAfterAMileBoundarySprint() {
        let mileStart = 2.0 * 1609.34
        let windows = PaceWindows(
            slowPace: Pace(minutes: 11, seconds: 0),
            mediumPace: Pace(minutes: 10, seconds: 55),
            fastPace: Pace(minutes: 7, seconds: 30),
            lastMilePace: nil
        )
        // 15 s past the boundary, sprinting at ~7:30/mi.
        let sprintSeconds = 15.0
        let sprintMeters = sprintSeconds * (1609.34 / 450.0)

        let s = state(
            distanceMeters: mileStart + sprintMeters,
            elapsed: 1321 + sprintSeconds,
            mileStartMeters: mileStart,
            mileStartTime: 1321,
            windows: windows
        )

        guard let split = s.splitPace, let trailing = windows.slowPace,
              let fast = windows.fastPace else { return XCTFail("missing paces") }

        let toFast = abs(split.totalSeconds - fast.totalSeconds)
        let toTrailing = abs(split.totalSeconds - trailing.totalSeconds)
        XCTAssertLessThan(toFast, toTrailing,
            "just after a boundary the split should sit nearer the short window "
            + "(split \(split.formatted), fast \(fast.formatted), trailing \(trailing.formatted))")
    }

    /// The split covers only the current mile, so a slow current mile reads slow
    /// even when the trailing mile is fast.
    func testSlowCurrentMileReadsSlowDespiteAFastTrailingMile() {
        let mileStart = 3.0 * 1609.34
        let windows = PaceWindows(
            slowPace: Pace(minutes: 8, seconds: 0),
            mediumPace: Pace(minutes: 8, seconds: 30),
            fastPace: Pace(minutes: 13, seconds: 0),
            lastMilePace: nil
        )
        // 0.2 mi into the mile at ~13:00 pace.
        let meters = 0.2 * 1609.34
        let seconds = 0.2 * 780.0

        let s = state(
            distanceMeters: mileStart + meters,
            elapsed: 2000 + seconds,
            mileStartMeters: mileStart,
            mileStartTime: 2000,
            windows: windows
        )

        guard let split = s.splitPace else { return XCTFail("expected a split pace") }
        XCTAssertEqual(split.totalSeconds, 780, accuracy: 20,
            "split should read the slow current mile, got \(split.formatted)")
        XCTAssertGreaterThan(split.totalSeconds, windows.slowPace!.totalSeconds + 120,
            "split must not collapse onto the faster trailing mile")
    }
}
