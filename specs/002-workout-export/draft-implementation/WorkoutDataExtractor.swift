import Foundation
import HealthKit
import CoreLocation

/// Extracts detailed workout data from HealthKit for export
///
/// Queries HealthKit for all data associated with a completed workout:
/// workout summary, heart rate, route, splits, cadence, and VO2 Max.
///
/// Uses async/await for clean composition of multiple HealthKit queries.
/// All queries are read-only — no data is written to HealthKit.
///
/// Constitution compliance:
/// - Native Performance First: All queries via native HealthKit APIs
/// - Battery Life as Feature: One-time queries per workout, not polling
/// - Workout Independence: Read-only access to existing workout data
public final class WorkoutDataExtractor {

    // MARK: - Dependencies

    private let healthStore: HKHealthStore
    private let metersPerMile: Double = 1609.34
    private let feetPerMeter: Double = 3.28084

    // MARK: - Initialization

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    // MARK: - Public API

    /// Extracts all available data for a workout into an export model
    /// - Parameter workout: The HKWorkout to extract data from
    /// - Returns: Complete WorkoutExport ready for formatting
    public func extractAll(from workout: HKWorkout) async throws -> WorkoutExport {
        let summary = extractWorkoutSummary(workout)

        // Run independent queries in parallel
        async let heartRateResult = extractHeartRate(
            start: workout.startDate,
            end: workout.endDate
        )
        async let routeResult = extractRoute(for: workout)
        async let cadenceResult = extractCadence(
            start: workout.startDate,
            end: workout.endDate
        )
        async let vo2MaxResult = extractVO2Max()

        let heartRate = try? await heartRateResult
        let routeLocations = try? await routeResult
        let cadence = try? await cadenceResult
        let vo2Max = try? await vo2MaxResult

        // Compute splits from route (requires both route and optionally HR)
        let hrSamples = try? await queryHRSamples(
            start: workout.startDate,
            end: workout.endDate
        )
        let splits: [SplitData]
        let routeData: RouteData?

        if let locations = routeLocations, !locations.isEmpty {
            splits = computeSplits(
                from: locations,
                hrSamples: hrSamples ?? [],
                workoutStart: workout.startDate
            )
            routeData = buildRouteData(from: locations)
        } else {
            splits = []
            routeData = nil
        }

        // Build extras
        let extras: ExtraMetrics?
        if cadence != nil || vo2Max != nil {
            extras = ExtraMetrics(avgCadence: cadence, vo2Max: vo2Max)
        } else {
            extras = nil
        }

        return WorkoutExport(
            workout: summary,
            heartRate: heartRate,
            splits: splits,
            route: routeData,
            extras: extras
        )
    }

    // MARK: - Workout Summary

    /// Extracts basic workout metadata (synchronous — data is on the HKWorkout object)
    public func extractWorkoutSummary(_ workout: HKWorkout) -> WorkoutSummaryExport {
        let distanceMiles: Double
        if let distance = workout.totalDistance {
            distanceMiles = distance.doubleValue(for: .mile())
        } else {
            distanceMiles = 0
        }

        let calories: Int
        if let energy = workout.totalEnergyBurned {
            calories = Int(energy.doubleValue(for: .kilocalorie()))
        } else {
            calories = 0
        }

        let duration = Int(workout.duration)
        let avgPaceSeconds: Int
        if distanceMiles > 0 {
            avgPaceSeconds = Int(Double(duration) / distanceMiles)
        } else {
            avgPaceSeconds = 0
        }

        let isIndoor = workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool ?? false
        let type = isIndoor ? "indoor_run" : "outdoor_run"
        let source = workout.sourceRevision.source.name

        return WorkoutSummaryExport(
            uuid: workout.uuid.uuidString,
            type: type,
            startDate: workout.startDate,
            endDate: workout.endDate,
            duration: duration,
            distance: round(distanceMiles * 100) / 100,  // 2 decimal places
            calories: calories,
            avgPaceSeconds: avgPaceSeconds,
            source: source
        )
    }

    // MARK: - Heart Rate

