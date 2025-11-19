import Foundation

/// Represents a running distance in miles
///
/// Stores distance in miles (primary unit for US runners) with conversion
/// utilities for meters and kilometers. Supports distances from 0 to ultra-marathon
/// lengths (100+ miles).
///
/// Examples:
/// - 5K: Distance(miles: 3.10686)
/// - Half marathon: Distance(miles: 13.1)
/// - Marathon: Distance(miles: 26.2)
/// - Ultra: Distance(miles: 50.0)
///
/// Constitution compliance:
/// - Native Performance First: Struct with value semantics, minimal conversions
/// - User Experience Consistency: Formatted display in miles for US market
public struct Distance: Codable, Equatable, Comparable {

    // MARK: - Constants

    /// Meters per mile (international standard)
    private static let metersPerMile: Double = 1609.34

    /// Meters per kilometer
    private static let metersPerKilometer: Double = 1000.0

    // MARK: - Properties

    /// Distance in miles
    public let miles: Double

    // MARK: - Computed Properties

    /// Distance in meters
    /// - Returns: miles * 1609.34
    public var meters: Double {
        miles * Self.metersPerMile
    }

    /// Distance in kilometers
    /// - Returns: meters / 1000
    public var kilometers: Double {
        meters / Self.metersPerKilometer
    }

    /// Formatted distance string for display
    /// - Returns: "X.X mi" format (e.g., "26.2 mi", "5.0 mi")
    public var formatted: String {
        String(format: "%.1f mi", miles)
    }

    // MARK: - Initialization

    /// Creates a new Distance
    /// - Parameter miles: Distance in miles (must be non-negative)
    /// - Precondition: Miles must be >= 0
    public init(miles: Double) {
        precondition(miles >= 0.0,
                     "Distance must be non-negative, got \(miles)")
        self.miles = miles
    }

    // MARK: - Comparable Conformance

    /// Compares two distances
    /// - Returns: true if lhs is shorter than rhs
    public static func < (lhs: Distance, rhs: Distance) -> Bool {
        lhs.miles < rhs.miles
    }
}
