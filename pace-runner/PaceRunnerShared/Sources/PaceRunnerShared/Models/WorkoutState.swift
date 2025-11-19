import Foundation

/// Represents the current state of an active workout
///
/// WorkoutState is the real-time data model used during workout execution.
/// It's continuously updated by:
/// - GPSManager (distance, current pace)
/// - PaceCalculator (smoothed pace)
/// - WorkoutManager (time elapsed, mile markers)
///
/// This state drives:
/// - Watch face UI updates (current pace, distance, time)
/// - Audio feedback (tempo beats, voice alerts)
/// - Deviation detection (pace too fast/slow)
///
/// Lifecycle:
/// - Created when workout starts
/// - Updated every GPS sample (~1 Hz)
/// - Converted to WorkoutSummary when workout ends
///
/// Constitution compliance:
/// - Native Performance First: Lightweight struct, no heap allocations
/// - Battery Life as Feature: Minimal state, no unnecessary computations
/// - <200ms GPS Latency: Direct property updates, no async transforms
public struct WorkoutState: Equatable {

    // MARK: - Properties

    /// Configuration being used for this workout
    public let configuration: RunConfiguration

    /// Current workout status
    public var status: Status

    /// Timestamp when workout started
    public let startTime: Date

    /// Total distance covered so far (meters)
    public var distanceCovered: Double

    /// Current pace (smoothed via EWMA)
    /// Updated every GPS sample
    public var currentPace: Pace?

    /// Time elapsed since workout start (seconds)
    public var elapsedTime: TimeInterval

    /// Mile markers reached so far
    /// Populated when runner crosses each mile threshold
    public var mileSplits: [MileSplit]

    /// Current mile number (1-based)
    /// Increments when runner crosses mile marker
    public var currentMile: Int

    // MARK: - Status Enum

    /// Possible workout states
    public enum Status: Equatable {
        /// Workout running normally
        case running

        /// Workout paused by user
        case paused

        /// Workout ended (either completed or stopped early)
        case ended

        /// Waiting for GPS lock before starting
        case waitingForGPS
    }

    // MARK: - Initialization

    /// Creates initial workout state
    /// - Parameter configuration: Run configuration for this workout
    public init(configuration: RunConfiguration) {
        self.configuration = configuration
        self.status = .waitingForGPS
        self.startTime = Date()
        self.distanceCovered = 0.0
        self.currentPace = nil
        self.elapsedTime = 0.0
        self.mileSplits = []
        self.currentMile = 1
    }

    // MARK: - Computed Properties

    /// Distance remaining to configured total
    /// - Returns: Meters remaining, 0 if already exceeded
    public var distanceRemaining: Double {
        let totalMeters = configuration.distance.meters
        return max(0, totalMeters - distanceCovered)
    }

    /// Current progress as percentage
    /// - Returns: 0.0 to 1.0 (or >1.0 if exceeded configured distance)
    public var progress: Double {
        let totalMeters = configuration.distance.meters
        guard totalMeters > 0 else { return 0.0 }
        return distanceCovered / totalMeters
    }

    /// Target pace for current mile
    /// - Returns: Pace from configuration for current mile number
    public var targetPace: Pace {
        let index = min(currentMile - 1, configuration.milePaces.count - 1)
        return configuration.milePaces[index]
    }

    /// Pace deviation from target in seconds
    /// - Returns: nil if no current pace yet, otherwise deviation in seconds
    public var paceDeviation: Int? {
        guard let current = currentPace else { return nil }
        return current.totalSeconds - targetPace.totalSeconds
    }

    /// Whether current pace is within tolerance
    /// - Returns: true if deviation within ±tolerance, false if outside, nil if no pace yet
    public var isWithinTolerance: Bool? {
        guard let deviation = paceDeviation else { return nil }
        return abs(deviation) <= configuration.paceTolerance
    }

    /// Current distance in miles
    /// - Returns: Distance covered in miles
    public var milesCompleted: Double {
        distanceCovered / 1609.34
    }

    /// Whether workout has reached configured distance
    /// - Returns: true if distance covered >= configured distance
    public var isDistanceComplete: Bool {
        distanceCovered >= configuration.distance.meters
    }

    // MARK: - State Updates

    /// Updates state with new GPS location
    /// - Parameters:
    ///   - distance: Distance covered in meters
    ///   - pace: Current smoothed pace
    ///   - elapsed: Time elapsed since start
    public mutating func update(distance: Double, pace: Pace?, elapsed: TimeInterval) {
        self.distanceCovered = distance
        self.currentPace = pace
        self.elapsedTime = elapsed

        // Check if crossed into next mile
        let newMileNumber = Int(milesCompleted) + 1
        if newMileNumber > currentMile {
            currentMile = newMileNumber
        }
    }

    /// Records a completed mile split
    /// - Parameter split: MileSplit data for completed mile
    public mutating func recordMileSplit(_ split: MileSplit) {
        mileSplits.append(split)
    }

    /// Converts current state to WorkoutSummary
    /// - Returns: Immutable summary of completed workout
    public func toSummary() -> WorkoutSummary {
        let endTime = Date()
        let totalDistance = Distance(miles: milesCompleted)

        // Calculate average pace: total time / total distance
        let totalSeconds = Int(elapsedTime)
        let paceSeconds = Int(Double(totalSeconds) / milesCompleted)
        let avgPace = Pace(
            minutes: paceSeconds / 60,
            seconds: paceSeconds % 60
        )

        return WorkoutSummary(
            configurationName: configuration.name,
            startTime: startTime,
            endTime: endTime,
            totalDistance: totalDistance,
            averagePace: avgPace,
            mileSplits: mileSplits
        )
    }
}
