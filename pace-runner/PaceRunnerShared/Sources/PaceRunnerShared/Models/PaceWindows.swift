import Foundation

/// Represents pace calculated across multiple time and distance windows
///
/// Provides hierarchical pace feedback with configurable windows:
/// - Slow (master): Distance-based rolling average (default 1 mile) - THE MASTER PACE
/// - Medium: Time-based rolling average (default 4 minutes)
/// - Fast: Time-based rolling average (default 2 minutes)
///
/// Voice cue logic:
/// - Slow pace is always the master pace for determining overall progress
/// - If master is fast, skip "speed up" cues (you're ahead)
/// - If master is slow, skip "slow down" cues (you're behind)
/// - Fast pace filters opposite direction cues (immediate trend)
public struct PaceWindows: Equatable {

    // MARK: - Primary Pace Windows (Fast/Medium/Slow naming)

    /// Slow rolling average - THE MASTER PACE (distance-based, default 1 mile)
    /// This is the primary indicator of your overall pace for the run
    public let slowPace: Pace?

    /// Medium rolling average (time-based, default 4 minutes)
    public let mediumPace: Pace?

    /// Fast rolling average (time-based, default 2 minutes)
    public let fastPace: Pace?

    // MARK: - Legacy Properties (backward compatibility)

    // NOTE: there is deliberately no `splitPace` here.
    //
    // It used to exist as `slowPace` under a doc comment claiming it was
    // "distance/time since last mile marker". It was not — it returned the
    // trailing-mile window, so both watch and phone rendered the current mile
    // split and the trailing mile as the same number, always and exactly.
    // The real per-mile split is `WorkoutState.splitPace`, computed from
    // `currentMileSplitStart`/`currentMileSplitStartTime`. Bind to that.

    /// Trailing mile pace - maps to slow pace
    public var trailingMilePace: Pace? { slowPace }

    /// Last completed mile pace (not used in new logic)
    public let lastMilePace: Pace?

    /// Rolling 3-minute average pace - maps to medium pace
    public var threeMinPace: Pace? { mediumPace }

    /// Rolling 1-minute average pace - maps to fast pace
    public var oneMinPace: Pace? { fastPace }

    // MARK: - Initialization

    /// New initializer with Fast/Medium/Slow naming
    public init(
        slowPace: Pace? = nil,
        mediumPace: Pace? = nil,
        fastPace: Pace? = nil,
        lastMilePace: Pace? = nil
    ) {
        self.slowPace = slowPace
        self.mediumPace = mediumPace
        self.fastPace = fastPace
        self.lastMilePace = lastMilePace
    }

    // The legacy initializer (trailingMilePace:/threeMinPace:/oneMinPace:) was
    // removed with the `splitPace` alias: it had no call sites, and with the
    // conflated parameter gone its all-default signature made `PaceWindows()`
    // ambiguous against the primary initializer.

    /// Returns the most important pace window that's out of tolerance
    /// - Parameters:
    ///   - targetPace: Target pace for current mile
    ///   - tolerance: Tolerance in seconds
    /// - Returns: Tuple of (pace, window name) for highest priority out-of-tolerance window, or nil if all in tolerance
    public func mostImportantDeviation(targetPace: Pace, tolerance: Int) -> (pace: Pace, window: String)? {
        // Check in priority order: slow (master) > medium > fast
        if let slow = slowPace {
            let deviation = abs(slow.totalSeconds - targetPace.totalSeconds)
            if deviation > tolerance {
                return (slow, "slow")
            }
        }

        if let medium = mediumPace {
            let deviation = abs(medium.totalSeconds - targetPace.totalSeconds)
            if deviation > tolerance {
                return (medium, "medium")
            }
        }

        if let fast = fastPace {
            let deviation = abs(fast.totalSeconds - targetPace.totalSeconds)
            if deviation > tolerance {
                return (fast, "fast")
            }
        }

        return nil
    }

    /// Returns the master pace (slow/distance-based average)
    /// This is THE pace that determines overall run progress
    public var masterPace: Pace? {
        slowPace
    }

    /// Returns the most important pace (first available in priority order)
    /// Used for graduated voice alerts that work even within tolerance
    /// - Returns: Most important pace, or nil if no pace data available
    public func mostImportantPace() -> Pace? {
        // Return first available in priority order: slow > medium > fast
        return slowPace ?? mediumPace ?? fastPace
    }

    /// Checks if master (slow) pace is faster than target
    /// - Parameter targetPace: Target pace in seconds
    /// - Returns: true if running faster than target (ahead of schedule)
    public func isMasterFasterThanTarget(_ targetPace: Pace) -> Bool {
        guard let master = slowPace else { return false }
        return master.totalSeconds < targetPace.totalSeconds
    }

    /// Checks if master (slow) pace is slower than target
    /// - Parameter targetPace: Target pace in seconds
    /// - Returns: true if running slower than target (behind schedule)
    public func isMasterSlowerThanTarget(_ targetPace: Pace) -> Bool {
        guard let master = slowPace else { return false }
        return master.totalSeconds > targetPace.totalSeconds
    }

    /// Checks if fast pace indicates running faster than target (including tolerance)
    /// - Parameters:
    ///   - targetPace: Target pace
    ///   - tolerance: Tolerance in seconds
    /// - Returns: true if fast pace is at or faster than target (cyan/magenta zone)
    public func isFastPaceFasterThanTarget(_ targetPace: Pace, tolerance: Int) -> Bool {
        guard let fast = fastPace else { return false }
        // Fast pace shows we're running faster (lower seconds = faster)
        return fast.totalSeconds <= targetPace.totalSeconds
    }

    /// Checks if fast pace indicates running slower than target (including tolerance)
    /// - Parameters:
    ///   - targetPace: Target pace
    ///   - tolerance: Tolerance in seconds
    /// - Returns: true if fast pace is at or slower than target (yellow/red zone)
    public func isFastPaceSlowerThanTarget(_ targetPace: Pace, tolerance: Int) -> Bool {
        guard let fast = fastPace else { return false }
        // Fast pace shows we're running slower (higher seconds = slower)
        return fast.totalSeconds >= targetPace.totalSeconds
    }

    /// Returns the appropriate pace for voice cues
    /// Now simplified: always returns slow (master) pace
    /// - Parameters:
    ///   - elapsedTime: Total elapsed time in seconds
    ///   - distanceCovered: Total distance covered in meters
    /// - Returns: Master pace for voice cues, or nil if not enough data
    public func paceForVoiceCues(elapsedTime: TimeInterval, distanceCovered: Double) -> Pace? {
        // No cues in first minute (not enough data)
        guard elapsedTime >= 60 else {
            return nil
        }

        // Always use slow (master) pace - it's the source of truth
        // Fall back to medium then fast if master not available yet
        return slowPace ?? mediumPace ?? fastPace
    }
}
