import Foundation
import CoreLocation

/// Method used to compute the per-sample distance delta.
public enum DistanceCalcMethod: String, Codable, CaseIterable {
    /// Sum of straight-line (chord) distances between consecutive samples, 2D only.
    /// This is the historical default.
    case chord
    /// Same as chord, including altitude delta (3D chord).
    case chord3D
    /// max(chord, GPS-reported speed × dt). Uses the chip's Kalman-filtered speed
    /// as a floor so corner-cutting can't shrink the distance below what the chip
    /// believes you actually traveled.
    case speedFloor
    /// Same as speedFloor with altitude included in the chord component.
    case speedFloor3D

    public var displayName: String {
        switch self {
        case .chord:        return "Chord (2D)"
        case .chord3D:      return "Chord (3D)"
        case .speedFloor:   return "Speed Floor (2D)"
        case .speedFloor3D: return "Speed Floor (3D)"
        }
    }
}

/// Computes accumulated distance from a stream of `CLLocation` samples.
///
/// Implementations track their own state and a running total. The same protocol
/// is used both for the active "drives the workout" calculator and for the
/// shadow calculators that run in parallel during verbose GPS logging.
public protocol DistanceCalculator: AnyObject {
    /// Stable identifier used in logs and settings.
    var method: DistanceCalcMethod { get }

    /// Cumulative distance in meters since `reset()` (or construction).
    var totalDistance: Double { get }

    /// Feed one location sample.
    /// - Returns: delta added to totalDistance for this sample (may be 0).
    @discardableResult
    func addLocation(_ location: CLLocation) -> Double

    /// Clear state and totals.
    func reset()
}

// MARK: - Chord (2D)

public final class ChordDistanceCalculator: DistanceCalculator {
    public let method: DistanceCalcMethod = .chord
    public private(set) var totalDistance: Double = 0
    private var lastLocation: CLLocation?

    /// Minimum step distance that gets accumulated. Below this, the sample is
    /// treated as noise. Matches historical behavior.
    private let minStepMeters: Double = 0.5

    public init() {}

    @discardableResult
    public func addLocation(_ location: CLLocation) -> Double {
        defer { lastLocation = location }
        guard let last = lastLocation else { return 0 }
        let delta = location.distance(from: last)
        if delta >= minStepMeters {
            totalDistance += delta
            return delta
        }
        return 0
    }

    public func reset() {
        lastLocation = nil
        totalDistance = 0
    }
}

// MARK: - Chord (3D)

public final class Chord3DDistanceCalculator: DistanceCalculator {
    public let method: DistanceCalcMethod = .chord3D
    public private(set) var totalDistance: Double = 0
    private var lastLocation: CLLocation?

    private let minStepMeters: Double = 0.5

    public init() {}

    @discardableResult
    public func addLocation(_ location: CLLocation) -> Double {
        defer { lastLocation = location }
        guard let last = lastLocation else { return 0 }

        let horizontal = location.distance(from: last)
        let vertical: Double
        // Only include altitude if vertical accuracy is reasonable; otherwise 0
        if location.verticalAccuracy > 0 && last.verticalAccuracy > 0 {
            vertical = location.altitude - last.altitude
        } else {
            vertical = 0
        }
        let delta = (horizontal * horizontal + vertical * vertical).squareRoot()
        if delta >= minStepMeters {
            totalDistance += delta
            return delta
        }
        return 0
    }

    public func reset() {
        lastLocation = nil
        totalDistance = 0
    }
}

// MARK: - Speed Floor (2D)

/// Uses the larger of: chord distance, or GPS-reported speed × time elapsed
/// since the previous sample. The chip's reported `speed` is Kalman-filtered
/// from the recent past; when chord shrinks (corner cutting) but the chip
/// still reports forward speed, we trust the speed value as a floor.
public final class SpeedFloorDistanceCalculator: DistanceCalculator {
    public let method: DistanceCalcMethod = .speedFloor
    public private(set) var totalDistance: Double = 0
    private var lastLocation: CLLocation?

    private let minStepMeters: Double = 0.5

    public init() {}

    @discardableResult
    public func addLocation(_ location: CLLocation) -> Double {
        defer { lastLocation = location }
        guard let last = lastLocation else { return 0 }

        let chord = location.distance(from: last)
        let dt = location.timestamp.timeIntervalSince(last.timestamp)

        // Use speed × dt as a lower bound when valid (CLLocation.speed = -1 = unknown)
        let speedFloor: Double
        if location.speed >= 0 && dt > 0 {
            speedFloor = location.speed * dt
        } else {
            speedFloor = 0
        }

        let delta = max(chord, speedFloor)
        if delta >= minStepMeters {
            totalDistance += delta
            return delta
        }
        return 0
    }

    public func reset() {
        lastLocation = nil
        totalDistance = 0
    }
}

// MARK: - Speed Floor (3D)

public final class SpeedFloor3DDistanceCalculator: DistanceCalculator {
    public let method: DistanceCalcMethod = .speedFloor3D
    public private(set) var totalDistance: Double = 0
    private var lastLocation: CLLocation?

    private let minStepMeters: Double = 0.5

    public init() {}

    @discardableResult
    public func addLocation(_ location: CLLocation) -> Double {
        defer { lastLocation = location }
        guard let last = lastLocation else { return 0 }

        let horizontal = location.distance(from: last)
        let vertical: Double
        if location.verticalAccuracy > 0 && last.verticalAccuracy > 0 {
            vertical = location.altitude - last.altitude
        } else {
            vertical = 0
        }
        let chord3D = (horizontal * horizontal + vertical * vertical).squareRoot()

        let dt = location.timestamp.timeIntervalSince(last.timestamp)
        let speedFloor: Double
        if location.speed >= 0 && dt > 0 {
            speedFloor = location.speed * dt
        } else {
            speedFloor = 0
        }

        let delta = max(chord3D, speedFloor)
        if delta >= minStepMeters {
            totalDistance += delta
            return delta
        }
        return 0
    }

    public func reset() {
        lastLocation = nil
        totalDistance = 0
    }
}

// MARK: - Factory

public enum DistanceCalculatorFactory {
    public static func make(method: DistanceCalcMethod) -> DistanceCalculator {
        switch method {
        case .chord:        return ChordDistanceCalculator()
        case .chord3D:      return Chord3DDistanceCalculator()
        case .speedFloor:   return SpeedFloorDistanceCalculator()
        case .speedFloor3D: return SpeedFloor3DDistanceCalculator()
        }
    }

    public static func makeAll() -> [DistanceCalculator] {
        DistanceCalcMethod.allCases.map { make(method: $0) }
    }
}
