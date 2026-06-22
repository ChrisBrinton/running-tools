import Foundation

/// Represents a completed workout with all performance metrics
///
/// WorkoutSummary is created at workout completion and contains:
/// - Configuration metadata (which run plan was used)
/// - Time bounds (start and end timestamps)
/// - Aggregate metrics (total distance, average pace)
/// - Mile-by-mile splits for detailed analysis
///
/// Summaries are:
/// - Saved to HealthKit (as HKWorkout with associated samples)
/// - Displayed in iPhone history view
/// - Synced to cloud analytics service (future, via workout-sync-service)
///
/// Examples:
/// - Marathon completed in 3:29:24 at 7:58/mile average
/// - Long run: 20 miles in 2:40:00 with progressive pacing
/// - Tempo run: 6 miles at 6:45/mile (target was 7:00/mile)
///
/// Constitution compliance:
/// - Workout Independence: Created and stored locally, no cloud dependency
/// - User Experience Consistency: Standardized summary format across views
public struct WorkoutSummary: Codable, Identifiable {

    // MARK: - Properties

    /// Unique identifier for this workout
    public let id: UUID

    /// Name of the RunConfiguration used for this workout
    /// Stored as string (not reference) since config may be deleted/modified later
    public let configurationName: String

    /// Timestamp when workout started
    public let startTime: Date

    /// Timestamp when workout ended
    public let endTime: Date

    /// Total distance covered during workout
    /// May differ from configured distance if workout stopped early
    public let totalDistance: Distance

    /// Average pace across entire workout
    /// Calculated as total time / total distance
    public let averagePace: Pace

    /// Per-mile split data
    /// Array length = number of mile markers reached
    /// Example: Marathon has 27 splits (26 full miles + 0.2 final)
    public let mileSplits: [MileSplit]

    /// Debug log capturing timing, sync, and calibration events
    /// Used for troubleshooting timing discrepancies between PaceRunner and Workout app
    public let debugLog: DebugLog?

    /// Full RunConfiguration snapshot at time of workout (nil for legacy summaries)
    public let configuration: RunConfiguration?

    /// AppSettings snapshot at time of workout (nil for legacy summaries)
    public let settings: AppSettings?

    // MARK: - Initialization

    /// Creates a new WorkoutSummary
    /// - Parameters:
    ///   - id: Unique identifier (generates new UUID if not provided)
    ///   - configurationName: Name of configuration used
    ///   - startTime: Workout start timestamp
    ///   - endTime: Workout end timestamp
    ///   - totalDistance: Total distance covered
    ///   - averagePace: Average pace for workout
    ///   - mileSplits: Per-mile performance data
    ///   - debugLog: Optional debug log for troubleshooting
    ///   - configuration: Full RunConfiguration snapshot (optional)
    ///   - settings: AppSettings snapshot (optional)
    /// - Precondition: End time must be after start time
    /// - Precondition: Configuration name must not be empty
    public init(
        id: UUID = UUID(),
        configurationName: String,
        startTime: Date,
        endTime: Date,
        totalDistance: Distance,
        averagePace: Pace,
        mileSplits: [MileSplit],
        debugLog: DebugLog? = nil,
        configuration: RunConfiguration? = nil,
        settings: AppSettings? = nil
    ) {
        precondition(!configurationName.isEmpty,
                     "Configuration name must not be empty")
        precondition(endTime > startTime,
                     "End time must be after start time")

        self.id = id
        self.configurationName = configurationName
        self.startTime = startTime
        self.endTime = endTime
        self.totalDistance = totalDistance
        self.averagePace = averagePace
        self.mileSplits = mileSplits
        self.debugLog = debugLog
        self.configuration = configuration
        self.settings = settings
    }

    /// Returns a copy with `debugLog` removed. Use this before persisting to
    /// UserDefaults or syncing via WatchConnectivity — debug logs from verbose
    /// GPS workouts can exceed 1MB and have caused OOM/sync-fail on watchOS.
    /// The debug log is persisted/synced separately (UserDefaults "lastDebugLog"
    /// and the `syncDebugLog` message type).
    public func withoutDebugLog() -> WorkoutSummary {
        WorkoutSummary(
            id: id,
            configurationName: configurationName,
            startTime: startTime,
            endTime: endTime,
            totalDistance: totalDistance,
            averagePace: averagePace,
            mileSplits: mileSplits,
            debugLog: nil,
            configuration: configuration,
            settings: settings
        )
    }

    // MARK: - Computed Properties

