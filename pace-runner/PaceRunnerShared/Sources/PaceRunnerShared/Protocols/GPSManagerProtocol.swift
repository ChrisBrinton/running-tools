import Foundation
import CoreLocation
import Combine

/// Protocol for GPS tracking and distance calculation
///
/// GPSManager is responsible for:
/// - Starting/stopping location updates
/// - Filtering location quality
/// - Calculating accumulated distance
/// - Publishing location updates for pace calculation
///
/// Constitution: <200ms GPS pipeline latency
public protocol GPSManagerProtocol: AnyObject {
    /// Publisher for valid location updates
    var locationPublisher: AnyPublisher<CLLocation, Never> { get }

    /// Publisher for GPS errors
    var errorPublisher: AnyPublisher<Error, Never> { get }

    /// Total distance accumulated in meters
    var totalDistance: Double { get }

    /// Most recent valid location
    var currentLocation: CLLocation? { get }

    /// Whether GPS tracking is active
    var isTracking: Bool { get }

    /// Start GPS tracking
    func startTracking()

    /// Stop GPS tracking
    func stopTracking()

    /// Reset distance counter
    func resetDistance()

    /// Break sample continuity across a pause without losing accumulated
    /// distance. The next fix after resume starts a fresh segment so no
    /// straight-line chord is drawn across the paused interval.
    func breakContinuity()
}
