import Foundation

/// A named pace preset for quick-create workflows
///
/// Examples:
/// - NamedPace(name: "Easy", pace: Pace(minutes: 10, seconds: 0))
/// - NamedPace(name: "Tempo", pace: Pace(minutes: 8, seconds: 30))
/// - NamedPace(name: "Fast", pace: Pace(minutes: 7, seconds: 30))
public struct NamedPace: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var pace: Pace

    public init(id: UUID = UUID(), name: String, pace: Pace) {
        self.id = id
        self.name = name
        self.pace = pace
    }
}
