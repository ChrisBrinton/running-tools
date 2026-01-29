import Foundation

/// A single debug event captured during a workout
public struct DebugEvent: Codable, Equatable {
    /// When the event occurred
    public let timestamp: Date

    /// Event category for filtering
    public let category: String

    /// Human-readable event description
    public let message: String

    /// Optional additional data (distances, times, etc.)
    public let data: [String: String]?

    public init(
        timestamp: Date = Date(),
        category: String,
        message: String,
        data: [String: String]? = nil
    ) {
        self.timestamp = timestamp
        self.category = category
        self.message = message
        self.data = data
    }
}

/// Debug log for a workout session
/// Captures timing, sync, and calibration events for troubleshooting
public struct DebugLog: Codable, Equatable {

    /// All captured events
    public private(set) var events: [DebugEvent]

    /// App version that generated this log
    public let appVersion: String

    /// Watch or Phone
    public let platform: String

    /// When the log was created
    public let createdAt: Date

    public init(
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
        buildNumber: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
        platform: String = "Watch"
    ) {
        self.events = []
        self.appVersion = "\(appVersion) (\(buildNumber))"
        self.platform = platform
        self.createdAt = Date()
    }

    // MARK: - Logging Methods

    /// Add an event to the log
    public mutating func log(
        category: String,
        message: String,
        data: [String: String]? = nil
    ) {
        let event = DebugEvent(
            timestamp: Date(),
            category: category,
            message: message,
            data: data
        )
        events.append(event)
    }

    /// Log a timing-related event
    public mutating func logTiming(_ message: String, data: [String: String]? = nil) {
        log(category: "timing", message: message, data: data)
    }

    /// Log a sync-related event
    public mutating func logSync(_ message: String, data: [String: String]? = nil) {
        log(category: "sync", message: message, data: data)
    }

    /// Log a distance/calibration event
    public mutating func logDistance(_ message: String, data: [String: String]? = nil) {
        log(category: "distance", message: message, data: data)
    }

    /// Log a mile marker event
    public mutating func logMile(_ message: String, data: [String: String]? = nil) {
        log(category: "mile", message: message, data: data)
    }

    /// Log a pause/resume event
    public mutating func logPause(_ message: String, data: [String: String]? = nil) {
        log(category: "pause", message: message, data: data)
    }

    // MARK: - Export

    /// Export log as formatted JSON string for sharing
    public func exportAsJSON() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{ \"error\": \"Failed to encode debug log\" }"
        }

        return json
    }

    /// Export log as human-readable text
    public func exportAsText() -> String {
        var lines: [String] = []

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss.SSS"

        lines.append("=== PaceRunner Debug Log ===")
        lines.append("Version: \(appVersion)")
        lines.append("Platform: \(platform)")
        lines.append("Created: \(dateFormatter.string(from: createdAt))")
        lines.append("Events: \(events.count)")
        lines.append("")
        lines.append("=== Events ===")

        for event in events {
            let time = timeFormatter.string(from: event.timestamp)
            var line = "[\(time)] [\(event.category)] \(event.message)"

            if let data = event.data, !data.isEmpty {
                let dataStr = data.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                line += " {\(dataStr)}"
            }

            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }
}
