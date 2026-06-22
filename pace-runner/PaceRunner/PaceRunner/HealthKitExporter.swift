import Foundation
import HealthKit
import CoreLocation

/// Reads Apple Health workout data on iOS and packages everything we can pull
/// from HealthKit (workout metadata, the GPS route as GPX, associated quantity
/// samples, and workout events) into a single shareable bundle.
///
/// The bundle is structured so that the python `tools/distance_compare.py`
/// script and any future analysis tools can find what they need by path:
///
///     pacerunner-export-<timestamp>/
///       debug.txt                          # existing PR text export
///       pacerunner-verbose-log.txt         # if a verbose GPS log was on disk
///       healthkit/
///         workout-00-2026-06-05_07-27-Running/
///           workout.json                   # metadata (start/end, totals, etc.)
///           route.gpx                      # GPS route in Apple-compatible GPX
///           samples.json                   # HR, distance, energy, etc.
///           events.json                    # pause/resume/lap if any
///
/// The directory is then zipped via NSFileCoordinator(.forUploading) for the
/// share sheet to hand off as a single file.
@MainActor
final class HealthKitExporter {

    static let shared = HealthKitExporter()

    private let healthStore = HKHealthStore()

    private init() {}

    // MARK: - Authorization

    /// All HK types we'd like to read. Failing to grant any is non-fatal —
    /// the queries simply return empty results for unauthorized types.
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.heartRate),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.basalEnergyBurned),
            HKQuantityType(.stepCount),
            HKQuantityType(.vo2Max),
        ]
        if #available(iOS 16.0, *) {
            types.formUnion([
                HKQuantityType(.runningSpeed),
                HKQuantityType(.runningPower),
                HKQuantityType(.runningStrideLength),
                HKQuantityType(.runningGroundContactTime),
                HKQuantityType(.runningVerticalOscillation),
            ])
        }
        return types
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitExportError.unavailable
        }
        try await healthStore.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Diagnostic check: is the workout *read* path actually usable? iOS gives
    /// us a binary "Not Determined" / "Sharing Denied" / "Sharing Authorized"
    /// for *write* status only — there's no public API for read status — but
    /// we can probe by running a tiny query and seeing if it returns nothing
    /// when we know workouts exist on-device. For now we just return whether
    /// the user has *ever* responded to the auth prompt for the workout type
    /// (Not Determined = never asked or never answered).
    func isAuthorizationDetermined() -> Bool {
        healthStore.authorizationStatus(for: .workoutType()) != .notDetermined
    }

    // MARK: - Queries

    /// Workouts whose start falls in [from, to). Sorted oldest-first.
    func fetchWorkouts(from start: Date, to end: Date) async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { cont in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error = error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            healthStore.execute(query)
        }
    }

    /// All CLLocations associated with the given workout via its
    /// HKWorkoutRoute series. Returned in chronological order.
    func fetchRouteLocations(for workout: HKWorkout) async throws -> [CLLocation] {
        let routes: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { cont in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKAnchoredObjectQuery(
                type: HKSeriesType.workoutRoute(),
                predicate: predicate,
                anchor: nil,
                limit: HKObjectQueryNoLimit
            ) { _, samples, _, _, error in
                if let error = error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            healthStore.execute(query)
        }

        var all: [CLLocation] = []
        for route in routes {
            let batch: [CLLocation] = try await withCheckedThrowingContinuation { cont in
                var accumulated: [CLLocation] = []
                var settled = false
                let query = HKWorkoutRouteQuery(route: route) { _, locs, done, error in
                    if settled { return }
                    if let error = error {
                        settled = true
                        cont.resume(throwing: error)
                        return
                    }
                    if let locs = locs { accumulated.append(contentsOf: locs) }
                    if done {
                        settled = true
                        cont.resume(returning: accumulated)
                    }
                }
                healthStore.execute(query)
            }
            all.append(contentsOf: batch)
        }
        all.sort { $0.timestamp < $1.timestamp }
        return all
    }

    /// Quantity samples scoped to the workout (NOT all samples in the time
    /// window — uses HK's workout-relationship predicate). Empty on auth fail.
    private func fetchSamples(for workout: HKWorkout, type: HKQuantityType) async -> [HKQuantitySample] {
        await withCheckedContinuation { cont in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Bundle building

    /// Builds the directory described in the file header. Caller wraps it via
    /// `zipDirectoryForSharing(_:)` to get a single .zip for the share sheet.
    func exportBundle(
        workouts: [HKWorkout],
        debugText: String,
        verboseLog: String?
    ) async throws -> URL {
        let stamp = Self.timestampFormatter.string(from: Date())
        let bundleDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacerunner-export-\(stamp)", isDirectory: true)
        try? FileManager.default.removeItem(at: bundleDir)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        try debugText.write(
            to: bundleDir.appendingPathComponent("debug.txt"),
            atomically: true,
            encoding: .utf8
        )

        if let verboseLog = verboseLog, !verboseLog.isEmpty {
            try verboseLog.write(
                to: bundleDir.appendingPathComponent("pacerunner-verbose-log.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        if !workouts.isEmpty {
            let hkDir = bundleDir.appendingPathComponent("healthkit", isDirectory: true)
            try FileManager.default.createDirectory(at: hkDir, withIntermediateDirectories: true)
            for (idx, workout) in workouts.enumerated() {
                try await exportWorkout(workout, index: idx, into: hkDir)
            }
        }

        return bundleDir
    }

    private func exportWorkout(_ workout: HKWorkout, index: Int, into root: URL) async throws {
        let typeName = Self.activityName(workout.workoutActivityType)
            .replacingOccurrences(of: " ", with: "")
        let timeStr = Self.fileTimeFormatter.string(from: workout.startDate)
        let dirName = String(format: "workout-%02d-%@-%@", index, timeStr, typeName)
        let dir = root.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // workout.json
        let meta = workoutMetadata(workout)
        let metaData = try JSONSerialization.data(
            withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]
        )
        try metaData.write(to: dir.appendingPathComponent("workout.json"))

        // route.gpx
        if let locations = try? await fetchRouteLocations(for: workout), !locations.isEmpty {
            let gpx = renderGPX(locations: locations, workout: workout)
            try gpx.write(
                to: dir.appendingPathComponent("route.gpx"),
                atomically: true,
                encoding: .utf8
            )
        }

        // samples.json
        var samplesOut: [String: Any] = [:]
        for (key, type) in Self.quantityTypes() {
            let samples = await fetchSamples(for: workout, type: type)
            guard !samples.isEmpty else { continue }
            let unit = Self.preferredUnit(for: type)
            samplesOut[key] = samples.map { (s: HKQuantitySample) -> [String: Any] in
                [
                    "start": Self.isoFormatter.string(from: s.startDate),
                    "end": Self.isoFormatter.string(from: s.endDate),
                    "value": s.quantity.doubleValue(for: unit),
                    "unit": unit.unitString,
                    "source": s.sourceRevision.source.name,
                ]
            }
        }
        if !samplesOut.isEmpty {
            let data = try JSONSerialization.data(
                withJSONObject: samplesOut, options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: dir.appendingPathComponent("samples.json"))
        }

        // events.json
        if let events = workout.workoutEvents, !events.isEmpty {
            let eventsOut: [[String: Any]] = events.map { ev in
                [
                    "type": Self.eventName(ev.type),
                    "start": Self.isoFormatter.string(from: ev.dateInterval.start),
                    "duration": ev.dateInterval.duration,
                ]
            }
            let data = try JSONSerialization.data(
                withJSONObject: eventsOut, options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: dir.appendingPathComponent("events.json"))
        }
    }

    // MARK: - Zipping

    /// NSFileCoordinator with `.forUploading` produces a zip but deletes it
    /// when the callback returns. We copy it to a stable path so the share
    /// sheet can hand it off to AirDrop / Mail / Files without races.
    func zipDirectoryForSharing(_ directory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            var settled = false
            coordinator.coordinate(
                readingItemAt: directory,
                options: [.forUploading],
                error: &coordError
            ) { zipURL in
                let dest = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("\(directory.lastPathComponent).zip")
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.copyItem(at: zipURL, to: dest)
                    settled = true
                    cont.resume(returning: dest)
                } catch {
                    settled = true
                    cont.resume(throwing: error)
                }
            }
            if !settled, let err = coordError {
                cont.resume(throwing: err)
            }
        }
    }

    // MARK: - Metadata helpers

    private func workoutMetadata(_ w: HKWorkout) -> [String: Any] {
        var dict: [String: Any] = [
            "activityType": Self.activityName(w.workoutActivityType),
            "activityTypeRawValue": Int(w.workoutActivityType.rawValue),
            "uuid": w.uuid.uuidString,
            "startDate": Self.isoFormatter.string(from: w.startDate),
            "endDate": Self.isoFormatter.string(from: w.endDate),
            "duration": w.duration,
            "sourceName": w.sourceRevision.source.name,
            "sourceBundleID": w.sourceRevision.source.bundleIdentifier,
        ]
        if let totalDistance = w.totalDistance {
            dict["totalDistanceMeters"] = totalDistance.doubleValue(for: .meter())
            dict["totalDistanceMiles"] = totalDistance.doubleValue(for: .mile())
        }
        if let totalEnergy = w.totalEnergyBurned {
            dict["totalEnergyKcal"] = totalEnergy.doubleValue(for: .kilocalorie())
        }
        if let metadata = w.metadata, !metadata.isEmpty {
            // Stringify whatever's in workout metadata — types vary widely.
            var stringMeta: [String: String] = [:]
            for (k, v) in metadata {
                stringMeta[k] = String(describing: v)
            }
            dict["metadata"] = stringMeta
        }
        return dict
    }

    /// GPX output that matches Apple Health's export schema (incl. <speed>,
    /// <course>, <hAcc>, <vAcc> in <extensions>), so the python comparison
    /// tool reads it without changes.
    private func renderGPX(locations: [CLLocation], workout: HKWorkout) -> String {
        var s = #"""
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="PaceRunner Export" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata>
    <time>\#(Self.isoFormatter.string(from: Date()))</time>
  </metadata>
  <trk>
    <name>Workout \#(Self.activityName(workout.workoutActivityType)) \#(Self.isoFormatter.string(from: workout.startDate))</name>
    <trkseg>

"""#
        for loc in locations {
            let lat = String(format: "%.6f", loc.coordinate.latitude)
            let lon = String(format: "%.6f", loc.coordinate.longitude)
            let ele = String(format: "%.3f", loc.altitude)
            let time = Self.isoFormatter.string(from: loc.timestamp)
            let speed = String(format: "%.3f", max(loc.speed, 0))
            let course = String(format: "%.3f", max(loc.course, 0))
            let hAcc = String(format: "%.3f", loc.horizontalAccuracy)
            let vAcc = String(format: "%.3f", loc.verticalAccuracy)
            s += #"      <trkpt lon="\#(lon)" lat="\#(lat)"><ele>\#(ele)</ele><time>\#(time)</time>"#
            s += #"<extensions><speed>\#(speed)</speed><course>\#(course)</course><hAcc>\#(hAcc)</hAcc><vAcc>\#(vAcc)</vAcc></extensions></trkpt>"#
            s += "\n"
        }
        s += """
    </trkseg>
  </trk>
</gpx>
"""
        return s
    }

    // MARK: - Type mappings

    private static func quantityTypes() -> [(String, HKQuantityType)] {
        var pairs: [(String, HKQuantityType)] = [
            ("heartRate", HKQuantityType(.heartRate)),
            ("distanceWalkingRunning", HKQuantityType(.distanceWalkingRunning)),
            ("activeEnergyBurned", HKQuantityType(.activeEnergyBurned)),
            ("basalEnergyBurned", HKQuantityType(.basalEnergyBurned)),
            ("stepCount", HKQuantityType(.stepCount)),
            ("vo2Max", HKQuantityType(.vo2Max)),
        ]
        if #available(iOS 16.0, *) {
            pairs.append(contentsOf: [
                ("runningSpeed", HKQuantityType(.runningSpeed)),
                ("runningPower", HKQuantityType(.runningPower)),
                ("runningStrideLength", HKQuantityType(.runningStrideLength)),
                ("runningGroundContactTime", HKQuantityType(.runningGroundContactTime)),
                ("runningVerticalOscillation", HKQuantityType(.runningVerticalOscillation)),
            ])
        }
        return pairs
    }

    private static func preferredUnit(for type: HKQuantityType) -> HKUnit {
        switch type.identifier {
        case HKQuantityTypeIdentifier.heartRate.rawValue:
            return HKUnit.count().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
            return .meter()
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
             HKQuantityTypeIdentifier.basalEnergyBurned.rawValue:
            return .kilocalorie()
        case HKQuantityTypeIdentifier.stepCount.rawValue:
            return .count()
        case HKQuantityTypeIdentifier.vo2Max.rawValue:
            return HKUnit(from: "mL/kg*min")
        case "HKQuantityTypeIdentifierRunningSpeed":
            return HKUnit.meter().unitDivided(by: .second())
        case "HKQuantityTypeIdentifierRunningPower":
            return .watt()
        case "HKQuantityTypeIdentifierRunningStrideLength":
            return .meter()
        case "HKQuantityTypeIdentifierRunningGroundContactTime":
            return HKUnit.secondUnit(with: .milli)
        case "HKQuantityTypeIdentifierRunningVerticalOscillation":
            return HKUnit.meterUnit(with: .centi)
        default:
            return .count()
        }
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

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let fileTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

enum HealthKitExportError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: return "HealthKit isn't available on this device."
        }
    }
}
