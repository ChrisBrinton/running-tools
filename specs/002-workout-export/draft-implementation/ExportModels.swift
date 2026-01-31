import Foundation

// MARK: - Top-Level Export Model

/// Complete workout export structure matching the spec JSON schema (v1.0)
///
/// This is the root object serialized to JSON for each exported workout.
/// Optional sections are nil when data is unavailable (e.g., no HR, indoor workout).
///
/// Output path: iCloud Drive/Workouts/run-YYYY-MM-DD-HHMMSS.json
public struct WorkoutExport: Codable {
    /// Schema version for forward compatibility
    public let version: String

    /// When this export was generated (ISO 8601)
    public let exportedAt: Date

    /// Core workout summary (always present)
    public let workout: WorkoutSummaryExport

    /// Heart rate data with zones (nil if no HR sensor data)
    public let heartRate: HeartRateData?

    /// Per-mile splits (empty array if no route data)
    public let splits: [SplitData]

    /// GPS route with elevation (nil if indoor/treadmill)
    public let route: RouteData?

    /// Additional metrics — cadence, VO2 Max (nil if unavailable)
    public let extras: ExtraMetrics?

    public init(
        workout: WorkoutSummaryExport,
        heartRate: HeartRateData? = nil,
        splits: [SplitData] = [],
        route: RouteData? = nil,
        extras: ExtraMetrics? = nil
    ) {
        self.version = "1.0"
        self.exportedAt = Date()
        self.workout = workout
        self.heartRate = heartRate
        self.splits = splits
        self.route = route
        self.extras = extras
    }
}

// MARK: - Workout Summary

/// Core workout metadata — always populated for every export
public struct WorkoutSummaryExport: Codable {
    /// HealthKit workout UUID
    public let uuid: String

    /// "outdoor_run" or "indoor_run"
    public let type: String

    /// Workout start (ISO 8601)
    public let startDate: Date

    /// Workout end (ISO 8601)
    public let endDate: Date

    /// Total duration in seconds
    public let duration: Int

    /// Total distance in miles
    public let distance: Double

    /// Always "mi" (US-focused app)
    public let distanceUnit: String

    /// Active energy burned in kcal
    public let calories: Int

    /// Formatted average pace (e.g., "7:52")
    public let avgPace: String

    /// Average pace in total seconds per mile
    public let avgPaceSeconds: Int

    /// Source app name (e.g., "Apple Watch Workout", "PaceRunner")
    public let source: String?

    public init(
        uuid: String,
        type: String,
        startDate: Date,
        endDate: Date,
        duration: Int,
        distance: Double,
        calories: Int,
        avgPaceSeconds: Int,
        source: String? = nil
    ) {
        self.uuid = uuid
        self.type = type
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.distance = distance
        self.distanceUnit = "mi"
        self.calories = calories
        self.avgPaceSeconds = avgPaceSeconds
        self.avgPace = Self.formatPace(seconds: avgPaceSeconds)
        self.source = source
    }

    /// Formats seconds-per-mile as "M:SS"
    static func formatPace(seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Heart Rate

/// Heart rate data for a workout, including zones and raw samples
public struct HeartRateData: Codable {
    /// Average BPM across workout
    public let avg: Int

    /// Maximum BPM
    public let max: Int

    /// Minimum BPM
    public let min: Int

    /// Time spent in each HR zone
    public let zones: [HeartRateZone]

    /// Raw HR samples for charting (timestamped BPM values)
    public let samples: [HRSample]

    public init(avg: Int, max: Int, min: Int, zones: [HeartRateZone], samples: [HRSample]) {
        self.avg = avg
        self.max = max
        self.min = min
        self.zones = zones
        self.samples = samples
    }
}

/// Time spent in a heart rate zone
public struct HeartRateZone: Codable {
    /// Zone number (1-5)
    public let zone: Int

    /// Human-readable label ("Recovery", "Easy", "Tempo", "Threshold", "Max")
    public let label: String

    /// Minutes spent in this zone
    public let minutes: Int

    public init(zone: Int, label: String, minutes: Int) {
        self.zone = zone
        self.label = label
        self.minutes = minutes
    }

    /// Standard zone labels
    public static let labels: [Int: String] = [
        1: "Recovery",
        2: "Easy",
        3: "Tempo",
        4: "Threshold",
        5: "Max"
    ]
}

/// A single heart rate sample
public struct HRSample: Codable {
    /// Timestamp (ISO 8601)
    public let t: Date

    /// Beats per minute
    public let bpm: Int

    public init(t: Date, bpm: Int) {
        self.t = t
        self.bpm = bpm
    }
}

// MARK: - Splits

/// Performance data for a single mile split
public struct SplitData: Codable {
    /// Mile number (1-based)
    public let mile: Int

    /// Formatted pace (e.g., "7:45")
    public let pace: String

    /// Pace in seconds per mile
    public let paceSeconds: Int

    /// Average heart rate during this mile (nil if no HR data)
    public let avgHR: Int?

    /// Cumulative elapsed time at end of this mile (e.g., "15:35")
    public let elapsed: String

    public init(mile: Int, paceSeconds: Int, avgHR: Int?, elapsedSeconds: Int) {
        self.mile = mile
        self.paceSeconds = paceSeconds
        self.pace = WorkoutSummaryExport.formatPace(seconds: paceSeconds)
        self.avgHR = avgHR
        self.elapsed = Self.formatElapsed(seconds: elapsedSeconds)
    }

    /// Formats total elapsed seconds as "M:SS" or "H:MM:SS"
    static func formatElapsed(seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Route

/// GPS route data with elevation
public struct RouteData: Codable {
    /// Total elevation gain in feet
    public let elevationGain: Int

    /// Total elevation loss in feet
    public let elevationLoss: Int

    /// Always "ft"
    public let elevationUnit: String

    /// Downsampled GPS points (every 5-10 seconds)
    public let points: [RoutePoint]

    public init(elevationGain: Int, elevationLoss: Int, points: [RoutePoint]) {
        self.elevationGain = elevationGain
        self.elevationLoss = elevationLoss
        self.elevationUnit = "ft"
        self.points = points
    }
}

/// A single GPS route point
public struct RoutePoint: Codable {
    public let lat: Double
    public let lon: Double
    public let alt: Double
    public let t: Date

    public init(lat: Double, lon: Double, alt: Double, t: Date) {
        self.lat = lat
        self.lon = lon
        self.alt = alt
        self.t = t
    }
}

// MARK: - Extra Metrics

/// Additional workout metrics (when available from Apple Watch sensors)
public struct ExtraMetrics: Codable {
    /// Average running cadence in steps per minute (nil if unavailable)
    public let avgCadence: Int?

    /// Most recent VO2 Max in mL/kg/min (nil if unavailable)
    public let vo2Max: Double?

    public init(avgCadence: Int? = nil, vo2Max: Double? = nil) {
        self.avgCadence = avgCadence
        self.vo2Max = vo2Max
    }
}

// MARK: - Export Settings

/// User-configurable export preferences (stored in AppSettings)
public enum ExportFormat: String, Codable {
    case json = "json"
    case both = "both"  // JSON + plain text
}
