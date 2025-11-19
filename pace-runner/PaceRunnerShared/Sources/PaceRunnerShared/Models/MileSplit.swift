import Foundation

/// Represents pace data for a single mile within a workout
///
/// MileSplit captures both target and actual performance for each mile marker,
/// enabling post-run analysis of pacing consistency and deviations.
///
/// Examples:
/// - Mile 1: Target 8:00/mile, Actual 7:55/mile (5 seconds fast)
/// - Mile 20: Target 8:00/mile, Actual 8:15/mile (15 seconds slow - fatigue)
/// - Mile 26.2: Target 8:00/mile, Actual 7:30/mile (final sprint, partial mile)
///
/// Constitution compliance:
/// - User Experience Consistency: Standardized split format for history display
/// - Native Performance First: Lightweight struct, minimal memory overhead
public struct MileSplit: Codable, Equatable {

    // MARK: - Properties

    /// Mile marker number (1-based index)
    /// For marathon: 1-26 for full miles, 27 for final 0.2 miles
    public let mileNumber: Int

    /// Actual pace achieved for this mile
    public let actualPace: Pace

    /// Target pace configured for this mile
    public let targetPace: Pace

    /// Actual distance covered for this mile marker
    /// Usually 1.0 miles, but may be fractional for final mile
    /// Example: Marathon final mile is 0.2 miles
    public let distance: Distance

    // MARK: - Initialization

    /// Creates a new mile split entry
    /// - Parameters:
    ///   - mileNumber: 1-based mile index (e.g., 1 for Mile 1)
    ///   - actualPace: Pace achieved for this mile
    ///   - targetPace: Goal pace for this mile
    ///   - distance: Distance covered for this marker (defaults handled by caller)
    public init(mileNumber: Int,
                actualPace: Pace,
                targetPace: Pace,
                distance: Distance) {
        self.mileNumber = mileNumber
        self.actualPace = actualPace
        self.targetPace = targetPace
        self.distance = distance
    }

    // MARK: - Computed Properties

    /// Deviation from target pace in seconds
    /// - Returns: Positive if slower than target, negative if faster
    public var paceDeviation: Int {
        actualPace.totalSeconds - targetPace.totalSeconds
    }

    /// Whether this mile was within configured tolerance
    /// Note: Tolerance check requires context (not stored in MileSplit)
    /// - Parameter tolerance: Allowed deviation in seconds
    /// - Returns: true if deviation within ±tolerance
    public func isWithinTolerance(_ tolerance: Int) -> Bool {
        abs(paceDeviation) <= tolerance
    }

    /// Duration in seconds to complete this mile
    /// - Returns: actualPace * distance (in miles)
    public var duration: TimeInterval {
        TimeInterval(actualPace.totalSeconds) * distance.miles
    }

    /// Formatted split display string
    /// - Returns: "Mile X: M:SS (±S)" format
    public var formatted: String {
        let deviationSign = paceDeviation >= 0 ? "+" : ""
        return "Mile \(mileNumber): \(actualPace.formatted) (\(deviationSign)\(paceDeviation)s)"
    }
}
