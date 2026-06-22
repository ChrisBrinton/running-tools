import Foundation
import CoreLocation
import Combine

/// Concrete implementation of `GPSManagerProtocol` that wraps `CLLocationManager`.
///
/// Distance accumulation is delegated to a `DistanceCalculator`. When verbose
/// GPS logging is enabled, all available calculators run in parallel and the
/// per-sample callback exposes each method's delta and total so the log can
/// compare them. The "active" calculator (selected by `AppSettings.distanceCalcMethod`)
/// drives the public `totalDistance` property.
public final class GPSManager: NSObject, GPSManagerProtocol {
    private let locationManager: LocationManagerProtocol
    private let locationSubject = PassthroughSubject<CLLocation, Never>()
    private let errorSubject = PassthroughSubject<Error, Never>()

    private var lastLocation: CLLocation?
    public private(set) var isTracking: Bool = false

    // MARK: - Distance Calculators

    /// The calculator that drives the public `totalDistance` value.
    private var activeCalculator: DistanceCalculator

    /// All calculators that run in parallel (active + shadow). When the active
    /// method is set, the active one is at index 0. Used for verbose logging.
    private var allCalculators: [DistanceCalculator]

    /// Whether to populate the shadow-method values in the per-sample callback.
    public var runShadowCalculators: Bool = false

    /// Public read-only accumulated distance from the active calculator.
    public var totalDistance: Double {
        activeCalculator.totalDistance
    }

    // MARK: - Callbacks

    /// Callback invoked when a GPS location is filtered out (for debug sounds)
    public var onLocationFiltered: (() -> Void)?

    /// Detailed per-sample callback for diagnostic logging.
    /// Fires for every CLLocation received (accepted or rejected) with full data.
    /// Used by WorkoutManager when verbose GPS logging is enabled.
    public var onLocationProcessed: ((LocationProcessedDetail) -> Void)?

    public var currentLocation: CLLocation? {
        lastLocation
    }

    public var locationPublisher: AnyPublisher<CLLocation, Never> {
        locationSubject.eraseToAnyPublisher()
    }

    public var errorPublisher: AnyPublisher<Error, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    public init(
        locationManager: LocationManagerProtocol = CLLocationManager(),
        activeMethod: DistanceCalcMethod = .chord
    ) {
        self.locationManager = locationManager
        self.allCalculators = DistanceCalculatorFactory.makeAll()
        // Promote the active one to index 0 for clarity in logs
        self.activeCalculator = self.allCalculators.first(where: { $0.method == activeMethod })
            ?? self.allCalculators[0]
        super.init()
        configureLocationManager()
    }

    /// Swap the active distance calculator at runtime (e.g., when settings change).
    /// Resets all calculators so they all start from zero on the same baseline.
    public func setActiveMethod(_ method: DistanceCalcMethod) {
        guard let next = allCalculators.first(where: { $0.method == method }) else { return }
        activeCalculator = next
    }

    private func configureLocationManager() {
        locationManager.delegate = self
        locationManager.activityType = .fitness
        // BestForNavigation pairs with CLLocationManager's tighter update
        // cadence (intended for in-vehicle / running navigation). Combined
        // with distanceFilter=None this gets us ~1 Hz fixes — matching
        // Apple Workout's sample density. The previous values
        // (Best + 5m filter) produced ~0.4 Hz and exaggerated chord
        // corner-cutting because each fix-to-fix gap spanned more curvature.
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone

        // Only enable background updates if the Info.plist declares the location
        // background mode. Otherwise CoreLocation throws an exception.
        if Self.hasLocationBackgroundMode() {
            locationManager.allowsBackgroundLocationUpdates = true
        } else {
            print("[GPSManager] Skipping allowsBackgroundLocationUpdates — UIBackgroundModes missing 'location'")
        }
    }

    private static func hasLocationBackgroundMode() -> Bool {
        guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] else {
            return false
        }
        return modes.contains("location")
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
        lastLocation = nil
        for calc in allCalculators {
            calc.reset()
        }
    }
}

extension GPSManager: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            let validity = validate(location: location)
            guard validity == .valid else {
                onLocationFiltered?()
                onLocationProcessed?(LocationProcessedDetail(
                    location: location,
                    accepted: false,
                    deltaMeters: 0,
                    cumulativeMeters: activeCalculator.totalDistance,
                    rejectionReason: validity.reason,
                    methodResults: nil
                ))
                continue
            }

            // Run the active calculator unconditionally
            let activeDelta = activeCalculator.addLocation(location)

            // Optionally run all the others as shadows for diagnostic logging.
            // Note: `addLocation` is idempotent in the sense that we already
            // called the active one above; we need to call the others too,
            // but skip the active calculator to avoid double-counting.
            var methodResults: [DistanceMethodResult]?
            if runShadowCalculators {
                var results: [DistanceMethodResult] = []
                for calc in allCalculators {
                    if calc === activeCalculator {
                        results.append(DistanceMethodResult(
                            method: calc.method,
                            delta: activeDelta,
                            total: calc.totalDistance,
                            isActive: true
                        ))
                    } else {
                        let d = calc.addLocation(location)
                        results.append(DistanceMethodResult(
                            method: calc.method,
                            delta: d,
                            total: calc.totalDistance,
                            isActive: false
                        ))
                    }
                }
                methodResults = results
            }

            lastLocation = location
            locationSubject.send(location)

            onLocationProcessed?(LocationProcessedDetail(
                location: location,
                accepted: true,
                deltaMeters: activeDelta,
                cumulativeMeters: activeCalculator.totalDistance,
                rejectionReason: nil,
                methodResults: methodResults
            ))
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorSubject.send(error)
    }

    private enum Validity {
        case valid
        case invalidAccuracy
        case staleTimestamp

        var reason: String? {
            switch self {
            case .valid: return nil
            case .invalidAccuracy: return "accuracy"
            case .staleTimestamp: return "stale"
            }
        }
    }

    private func validate(location: CLLocation) -> Validity {
        let age = abs(location.timestamp.timeIntervalSinceNow)
        if location.horizontalAccuracy < 0 || location.horizontalAccuracy > 20 {
            return .invalidAccuracy
        }
        if age > 5 {
            return .staleTimestamp
        }
        return .valid
    }
}

/// Per-sample result from one of the parallel distance calculators.
public struct DistanceMethodResult {
    public let method: DistanceCalcMethod
    public let delta: Double
    public let total: Double
    public let isActive: Bool
}

/// Detailed information about a single GPS sample for diagnostic logging.
public struct LocationProcessedDetail {
    public let location: CLLocation
    public let accepted: Bool
    /// Delta for the active calculator only.
    public let deltaMeters: Double
    /// Cumulative for the active calculator only.
    public let cumulativeMeters: Double
    public let rejectionReason: String?
    /// All methods' results when shadow calculators are enabled (verbose GPS).
    public let methodResults: [DistanceMethodResult]?
}
