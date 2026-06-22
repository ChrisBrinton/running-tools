import Foundation

/// Represents user preferences and app-wide settings
///
/// AppSettings stores user customizations that apply across all workouts:
/// - Audio preferences (voice alerts, tempo beats)
/// - Display preferences (units, metric visibility)
/// - Default values for new configurations
///
/// Persistence:
/// - Stored in UserDefaults with key "app_settings"
/// - Synced between iPhone and Watch via WatchConnectivity
/// - Changes take effect immediately (no restart required)
///
/// Examples:
/// - User disables voice alerts but keeps tempo beats
/// - User sets default cadence to 170 SPM for all new configs
/// - User enables metric system (kilometers instead of miles)
///
/// Constitution compliance:
/// - User Experience Consistency: Settings apply consistently across devices
/// - Workout Independence: Settings stored locally, no cloud dependency
public struct AppSettings: Codable, Equatable {

    // MARK: - Workout Mode

    /// Whether to run in companion mode (alongside native Workout app)
    /// - true: PaceRunner provides audio feedback only, no HealthKit workout session
    /// - false: PaceRunner manages its own HealthKit workout session (standalone)
    /// Default: true (companion mode)
    public var companionMode: Bool

    /// Whether to use HealthKit distance instead of GPS (standalone mode only)
    /// - true: Use distance from HKLiveWorkoutBuilder (matches Apple Workout app)
    /// - false: Use GPS-calculated distance with our own filtering
    /// Note: Only applies when companionMode=false (has no effect in companion mode)
    /// Default: true (use HealthKit for better accuracy)
    public var useHealthKitDistance: Bool

    // MARK: - Audio Settings

    /// Whether to play audio tempo beats during workouts
    /// Default: true
    public var audioBeatsEnabled: Bool

    /// Whether to play voice alerts (mile markers, pace deviations)
    /// Default: true
    public var voiceAlertsEnabled: Bool

    /// Minimum interval between voice alerts (seconds)
    /// Prevents alert spam when pace fluctuates
    /// Default: 30 seconds
    public var alertThrottleInterval: Int

    /// Whether to use adaptive metronome volume (louder when off pace)
    /// - true: Volume scales with deviation (silent on pace, louder when off)
    /// - false: Full volume whenever outside tolerance (simpler feedback)
    /// Default: false
    public var adaptiveMetronomeVolume: Bool

    /// Master volume for all audio output (voice alerts)
    /// Range: 0.0 (silent) to 1.0 (maximum)
    /// Default: 1.0 (full volume)
    public var masterVolume: Float

    /// Beat volume relative to master volume (gain/boost for metronome)
    /// Range: 0.0 (silent) to 30.0 (30x boost)
    /// Applied as a multiplier: effective volume = masterVolume * beatVolume
    /// Default: 10.0 (medium)
    public var beatVolume: Float

    /// Whether to announce mile marker completions with pace
    /// Default: true
    public var announceMileMarkers: Bool

    /// Debug override for Pro entitlement — syncs between iPhone and Watch
    /// Default: false
    public var debugProOverride: Bool

    /// Whether to play debug sounds for GPS filtering (woodblock clicks)
    /// Helps diagnose overly aggressive GPS filtering
    /// Default: false
    public var gpsFilterDebugSounds: Bool

    /// Whether to log detailed per-sample GPS data to the debug log.
    /// Captures lat/lng/accuracy/speed/course/delta for every sample.
    /// Useful for diagnosing systematic distance errors at specific locations.
    /// Default: false
    public var verboseGPSLogging: Bool

    /// Distance accumulation method used for the active workout total.
    /// Default: .chord (historical behavior).
    public var distanceCalcMethod: DistanceCalcMethod

    /// Whether to play emphasis beats (accented beat on interval)
    /// Can be used with or without regular metronome beats
    /// Default: false
    public var emphasisBeatEnabled: Bool

    /// Interval for emphasis beats (every Nth beat)
    /// Options: 2, 4, 8
    /// Default: 2 (every other beat, effectively half BPM)
    public var emphasisBeatInterval: Int

    // MARK: - Display Settings

