import Foundation

/// Tracks mile boundaries and progress within the current mile.
public final class MileTracker {
    private let metersPerMile: Double = 1609.34

    private var totalDistance: Double = 0
    private var lastMileDistance: Double = 0
    private var currentMile: Int = 0

    public init() {}

    /// Updates the tracker with the latest total distance (in meters).
    /// - Returns: The completed mile number if a new mile boundary was crossed.
    @discardableResult
    public func updateDistance(_ distance: Double) -> Int? {
        guard distance.isFinite, distance >= 0 else { return nil }
        totalDistance = distance
        let distanceSinceLastMile = totalDistance - lastMileDistance

        if distanceSinceLastMile >= metersPerMile {
            currentMile += 1
            lastMileDistance = totalDistance
            return currentMile
        }

        return nil
    }

    /// Returns the index of the current mile (0 before the first mile is completed).
    public var mileIndex: Int {
        currentMile
    }

    /// Progress within the active mile as a value between 0 and 1.
    public var progressInCurrentMile: Double {
        let distanceSinceLastMile = max(totalDistance - lastMileDistance, 0)
        return min(distanceSinceLastMile / metersPerMile, 1.0)
    }

    /// Resets the tracker.
    public func reset() {
        totalDistance = 0
        lastMileDistance = 0
        currentMile = 0
    }
}