    /// Total workout duration in seconds
    /// - Returns: Time interval from start to end
    public var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    /// Formatted duration string
    /// - Returns: "H:MM:SS" for workouts over 1 hour, "MM:SS" otherwise
    public var formattedDuration: String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    /// Formatted start date string
    /// - Returns: Human-readable date (e.g., "Jan 15, 2025")
    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: startTime)
    }

    /// Formatted start time string
    /// - Returns: Time of day (e.g., "8:30 AM")
    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: startTime)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, configurationName, startTime, endTime, totalDistance
        case averagePace, mileSplits, debugLog, configuration, settings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.configurationName = try container.decode(String.self, forKey: .configurationName)
        self.startTime = try container.decode(Date.self, forKey: .startTime)
        self.endTime = try container.decode(Date.self, forKey: .endTime)
        self.totalDistance = try container.decode(Distance.self, forKey: .totalDistance)
        self.averagePace = try container.decode(Pace.self, forKey: .averagePace)
        self.mileSplits = try container.decode([MileSplit].self, forKey: .mileSplits)
        self.debugLog = try container.decodeIfPresent(DebugLog.self, forKey: .debugLog)
        self.configuration = try container.decodeIfPresent(RunConfiguration.self, forKey: .configuration)
        self.settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings)
    }

    // MARK: - Export

    /// Export workout summary as comprehensive text including configuration, settings, and debug log
    public func exportAsText() -> String {
        var lines: [String] = []

        lines.append("=== PaceRunner Run Export ===")
        lines.append("Config: \(configurationName)")

        if let config = configuration {
            lines.append("Distance: \(config.distance.formatted)")

            // Format target paces
            let uniquePaces = Set(config.milePaces.map { $0.formatted })
            if uniquePaces.count == 1, let pace = uniquePaces.first {
                lines.append("Target Paces: \(pace)/mi (uniform)")
            } else {
                let paceStrs = config.milePaces.enumerated().map { "  Mile \($0.offset + 1): \($0.element.formatted)/mi" }
                lines.append("Target Paces:")
                lines.append(contentsOf: paceStrs)
            }

            lines.append("Cadence Offset: \(config.cadenceOffset)")
            lines.append("Pace Tolerance: \(config.paceTolerance)s")
            lines.append("Auto-End: \(config.autoEndRun)")
        }

        lines.append("")
        lines.append("Date: \(formattedDate) \(formattedTime)")
        lines.append("Distance: \(totalDistance.formatted)")
        lines.append("Duration: \(formattedDuration)")
        lines.append("Avg Pace: \(averagePace.formatted)/mi")

        if !mileSplits.isEmpty {
            lines.append("")
            lines.append("=== Splits ===")
            for split in mileSplits {
                let devSign = split.paceDeviation >= 0 ? "+" : ""
                var line = "Mile \(split.mileNumber): \(split.actualPace.formatted) (target \(split.targetPace.formatted), \(devSign)\(split.paceDeviation)s)"
                if let hr = split.averageHeartRate {
                    line += " HR: \(hr)"
                }
                lines.append(line)
            }
        }

        if let settings = settings {
            lines.append("")
            lines.append("=== Settings Snapshot ===")
            lines.append("Companion Mode: \(settings.companionMode)")
            lines.append("HealthKit Distance: \(settings.useHealthKitDistance)")

            let calSign = settings.paceCalibrationSeconds >= 0 ? "+" : ""
            let calFactor = String(format: "%.4f", settings.distanceCalibrationFactor())
            lines.append("Pace Calibration: \(calSign)\(settings.paceCalibrationSeconds)s (factor: \(calFactor))")
            lines.append("Stride Length: \(String(format: "%.1f", settings.strideLengthInches))\"")

            lines.append("Fast Avg: \(settings.fastAverageSeconds)s | Med Avg: \(settings.mediumAverageSeconds)s | Slow Avg: \(String(format: "%.1f", settings.slowAverageMiles))mi")

            let beatsStr = settings.audioBeatsEnabled ? "on" : "off"
            let voiceStr = settings.voiceAlertsEnabled ? "on" : "off"
            let volPct = Int(settings.masterVolume * 100)
            let beatVol = String(format: "%.1f", settings.beatVolume)
            lines.append("Audio: beats=\(beatsStr), voice=\(voiceStr), volume=\(volPct)%, beat=\(beatVol)x")

            let emphStr = settings.emphasisBeatEnabled ? "every \(settings.emphasisBeatInterval)" : "off"
            lines.append("Emphasis: \(emphStr)")
        }

        if let debugLog = debugLog {
            lines.append("")
            lines.append(debugLog.exportAsText())
        }

        return lines.joined(separator: "\n")
    }
}