    /// Whether to display metric units (km) instead of imperial (miles)
    /// Default: false (US market uses miles)
    public var useMetricUnits: Bool

    /// Whether to show detailed pace deviation on watch face
    /// Example: "+5s" vs just red/green indicator
    /// Default: true
    public var showPaceDeviation: Bool

    /// Whether to display current cadence on watch face
    /// Requires additional HealthKit query (minor battery impact)
    /// Default: false (not in MVP)
    public var showCadence: Bool

    // MARK: - Pace Averaging Windows

    /// Fast rolling average window in seconds
    /// Options: 60, 90, 120, 150 seconds
    /// Default: 120 seconds (2 minutes)
    public var fastAverageSeconds: Int

    /// Medium rolling average window in seconds
    /// Options: 180, 210, 240, 270, 300 seconds
    /// Default: 240 seconds (4 minutes)
    public var mediumAverageSeconds: Int

    /// Slow rolling average window in miles (distance-based)
    /// Options: 0.5, 1.0, 1.5, 2.0, 2.5, 3.0 miles
    /// Default: 1.0 mile
    public var slowAverageMiles: Double

    // MARK: - Stride & Cadence Calculation

    /// User's stride length in inches
    /// Used to calculate base BPM for a given target pace
    /// Formula: BPM = (pace in min/mile) / (stride in inches) * conversion
    /// Typical range: 24-36 inches
    /// Default: 30 inches
    public var strideLengthInches: Double

    // MARK: - Pace Calibration

    /// Pace calibration offset in seconds per mile
    /// Positive = PaceRunner reads faster than actual (subtract from GPS distance)
    /// Negative = PaceRunner reads slower than actual (add to GPS distance)
    /// Range: -15 to +15 seconds
    /// Default: 0 (no calibration)
    public var paceCalibrationSeconds: Int

    // MARK: - Default Values for New Configurations

    /// Default pace tolerance for new run configurations (seconds)
    /// Default: 10 seconds
    public var defaultTolerance: Int

    // MARK: - Quick-Create Presets

    /// Common distances shown in quick-create flow (in miles)
    /// Default: [3, 5, 10, 13.1, 26.2]
    public var commonDistances: [Double]

    /// Named pace presets for quick-create flow
    /// Default: Easy (10:00), Tempo (8:30), Fast (7:30)
    public var namedPaces: [NamedPace]

    // MARK: - Initialization

    /// Creates AppSettings with default values
    public init() {
        // Workout mode defaults
        self.companionMode = true // Default to companion mode (works alongside native Workout app)
        self.useHealthKitDistance = true // Use HealthKit distance for accuracy (standalone mode only)

        // Audio defaults
        self.audioBeatsEnabled = true
        self.voiceAlertsEnabled = true
        self.alertThrottleInterval = 30
        self.adaptiveMetronomeVolume = false
        self.masterVolume = 1.0
        self.beatVolume = 10.0  // Medium (scale: 3=low, 10=medium, 30=high)
        self.announceMileMarkers = true
        self.debugProOverride = false
        self.gpsFilterDebugSounds = false
        self.verboseGPSLogging = false
        self.distanceCalcMethod = .chord
        self.emphasisBeatEnabled = false
        self.emphasisBeatInterval = 2  // Every other beat

        // Display defaults
        self.useMetricUnits = false
        self.showPaceDeviation = true
        self.showCadence = false

        // Pace averaging defaults
        self.fastAverageSeconds = 120    // 2 minutes
        self.mediumAverageSeconds = 240  // 4 minutes
        self.slowAverageMiles = 1.0      // 1 mile

        // Stride and calibration defaults
        self.strideLengthInches = 30.0   // 30 inches typical stride
        self.paceCalibrationSeconds = 0  // No calibration

        // Configuration defaults
        self.defaultTolerance = 10

        // Quick-create presets
        self.commonDistances = Self.defaultCommonDistances
        self.namedPaces = Self.defaultNamedPaces
    }

