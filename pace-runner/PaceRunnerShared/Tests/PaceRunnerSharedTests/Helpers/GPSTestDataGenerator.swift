import Foundation
import CoreLocation

/// Synthetic GPS path data for testing distance accuracy.
struct GPSTestData {
    /// All generated location samples in time order.
    let samples: [CLLocation]
    /// True path length in meters (sum of step distances).
    let truePathLengthMeters: Double
    /// Sample indices where 90° turns occurred.
    let turnIndices: [Int]
    /// Description of turns: index → direction
    let turnDirections: [(index: Int, leftTurn: Bool)]
}

/// Generates deterministic synthetic GPS sample data for testing distance calculation logic.
///
/// Path structure:
/// - Starts at a fixed lat/lng heading north
/// - Each sample advances by `paceMetersPerSecond / sampleHz` meters along current heading
/// - Every 300-700 samples (configurable), executes a random 90° turn (left or right)
/// - Continues until cumulative distance ≥ targetDistanceMeters
///
/// The generator intentionally produces samples faster than real GPS (10 Hz)
/// so tests exercise behavior with sub-meter step distances — letting us verify
/// our distance calculator handles fine-grained input correctly.
enum GPSTestDataGenerator {
    /// Optional bias model applied around turns to simulate antenna/multipath
    /// behavior. Real wrist-worn GPS often gets pushed several meters toward
    /// the *outside* of a turn (or, equivalently, the position lags / overshoots).
    enum TurnBias {
        case none
        /// Push samples within `windowSamples` of each turn point by `meters`
        /// perpendicular to the post-turn heading. Positive = outside of turn,
        /// negative = inside. Half on entry side, half on exit side.
        case lateral(meters: Double, windowSamples: Int)
    }

    static func generateRunPath(
        targetDistanceMeters: Double,
        sampleHz: Double = 10.0,
        paceMetersPerSecond: Double = 3.0,        // ~5:30/mi default
        turnEvery: ClosedRange<Int> = 300...700,
        startLatitude: Double = 37.3318,
        startLongitude: Double = -122.0312,
        horizontalAccuracy: Double = 5.0,
        coordinateNoiseMeters: Double = 0.0,      // 0 = ideal, >0 = jitter
        turnBias: TurnBias = .none,
        forceStraightLine: Bool = false,          // Disable turns entirely
        seed: UInt64 = 42
    ) -> GPSTestData {
        var rng = SeededRNG(seed: seed)
        let stepDistance = paceMetersPerSecond / sampleHz
        let dtPerSample = 1.0 / sampleHz

        var samples: [CLLocation] = []
        var turnIndices: [Int] = []
        var turnDirections: [(index: Int, leftTurn: Bool)] = []
        var cumulativeDistance: Double = 0
        var heading: Double = 0   // 0 = north, 90 = east, 180 = south, 270 = west
        var lat = startLatitude
        var lon = startLongitude

        // Use timestamps that all stay within the GPSManager validity window
        // (age <= 5s). Set them all to "now" — GPSManager doesn't use sample
        // timestamps for distance calc anyway.
        let now = Date()

        var samplesUntilNextTurn = Int.random(in: turnEvery, using: &rng)

        // Pre-add the starting sample at time 0
        samples.append(makeLocation(
            lat: lat, lon: lon, accuracy: horizontalAccuracy, timestamp: now,
            noise: coordinateNoiseMeters, rng: &rng
        ))

        while cumulativeDistance < targetDistanceMeters {
            // Advance position by stepDistance in heading direction
            let headingRad = heading * .pi / 180
            let deltaNorthMeters = stepDistance * cos(headingRad)
            let deltaEastMeters  = stepDistance * sin(headingRad)
            lat += metersToLatitudeDelta(deltaNorthMeters)
            lon += metersToLongitudeDelta(deltaEastMeters, atLatitude: lat)
            cumulativeDistance += stepDistance
            samplesUntilNextTurn -= 1

            // Use timestamps within the validity window. We can't use real
            // dtPerSample (long runs would push age past 5s). Stamp all
            // samples within the 4-second window relative to "now".
            let pseudoOffset = Double(samples.count) * dtPerSample
            let stampWithin5s = now.addingTimeInterval(-min(pseudoOffset, 4.0))

            samples.append(makeLocation(
                lat: lat, lon: lon, accuracy: horizontalAccuracy,
                timestamp: stampWithin5s,
                noise: coordinateNoiseMeters, rng: &rng
            ))

            if !forceStraightLine && samplesUntilNextTurn <= 0 {
                let turnLeft = Bool.random(using: &rng)
                heading += turnLeft ? -90 : 90
                heading = heading.truncatingRemainder(dividingBy: 360)
                if heading < 0 { heading += 360 }
                let turnIndex = samples.count - 1
                turnIndices.append(turnIndex)
                turnDirections.append((index: turnIndex, leftTurn: turnLeft))
                samplesUntilNextTurn = Int.random(in: turnEvery, using: &rng)
            }
        }

        // Apply turn bias as a post-processing step.
        // Lateral bias displaces samples near each turn perpendicular to the
        // post-turn heading. This simulates the multipath/antenna geometry
        // effect where positions get nudged consistently to one side of a turn.
        if case let .lateral(meters, windowSamples) = turnBias {
            samples = applyLateralTurnBias(
                samples: samples,
                turns: turnDirections,
                samplesPerTurn: windowSamples,
                lateralMeters: meters,
                horizontalAccuracy: horizontalAccuracy
            )
        }

        return GPSTestData(
            samples: samples,
            truePathLengthMeters: cumulativeDistance,
            turnIndices: turnIndices,
            turnDirections: turnDirections
        )
    }

