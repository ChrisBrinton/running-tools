import Foundation
import HealthKit

/// Orchestrates automatic post-workout export to iCloud Drive
///
/// This is the main entry point for the workout export feature.
/// Register on app launch to start observing workout completions.
///
/// Pipeline:
/// 1. HKObserverQuery detects new workout in HealthKit
/// 2. Query all unexported running workouts
/// 3. For each: extract data → format → write file → mark exported
///
/// Usage:
/// ```swift
/// // In PaceRunnerApp.init():
/// let exportService = WorkoutExportService()
/// exportService.registerObserver()
/// ```
///
/// Constitution compliance:
/// - Battery Life as Feature: Event-driven, not polling
/// - Workout Independence: Processes after workout ends, no interference
/// - Native Performance First: All HealthKit + Foundation APIs
public final class WorkoutExportService {

    // MARK: - Dependencies

    private let healthStore: HKHealthStore
    private let extractor: WorkoutDataExtractor
    private let formatter: WorkoutExportFormatter
    private let fileWriter: ExportFileWriter
    private let dedupStore: ExportDeduplicationStore

    /// User settings provider (for max HR override, export format)
    private let settingsProvider: () -> ExportSettings

    /// Observer query (retained to keep it alive)
    private var observerQuery: HKObserverQuery?

    private let logPrefix = "[WorkoutExportService]"

    // MARK: - Initialization

    public init(
        healthStore: HKHealthStore = HKHealthStore(),
        extractor: WorkoutDataExtractor? = nil,
        formatter: WorkoutExportFormatter = WorkoutExportFormatter(),
        fileWriter: ExportFileWriter = ExportFileWriter(),
        dedupStore: ExportDeduplicationStore = ExportDeduplicationStore(),
        settingsProvider: @escaping () -> ExportSettings = { ExportSettings() }
    ) {
        self.healthStore = healthStore
        self.extractor = extractor ?? WorkoutDataExtractor(healthStore: healthStore)
        self.formatter = formatter
        self.fileWriter = fileWriter
        self.dedupStore = dedupStore
        self.settingsProvider = settingsProvider
    }

    // MARK: - Observer Registration

    /// Registers the HKObserverQuery for workout completions with background delivery
    ///
    /// Call this once on app launch. The observer persists across app lifecycle.
    /// Background delivery requires the HealthKit background delivery entitlement.
    public func registerObserver() {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("\(logPrefix) HealthKit not available, skipping observer registration")
            return
        }

        let workoutType = HKObjectType.workoutType()