    /// Creates AppSettings with custom values
    /// - Parameters:
    ///   - companionMode: Run alongside native Workout app (no HealthKit session)
    ///   - useHealthKitDistance: Use HealthKit distance in standalone mode (matches Workout app)
    ///   - audioBeatsEnabled: Enable tempo beats
    ///   - voiceAlertsEnabled: Enable voice alerts
    ///   - alertThrottleInterval: Minimum seconds between alerts (30/60/90/120)
    ///   - adaptiveMetronomeVolume: Use adaptive volume (scales with deviation)
    ///   - masterVolume: Master volume for all audio (0.0-1.0)
    ///   - beatVolume: Beat volume multiplier (0.0-30.0)
    ///   - announceMileMarkers: Announce mile completions with pace
    ///   - gpsFilterDebugSounds: Play debug sounds for GPS filtering
    ///   - emphasisBeatEnabled: Enable emphasis beats on interval
    ///   - emphasisBeatInterval: Play emphasis beat every Nth beat (2, 4, or 8)
    ///   - useMetricUnits: Use kilometers instead of miles
    ///   - showPaceDeviation: Show pace deviation on watch
    ///   - showCadence: Show cadence on watch (not MVP)
    ///   - fastAverageSeconds: Fast rolling average window (60-150s)
    ///   - mediumAverageSeconds: Medium rolling average window (180-300s)
    ///   - slowAverageMiles: Slow rolling average window (0.5-3.0 miles)
    ///   - strideLengthInches: User's stride length for BPM calculation (20-50 inches)
    ///   - paceCalibrationSeconds: Pace calibration offset (-15 to +15 seconds)
    ///   - defaultTolerance: Default tolerance for new configs
    ///   - commonDistances: Common distances for quick-create
    ///   - namedPaces: Named pace presets for quick-create
    public init(
        companionMode: Bool = true,
        useHealthKitDistance: Bool = true,
        audioBeatsEnabled: Bool = true,
        voiceAlertsEnabled: Bool = true,
        alertThrottleInterval: Int = 30,
        adaptiveMetronomeVolume: Bool = false,
        masterVolume: Float = 1.0,
        beatVolume: Float = 10.0,
        announceMileMarkers: Bool = true,
        debugProOverride: Bool = false,
        gpsFilterDebugSounds: Bool = false,
        verboseGPSLogging: Bool = false,
        distanceCalcMethod: DistanceCalcMethod = .chord,
        emphasisBeatEnabled: Bool = false,
        emphasisBeatInterval: Int = 2,
        useMetricUnits: Bool = false,
        showPaceDeviation: Bool = true,
        showCadence: Bool = false,
        fastAverageSeconds: Int = 120,
        mediumAverageSeconds: Int = 240,
        slowAverageMiles: Double = 1.0,
        strideLengthInches: Double = 30.0,
        paceCalibrationSeconds: Int = 0,
        defaultTolerance: Int = 10,
        commonDistances: [Double]? = nil,
        namedPaces: [NamedPace]? = nil
    ) {
        precondition(alertThrottleInterval > 0,
                     "Alert throttle interval must be positive")
        precondition(defaultTolerance > 0,
                     "Default tolerance must be positive")
        precondition(0.0...1.0 ~= masterVolume,
                     "Master volume must be between 0.0 and 1.0")

        self.companionMode = companionMode
        self.useHealthKitDistance = useHealthKitDistance
        self.audioBeatsEnabled = audioBeatsEnabled
        self.voiceAlertsEnabled = voiceAlertsEnabled
        self.alertThrottleInterval = alertThrottleInterval
        self.adaptiveMetronomeVolume = adaptiveMetronomeVolume
        self.masterVolume = masterVolume
        self.beatVolume = beatVolume
        self.announceMileMarkers = announceMileMarkers
        self.debugProOverride = debugProOverride
        self.gpsFilterDebugSounds = gpsFilterDebugSounds
        self.verboseGPSLogging = verboseGPSLogging
        self.distanceCalcMethod = distanceCalcMethod
        self.emphasisBeatEnabled = emphasisBeatEnabled
        self.emphasisBeatInterval = emphasisBeatInterval
        self.useMetricUnits = useMetricUnits
        self.showPaceDeviation = showPaceDeviation
        self.showCadence = showCadence
        self.fastAverageSeconds = fastAverageSeconds
        self.mediumAverageSeconds = mediumAverageSeconds
        self.slowAverageMiles = slowAverageMiles
        self.strideLengthInches = strideLengthInches
        self.paceCalibrationSeconds = paceCalibrationSeconds
        self.defaultTolerance = defaultTolerance
        self.commonDistances = commonDistances ?? Self.defaultCommonDistances
        self.namedPaces = namedPaces ?? Self.defaultNamedPaces
    }

