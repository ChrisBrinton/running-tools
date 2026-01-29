import Foundation

/// Represents a completed workout with all performance metrics
///
/// WorkoutSummary is created at workout completion and contains:
/// - Configuration metadata (which run plan was used)
/// - Time bounds (start and end timestamps)
/// - Aggregate metrics (total distance, average pace)
/// - Mile-by-mile splits for detailed analysis
///
/// Summaries are:
/// - Saved to HealthKit (as HKWorkout with associated samples)
/// - Displayed in iPhone history view
/// - Synced to cloud analytics service (future, via workout-sync-service)
///
/// Examples:
/// - Marathon completed in 3:29:24 at 7:58/mile average
/// - Long run: 20 miles in 2:40:00 with progressive pacing
/// - Tempo run: 6 miles at 6:45/mile (target was 7:00/mile)
///
/// Constitution compliance:
/// - Workout Independence: Created and stored locally, no cloud dependency
/// - User Experience Consistency: Standardized summary format across views
public struct WorkoutSummary: Codable, Identifiable {

    // MARK: - Properties

    /// Unique identifier for this workout
    public let id: UUID

    /// Name of the RunConfiguration used for this workout
    /// Stored as string (not reference) since config may be deleted/modified later
    public let configurationName: String

    /// Timestamp when workout started
    public let startTime: Date

    /// Timestamp when workout ended
    public let endTime: Date

    /// Total distance covered during workout
    /// May differ from configured distance if workout stopped early
    public let totalDistance: Distance

    /// Average pace across entire workout
    /// Calculated as total time / total distance
    public let averagePace: Pace

    /// Per-mile split data
    /// Array length = number of mile markers reached
    /// Example: Marathon has 27 splits (26 full miles + 0.2 final)
    public let mileSplits: [MileSplit]

    /// Debug log capturing timing, sync, and calibration events
    /// Used for troubleshooting timing discrepancies between PaceRunner and Workout app
    public let debugLog: DebugLog?

    // MARK: - Initialization

    /// Creates a new WorkoutSummary
    /// - Parameters:
    ///   - id: Unique identifier (generates new UUID if not provided)
    ///   - configurationName: Name of configuration used
    ///   - startTime: Workout start timestamp
    ///   - endTime: Workout end timestamp
    ///   - totalDistance: Total distance covered
    ///   - averagePace: Average pace for workout
    ///   - mileSplits: Per-mile performance data
    ///   - debugLog: Optional debug log for troubleshooting
    /// - Precondition: End time must be after start time
    /// - Precondition: Configuration name must not be empty
    public init(
        id: UUID = UUID(),
        configurationName: String,
        startTime: Date,
        endTime: Date,
        totalDistance: Distance,
        averagePace: Pace,
        mileSplits: [MileSplit],
        debugLog: DebugLog? = nil
    ) {
        precondition(!configurationName.isEmpty,
                     "Configuration name must not be empty")
        precondition(endTime > startTime,
                     "End time must be after start time")

        self.id = id
        self.configurationName = configurationName
        self.startTime = startTime
        self.endTime = endTime
        self.totalDistance = totalDistance
        self.averagePace = averagePace
        self.mileSplits = mileSplits
        self.debugLog = debugLog
    }

    // MARK: - Computed Properties

    /// Total workout duration in seconds
    /// - Returns: Time interval from start to end
    public var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    /// Formatted duration string
    /// - Returns: "H:MM:SS" for workouts over 1 hour, "MM:SS" otherwise
    public var formattedDuration: String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    /// Formatted start date string
    /// - Returns: Human-readable date (e.g., "Jan 15, 2025")
    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: startTime)
    }

    /// Formatted start time string
    /// - Returns: Time of day (e.g., "8:30 AM")
    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: startTime)
    }
}
