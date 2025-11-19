import Foundation
import Combine

/// Protocol for pace calculation with smoothing
///
/// PaceCalculator converts GPS location streams into smoothed pace values
/// using EWMA (Exponentially Weighted Moving Average) algorithm.
///
/// Constitution: <50ms computation time per sample
public protocol PaceCalculatorProtocol: AnyObject {
    /// Publisher for smoothed pace updates
    var pacePublisher: AnyPublisher<Pace?, Never> { get }

    /// Most recent smoothed pace
    var currentPace: Pace? { get }

    /// Add location sample for pace calculation
    /// - Parameter location: GPS location with timestamp
    func addSample(distance: Double, timestamp: Date)

    /// Reset calculator state
    func reset()
}
