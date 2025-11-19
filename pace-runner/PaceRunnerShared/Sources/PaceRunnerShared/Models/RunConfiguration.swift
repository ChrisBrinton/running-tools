import Foundation

/// Represents a configured running workout with target paces and settings
///
/// A RunConfiguration defines all parameters needed for a training run:
/// - Total distance to cover
/// - Target pace for each mile (can vary for progressive runs)
/// - Base cadence for audio tempo beats
/// - Pace tolerance for deviation alerts
///
/// Examples:
/// - Even-paced marathon: 26.2 miles at 8:00/mile throughout
/// - Progressive long run: First 15 miles at 9:00/mile, last 5 at 8:30/mile
/// - Tempo run: 6 miles at 7:00/mile with tight 5-second tolerance
///
/// Constitution compliance:
/// - User Experience Consistency: Configurations created on iPhone, synced to Watch
/// - Workout Independence: Stored locally in UserDefaults, no cloud dependency
public struct RunConfiguration: Codable, Identifiable, Equatable {

    // MARK: - Properties

    /// Unique identifier for this configuration
    public let id: UUID

    /// User-friendly name (e.g., "Marathon - Even Pace", "Long Run - Progressive")
    public var name: String

    /// Total distance for this run
    public var distance: Distance

    /// Target pace for each mile
    /// Array length = ceil(distance.miles)
    /// Example: 26.2 miles → 27 paces (26 full miles + partial final mile)
    public var milePaces: [Pace]

    /// Base cadence in steps per minute (SPM) for audio tempo beats
    /// Typical range: 150-200 SPM
    /// Default: 180 SPM (standard marathon cadence)
    public var baseCadence: Int

    /// Pace tolerance in seconds for deviation alerts
    /// Example: 10 means alert when current pace deviates ±10 seconds from target
    /// Default: 10 seconds
    public var paceTolerance: Int

    /// Timestamp when configuration was created
    public let createdAt: Date

    /// Timestamp when configuration was last modified
    public var modifiedAt: Date

    // MARK: - Initialization

    /// Creates a new RunConfiguration with a single target pace
    /// - Parameters:
    ///   - id: Unique identifier (generates new UUID if not provided)
    ///   - name: Configuration name
    ///   - distance: Total run distance
    ///   - targetPace: Single pace applied to all miles
    ///   - baseCadence: Audio tempo cadence (default: 180 SPM)
    ///   - paceTolerance: Alert threshold in seconds (default: 10)
    /// - Precondition: Name must not be empty
    /// - Precondition: Base cadence must be in range 150-200
    /// - Precondition: Pace tolerance must be positive
    public init(
        id: UUID = UUID(),
        name: String,
        distance: Distance,
        targetPace: Pace,
        baseCadence: Int = 180,
        paceTolerance: Int = 10
    ) {
        precondition(!name.isEmpty, "Configuration name must not be empty")
        precondition(150...200 ~= baseCadence,
                     "Base cadence must be 150-200 SPM, got \(baseCadence)")
        precondition(paceTolerance > 0,
                     "Pace tolerance must be positive, got \(paceTolerance)")

        let now = Date()
        self.id = id
        self.name = name
        self.distance = distance
        self.baseCadence = baseCadence
        self.paceTolerance = paceTolerance
        self.createdAt = now
        self.modifiedAt = now

        // Create mile pace array with length = ceiling of miles
        let mileCount = Int(ceil(distance.miles))
        self.milePaces = Array(repeating: targetPace, count: mileCount)
    }

    /// Creates a new RunConfiguration with custom mile paces
    /// - Parameters:
    ///   - id: Unique identifier (generates new UUID if not provided)
    ///   - name: Configuration name
    ///   - distance: Total run distance
    ///   - milePaces: Custom pace for each mile
    ///   - baseCadence: Audio tempo cadence (default: 180 SPM)
    ///   - paceTolerance: Alert threshold in seconds (default: 10)
    /// - Precondition: Name must not be empty
    /// - Precondition: Base cadence must be in range 150-200
    /// - Precondition: Pace tolerance must be positive
    /// - Precondition: Mile paces array length must match ceiling(distance.miles)
    public init(
        id: UUID = UUID(),
        name: String,
        distance: Distance,
        milePaces: [Pace],
        baseCadence: Int = 180,
        paceTolerance: Int = 10
    ) {
        let expectedMiles = Int(ceil(distance.miles))

        precondition(!name.isEmpty, "Configuration name must not be empty")
        precondition(150...200 ~= baseCadence,
                     "Base cadence must be 150-200 SPM, got \(baseCadence)")
        precondition(paceTolerance > 0,
                     "Pace tolerance must be positive, got \(paceTolerance)")
        precondition(milePaces.count == expectedMiles,
                     "Mile paces count (\(milePaces.count)) must match ceiling of distance (\(expectedMiles))")

        let now = Date()
        self.id = id
        self.name = name
        self.distance = distance
        self.milePaces = milePaces
        self.baseCadence = baseCadence
        self.paceTolerance = paceTolerance
        self.createdAt = now
        self.modifiedAt = now
    }

    // MARK: - Computed Properties

    /// Calculates average pace across all miles
    /// - Returns: Average of all mile paces
    public func averagePace() -> Pace {
        let totalSeconds = milePaces.reduce(0) { $0 + $1.totalSeconds }
        let averageSeconds = totalSeconds / milePaces.count
        let minutes = averageSeconds / 60
        let seconds = averageSeconds % 60
        return Pace(minutes: minutes, seconds: seconds)
    }

    /// Calculates estimated total duration for the run
    /// - Returns: Total seconds to complete the run at target paces
    public func estimatedDuration() -> TimeInterval {
        let totalPaceSeconds = milePaces.reduce(0) { $0 + $1.totalSeconds }
        return TimeInterval(totalPaceSeconds)
    }
}
