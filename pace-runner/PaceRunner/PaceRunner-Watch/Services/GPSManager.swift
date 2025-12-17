import Foundation
import CoreLocation
import Combine

/// GPS tracking service for workout distance and location
///
/// Responsibilities:
/// - Configure CLLocationManager for optimal battery/accuracy
/// - Filter GPS samples for quality (accuracy, age, spike detection)
/// - Calculate accumulated distance
/// - Publish valid locations for pace calculation
///
/// Constitution compliance:
/// - <200ms latency: Direct property updates, no async transforms
/// - Battery efficiency: 5m distance filter, accuracy-based filtering
/// - Outlier rejection: Prevents GPS spikes from corrupting distance
///
/// Reference: specs/001-pace-runner-mvp/contracts/corelocation.md
class GPSManager: NSObject, GPSManagerProtocol {

    // MARK: - Published Properties

    private let locationSubject = PassthroughSubject<CLLocation, Never>()
    var locationPublisher: AnyPublisher<CLLocation, Never> {
        locationSubject.eraseToAnyPublisher()
    }

    private let errorSubject = PassthroughSubject<Error, Never>()
    var errorPublisher: AnyPublisher<Error, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    // MARK: - Public Properties

    private(set) var totalDistance: Double = 0.0
    private(set) var currentLocation: CLLocation?
    private(set) var isTracking: Bool = false

    // MARK: - Private Properties

    private let locationManager: LocationManagerProtocol
    private var lastValidLocation: CLLocation?

    // Quality thresholds
    private let maxHorizontalAccuracy: CLLocationAccuracy = 50.0 // meters
    private let maxLocationAge: TimeInterval = 10.0 // seconds
    private let maxRealisticSpeed: CLLocationSpeed = 15.0 // m/s (~3:30/mile pace)

    // Debug callback for filtered points
    var onLocationFiltered: (() -> Void)?

    // MARK: - Initialization

    init(locationManager: LocationManagerProtocol = CLLocationManager()) {
        self.locationManager = locationManager
        super.init()
        configureLocationManager()
    }

    // MARK: - Configuration

    private func configureLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .fitness
        locationManager.distanceFilter = 5.0 // meters
        locationManager.allowsBackgroundLocationUpdates = true
    }

    // MARK: - Public Methods

    func startTracking() {
        guard !isTracking else { return }

        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()
        isTracking = true
    }

    func stopTracking() {
        guard isTracking else { return }

        locationManager.stopUpdatingLocation()
        isTracking = false
    }

    func resetDistance() {
        totalDistance = 0.0
        lastValidLocation = nil
        currentLocation = nil
    }

    // MARK: - Location Processing

    private func processLocation(_ location: CLLocation) {
        // Quality filtering per contract requirements
        guard isValidLocation(location) else {
            onLocationFiltered?() // Notify that a point was filtered
            return
        }

        // Update current location
        currentLocation = location

        // Calculate distance if we have a previous location
        if let previous = lastValidLocation {
            // Spike detection: Check if implied speed is realistic
            let distance = location.distance(from: previous)
            let timeInterval = location.timestamp.timeIntervalSince(previous.timestamp)

            guard timeInterval > 0 else { return }

            let impliedSpeed = distance / timeInterval

            // Reject unrealistic speeds (GPS spikes)
            guard impliedSpeed <= maxRealisticSpeed else {
                // Log spike but don't update distance
                onLocationFiltered?() // Notify that a point was filtered (spike)
                return
            }

            // Accumulate distance
            totalDistance += distance
        }

        // Store as last valid location
        lastValidLocation = location

        // Publish to subscribers (for pace calculation)
        locationSubject.send(location)
    }

    private func isValidLocation(_ location: CLLocation) -> Bool {
        // Reject invalid accuracy
        guard location.horizontalAccuracy >= 0 else {
            return false
        }

        // Reject poor accuracy (>50m per contract)
        guard location.horizontalAccuracy < maxHorizontalAccuracy else {
            return false
        }

        // Reject stale locations
        let locationAge = Date().timeIntervalSince(location.timestamp)
        guard locationAge < maxLocationAge else {
            return false
        }

        // Reject invalid coordinates
        guard CLLocationCoordinate2DIsValid(location.coordinate) else {
            return false
        }

        return true
    }
}

// MARK: - CLLocationManagerDelegate

extension GPSManager: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Process each location (usually get 1 at a time)
        locations.forEach { processLocation($0) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Publish error for UI handling
        errorSubject.send(error)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Handle authorization changes
        let status = manager.authorizationStatus

        switch status {
        case .notDetermined:
            // Initial state, will request when startTracking() called
            break

        case .denied, .restricted:
            // Permission denied - publish error
            let error = NSError(
                domain: "GPSManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Location permission denied"]
            )
            errorSubject.send(error)

        case .authorizedAlways, .authorizedWhenInUse:
            // Permission granted - ready to track
            break

        @unknown default:
            break
        }
    }
}
