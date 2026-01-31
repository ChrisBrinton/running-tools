import Foundation

/// Writes export files to iCloud Drive (primary) or local Documents (fallback)
///
/// Handles:
/// - iCloud Drive availability detection
/// - Directory creation (Workouts/ subfolder)
/// - Filename generation from workout date
/// - Atomic writes for data safety
///
/// Output path:
/// - Primary: iCloud Drive/Documents/Workouts/run-YYYY-MM-DD-HHMMSS.json
/// - Fallback: <App Documents>/Workouts/run-YYYY-MM-DD-HHMMSS.json
///
/// Constitution compliance:
/// - Workout Independence: Files written locally, iCloud syncs in background
/// - No Network Dependency: Local fallback ensures export never fails due to connectivity
public struct ExportFileWriter {

    // MARK: - Configuration

    /// Subdirectory within the output directory for workout files
    private let subdirectory = "Workouts"

    /// iCloud container identifier (nil = default container)
    private let containerIdentifier: String?

    // MARK: - Initialization

    /// Creates an ExportFileWriter
    /// - Parameter containerIdentifier: iCloud container ID (nil for default)
    public init(containerIdentifier: String? = nil) {
        self.containerIdentifier = containerIdentifier
    }

    // MARK: - Public API

    /// Writes JSON and optional text export files
    /// - Parameters:
    ///   - json: JSON data to write
    ///   - text: Optional plain text summary
    ///   - workoutDate: Workout start date (used for filename)
    /// - Returns: URL of the written JSON file
    /// - Throws: File system errors
    @discardableResult
    public func writeExport(
        json: Data,
        text: String?,
        workoutDate: Date
    ) throws -> URL {
        let directory = try ensureOutputDirectory()

        // Write JSON
        let jsonFilename = filename(for: workoutDate, extension: "json")
        let jsonURL = directory.appendingPathComponent(jsonFilename)
        try json.write(to: jsonURL, options: .atomic)
        print("[ExportFileWriter] Wrote JSON: \(jsonURL.path)")

        // Write plain text (if provided)
        if let text = text {
            let txtFilename = filename(for: workoutDate, extension: "txt")
            let txtURL = directory.appendingPathComponent(txtFilename)
            try text.write(to: txtURL, atomically: true, encoding: .utf8)
            print("[ExportFileWriter] Wrote text: \(txtURL.path)")
        }

        return jsonURL
    }

    // MARK: - Output Directory

    /// Returns the output directory, creating it if necessary
    /// Prefers iCloud Drive; falls back to local Documents
    public func ensureOutputDirectory() throws -> URL {
        let baseURL = outputBaseDirectory()
        let workoutsURL = baseURL.appendingPathComponent(subdirectory)

        if !FileManager.default.fileExists(atPath: workoutsURL.path) {
            try FileManager.default.createDirectory(
                at: workoutsURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            print("[ExportFileWriter] Created directory: \(workoutsURL.path)")
        }

        return workoutsURL
    }

    /// Returns the base output directory (iCloud or local)
    public func outputBaseDirectory() -> URL {
        // Try iCloud Drive first
        if let iCloudURL = FileManager.default.url(
            forUbiquityContainerIdentifier: containerIdentifier
        ) {
            let documentsURL = iCloudURL.appendingPathComponent("Documents")
            print("[ExportFileWriter] Using iCloud Drive: \(documentsURL.path)")
            return documentsURL
        }

        // Fall back to local Documents directory
        let localURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        print("[ExportFileWriter] iCloud unavailable, using local: \(localURL.path)")
        return localURL
    }

    // MARK: - Filename Generation

    /// Generates a filename from a workout date
    /// Format: run-YYYY-MM-DD-HHMMSS.ext
    /// - Parameters:
    ///   - date: Workout start date
    ///   - ext: File extension ("json" or "txt")
    /// - Returns: Filename string
    public func filename(for date: Date, extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.timeZone = TimeZone.current
        let dateStr = formatter.string(from: date)
        return "run-\(dateStr).\(ext)"
    }
}
