import Foundation

/// Represents a running pace in minutes and seconds per mile
///
/// Valid range: 4:00/mile to 20:00/mile (240-1200 seconds total)
/// This range covers all practical running paces from elite marathon runners
/// (~4:30/mile) to casual joggers (~15:00/mile).
///
/// Examples:
/// - Marathon pace: Pace(minutes: 7, seconds: 30)
/// - Easy run: Pace(minutes: 9, seconds: 0)
/// - Recovery: Pace(minutes: 10, seconds: 30)
///
/// Constitution compliance:
/// - Native Performance First: Struct with value semantics, no heap allocation
/// - User Experience Consistency: Formatted display ensures consistent pace presentation
public struct Pace: Codable, Equatable, Comparable {

    // MARK: - Properties

    /// Minutes component of pace (e.g., 8 for "8:30/mile")
    public let minutes: Int

    /// Seconds component of pace (e.g., 30 for "8:30/mile")
    /// Valid range: 0-59
    public let seconds: Int

    // MARK: - Computed Properties

    /// Total pace duration in seconds
    /// - Returns: minutes * 60 + seconds
    public var totalSeconds: Int {
        minutes * 60 + seconds
    }

    /// Pace expressed as seconds per meter (for per-sample calculations)
    /// - Returns: totalSeconds / meters per mile (1609.34)
    public var secondsPerMeter: Double {
        Double(totalSeconds) / 1609.34
    }

    /// Formatted pace string for display
    /// - Returns: "M:SS" format (e.g., "8:30", "7:05")
    public var formatted: String {
        String(format: "%d:%02d", minutes, seconds)
    }

    /// Pace phrased for text-to-speech announcements
    ///
    /// `formatted` must never be spoken: AVSpeechSynthesizer parses "9:00" as a
    /// clock time and reads it as "nine o'clock". This spells out the units.
    /// - Returns: e.g. "9 minutes per mile", "8 minutes 42 seconds per mile"
    public var spoken: String {
        guard seconds > 0 else {
            return "\(minutes) minutes per mile"
        }
        let secondUnit = seconds == 1 ? "second" : "seconds"
        return "\(minutes) minutes \(seconds) \(secondUnit) per mile"
    }

    // MARK: - Initialization

    /// Creates a new Pace
    /// - Parameters:
    ///   - minutes: Minutes component (must result in total 240-1200 seconds)
    ///   - seconds: Seconds component (must be 0-59)
    /// - Precondition: Total seconds must be in range 240-1200 (4:00-20:00/mile)
    /// - Precondition: Seconds must be in range 0-59
    public init(minutes: Int, seconds: Int) {
        // Validate seconds range
        precondition(0...59 ~= seconds,
                     "Seconds must be in range 0-59, got \(seconds)")

        let total = minutes * 60 + seconds

        // Validate total pace range (4:00/mile to 20:00/mile)
        precondition(240...1200 ~= total,
                     "Total pace must be 240-1200 seconds (4:00-20:00/mile), got \(total)")

        self.minutes = minutes
        self.seconds = seconds
    }

    /// Creates a pace from the total number of seconds per mile.
    /// - Parameter totalSeconds: Total seconds for one mile.
    /// - Returns: `nil` if the value is outside the supported range.
    public init?(totalSeconds: Int) {
        guard 240...1200 ~= totalSeconds else { return nil }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        self.init(minutes: minutes, seconds: seconds)
    }

    /// Creates a pace from a seconds-per-meter measurement.
    /// - Parameter secondsPerMeter: Seconds required to travel one meter.
    /// - Returns: `nil` if the computed pace is outside the supported range.
    public init?(secondsPerMeter: Double) {
        guard secondsPerMeter.isFinite, secondsPerMeter > 0 else { return nil }
        let totalSeconds = Int((secondsPerMeter * 1609.34).rounded())
        self.init(totalSeconds: totalSeconds)
    }

    // MARK: - Comparable Conformance

    /// Compares two paces
    /// - Note: Faster paces (fewer seconds) are "less than" slower paces
    /// - Returns: true if lhs is faster than rhs
    public static func < (lhs: Pace, rhs: Pace) -> Bool {
        lhs.totalSeconds < rhs.totalSeconds
    }
}
