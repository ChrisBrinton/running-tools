import Foundation

/// Represents a configured running workout with target paces and settings
///
/// A RunConfiguration defines all parameters needed for a training run:
/// - Total distance to cover
/// - Target pace for each mile (can vary for progressive runs)
/// - Base cadence for audio tempo beats
/// - Pace tolerance for deviation alerts
///
/// Examples:
/// - Even-paced marathon: 26.2 miles at 8:00/mile throughout
/// - Progressive long run: First 15 miles at 9:00/mile, last 5 at 8:30/mile
/// - Tempo run: 6 miles at 7:00/mile with tight 5-second tolerance
///
/// Constitution compliance:
/// - User Experience Consistency: Configurations created on iPhone, synced to Watch
/// - Workout Independence: Stored locally in UserDefaults, no cloud dependency
public struct RunConfiguration: Codable, Identifiable, Equatable {

    // MARK: - Properties

    /// Unique identifier for this configuration
    public let id: UUID

    /// User-friendly name (e.g., "Marathon - Even Pace", "Long Run - Progressive")
    public var name: String

    /// Total distance for this run
    public var distance: Distance

    /// Target pace for each mile
    /// Array length = ceil(distance.miles)
    /// Example: 26.2 miles → 27 paces (26 full miles + partial final mile)
    public var milePaces: [Pace]

    /// Cadence offset from calculated base BPM
    /// Range: -15 to +15 BPM
    /// Default: 0 (use calculated BPM from stride length and pace)
    /// The effective BPM = calculateBaseBPM(for: targetPace) + cadenceOffset
    public var cadenceOffset: Int

    /// Pace tolerance in seconds for deviation alerts
    /// Example: 10 means alert when current pace deviates ±10 seconds from target
    /// Default: 10 seconds
    public var paceTolerance: Int

    /// Minimum metronome volume (0.0-1.0)
    /// Used when barely outside tolerance
    /// Default: 1.0
    public var metronomeMinVolume: Float

    /// Maximum metronome volume (0.0-1.0)
    /// Used when far outside tolerance
    /// Default: 1.0
    public var metronomeMaxVolume: Float

    /// Whether to automatically end the run when distance is reached
    /// Default: true
    public var autoEndRun: Bool

    /// Timestamp when configuration was created
    public let createdAt: Date

    /// Timestamp when configuration was last modified
    public var modifiedAt: Date

    // MARK: - Initialization

    /// Creates a new RunConfiguration with a single target pace
    /// - Parameters:
    ///   - id: Unique identifier (generates new UUID if not provided)
    ///   - name: Configuration name
    ///   - distance: Total run distance
    ///   - targetPace: Single pace applied to all miles
    ///   - cadenceOffset: Offset from calculated base BPM (default: 0)
    ///   - paceTolerance: Alert threshold in seconds (default: 10)
    ///   - metronomeMinVolume: Minimum volume when barely off pace (default: 1.0)
    ///   - metronomeMaxVolume: Maximum volume when far off pace (default: 1.0)
    ///   - autoEndRun: Whether to auto-end when distance reached (default: true)
    /// - Precondition: Name must not be empty
    /// - Precondition: Cadence offset must be in range -15 to +15 BPM
    /// - Precondition: Pace tolerance must be positive
    public init(
        id: UUID = UUID(),
        name: String,
        distance: Distance,
        targetPace: Pace,
        cadenceOffset: Int = 0,
        paceTolerance: Int = 10,
        metronomeMinVolume: Float = 1.0,
        metronomeMaxVolume: Float = 1.0,
        autoEndRun: Bool = true
    ) {
        precondition(!name.isEmpty, "Configuration name must not be empty")
        precondition(-15...15 ~= cadenceOffset,
                     "Cadence offset must be -15 to +15 BPM, got \(cadenceOffset)")
        precondition(paceTolerance > 0,
                     "Pace tolerance must be positive, got \(paceTolerance)")

        let now = Date()
        self.id = id
        self.name = name
        self.distance = distance
        self.cadenceOffset = cadenceOffset
        self.paceTolerance = paceTolerance
        self.metronomeMinVolume = metronomeMinVolume
        self.metronomeMaxVolume = metronomeMaxVolume
        self.autoEndRun = autoEndRun
        self.createdAt = now
        self.modifiedAt = now

        // Create mile pace array with length = ceiling of miles
        let mileCount = Int(ceil(distance.miles))
        self.milePaces = Array(repeating: targetPace, count: mileCount)
    }

