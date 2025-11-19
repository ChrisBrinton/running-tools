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

    // MARK: - Default Values for New Configurations

    /// Default cadence for new run configurations (SPM)
    /// Default: 180 SPM (standard marathon cadence)
    public var defaultCadence: Int

    /// Default pace tolerance for new run configurations (seconds)
    /// Default: 10 seconds
    public var defaultTolerance: Int

    // MARK: - Initialization

    /// Creates AppSettings with default values
    public init() {
        // Audio defaults
        self.audioBeatsEnabled = true
        self.voiceAlertsEnabled = true
        self.alertThrottleInterval = 30

        // Display defaults
        self.useMetricUnits = false
        self.showPaceDeviation = true
        self.showCadence = false

        // Configuration defaults
        self.defaultCadence = 180
        self.defaultTolerance = 10
    }

    /// Creates AppSettings with custom values
    /// - Parameters:
    ///   - audioBeatsEnabled: Enable tempo beats
    ///   - voiceAlertsEnabled: Enable voice alerts
    ///   - alertThrottleInterval: Minimum seconds between alerts
    ///   - useMetricUnits: Use kilometers instead of miles
    ///   - showPaceDeviation: Show pace deviation on watch
    ///   - showCadence: Show cadence on watch (not MVP)
    ///   - defaultCadence: Default SPM for new configs
    ///   - defaultTolerance: Default tolerance for new configs
    public init(
        audioBeatsEnabled: Bool = true,
        voiceAlertsEnabled: Bool = true,
        alertThrottleInterval: Int = 30,
        useMetricUnits: Bool = false,
        showPaceDeviation: Bool = true,
        showCadence: Bool = false,
        defaultCadence: Int = 180,
        defaultTolerance: Int = 10
    ) {
        precondition(alertThrottleInterval > 0,
                     "Alert throttle interval must be positive")
        precondition(150...200 ~= defaultCadence,
                     "Default cadence must be 150-200 SPM")
        precondition(defaultTolerance > 0,
                     "Default tolerance must be positive")

        self.audioBeatsEnabled = audioBeatsEnabled
        self.voiceAlertsEnabled = voiceAlertsEnabled
        self.alertThrottleInterval = alertThrottleInterval
        self.useMetricUnits = useMetricUnits
        self.showPaceDeviation = showPaceDeviation
        self.showCadence = showCadence
        self.defaultCadence = defaultCadence
        self.defaultTolerance = defaultTolerance
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
}