    /// Displaces samples around each turn perpendicular to the post-turn
    /// heading. The displacement falls off linearly with distance from the
    /// turn point so the path bulges out (or in) at the corner.
    private static func applyLateralTurnBias(
        samples: [CLLocation],
        turns: [(index: Int, leftTurn: Bool)],
        samplesPerTurn: Int,
        lateralMeters: Double,
        horizontalAccuracy: Double
    ) -> [CLLocation] {
        guard !turns.isEmpty, lateralMeters != 0, samplesPerTurn > 0 else {
            return samples
        }

        var biased = samples
        let half = samplesPerTurn / 2

        for turn in turns {
            // Determine perpendicular direction from sample heading.
            // Heading approximated from the next sample after the turn.
            let i = turn.index
            guard i + 1 < biased.count else { continue }

            let turnLoc = biased[i]
            let nextLoc = biased[i + 1]
            let bearing = bearingBetween(from: turnLoc, to: nextLoc)

            // Perpendicular: 90° to right of post-turn heading is "outside" of
            // a left turn; 90° to left is "outside" of a right turn.
            let perpBearing = turn.leftTurn
                ? bearing + 90    // outside of left turn = right of new heading
                : bearing - 90    // outside of right turn = left of new heading

            // Apply triangular weighting centered on turn
            let lo = max(0, i - half)
            let hi = min(biased.count - 1, i + half)
            for j in lo...hi {
                let weight = 1.0 - Double(abs(j - i)) / Double(half + 1)
                let offsetMeters = lateralMeters * weight
                let oldLoc = biased[j]
                let displaced = displace(
                    coord: oldLoc.coordinate,
                    bearingDegrees: perpBearing,
                    meters: offsetMeters
                )
                biased[j] = CLLocation(
                    coordinate: displaced,
                    altitude: oldLoc.altitude,
                    horizontalAccuracy: oldLoc.horizontalAccuracy,
                    verticalAccuracy: oldLoc.verticalAccuracy,
                    timestamp: oldLoc.timestamp
                )
            }
        }

        return biased
    }

    private static func bearingBetween(from a: CLLocation, to b: CLLocation) -> Double {
        let lat1 = a.coordinate.latitude * .pi / 180
        let lat2 = b.coordinate.latitude * .pi / 180
        let dLon = (b.coordinate.longitude - a.coordinate.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var bearing = atan2(y, x) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        return bearing
    }

    private static func displace(
        coord: CLLocationCoordinate2D,
        bearingDegrees: Double,
        meters: Double
    ) -> CLLocationCoordinate2D {
        let bearingRad = bearingDegrees * .pi / 180
        let north = meters * cos(bearingRad)
        let east  = meters * sin(bearingRad)
        let lat = coord.latitude + metersToLatitudeDelta(north)
        let lon = coord.longitude + metersToLongitudeDelta(east, atLatitude: coord.latitude)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - Helpers

    private static func metersToLatitudeDelta(_ meters: Double) -> Double {
        meters / 111_320.0
    }

    private static func metersToLongitudeDelta(_ meters: Double, atLatitude lat: Double) -> Double {
        meters / (111_320.0 * cos(lat * .pi / 180))
    }

    private static func makeLocation(
        lat: Double,
        lon: Double,
        accuracy: Double,
        timestamp: Date,
        noise: Double,
        rng: inout SeededRNG
    ) -> CLLocation {
        var noisyLat = lat
        var noisyLon = lon
        if noise > 0 {
            let n1 = Double.random(in: -noise...noise, using: &rng)
            let n2 = Double.random(in: -noise...noise, using: &rng)
            noisyLat += metersToLatitudeDelta(n1)
            noisyLon += metersToLongitudeDelta(n2, atLatitude: lat)
        }
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: noisyLat, longitude: noisyLon),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: accuracy,
            timestamp: timestamp
        )
    }
}

/// Deterministic seeded RNG for reproducible test data.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xdeadbeef : seed
    }

    mutating func next() -> UInt64 {
        // splitmix64 — good enough for tests
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