    /// Creates a new RunConfiguration with custom mile paces
    /// - Parameters:
    ///   - id: Unique identifier (generates new UUID if not provided)
    ///   - name: Configuration name
    ///   - distance: Total run distance
    ///   - milePaces: Custom pace for each mile
    ///   - cadenceOffset: Offset from calculated base BPM (default: 0)
    ///   - paceTolerance: Alert threshold in seconds (default: 10)
    ///   - metronomeMinVolume: Minimum volume when barely off pace (default: 1.0)
    ///   - metronomeMaxVolume: Maximum volume when far off pace (default: 1.0)
    ///   - autoEndRun: Whether to auto-end when distance reached (default: true)
    /// - Precondition: Name must not be empty
    /// - Precondition: Cadence offset must be in range -15 to +15 BPM
    /// - Precondition: Pace tolerance must be positive
    /// - Precondition: Mile paces array length must match ceiling(distance.miles)
    public init(
        id: UUID = UUID(),
        name: String,
        distance: Distance,
        milePaces: [Pace],
        cadenceOffset: Int = 0,
        paceTolerance: Int = 10,
        metronomeMinVolume: Float = 1.0,
        metronomeMaxVolume: Float = 1.0,
        autoEndRun: Bool = true
    ) {
        let expectedMiles = Int(ceil(distance.miles))

        precondition(!name.isEmpty, "Configuration name must not be empty")
        precondition(-15...15 ~= cadenceOffset,
                     "Cadence offset must be -15 to +15 BPM, got \(cadenceOffset)")
        precondition(paceTolerance > 0,
                     "Pace tolerance must be positive, got \(paceTolerance)")
        precondition(milePaces.count == expectedMiles,
                     "Mile paces count (\(milePaces.count)) must match ceiling of distance (\(expectedMiles))")

        let now = Date()
        self.id = id
        self.name = name
        self.distance = distance
        self.milePaces = milePaces
        self.cadenceOffset = cadenceOffset
        self.paceTolerance = paceTolerance
        self.metronomeMinVolume = metronomeMinVolume
        self.metronomeMaxVolume = metronomeMaxVolume
        self.autoEndRun = autoEndRun
        self.createdAt = now
        self.modifiedAt = now
    }

    // MARK: - Computed Properties

    /// Calculates average pace across all miles
    /// - Returns: Average of all mile paces
    public func averagePace() -> Pace {
        let totalSeconds = milePaces.reduce(0) { $0 + $1.totalSeconds }
        let averageSeconds = totalSeconds / milePaces.count
        let minutes = averageSeconds / 60
        let seconds = averageSeconds % 60
        return Pace(minutes: minutes, seconds: seconds)
    }

    /// Calculates estimated total duration for the run
    /// - Returns: Total seconds to complete the run at target paces
    public func estimatedDuration() -> TimeInterval {
        let totalPaceSeconds = milePaces.reduce(0) { $0 + $1.totalSeconds }
        return TimeInterval(totalPaceSeconds)
    }

    /// Calculates effective BPM using stride length from settings and target pace
    /// - Parameter settings: App settings containing stride length
    /// - Returns: Effective BPM (base from stride + offset)
    public func effectiveBPM(settings: AppSettings) -> Int {
        let targetPace = milePaces.first ?? averagePace()
        let baseBPM = settings.calculateBaseBPM(for: targetPace)
        return baseBPM + cadenceOffset
    }

    // MARK: - Codable

    /// Coding keys for custom encoding/decoding
    private enum CodingKeys: String, CodingKey {
        case id, name, distance, milePaces, baseCadence, cadenceOffset, paceTolerance
        case metronomeMinVolume, metronomeMaxVolume, autoEndRun
        case createdAt, modifiedAt
    }

    /// Custom decoder that provides defaults for missing properties
    /// Enables backward compatibility when new properties are added
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Required properties (always present in stored data)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.distance = try container.decode(Distance.self, forKey: .distance)
        self.milePaces = try container.decode([Pace].self, forKey: .milePaces)
        self.paceTolerance = try container.decode(Int.self, forKey: .paceTolerance)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)

        // Handle migration from baseCadence to cadenceOffset
        // New configs have cadenceOffset, old configs have baseCadence
        if let offset = try container.decodeIfPresent(Int.self, forKey: .cadenceOffset) {
            self.cadenceOffset = offset
        } else {
            // Legacy: default to 0 offset (ignore old baseCadence since we can't
            // accurately convert without knowing the stride length at save time)
            self.cadenceOffset = 0
        }

        // New properties with defaults for backward compatibility
        self.metronomeMinVolume = try container.decodeIfPresent(Float.self, forKey: .metronomeMinVolume) ?? 1.0
        self.metronomeMaxVolume = try container.decodeIfPresent(Float.self, forKey: .metronomeMaxVolume) ?? 1.0
        self.autoEndRun = try container.decodeIfPresent(Bool.self, forKey: .autoEndRun) ?? true
    }

    /// Custom encoder
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(distance, forKey: .distance)
        try container.encode(milePaces, forKey: .milePaces)
        try container.encode(cadenceOffset, forKey: .cadenceOffset)
        try container.encode(paceTolerance, forKey: .paceTolerance)
        try container.encode(metronomeMinVolume, forKey: .metronomeMinVolume)
        try container.encode(metronomeMaxVolume, forKey: .metronomeMaxVolume)
        try container.encode(autoEndRun, forKey: .autoEndRun)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }
}
