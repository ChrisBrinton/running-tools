import Foundation
import CoreLocation

/// Lightweight representation of a GPS observation used by pace/gps services.
struct GPSSample {
    /// Raw CoreLocation reading (optional when created from aggregated distance).
    let location: CLLocation?

    /// Timestamp associated with the reading.
    let timestamp: Date

    /// Instantaneous speed in meters/second.
    let speed: Double

    /// Cumulative distance covered at this sample (in meters)
    let cumulativeDistance: Double

    /// Seconds required to travel one meter.
    var secondsPerMeter: Double {
        guard speed > 0 else { return .infinity }
        return 1.0 / speed
    }

    /// Whether the sample should be considered valid for pace calculation.
    var isValid: Bool {
        speed.isFinite && speed > 0 && speed < 15.0
    }

    init(location: CLLocation, cumulativeDistance: Double) {
        self.location = location
        self.timestamp = location.timestamp
        self.cumulativeDistance = cumulativeDistance
        if location.speed.isFinite, location.speed >= 0 {
            self.speed = location.speed
        } else {
            self.speed = 0
        }
    }

    init(timestamp: Date, speed: Double, cumulativeDistance: Double) {
        self.location = nil
        self.timestamp = timestamp
        self.speed = speed
        self.cumulativeDistance = cumulativeDistance
    }
}
