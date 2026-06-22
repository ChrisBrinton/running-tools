import Foundation
import HealthKit
import CoreLocation
import PaceRunnerShared

/// Tool implementations exposed over MCP. Each tool has a descriptor (used by
/// `tools/list`) and a handler (called by `tools/call`). The handlers wrap
/// our existing data sources — `HealthKitExporter`, `WorkoutHistoryStore`,
/// `DebugLogStore` — so an AI coach can pull whatever it needs without us
/// shipping a separate API surface.
///
/// v1 tools:
///   - list_workouts: directory view of workouts in a date range.
///   - get_workout: pull selectable fields (metadata / route_gpx / samples /
///     events / pacerunner_log) for a specific workout by HealthKit UUID.
///   - get_pacerunner_log: pull the verbose debug log for a PR workout by ID.
enum MCPTools {

    // MARK: - tools/list descriptors

    /// Static array of tool descriptors with JSON-schema-ish input shapes.
    /// MCP clients render these to the model; the names and descriptions
    /// here are what the LLM sees, so they're written for an LLM audience.
    static let descriptors: [[String: Any]] = [
        [
            "name": "list_workouts",
            "description": "Lists workouts on the iPhone from Apple Health, optionally bounded by date. Returns an array of workout summaries with HealthKit UUID, activity type, start/end time, duration, total distance, and source app. Use this first to discover what's available, then call get_workout for details.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "since": [
                        "type": "string",
                        "description": "ISO-8601 lower bound, inclusive. Defaults to 30 days ago.",
                    ],
                    "until": [
                        "type": "string",
                        "description": "ISO-8601 upper bound, exclusive. Defaults to now.",
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Maximum number of workouts to return. Defaults to 50.",
                    ],
                    "activity_type": [
                        "type": "string",
                        "description": "Optional filter: 'running', 'walking', 'cycling', 'hiking', 'swimming'. Omit to return all activities.",
                    ],
                ],
            ],
        ],
        [
            "name": "get_workout",
            "description": "Returns selected fields for a specific workout. The 'id' is a HealthKit workout UUID as returned by list_workouts. The 'fields' parameter selects which slices to include — request only what you need to keep responses manageable. The 'route_gpx' field is the most expensive (can be hundreds of KB).",
            "inputSchema": [
                "type": "object",
                "required": ["id"],
                "properties": [
                    "id": [
                        "type": "string",
                        "description": "HealthKit workout UUID.",
                    ],
                    "fields": [
                        "type": "array",
                        "description": "Subset of: 'metadata' (totals + source), 'route_gpx' (full GPS trace in GPX), 'samples' (HR / distance / energy / running dynamics as time series), 'events' (pause/resume/lap markers), 'pacerunner_log' (verbose GPS debug log if PaceRunner also captured this run). Default: ['metadata'].",
                        "items": ["type": "string"],
                    ],
                ],
            ],
        ],
        [
            "name": "get_pacerunner_log",
            "description": "Returns the PaceRunner verbose GPS debug log for a workout, if one exists on disk. The 'workout_id' can be either a PaceRunner WorkoutSummary UUID or a HealthKit workout UUID — for the latter, we match by time overlap. Returns null when no log is on disk for that workout.",
            "inputSchema": [
                "type": "object",
                "required": ["workout_id"],
                "properties": [
                    "workout_id": [
                        "type": "string",
                        "description": "PaceRunner WorkoutSummary UUID, or HealthKit workout UUID.",
                    ],
                ],
            ],
        ],
    ]

    // MARK: - tools/call dispatch

    static func call(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "list_workouts":
            return try await listWorkouts(arguments: arguments)
        case "get_workout":
            return try await getWorkout(arguments: arguments)
        case "get_pacerunner_log":
            return try await getPaceRunnerLog(arguments: arguments)
        default:
            throw MCPError(code: -32602, message: "Unknown tool: \(name)")
        }
    }

    // MARK: - list_workouts

    @MainActor
    private static func listWorkouts(arguments: [String: Any]) async throws -> [String: Any] {
        let now = Date()
        let defaultSince = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        let since = parseDate(arguments["since"]) ?? defaultSince
        let until = parseDate(arguments["until"]) ?? now
        let limit = (arguments["limit"] as? Int) ?? 50
        let activityFilter = (arguments["activity_type"] as? String)?.lowercased()

        let exporter = HealthKitExporter.shared
        try await exporter.requestAuthorization()
        let workouts = try await exporter.fetchWorkouts(from: since, to: until)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        var rows: [[String: Any]] = []
        for w in workouts {
            let typeName = activityName(w.workoutActivityType).lowercased()
            if let activityFilter, typeName != activityFilter { continue }
            var row: [String: Any] = [
                "id": w.uuid.uuidString,
                "activity_type": typeName,
                "start": isoFormatter.string(from: w.startDate),
                "end": isoFormatter.string(from: w.endDate),
                "duration_seconds": w.duration,
                "source": w.sourceRevision.source.name,
            ]
            if let dist = w.totalDistance?.doubleValue(for: .meter()) {
                row["distance_meters"] = dist
                row["distance_miles"] = dist / 1609.344
            }
            // Cross-reference: do we have a PR debug log that overlaps this
            // workout's time range? Surfacing this in the directory means the
            // LLM can choose whether to also call get_pacerunner_log.
            row["has_pacerunner_log"] = paceRunnerLogID(matching: w) != nil
            rows.append(row)
            if rows.count >= limit { break }
        }

        return [
            "count": rows.count,
            "since": isoFormatter.string(from: since),
            "until": isoFormatter.string(from: until),
            "workouts": rows,
        ]
    }

    // MARK: - get_workout

    @MainActor
    private static func getWorkout(arguments: [String: Any]) async throws -> [String: Any] {
        guard let idStr = arguments["id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw MCPError(code: -32602, message: "Missing or invalid 'id' (must be a UUID)")
        }
        let fields = Set((arguments["fields"] as? [String]) ?? ["metadata"])

        let exporter = HealthKitExporter.shared
        try await exporter.requestAuthorization()
        // Fetch a wide window then filter by UUID. HK doesn't have a direct
        // "workout by UUID" query, so we accept a small inefficiency here.
        let now = Date()
        let since = Calendar.current.date(byAdding: .day, value: -365, to: now) ?? now
        let workouts = try await exporter.fetchWorkouts(from: since, to: now)
        guard let workout = workouts.first(where: { $0.uuid == uuid }) else {
            throw MCPError(code: -32602, message: "Workout not found: \(idStr)")
        }

        var out: [String: Any] = ["id": idStr]
        if fields.contains("metadata") {
            out["metadata"] = workoutMetadata(workout)
        }
        if fields.contains("route_gpx") {
            let locations = (try? await exporter.fetchRouteLocations(for: workout)) ?? []
            out["route_gpx"] = renderGPX(locations: locations, workout: workout)
            out["route_point_count"] = locations.count
        }
        if fields.contains("samples") {
            out["samples"] = await fetchAllQuantitySamples(for: workout)
        }
        if fields.contains("events") {
            out["events"] = (workout.workoutEvents ?? []).map { ev in
                [
                    "type": eventName(ev.type),
                    "start": ISO8601DateFormatter().string(from: ev.dateInterval.start),
                    "duration_seconds": ev.dateInterval.duration,
                ] as [String: Any]
            }
        }
        if fields.contains("pacerunner_log") {
            if let prID = paceRunnerLogID(matching: workout),
               let log = DebugLogStore.shared.load(for: prID) {
                out["pacerunner_log"] = log
                out["pacerunner_log_workout_id"] = prID.uuidString
            } else {
                out["pacerunner_log"] = NSNull()
            }
        }
        return out
    }

    // MARK: - get_pacerunner_log

    @MainActor
    private static func getPaceRunnerLog(arguments: [String: Any]) async throws -> [String: Any] {
        guard let idStr = arguments["workout_id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw MCPError(code: -32602, message: "Missing or invalid 'workout_id' (must be a UUID)")
        }

        // First treat the ID as a PR WorkoutSummary UUID — DebugLogStore is
        // keyed by that. If nothing matches, try interpreting as an HK
        // workout UUID and time-match against the PR history.
        if let log = DebugLogStore.shared.load(for: uuid) {
            return [
                "workout_id": uuid.uuidString,
                "match": "pacerunner",
                "log": log,
            ]
        }

        let exporter = HealthKitExporter.shared
        try await exporter.requestAuthorization()
        let now = Date()
        let since = Calendar.current.date(byAdding: .day, value: -365, to: now) ?? now
        let workouts = try await exporter.fetchWorkouts(from: since, to: now)
        guard let hk = workouts.first(where: { $0.uuid == uuid }) else {
            return ["workout_id": uuid.uuidString, "log": NSNull()]
        }
        if let prID = paceRunnerLogID(matching: hk), let log = DebugLogStore.shared.load(for: prID) {
            return [
                "workout_id": uuid.uuidString,
                "match": "healthkit",
                "pacerunner_workout_id": prID.uuidString,
                "log": log,
            ]
        }
        return ["workout_id": uuid.uuidString, "log": NSNull()]
    }

    // MARK: - HK helpers (duplicated lightly from HealthKitExporter so we
    //         can call them from outside that type without exposing internals)

    @MainActor
    private static func fetchAllQuantitySamples(for workout: HKWorkout) async -> [String: Any] {
        let healthStore = HKHealthStore()
        var pairs: [(String, HKQuantityType, HKUnit)] = [
            ("heartRate", HKQuantityType(.heartRate), HKUnit.count().unitDivided(by: .minute())),
            ("distanceWalkingRunning", HKQuantityType(.distanceWalkingRunning), .meter()),
            ("activeEnergyBurned", HKQuantityType(.activeEnergyBurned), .kilocalorie()),
            ("basalEnergyBurned", HKQuantityType(.basalEnergyBurned), .kilocalorie()),
            ("stepCount", HKQuantityType(.stepCount), .count()),
            ("vo2Max", HKQuantityType(.vo2Max), HKUnit(from: "mL/kg*min")),
        ]
        if #available(iOS 16.0, *) {
            pairs.append(contentsOf: [
                ("runningSpeed", HKQuantityType(.runningSpeed), HKUnit.meter().unitDivided(by: .second())),
                ("runningPower", HKQuantityType(.runningPower), .watt()),
                ("runningStrideLength", HKQuantityType(.runningStrideLength), .meter()),
                ("runningGroundContactTime", HKQuantityType(.runningGroundContactTime), HKUnit.secondUnit(with: .milli)),
                ("runningVerticalOscillation", HKQuantityType(.runningVerticalOscillation), HKUnit.meterUnit(with: .centi)),
            ])
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        var result: [String: Any] = [:]
        for (key, type, unit) in pairs {
            let samples: [HKQuantitySample] = await withCheckedContinuation { cont in
                let predicate = HKQuery.predicateForObjects(from: workout)
                let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
                let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                          limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
                    cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
                }
                healthStore.execute(query)
            }
            guard !samples.isEmpty else { continue }
            result[key] = samples.map { s in
                [
                    "start": isoFormatter.string(from: s.startDate),
                    "end": isoFormatter.string(from: s.endDate),
                    "value": s.quantity.doubleValue(for: unit),
                    "unit": unit.unitString,
                ] as [String: Any]
            }
        }
        return result
    }

    @MainActor
    private static func workoutMetadata(_ w: HKWorkout) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var dict: [String: Any] = [
            "activity_type": activityName(w.workoutActivityType),
            "activity_type_raw": Int(w.workoutActivityType.rawValue),
            "uuid": w.uuid.uuidString,
            "start": iso.string(from: w.startDate),
            "end": iso.string(from: w.endDate),
            "duration_seconds": w.duration,
            "source_name": w.sourceRevision.source.name,
            "source_bundle_id": w.sourceRevision.source.bundleIdentifier,
        ]
        if let totalDistance = w.totalDistance {
            dict["total_distance_meters"] = totalDistance.doubleValue(for: .meter())
            dict["total_distance_miles"] = totalDistance.doubleValue(for: .mile())
        }
        if let totalEnergy = w.totalEnergyBurned {
            dict["total_energy_kcal"] = totalEnergy.doubleValue(for: .kilocalorie())
        }
        if let metadata = w.metadata, !metadata.isEmpty {
            var stringMeta: [String: String] = [:]
            for (k, v) in metadata { stringMeta[k] = String(describing: v) }
            dict["raw_metadata"] = stringMeta
        }
        return dict
    }

    /// Renders the watch's CLLocations as GPX in the same schema as Apple's
    /// Health export — keeps the python comparison script happy.
    private static func renderGPX(locations: [CLLocation], workout: HKWorkout) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var s = """
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="PaceRunner MCP" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata>
    <time>\(iso.string(from: Date()))</time>
  </metadata>
  <trk>
    <name>Workout \(activityName(workout.workoutActivityType)) \(iso.string(from: workout.startDate))</name>
    <trkseg>
"""
        for loc in locations {
            let lat = String(format: "%.6f", loc.coordinate.latitude)
            let lon = String(format: "%.6f", loc.coordinate.longitude)
            let ele = String(format: "%.3f", loc.altitude)
            let time = iso.string(from: loc.timestamp)
            let speed = String(format: "%.3f", max(loc.speed, 0))
            let course = String(format: "%.3f", max(loc.course, 0))
            let hAcc = String(format: "%.3f", loc.horizontalAccuracy)
            let vAcc = String(format: "%.3f", loc.verticalAccuracy)
            s += "\n      <trkpt lon=\"\(lon)\" lat=\"\(lat)\"><ele>\(ele)</ele><time>\(time)</time>"
            s += "<extensions><speed>\(speed)</speed><course>\(course)</course><hAcc>\(hAcc)</hAcc><vAcc>\(vAcc)</vAcc></extensions></trkpt>"
        }
        s += "\n    </trkseg>\n  </trk>\n</gpx>"
        return s
    }

    /// Walks DebugLogStore to find a PR workout UUID whose log on disk
    /// matches the HK workout's time window. The PR id namespace and HK id
    /// namespace are different (PR writes its WorkoutSummary.id to the
    /// store), so we can't compare UUIDs directly — only time overlaps.
    @MainActor
    private static func paceRunnerLogID(matching hk: HKWorkout) -> UUID? {
        // For now: just check the most-recent log. If it's older than 24h
        // before HK workout start or starts more than 24h after, ignore it.
        // A future iteration can scan all files and match more carefully,
        // but the watch only keeps the last 5 anyway.
        let storedIDs = DebugLogStore.shared.storedIDs()
        // We don't have timestamps for the logs on disk other than file
        // mtime. Use that.
        let fm = FileManager.default
        var bestMatch: (id: UUID, diff: TimeInterval)?
        for id in storedIDs {
            let url = DebugLogStore.shared.fileURL(for: id)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            let diff = abs(mtime.timeIntervalSince(hk.endDate))
            if diff > 24 * 3600 { continue }
            if bestMatch == nil || diff < bestMatch!.diff {
                bestMatch = (id, diff)
            }
        }
        return bestMatch?.id
    }

    // MARK: - Static helpers

    private static func parseDate(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        // Try fractional-seconds first so callers that send Python-style
        // `.isoformat()` timestamps (`2026-06-02T15:21:20.294441Z`) parse cleanly.
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFractional.date(from: s) { return d }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        // Permit date-only forms too (YYYY-MM-DD)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.date(from: s)
    }

    private static func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .hiking: return "Hiking"
        case .swimming: return "Swimming"
        case .other: return "Other"
        default: return "Activity\(type.rawValue)"
        }
    }

    private static func eventName(_ type: HKWorkoutEventType) -> String {
        switch type {
        case .pause: return "pause"
        case .resume: return "resume"
        case .lap: return "lap"
        case .marker: return "marker"
        case .motionPaused: return "motionPaused"
        case .motionResumed: return "motionResumed"
        case .segment: return "segment"
        case .pauseOrResumeRequest: return "pauseOrResumeRequest"
        @unknown default: return "unknown"
        }
    }
}

