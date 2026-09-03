import Foundation
import Combine

/// Protocol for pace calculation with smoothing
///
/// PaceCalculator converts GPS location streams into smoothed pace values
/// using EWMA (Exponentially Weighted Moving Average) algorithm.
///
/// Provides multiple configurable windows for hierarchical pace feedback:
/// - Fast window: Short-term pace (configurable, default 2 minutes)
/// - Medium window: Medium-term trend (configurable, default 4 minutes)
/// - Slow window: Master pace - distance-based (configurable, default 1 mile)
///
/// Constitution: <50ms computation time per sample
/// A snapshot of what each pace window is actually covering.
public struct PaceWindowDiagnostics: Equatable {
    /// Total retained samples.
    public let sampleCount: Int
    /// Moving-time span the time-based windows may draw from.
    public let movingTimeSpan: TimeInterval
    /// Distance the distance-based master (rolling-mile) window actually spans.
    /// Well under the configured window means it has not filled yet — the case
    /// where the rolling mile legitimately duplicates the current mile split.
    public let masterWindowMeters: Double
    /// Moving time the master window spans.
    public let masterWindowSeconds: TimeInterval
    public let masterWindowSamples: Int
    public let fastWindowSamples: Int

    public init(
        sampleCount: Int,
        movingTimeSpan: TimeInterval,
        masterWindowMeters: Double,
        masterWindowSeconds: TimeInterval,
        masterWindowSamples: Int,
        fastWindowSamples: Int
    ) {
        self.sampleCount = sampleCount
        self.movingTimeSpan = movingTimeSpan
        self.masterWindowMeters = masterWindowMeters
        self.masterWindowSeconds = masterWindowSeconds
        self.masterWindowSamples = masterWindowSamples
        self.fastWindowSamples = fastWindowSamples
    }
}

public protocol PaceCalculatorProtocol: AnyObject {
    /// Publisher for smoothed pace updates (fast window)
    var pacePublisher: AnyPublisher<Pace?, Never> { get }

    /// Most recent smoothed pace (fast window)
    var currentPace: Pace? { get }

    /// Fast rolling average pace (time-based, configurable)
    /// Default: 2 minutes (120 seconds)
    var fastPace: Pace? { get }

    /// Medium rolling average pace (time-based, configurable)
    /// Default: 4 minutes (240 seconds)
    var mediumPace: Pace? { get }

    /// Slow rolling average pace - master pace (distance-based, configurable)
    /// Default: 1 mile trailing distance
    var slowPace: Pace? { get }

    // Legacy accessors for backward compatibility
    var oneMinutePace: Pace? { get }
    var threeMinutePace: Pace? { get }
    var trailingMilePace: Pace? { get }

    /// Moving-time span covered by the retained samples, in seconds.
    ///
    /// Distinct from a window having a *pace*: `fastPace`/`mediumPace` report a
    /// value after only a few samples, so a caller that needs "this window is
    /// actually full" must compare against this instead of a non-nil pace.
    /// Measured in moving time, so paused and glitch spans do not count.
    var movingTimeSpan: TimeInterval { get }

    /// Configure the averaging windows
    /// - Parameters:
    ///   - fastSeconds: Fast window duration in seconds (default 120)
    ///   - mediumSeconds: Medium window duration in seconds (default 240)
    ///   - slowMiles: Slow window distance in miles (default 1.0)
    func configureWindows(fastSeconds: Int, mediumSeconds: Int, slowMiles: Double)

    /// Add location sample for pace calculation
    /// - Parameter location: GPS location with timestamp
    func addSample(distance: Double, timestamp: Date)

    /// Inform the calculator that the workout was paused for `pauseDuration`
    /// seconds and has now resumed. The rolling windows must not count paused
    /// time as running time, so the calculator slides its accumulated history
    /// forward to stay contiguous (in "moving time") with post-resume samples.
    /// - Parameter pauseDuration: How long the workout was paused, in seconds.
    func notePauseGap(_ pauseDuration: TimeInterval)

    /// What each window is currently spanning — for diagnosing readouts that
    /// look wrong (e.g. the rolling mile duplicating the current mile split).
    var windowDiagnostics: PaceWindowDiagnostics { get }

    /// Restart the time-based windows at a segment boundary, preserving the
    /// sample history the distance-based master window needs.
    func restartTimeWindows()

    /// Reset calculator state
    func reset()
}
