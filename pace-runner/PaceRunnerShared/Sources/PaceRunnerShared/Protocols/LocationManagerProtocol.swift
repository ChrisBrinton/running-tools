import Foundation
import CoreLocation

/// Protocol abstracting CLLocationManager for testability
///
/// Allows mocking location updates in unit tests while using real
/// CLLocationManager in production.
///
/// Constitution: Native Performance First - minimal abstraction overhead
public protocol LocationManagerProtocol: AnyObject {
    var delegate: CLLocationManagerDelegate? { get set }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var activityType: CLActivityType { get set }
    var distanceFilter: CLLocationDistance { get set }
    var allowsBackgroundLocationUpdates: Bool { get set }

    func requestAlwaysAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}

/// Make CLLocationManager conform to our protocol
extension CLLocationManager: LocationManagerProtocol {}