    /// Extracts heart rate data with computed zones
    /// - Parameters:
    ///   - start: Workout start date
    ///   - end: Workout end date
    ///   - maxHR: User-provided max HR override (nil = use 190 default)
    /// - Returns: HeartRateData with zones and samples, or nil if no HR data
    public func extractHeartRate(
        start: Date,
        end: Date,
        maxHR: Int? = nil
    ) async throws -> HeartRateData? {
        let samples = try await queryHRSamples(start: start, end: end)
        guard !samples.isEmpty else { return nil }

        let bpmValues = samples.map { Int($0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))) }

        let avg = bpmValues.reduce(0, +) / bpmValues.count
        let maxBPM = bpmValues.max() ?? 0
        let minBPM = bpmValues.min() ?? 0

        // Compute zones
        let effectiveMaxHR = maxHR ?? 190
        let zones = HeartRateZoneCalculator.calculateZones(
            samples: samples,
            maxHR: effectiveMaxHR
        )

        // Build sample array for charting
        let hrSamples = samples.map { sample in
            HRSample(
                t: sample.startDate,
                bpm: Int(sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))
            )
        }

        return HeartRateData(
            avg: avg,
            max: maxBPM,
            min: minBPM,
            zones: zones,
            samples: hrSamples
        )
    }

    /// Queries raw HR samples from HealthKit
    private func queryHRSamples(start: Date, end: Date) async throws -> [HKQuantitySample] {
        let hrType = HKQuantityType(.heartRate)
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: .strictStartDate
        )
        let sortDescriptor = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate,
            ascending: true
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: hrType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let hrSamples = (samples as? [HKQuantitySample]) ?? []
                continuation.resume(returning: hrSamples)
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Route

    /// Extracts GPS route locations for a workout
    /// - Parameter workout: The HKWorkout to extract route from
    /// - Returns: Array of CLLocation sorted by timestamp, or nil if no route
    public func extractRoute(for workout: HKWorkout) async throws -> [CLLocation]? {
        // First, query for workout routes associated with this workout
        let routeType = HKSeriesType.workoutRoute()
        let predicate = HKQuery.predicateForObjects(from: workout)

        let routes: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: routeType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let routes = (samples as? [HKWorkoutRoute]) ?? []
                continuation.resume(returning: routes)
            }
            healthStore.execute(query)
        }

        guard let route = routes.first else { return nil }

        // Extract CLLocations from the route
        return try await extractLocations(from: route)
    }

    /// Iterates HKWorkoutRouteQuery to collect all CLLocations
    private func extractLocations(from route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { continuation in
            var allLocations: [CLLocation] = []

            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                if let locations = locations {
                    allLocations.append(contentsOf: locations)
                }
                if done {
                    // Sort by timestamp to ensure chronological order
                    allLocations.sort { $0.timestamp < $1.timestamp }
                    continuation.resume(returning: allLocations)
                }
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Splits

    /// Computes per-mile splits from route locations
    /// - Parameters:
    ///   - locations: GPS route points sorted by timestamp
    ///   - hrSamples: Heart rate samples for associating avg HR per mile
    ///   - workoutStart: Workout start time for elapsed calculation
    /// - Returns: Array of SplitData for each completed mile (+ partial final mile)
    public func computeSplits(
        from locations: [CLLocation],
        hrSamples: [HKQuantitySample],
        workoutStart: Date
    ) -> [SplitData] {
        guard locations.count >= 2 else { return [] }

        var splits: [SplitData] = []
        var accumulatedDistance: Double = 0
        var mileStartIndex = 0
        var currentMile = 1
        var mileStartTime = locations.first!.timestamp

        for i in 1..<locations.count {
            let delta = locations[i].distance(from: locations[i - 1])
            accumulatedDistance += delta

            // Check if we've crossed a mile boundary
            if accumulatedDistance >= metersPerMile {
                let mileEndTime = locations[i].timestamp
                let mileDuration = mileEndTime.timeIntervalSince(mileStartTime)
                let paceSeconds = Int(mileDuration)  // Time for ~1 mile
                let elapsedSeconds = Int(mileEndTime.timeIntervalSince(workoutStart))

                // Average HR for this mile's time window
                let avgHR = averageHR(
                    samples: hrSamples,
                    start: mileStartTime,
                    end: mileEndTime
                )

                splits.append(SplitData(
                    mile: currentMile,
                    paceSeconds: paceSeconds,
                    avgHR: avgHR,
                    elapsedSeconds: elapsedSeconds
                ))

                // Reset for next mile
                accumulatedDistance -= metersPerMile
                mileStartIndex = i
                mileStartTime = mileEndTime
                currentMile += 1
            }
        }

        // Final partial mile (if > 0.1 miles remaining)
        let remainingMiles = accumulatedDistance / metersPerMile
        if remainingMiles > 0.1, let lastLocation = locations.last {
            let mileDuration = lastLocation.timestamp.timeIntervalSince(mileStartTime)
            // Extrapolate to full mile pace
            let paceSeconds = Int(mileDuration / remainingMiles)
            let elapsedSeconds = Int(lastLocation.timestamp.timeIntervalSince(workoutStart))

            let avgHR = averageHR(
                samples: hrSamples,
                start: mileStartTime,
                end: lastLocation.timestamp
            )

            splits.append(SplitData(
                mile: currentMile,
                paceSeconds: paceSeconds,
                avgHR: avgHR,
                elapsedSeconds: elapsedSeconds
            ))
        }

        return splits
    }

    /// Computes average HR from samples within a time window
    private func averageHR(
        samples: [HKQuantitySample],
        start: Date,
        end: Date
    ) -> Int? {
        let unit = HKUnit.count().unitDivided(by: .minute())
        let windowSamples = samples.filter { $0.startDate >= start && $0.startDate <= end }
        guard !windowSamples.isEmpty else { return nil }

        let total = windowSamples.reduce(0.0) { $0 + $1.quantity.doubleValue(for: unit) }
        return Int(total / Double(windowSamples.count))
    }

    // MARK: - Route Data Building

    /// Builds RouteData with downsampled points and elevation
    private func buildRouteData(from locations: [CLLocation]) -> RouteData {
        let downsampled = downsampleLocations(locations, intervalSeconds: 5)
        let (gain, loss) = calculateElevation(from: locations)

        let points = downsampled.map { location in
            RoutePoint(
                lat: location.coordinate.latitude,
                lon: location.coordinate.longitude,
                alt: location.altitude * feetPerMeter,
                t: location.timestamp
            )
        }

        return RouteData(
            elevationGain: Int(gain * feetPerMeter),
            elevationLoss: Int(loss * feetPerMeter),
            points: points
        )
    }

    /// Downsamples locations to approximately one per intervalSeconds
    /// Keeps first and last points always
    private func downsampleLocations(
        _ locations: [CLLocation],
        intervalSeconds: TimeInterval
    ) -> [CLLocation] {
        guard locations.count > 2 else { return locations }

        var result: [CLLocation] = [locations.first!]
        var lastKeptTime = locations.first!.timestamp

        for i in 1..<(locations.count - 1) {
            let elapsed = locations[i].timestamp.timeIntervalSince(lastKeptTime)
            if elapsed >= intervalSeconds {
                result.append(locations[i])
                lastKeptTime = locations[i].timestamp
            }
        }

        result.append(locations.last!)
        return result
    }

    /// Calculates elevation gain and loss from location altitudes
    /// Uses simple moving average for noise filtering
    /// - Returns: (gain in meters, loss in meters)
    private func calculateElevation(from locations: [CLLocation]) -> (Double, Double) {
        guard locations.count >= 5 else { return (0, 0) }

        // Smooth altitude with 5-point moving average
        let altitudes = locations.map { $0.altitude }
        let smoothed = movingAverage(altitudes, window: 5)

        var gain: Double = 0
        var loss: Double = 0
        let noiseThreshold: Double = 1.0  // Ignore changes < 1 meter

        for i in 1..<smoothed.count {
            let delta = smoothed[i] - smoothed[i - 1]
            if delta > noiseThreshold {
                gain += delta
            } else if delta < -noiseThreshold {
                loss += abs(delta)
            }
        }

        return (gain, loss)
    }

    /// Simple moving average filter
    private func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard values.count >= window else { return values }

        var result: [Double] = []
        for i in 0..<values.count {
            let start = max(0, i - window / 2)
            let end = min(values.count, i + window / 2 + 1)
            let slice = values[start..<end]
            result.append(slice.reduce(0, +) / Double(slice.count))
        }
        return result
    }

    // MARK: - Cadence

    /// Extracts average running cadence from step count data
    /// - Returns: Average cadence in steps per minute, or nil if unavailable
    public func extractCadence(start: Date, end: Date) async throws -> Int? {
        let stepType = HKQuantityType(.stepCount)
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: .strictStartDate
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let sum = statistics?.sumQuantity() else {
                    continuation.resume(returning: nil)
                    return
                }

                let totalSteps = sum.doubleValue(for: .count())
                let durationMinutes = end.timeIntervalSince(start) / 60.0
                guard durationMinutes > 0 else {
                    continuation.resume(returning: nil)
                    return
                }

                // Cadence = steps per minute
                let cadence = Int(totalSteps / durationMinutes)
                continuation.resume(returning: cadence)
            }
            healthStore.execute(query)
        }
    }

    // MARK: - VO2 Max

    /// Extracts the most recent VO2 Max measurement
    /// - Returns: VO2 Max in mL/kg/min, or nil if unavailable
    public func extractVO2Max() async throws -> Double? {
        let vo2Type = HKQuantityType(.vo2Max)
        let sortDescriptor = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate,
            ascending: false
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: vo2Type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }

                let unit = HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
                let value = sample.quantity.doubleValue(for: unit)
                continuation.resume(returning: round(value * 10) / 10)  // 1 decimal
            }
            healthStore.execute(query)
        }
    }
}