        // Request permissions for all the data we need to read
        requestPermissions { [weak self] success in
            guard success else {
                print("\(self?.logPrefix ?? "") Permission request failed or denied")
                return
            }

            self?.setupObserverQuery()
        }
    }

    /// Requests HealthKit read permissions needed for export
    private func requestPermissions(completion: @escaping (Bool) -> Void) {
        let readTypes: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.stepCount),
            HKQuantityType(.vo2Max),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.runningStrideLength),
            HKSeriesType.workoutRoute()
        ]

        healthStore.requestAuthorization(
            toShare: nil,  // Read-only
            read: readTypes
        ) { success, error in
            if let error = error {
                print("[WorkoutExportService] Authorization error: \(error)")
            }
            completion(success)
        }
    }

    /// Sets up the observer query and enables background delivery
    private func setupObserverQuery() {
        let workoutType = HKObjectType.workoutType()

        let query = HKObserverQuery(
            sampleType: workoutType,
            predicate: nil
        ) { [weak self] _, completionHandler, error in
            if let error = error {
                print("\(self?.logPrefix ?? "") Observer error: \(error)")
                completionHandler()
                return
            }

            print("\(self?.logPrefix ?? "") Observer fired — processing new workouts")

            Task {
                await self?.processNewWorkouts()
                completionHandler()
            }
        }

        healthStore.execute(query)
        observerQuery = query

        // Enable background delivery for timely export
        healthStore.enableBackgroundDelivery(
            for: workoutType,
            frequency: .immediate
        ) { success, error in
            if let error = error {
                print("[WorkoutExportService] Background delivery error: \(error)")
            } else if success {
                print("[WorkoutExportService] Background delivery enabled")
            }
        }

        print("\(logPrefix) Observer registered")
    }

    // MARK: - Export Processing

    /// Processes all unexported running workouts
    ///
    /// Called by the observer query handler. Queries all running workouts,
    /// filters out already-exported ones, and exports each new workout.
    public func processNewWorkouts() async {
        let settings = settingsProvider()
        guard settings.autoExportEnabled else {
            print("\(logPrefix) Auto-export disabled, skipping")
            return
        }

        // Prune old dedup entries on each run
        dedupStore.pruneOldEntries()

        do {
            let workouts = try await queryRecentRunningWorkouts()
            print("\(logPrefix) Found \(workouts.count) recent running workouts")

            for workout in workouts {
                let uuid = workout.uuid
                guard !dedupStore.isExported(uuid) else {
                    continue  // Already exported
                }

                do {
                    try await exportWorkout(workout, settings: settings)
                    dedupStore.markExported(uuid)
                    print("\(logPrefix) ✅ Exported workout \(uuid)")
                } catch {
                    print("\(logPrefix) ❌ Failed to export workout \(uuid): \(error)")
                    // Don't mark as exported — will retry next time
                }
            }
        } catch {
            print("\(logPrefix) Failed to query workouts: \(error)")
        }
    }

    /// Exports a single workout through the full pipeline
    private func exportWorkout(
        _ workout: HKWorkout,
        settings: ExportSettings
    ) async throws {
        // 1. Extract all data
        let export = try await extractor.extractAll(from: workout)

        // 2. Format as JSON
        let jsonData = try formatter.formatJSON(export)

        // 3. Format as plain text (if both format selected)
        let textContent: String?
        if settings.exportFormat == .both {
            textContent = formatter.formatPlainText(export)
        } else {
            textContent = nil
        }

        // 4. Write files
        try fileWriter.writeExport(
            json: jsonData,
            text: textContent,
            workoutDate: workout.startDate
        )
    }

    // MARK: - Workout Query

    /// Queries recent running workouts from HealthKit
    /// Returns workouts from the last 7 days, sorted by start date descending
    private func queryRecentRunningWorkouts() async throws -> [HKWorkout] {
        let workoutType = HKObjectType.workoutType()
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!

        let datePredicate = HKQuery.predicateForSamples(
            withStart: sevenDaysAgo,
            end: nil,
            options: .strictStartDate
        )
        let runningPredicate = HKQuery.predicateForWorkouts(
            with: .running
        )
        let compound = NSCompoundPredicate(
            andPredicateWithSubpredicates: [datePredicate, runningPredicate]
        )

        let sortDescriptor = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate,
            ascending: false
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: workoutType,
                predicate: compound,
                limit: 10,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let workouts = (samples as? [HKWorkout]) ?? []
                continuation.resume(returning: workouts)
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Manual Export

    /// Manually triggers export for all unexported workouts
    /// Call from a UI action (e.g., "Export Now" button in Settings)
    public func exportNow() {
        Task {
            await processNewWorkouts()
        }
    }
}

// MARK: - Deduplication Store

/// Tracks which workout UUIDs have been exported to prevent duplicate exports
///
/// Backed by UserDefaults for persistence across app launches.
/// Entries are pruned after 90 days to prevent unbounded growth.
public final class ExportDeduplicationStore {

    private static let storageKey = "exportedWorkoutUUIDs"
    private static let timestampKey = "exportedWorkoutTimestamps"

    /// In-memory cache of exported UUIDs for fast lookup
    private var exportedUUIDs: Set<UUID>

    /// Timestamps for each UUID (for pruning old entries)
    private var timestamps: [UUID: Date]

    public init() {
        // Load from UserDefaults
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let uuids = try? JSONDecoder().decode([UUID].self, from: data) {
            exportedUUIDs = Set(uuids)
        } else {
            exportedUUIDs = []
        }

        if let data = UserDefaults.standard.data(forKey: Self.timestampKey),
           let ts = try? JSONDecoder().decode([UUID: Date].self, from: data) {
            timestamps = ts
        } else {
            timestamps = [:]
        }
    }

    /// Checks if a workout has already been exported
    public func isExported(_ uuid: UUID) -> Bool {
        exportedUUIDs.contains(uuid)
    }

