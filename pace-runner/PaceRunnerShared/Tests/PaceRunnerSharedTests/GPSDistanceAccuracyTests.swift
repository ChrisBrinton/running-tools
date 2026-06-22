import XCTest
import CoreLocation
@testable import PaceRunnerShared

/// Verifies the GPS distance calculation against synthetic data with known true path length.
///
/// These tests feed deterministic synthetic GPS samples through `GPSManager` and
/// compare reported distance to the known true distance. They are useful for:
/// - Catching regressions in distance accumulation logic
/// - Quantifying error introduced by sample rate, noise, and turn frequency
/// - Reproducing pace-spike-on-turn behavior in a controlled environment
final class GPSDistanceAccuracyTests: XCTestCase {

    /// Ideal data at 10 Hz (matches the generator default) with no coordinate noise.
    /// This exposes any algorithmic issues independent of GPS hardware noise.
    func testIdealPath_10Hz_noNoise_2miles() {
        runScenario(
            label: "10Hz / no noise / 2mi",
            sampleHz: 10.0,
            noise: 0.0
        )
    }

    /// Ideal data at 1 Hz — closer to real GPS rate. Should be very accurate.
    func testIdealPath_1Hz_noNoise_2miles() {
        runScenario(
            label: "1Hz / no noise / 2mi",
            sampleHz: 1.0,
            noise: 0.0
        )
    }

    /// Realistic sensor noise (~5m horizontal jitter, matching declared accuracy).
    /// Exposes the impact of noise on distance accumulation.
    func testNoisyPath_1Hz_5mNoise_2miles() {
        runScenario(
            label: "1Hz / 5m noise / 2mi",
            sampleHz: 1.0,
            noise: 5.0
        )
    }

    /// Realistic sensor noise at 10 Hz — represents a high-frequency feed with jitter.
    func testNoisyPath_10Hz_5mNoise_2miles() {
        runScenario(
            label: "10Hz / 5m noise / 2mi",
            sampleHz: 10.0,
            noise: 5.0
        )
    }

    // MARK: - Turn isolation tests
    //
    // These tests answer the question: "do sharp corners specifically
    // introduce error in our distance calculation?" by comparing paths
    // that differ only in whether they contain turns.

    /// Same path length, same noise, but no turns. The error here is
    /// noise-only — anything beyond this in the turning version is the
    /// turn-specific contribution.
    func testStraightLine_1Hz_5mNoise_2miles() {
        runScenario(
            label: "1Hz / 5m noise / 2mi / STRAIGHT",
            sampleHz: 1.0,
            noise: 5.0,
            forceStraightLine: true
        )
    }

    /// Same as above at 10Hz, no turns.
    func testStraightLine_10Hz_5mNoise_2miles() {
        runScenario(
            label: "10Hz / 5m noise / 2mi / STRAIGHT",
            sampleHz: 10.0,
            noise: 5.0,
            forceStraightLine: true
        )
    }

    /// Frequent turns, no noise. Confirms turns alone don't introduce error
    /// (they shouldn't — distance between adjacent samples is uniform).
    func testFrequentTurnsNoNoise_1Hz_2miles() {
        runScenario(
            label: "1Hz / no noise / 2mi / TURNS EVERY 30-60",
            sampleHz: 1.0,
            noise: 0.0,
            turnEvery: 30...60
        )
    }

    /// Reproduces the real-world "right turn faster / left turn slower" effect
    /// using a lateral bias around each turn. Compare to the noise-only
    /// straight-line baseline to see how much error this specific physical
    /// effect adds.
    func testTurnBias_1Hz_3mLateral_2miles() {
        runScenario(
            label: "1Hz / no noise / 2mi / 3m TURN LATERAL BIAS",
            sampleHz: 1.0,
            noise: 0.0,
            turnBias: .lateral(meters: 3.0, windowSamples: 10)
        )
    }

    /// Same with stronger 6m lateral bias around turns.
    func testTurnBias_1Hz_6mLateral_2miles() {
        runScenario(
            label: "1Hz / no noise / 2mi / 6m TURN LATERAL BIAS",
            sampleHz: 1.0,
            noise: 0.0,
            turnBias: .lateral(meters: 6.0, windowSamples: 20)
        )
    }

    /// Confirms the generator produced turns where expected.
    func testGeneratorProducesTurnsAndKnownDistance() {
        let testData = GPSTestDataGenerator.generateRunPath(
            targetDistanceMeters: 2 * 1609.34,
            sampleHz: 10.0,
            seed: 42
        )

        XCTAssertGreaterThan(testData.turnIndices.count, 0, "Should have at least one turn")
        XCTAssertGreaterThanOrEqual(testData.truePathLengthMeters, 2 * 1609.34)
        XCTAssertGreaterThan(testData.samples.count, 100)

        // Turn spacing should fall within configured range (300...700 by default)
        var lastTurn = 0
        for turn in testData.turnIndices {
            let gap = turn - lastTurn
            XCTAssertGreaterThanOrEqual(gap, 300, "Turn spacing too small")
            XCTAssertLessThanOrEqual(gap, 701, "Turn spacing too large")
            lastTurn = turn
        }
    }

    // MARK: - Helpers

    private func runScenario(
        label: String,
        targetMiles: Double = 2.0,
        sampleHz: Double,
        noise: Double,
        turnEvery: ClosedRange<Int> = 300...700,
        forceStraightLine: Bool = false,
        turnBias: GPSTestDataGenerator.TurnBias = .none,
        seed: UInt64 = 42
    ) {
        let testData = GPSTestDataGenerator.generateRunPath(
            targetDistanceMeters: targetMiles * 1609.34,
            sampleHz: sampleHz,
            paceMetersPerSecond: 3.0,
            turnEvery: turnEvery,
            coordinateNoiseMeters: noise,
            turnBias: turnBias,
            forceStraightLine: forceStraightLine,
            seed: seed
        )

        let mock = TestLocationManager()
        let manager = GPSManager(locationManager: mock)
        manager.startTracking()

        for sample in testData.samples {
            mock.send(location: sample)
        }

        report(testData: testData, reported: manager.totalDistance, label: label)
    }

    private func report(testData: GPSTestData, reported: Double, label: String) {
        let truth = testData.truePathLengthMeters
        let trueMiles = truth / 1609.34
        let reportedMiles = reported / 1609.34
        let errorMeters = reported - truth
        let errorPercent = truth > 0 ? (errorMeters / truth) * 100 : 0

        print("""

        === GPS Distance Accuracy: \(label) ===
        Samples fed: \(testData.samples.count)
        Turns: \(testData.turnIndices.count)
        True path:    \(String(format: "%.2f m (%.4f mi)", truth, trueMiles))
        Reported:     \(String(format: "%.2f m (%.4f mi)", reported, reportedMiles))
        Error:        \(String(format: "%+.2f m (%+.2f%%)", errorMeters, errorPercent))
        ===
        """)
    }
}

/// Mock LocationManager used by these tests. Forwards `send(location:)` calls
/// to the GPSManager via its delegate.
private final class TestLocationManager: NSObject, LocationManagerProtocol {
    var delegate: CLLocationManagerDelegate?
    var desiredAccuracy: CLLocationAccuracy = 0
    var activityType: CLActivityType = .other
    var distanceFilter: CLLocationDistance = 0
    var allowsBackgroundLocationUpdates: Bool = false

    private let backingManager = CLLocationManager()

    func requestAlwaysAuthorization() {}
    func startUpdatingLocation() {}
    func stopUpdatingLocation() {}

    func send(location: CLLocation) {
        delegate?.locationManager?(backingManager, didUpdateLocations: [location])
    }
}
