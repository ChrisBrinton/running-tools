import Foundation
import CoreLocation
import Combine

/// Concrete implementation of `GPSManagerProtocol` that wraps `CLLocationManager`.
public final class GPSManager: NSObject, GPSManagerProtocol {
    private let locationManager: LocationManagerProtocol
    private let locationSubject = PassthroughSubject<CLLocation, Never>()
    private let errorSubject = PassthroughSubject<Error, Never>()

    private var lastLocation: CLLocation?
    public private(set) var totalDistance: Double = 0
    public private(set) var isTracking: Bool = false

    /// Callback invoked when a GPS location is filtered out (for debug sounds)
    public var onLocationFiltered: (() -> Void)?

    public var currentLocation: CLLocation? {
        lastLocation
    }

    public var locationPublisher: AnyPublisher<CLLocation, Never> {
        locationSubject.eraseToAnyPublisher()
    }

    public var errorPublisher: AnyPublisher<Error, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    public init(locationManager: LocationManagerProtocol = CLLocationManager()) {
        self.locationManager = locationManager
        super.init()
        configureLocationManager()
    }

    private func configureLocationManager() {
        locationManager.delegate = self
        locationManager.activityType = .fitness
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5
        locationManager.allowsBackgroundLocationUpdates = true
    }

    public func startTracking() {
        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()
        isTracking = true
    }

    public func stopTracking() {
        locationManager.stopUpdatingLocation()
        isTracking = false
    }

    public func resetDistance() {
        totalDistance = 0
        lastLocation = nil
    }
}

extension GPSManager: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            guard isValid(location: location) else {
                // Notify that a location was filtered (for debug sounds)
                onLocationFiltered?()
                continue
            }

            if let last = lastLocation {
                let delta = location.distance(from: last)
                if delta >= 0.5 {
                    totalDistance += delta
                }
            }

            lastLocation = location
            locationSubject.send(location)
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorSubject.send(error)
    }

    private func isValid(location: CLLocation) -> Bool {
        let age = abs(location.timestamp.timeIntervalSinceNow)
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 20,
              age <= 5 else {
            return false
        }
        return true
    }
}
