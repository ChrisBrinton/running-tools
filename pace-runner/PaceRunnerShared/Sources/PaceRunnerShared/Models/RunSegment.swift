import Foundation

/// A single segment within a multi-segment run configuration
///
/// Each segment defines a distance, pace, and optional per-segment overrides
/// for cadence offset, pace tolerance, stride length, and pace calibration.
/// Multi-segment configs are a Pro feature.
///
/// Examples:
/// - Easy warmup: RunSegment(distance: Distance(miles: 2), pace: Pace(minutes: 10, seconds: 0), label: "Easy")
/// - Tempo block: RunSegment(distance: Distance(miles: 5), pace: Pace(minutes: 7, seconds: 30), label: "Tempo")
public struct RunSegment: Codable, Identifiable, Equatable {
    public let id: UUID
    public var distance: Distance
    public var pace: Pace
    public var label: String
    public var cadenceOffset: Int
    public var paceTolerance: Int

    /// Per-segment stride length override in inches
    /// nil = use global AppSettings.strideLengthInches
    public var strideLengthInches: Double?

    /// Per-segment pace calibration override in seconds per mile
    /// nil = use global AppSettings.paceCalibrationSeconds
    public var paceCalibrationSeconds: Int?

    public init(
        id: UUID = UUID(),
        distance: Distance,
        pace: Pace,
        label: String,
        cadenceOffset: Int = 0,
        paceTolerance: Int = 10,
        strideLengthInches: Double? = nil,
        paceCalibrationSeconds: Int? = nil
    ) {
        self.id = id
        self.distance = distance
        self.pace = pace
        self.label = label
        self.cadenceOffset = cadenceOffset
        self.paceTolerance = paceTolerance
        self.strideLengthInches = strideLengthInches
        self.paceCalibrationSeconds = paceCalibrationSeconds
    }
}