    /// Marks a workout as exported
    public func markExported(_ uuid: UUID) {
        exportedUUIDs.insert(uuid)
        timestamps[uuid] = Date()
        persist()
    }

    /// Removes entries older than the specified number of days
    public func pruneOldEntries(olderThanDays days: Int = 90) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let oldUUIDs = timestamps.filter { $0.value < cutoff }.map { $0.key }

        for uuid in oldUUIDs {
            exportedUUIDs.remove(uuid)
            timestamps.removeValue(forKey: uuid)
        }

        if !oldUUIDs.isEmpty {
            persist()
            print("[ExportDeduplicationStore] Pruned \(oldUUIDs.count) old entries")
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        if let data = try? encoder.encode(Array(exportedUUIDs)) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        if let data = try? encoder.encode(timestamps) {
            UserDefaults.standard.set(data, forKey: Self.timestampKey)
        }
    }
}

// MARK: - Export Settings

/// User-configurable export settings
/// These would be added to AppSettings in the real integration
public struct ExportSettings {
    /// Whether auto-export is enabled
    public var autoExportEnabled: Bool

    /// Max HR override for zone calculation (nil = use 190 default)
    public var maxHROverride: Int?

    /// Export format preference
    public var exportFormat: ExportFormat

    public init(
        autoExportEnabled: Bool = true,
        maxHROverride: Int? = nil,
        exportFormat: ExportFormat = .both
    ) {
        self.autoExportEnabled = autoExportEnabled
        self.maxHROverride = maxHROverride
        self.exportFormat = exportFormat
    }
}

// MARK: - Integration Points

/*
 INTEGRATION GUIDE — Where this hooks into the existing codebase:
 
 1. PaceRunnerApp.swift (iPhone app entry point):
    ────────────────────────────────────────────
    Add to init():
    
    ```swift
    // After SyncManager setup:
    let exportService = WorkoutExportService()
    exportService.registerObserver()
    self.exportService = exportService  // Retain reference
    ```
    
    Add property:
    ```swift
    private let exportService: WorkoutExportService
    ```

 2. SettingsView.swift (iPhone settings):
    ─────────────────────────────────────
    Add new section after "Workout Mode":
    
    ```swift
    Section(header: Text("Workout Export")) {
        Toggle("Auto-Export Workouts", isOn: $settings.autoExportEnabled)
            .onChange(of: settings.autoExportEnabled) { _, _ in saveSettings() }
        
        Picker("Export Format", selection: $settings.exportFormat) {
            Text("JSON Only").tag(ExportFormat.json)
            Text("JSON + Text").tag(ExportFormat.both)
        }
        .onChange(of: settings.exportFormat) { _, _ in saveSettings() }
        
        Stepper("Max HR: \(settings.maxHROverride ?? 190)",
                value: Binding(
                    get: { settings.maxHROverride ?? 190 },
                    set: { settings.maxHROverride = $0 }
                ),
                in: 140...220)
            .onChange(of: settings.maxHROverride) { _, _ in saveSettings() }
        
        Button("Export Now") {
            exportService.exportNow()
        }
    }
    ```

 3. AppSettings.swift (shared models):
    ──────────────────────────────────
    Add properties:
    
    ```swift
    /// Whether to auto-export workouts after completion
    public var autoExportEnabled: Bool  // default: true
    
    /// Max HR override for zone calculation (nil = age-based or 190)
    public var maxHROverride: Int?  // default: nil
    
    /// Export format preference
    public var exportFormat: ExportFormat  // default: .both
    ```
    
    Add to init(), Codable, and load/save.

 4. HealthKit Entitlements:
    ───────────────────────
    Add to PaceRunner.entitlements:
    - com.apple.developer.healthkit.background-delivery
    
    Add to Info.plist:
    - NSHealthShareUsageDescription (update existing)
    - Add read types: heartRate, vo2Max, stepCount, restingHeartRate,
      runningStrideLength, workoutRoute

 5. iCloud Entitlements:
    ────────────────────
    Add to PaceRunner.entitlements:
    - com.apple.developer.ubiquity-container-identifiers
    - com.apple.developer.icloud-services (CloudDocuments)
*/
