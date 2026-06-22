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
    /// DEPRECATED: Use paceWindows instead
    public var currentPace: Pace?

    /// Multi-window pace calculations
    /// Provides split, last mile, 3min, and 1min paces
    public var paceWindows: PaceWindows

    /// Time elapsed since workout start (seconds)
    public var elapsedTime: TimeInterval

    /// Distance at start of current mile (meters)
    /// Used to calculate split pace
    public var currentMileSplitStart: Double

    /// Time at start of current mile (seconds since workout start)
    /// Used to calculate split pace
    public var currentMileSplitStartTime: TimeInterval

    /// Mile markers reached so far
    /// Populated when runner crosses each mile threshold
    public var mileSplits: [MileSplit]

    /// Current mile number (1-based)
    /// Increments when runner crosses mile marker
    public var currentMile: Int

    // MARK: - Segment Tracking

    /// Current segment index (0-based) for multi-segment configs
    public var currentSegmentIndex: Int

    /// Distance (meters) where the current segment began
    public var segmentDistanceStart: Double

    // MARK: - Grace Period

    /// Whether workout is still in the initial grace period
    /// During grace period: metronome plays but no pace deviation alerts
    public var isInGracePeriod: Bool

    /// Current heart rate in BPM (nil if no HR data available yet)
    public var currentHeartRate: Int?

    /// When movement was first detected (grace period started)
    public var gracePeriodStartTime: Date?

    /// Duration of grace period in seconds (default 15)
    public static let gracePeriodDuration: TimeInterval = 15.0

    /// Minimum speed to detect movement (m/s) - roughly 3 mph walking pace
    public static let movementThreshold: Double = 0.5

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
        self.paceWindows = PaceWindows()
        self.elapsedTime = 0.0
        self.currentMileSplitStart = 0.0
        self.currentMileSplitStartTime = 0.0
        self.mileSplits = []
        self.currentMile = 1
        self.currentSegmentIndex = 0
        self.segmentDistanceStart = 0.0
        self.currentHeartRate = nil
        self.isInGracePeriod = true // Start in grace period
        self.gracePeriodStartTime = nil // Set when movement detected
    }

    /// Whether grace period has expired
    /// - Returns: true if grace period is over and alerts should be enabled
    public var isGracePeriodExpired: Bool {
        guard let startTime = gracePeriodStartTime else {
            return false // Movement not yet detected
        }
        return Date().timeIntervalSince(startTime) >= Self.gracePeriodDuration
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

    /// Current segment for multi-segment configs
    public var currentSegment: RunSegment? {
        guard let segments = configuration.segments,
              currentSegmentIndex < segments.count else { return nil }
        return segments[currentSegmentIndex]
    }

    /// Distance covered within the current segment
    public var segmentDistanceCovered: Double {
        distanceCovered - segmentDistanceStart
    }

    /// Progress within the current segment (0.0 to 1.0)
    public var segmentProgress: Double {
        guard let segment = currentSegment else { return 0.0 }
        guard segment.distance.meters > 0 else { return 0.0 }
        return segmentDistanceCovered / segment.distance.meters
    }

    /// Effective pace tolerance — uses segment override if available
    public var effectivePaceTolerance: Int {
        currentSegment?.paceTolerance ?? configuration.paceTolerance
    }

    /// Effective cadence offset — uses segment override if available
    public var effectiveCadenceOffset: Int {
        currentSegment?.cadenceOffset ?? configuration.cadenceOffset
    }

    /// Effective stride length — segment > config > global settings
    public func effectiveStrideLengthInches(settings: AppSettings) -> Double {
        currentSegment?.strideLengthInches
            ?? configuration.strideLengthInches
            ?? settings.strideLengthInches
    }

    /// Effective pace calibration — segment > config > global settings
    public func effectivePaceCalibrationSeconds(settings: AppSettings) -> Int {
        currentSegment?.paceCalibrationSeconds
            ?? configuration.paceCalibrationSeconds
            ?? settings.paceCalibrationSeconds
    }

    /// Target pace for current mile or segment
    /// Multi-segment: uses current segment's pace
    /// Single-segment: uses milePaces array
    public var targetPace: Pace {
        if let segment = currentSegment {
            return segment.pace
        }
        let index = min(currentMile - 1, configuration.milePaces.count - 1)
        return configuration.milePaces[index]
    }

    /// Current mile split pace
    /// Calculates pace for distance/time since start of current mile
    /// - Returns: Split pace, or nil if no distance covered yet in current mile
    public var splitPace: Pace? {
        let splitDistance = distanceCovered - currentMileSplitStart
        let splitTime = elapsedTime - currentMileSplitStartTime

        guard splitDistance > 0, splitTime > 0 else { return nil }

        // Calculate pace in seconds per mile
        let secondsPerMeter = splitTime / splitDistance
        let secondsPerMile = secondsPerMeter * 1609.34

        let totalSeconds = Int(secondsPerMile)

        // Validate range (4:00 - 20:00/mile)
        guard totalSeconds >= 240 && totalSeconds <= 1200 else {
            return nil
        }

        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        return Pace(minutes: minutes, seconds: seconds)
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
    /// - Parameters:
    ///   - debugLog: Optional debug log to include with the summary
    ///   - settings: Optional AppSettings snapshot at time of workout
    /// - Returns: Immutable summary of completed workout
    public func toSummary(debugLog: DebugLog? = nil, settings: AppSettings? = nil) -> WorkoutSummary {
        let endTime = Date()
        let totalDistance = Distance(miles: milesCompleted)

        let avgPace: Pace
        if milesCompleted > 0 {
            let totalSeconds = max(Int(elapsedTime), 1)
            let secondsPerMile = max(240, min(1200, Int((Double(totalSeconds) / milesCompleted).rounded())))
            avgPace = Pace(
                minutes: secondsPerMile / 60,
                seconds: secondsPerMile % 60
            )
        } else {
            avgPace = configuration.milePaces.first ?? Pace(minutes: 8, seconds: 0)
        }

        return WorkoutSummary(
            configurationName: configuration.name,
            startTime: startTime,
            endTime: endTime,
            totalDistance: totalDistance,
            averagePace: avgPace,
            mileSplits: mileSplits,
            debugLog: debugLog,
            configuration: configuration,
            settings: settings
        )
    }
}