    // MARK: - UserDefaults Integration

    /// UserDefaults key for storing settings
    public static let storageKey = "app_settings"

    /// Loads settings from UserDefaults
    /// - Returns: Stored settings, or default settings if none exist
    public static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings() // Return defaults
        }
        return settings
    }

    /// Saves settings to UserDefaults
    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Required properties
        self.companionMode = try container.decode(Bool.self, forKey: .companionMode)
        self.useHealthKitDistance = try container.decodeIfPresent(Bool.self, forKey: .useHealthKitDistance) ?? true
        self.audioBeatsEnabled = try container.decode(Bool.self, forKey: .audioBeatsEnabled)
        self.voiceAlertsEnabled = try container.decode(Bool.self, forKey: .voiceAlertsEnabled)
        self.alertThrottleInterval = try container.decode(Int.self, forKey: .alertThrottleInterval)
        self.adaptiveMetronomeVolume = try container.decode(Bool.self, forKey: .adaptiveMetronomeVolume)
        self.useMetricUnits = try container.decode(Bool.self, forKey: .useMetricUnits)
        self.showPaceDeviation = try container.decode(Bool.self, forKey: .showPaceDeviation)
        self.showCadence = try container.decode(Bool.self, forKey: .showCadence)
        self.defaultTolerance = try container.decode(Int.self, forKey: .defaultTolerance)

        // New properties with defaults for backward compatibility
        self.masterVolume = try container.decodeIfPresent(Float.self, forKey: .masterVolume) ?? 1.0
        self.beatVolume = try container.decodeIfPresent(Float.self, forKey: .beatVolume) ?? 10.0
        self.announceMileMarkers = try container.decodeIfPresent(Bool.self, forKey: .announceMileMarkers) ?? true
        self.debugProOverride = try container.decodeIfPresent(Bool.self, forKey: .debugProOverride) ?? false
        self.gpsFilterDebugSounds = try container.decodeIfPresent(Bool.self, forKey: .gpsFilterDebugSounds) ?? false
        self.verboseGPSLogging = try container.decodeIfPresent(Bool.self, forKey: .verboseGPSLogging) ?? false
        if let raw = try container.decodeIfPresent(String.self, forKey: .distanceCalcMethod),
           let method = DistanceCalcMethod(rawValue: raw) {
            self.distanceCalcMethod = method
        } else {
            self.distanceCalcMethod = .chord
        }

        // Emphasis beat settings with defaults
        self.emphasisBeatEnabled = try container.decodeIfPresent(Bool.self, forKey: .emphasisBeatEnabled) ?? false
        self.emphasisBeatInterval = try container.decodeIfPresent(Int.self, forKey: .emphasisBeatInterval) ?? 2

        // Pace averaging windows with defaults
        self.fastAverageSeconds = try container.decodeIfPresent(Int.self, forKey: .fastAverageSeconds) ?? 120
        self.mediumAverageSeconds = try container.decodeIfPresent(Int.self, forKey: .mediumAverageSeconds) ?? 240
        self.slowAverageMiles = try container.decodeIfPresent(Double.self, forKey: .slowAverageMiles) ?? 1.0

        // Stride and calibration with defaults
        self.strideLengthInches = try container.decodeIfPresent(Double.self, forKey: .strideLengthInches) ?? 30.0
        self.paceCalibrationSeconds = try container.decodeIfPresent(Int.self, forKey: .paceCalibrationSeconds) ?? 0

        // Quick-create presets with defaults
        self.commonDistances = try container.decodeIfPresent([Double].self, forKey: .commonDistances) ?? Self.defaultCommonDistances
        self.namedPaces = try container.decodeIfPresent([NamedPace].self, forKey: .namedPaces) ?? Self.defaultNamedPaces
    }

    // MARK: - Computed Properties

    /// Calculates base BPM for a given target pace based on stride length
    /// Formula: steps per mile = 63360 inches / stride length in inches
    /// BPM = (steps per mile) / (pace in minutes)
    /// - Parameter pace: Target pace
    /// - Returns: Calculated BPM for the given pace
    public func calculateBaseBPM(for pace: Pace) -> Int {
        let inchesPerMile: Double = 63360.0
        let stepsPerMile = inchesPerMile / strideLengthInches
        let paceMinutes = Double(pace.totalSeconds) / 60.0
        let bpm = stepsPerMile / paceMinutes
        return Int(round(bpm))
    }

    // MARK: - Quick-Create Defaults

    /// Default common distances for quick-create (in miles)
    public static let defaultCommonDistances: [Double] = [3, 5, 10, 13.1, 26.2]

    /// Default named paces for quick-create (ordered fastest to slowest)
    public static let defaultNamedPaces: [NamedPace] = [
        NamedPace(name: "Tempo", pace: Pace(minutes: 7, seconds: 30)),
        NamedPace(name: "Easy", pace: Pace(minutes: 10, seconds: 0)),
        NamedPace(name: "Recovery", pace: Pace(minutes: 12, seconds: 0))
    ]

    /// Derives a configuration name from distance and pace name
    /// - Parameters:
    ///   - distanceMiles: Distance in miles
    ///   - paceName: Name of the pace preset (e.g. "Easy")
    /// - Returns: Derived name like "5mi Easy" or "13.1mi Tempo"
    public static func derivedConfigName(distanceMiles: Double, paceName: String) -> String {
        let distanceLabel: String
        if distanceMiles == distanceMiles.rounded() {
            distanceLabel = String(format: "%.0f", distanceMiles)
        } else {
            distanceLabel = String(format: "%.1f", distanceMiles)
        }
        return "\(distanceLabel)mi \(paceName)"
    }

    /// Derives a configuration name from multi-segment definition
    /// - Parameter segments: Array of run segments
    /// - Returns: Name like "2mi Easy + 5mi Tempo"
    public static func derivedSegmentConfigName(segments: [RunSegment]) -> String {
        segments.map { segment in
            let distLabel: String
            if segment.distance.miles == segment.distance.miles.rounded() {
                distLabel = String(format: "%.0f", segment.distance.miles)
            } else {
                distLabel = String(format: "%.1f", segment.distance.miles)
            }
            return "\(distLabel)mi \(segment.label)"
        }.joined(separator: " + ")
    }

    /// Calculates base BPM with an optional stride override
    public func calculateBaseBPM(for pace: Pace, strideLengthOverride: Double?) -> Int {
        let stride = strideLengthOverride ?? strideLengthInches
        let inchesPerMile: Double = 63360.0
        let stepsPerMile = inchesPerMile / stride
        let paceMinutes = Double(pace.totalSeconds) / 60.0
        let bpm = stepsPerMile / paceMinutes
        return Int(round(bpm))
    }

    /// Calculates the distance calibration factor
    /// Returns a multiplier to apply to GPS distances
    /// - Returns: Calibration multiplier (e.g., 0.98 means GPS reads 2% fast)
    public func distanceCalibrationFactor() -> Double {
        guard paceCalibrationSeconds != 0 else { return 1.0 }

        // If calibration is +10s, it means our pace reads 10s/mile too fast
        // To fix: we need to reduce the distance we count (multiply by < 1.0)
        // At 8:00/mile pace (480s), +10s calibration means we're at 470s actual
        // Factor = actual/reported = 470/480 = 0.979
        // General formula: if reported pace is P and offset is C,
        // then actual pace = P - C, and factor = (P - C) / P = 1 - C/P
        // But we don't know P at calibration time, so use a reference pace of 8:00
        let referencePaceSeconds: Double = 480.0 // 8:00/mile as reference
        let factor = (referencePaceSeconds - Double(paceCalibrationSeconds)) / referencePaceSeconds
        return factor
    }
}
