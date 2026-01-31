import Foundation

/// Formats WorkoutExport data as JSON and plain text
///
/// Pure functions with no HealthKit dependency — easily testable.
/// JSON output matches the spec schema exactly (version "1.0").
/// Plain text output provides a human-readable summary with emoji.
///
/// Constitution compliance:
/// - Native Performance First: Foundation JSONEncoder, no third-party
/// - Test-Driven: Pure functions, deterministic output
public struct WorkoutExportFormatter {

    // MARK: - JSON Formatting

    /// Encodes a WorkoutExport as JSON data matching the spec schema
    /// - Parameter export: The workout export to serialize
    /// - Returns: JSON data with pretty-printing and sorted keys
    /// - Throws: EncodingError if serialization fails
    public func formatJSON(_ export: WorkoutExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
    }

    // MARK: - Plain Text Formatting

    /// Formats a WorkoutExport as a human-readable text summary
    /// - Parameter export: The workout export to format
    /// - Returns: Formatted plain text string matching spec format
    public func formatPlainText(_ export: WorkoutExport) -> String {
        var lines: [String] = []
        let w = export.workout

        // Header
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d, yyyy"
        let dateStr = dateFormatter.string(from: w.startDate)
        lines.append("🏃 Run Summary — \(dateStr)")
        lines.append("")

        // Overview line
        let distanceStr = String(format: "%.1f mi", w.distance)
        let durationStr = formatDuration(seconds: w.duration)
        lines.append("Distance: \(distanceStr) | Duration: \(durationStr) | Avg Pace: \(w.avgPace)/mi")

        // Calories and elevation
        var statsLine = "Calories: \(w.calories) kcal"
        if let route = export.route, route.elevationGain > 0 {
            statsLine += " | Elevation: +\(route.elevationGain) ft"
        }
        lines.append(statsLine)
        lines.append("")

        // Splits
        if !export.splits.isEmpty {
            lines.append("Splits:")
            for split in export.splits {
                var splitLine = "  Mile \(split.mile): \(split.pace)"
                if let hr = split.avgHR {
                    splitLine += " (HR \(hr))"
                }
                lines.append(splitLine)
            }
            lines.append("")
        }

        // Heart Rate
        if let hr = export.heartRate {
            lines.append("Heart Rate: Avg \(hr.avg) | Max \(hr.max)")

            for zone in hr.zones {
                let label = zone.label.padding(toLength: 12, withPad: " ", startingAt: 0)
                lines.append("  Z\(zone.zone) \(label) \(zone.minutes) min")
            }
            lines.append("")
        }

        // Extras
        var extrasLine: [String] = []
        if let cadence = export.extras?.avgCadence {
            extrasLine.append("Cadence: \(cadence) spm")
        }
        if let vo2 = export.extras?.vo2Max {
            extrasLine.append("VO2 Max: \(String(format: "%.1f", vo2))")
        }
        if !extrasLine.isEmpty {
            lines.append(extrasLine.joined(separator: " | "))
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Formats seconds as "H:MM:SS" or "M:SS"
    private func formatDuration(seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