// MARK: - Heart Rate Zone Calculator

/// Calculates heart rate zones from HR samples and max HR
///
/// Uses standard 5-zone model:
/// - Zone 1 (Recovery): < 60% max HR
/// - Zone 2 (Easy): 60-70% max HR
/// - Zone 3 (Tempo): 70-80% max HR
/// - Zone 4 (Threshold): 80-90% max HR
/// - Zone 5 (Max): > 90% max HR
public enum HeartRateZoneCalculator {

    /// Zone boundaries as percentage of max HR
    private static let zoneBoundaries: [(zone: Int, minPercent: Double, maxPercent: Double)] = [
        (1, 0.0, 0.60),
        (2, 0.60, 0.70),
        (3, 0.70, 0.80),
        (4, 0.80, 0.90),
        (5, 0.90, 2.0)  // 2.0 as upper bound (effectively no limit)
    ]

    /// Calculates time-in-zone for each HR zone
    /// - Parameters:
    ///   - samples: HR samples sorted by timestamp
    ///   - maxHR: Maximum heart rate (user-provided or estimated)
    /// - Returns: Array of 5 HeartRateZone entries with minutes in each zone
    public static func calculateZones(
        samples: [HKQuantitySample],
        maxHR: Int
    ) -> [HeartRateZone] {
        let unit = HKUnit.count().unitDivided(by: .minute())
        var zoneSeconds: [Int: Double] = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0]

