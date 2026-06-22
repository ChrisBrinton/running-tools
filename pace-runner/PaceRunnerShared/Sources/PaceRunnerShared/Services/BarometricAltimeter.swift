import Foundation
#if os(iOS) || os(watchOS)
import CoreMotion
#endif

/// Wraps `CMAltimeter` to expose the latest barometric pressure (kPa) and
/// relative altitude (meters from the start of the session).
///
/// Used for diagnostic logging — barometric altitude is much more stable than
/// GPS altitude and gives a second opinion on elevation change.
public final class BarometricAltimeter {

    public static var isRelativeAltitudeAvailable: Bool {
        #if os(iOS) || os(watchOS)
        return CMAltimeter.isRelativeAltitudeAvailable()
        #else
        return false
        #endif
    }

    /// Most recent relative altitude in meters (from session start). nil if
    /// not started or not available.
    public private(set) var relativeAltitudeMeters: Double?

    /// Most recent barometric pressure in kPa.
    public private(set) var pressureKPa: Double?

    /// Whether updates are currently being received.
    public private(set) var isRunning: Bool = false

    #if os(iOS) || os(watchOS)
    private let altimeter = CMAltimeter()
    #endif

    public init() {}

    /// Starts relative altitude updates. Safe to call when not available — silently no-ops.
    public func start() {
        #if os(iOS) || os(watchOS)
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            print("[BarometricAltimeter] Relative altitude not available on this device")
            return
        }
        guard !isRunning else { return }
        isRunning = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            if let error = error {
                print("[BarometricAltimeter] Update error: \(error)")
                return
            }
            guard let data = data else { return }
            self?.relativeAltitudeMeters = data.relativeAltitude.doubleValue
            self?.pressureKPa = data.pressure.doubleValue
        }
        #else
        print("[BarometricAltimeter] CoreMotion unavailable on this platform")
        #endif
    }

    public func stop() {
        #if os(iOS) || os(watchOS)
        guard isRunning else { return }
        altimeter.stopRelativeAltitudeUpdates()
        isRunning = false
        #endif
    }
}
