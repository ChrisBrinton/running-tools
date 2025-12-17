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

    /// Configure the averaging windows
    /// - Parameters:
    ///   - fastSeconds: Fast window duration in seconds (default 120)
    ///   - mediumSeconds: Medium window duration in seconds (default 240)
    ///   - slowMiles: Slow window distance in miles (default 1.0)
    func configureWindows(fastSeconds: Int, mediumSeconds: Int, slowMiles: Double)

    /// Add location sample for pace calculation
    /// - Parameter location: GPS location with timestamp
    func addSample(distance: Double, timestamp: Date)

    /// Reset calculator state
    func reset()
}