        for i in 0..<samples.count {
            let bpm = samples[i].quantity.doubleValue(for: unit)
            let hrPercent = bpm / Double(maxHR)

            // Determine which zone this sample falls in
            let zone = zoneForPercent(hrPercent)

            // Calculate duration this sample represents
            let duration: Double
            if i + 1 < samples.count {
                duration = samples[i + 1].startDate.timeIntervalSince(samples[i].startDate)
            } else if i > 0 {
                // Last sample — use same duration as previous interval
                duration = samples[i].startDate.timeIntervalSince(samples[i - 1].startDate)
            } else {
                duration = 0
            }

            zoneSeconds[zone, default: 0] += max(0, min(duration, 30))  // Cap at 30s to handle gaps
        }

        return zoneBoundaries.map { boundary in
            HeartRateZone(
                zone: boundary.zone,
                label: HeartRateZone.labels[boundary.zone] ?? "Zone \(boundary.zone)",
                minutes: Int((zoneSeconds[boundary.zone] ?? 0) / 60.0)
            )
        }
    }

    /// Determines which zone a given HR percentage falls in
    private static func zoneForPercent(_ percent: Double) -> Int {
        for boundary in zoneBoundaries {
            if percent < boundary.maxPercent {
                return boundary.zone
            }
        }
        return 5  // Fallback to max zone
    }
}
