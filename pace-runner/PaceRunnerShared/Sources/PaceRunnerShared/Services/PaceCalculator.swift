import Foundation
import Combine

/// Rolling-window pace calculator that smooths noisy GPS samples.
public final class PaceCalculator: PaceCalculatorProtocol {

    // MARK: - Nested Types

    public enum PaceStatus: Equatable {
        case tooSlow(deviation: Int)
        case onTarget
        case tooFast(deviation: Int)

        public var needsAlert: Bool {
            switch self {
            case .onTarget:
                return false
            default:
                return true
            }
        }
    }

    // MARK: - Configuration

    /// Configurable window sizes
    private var fastWindowSeconds: TimeInterval = 120   // 2 minutes (default)
    private var mediumWindowSeconds: TimeInterval = 240 // 4 minutes (default)
    private var slowWindowMeters: Double = 1609.34      // 1 mile (default)

    private let minSamples: Int = 3
    private let outlierThreshold: Double = 0.25  // 25%
    private let minimumDistanceDelta: Double = 0.5 // meters
    private let minimumTimeDelta: TimeInterval = 0.5

    // MARK: - State

    private let paceSubject = CurrentValueSubject<Pace?, Never>(nil)
    private var samples: [GPSSample] = []
    private var lastDistance: Double?
    private var lastTimestamp: Date?

    // MARK: - Lifecycle

    public init() {}

    // MARK: - PaceCalculatorProtocol

    public var pacePublisher: AnyPublisher<Pace?, Never> {
        paceSubject.eraseToAnyPublisher()
    }

    public var currentPace: Pace? {
        paceSubject.value
    }

    // MARK: - Configurable Pace Windows (Fast/Medium/Slow)

    /// Fast pace - time-based rolling average (configurable, default 2 min)
    public var fastPace: Pace? {
        calculateSmoothedPace(windowDuration: fastWindowSeconds)
    }

    /// Medium pace - time-based rolling average (configurable, default 4 min)
    public var mediumPace: Pace? {
        calculateSmoothedPace(windowDuration: mediumWindowSeconds)
    }

    /// Slow pace (master) - distance-based rolling average (configurable, default 1 mile)
    public var slowPace: Pace? {
        calculateDistanceBasedPace(distanceWindow: slowWindowMeters)
    }

    // MARK: - Legacy Accessors (backward compatibility)

    public var oneMinutePace: Pace? {
        fastPace  // Maps to fast pace
    }

    public var threeMinutePace: Pace? {
        mediumPace  // Maps to medium pace
    }

    public var trailingMilePace: Pace? {
        slowPace  // Maps to slow (master) pace
    }

    // MARK: - Configuration

    public func configureWindows(fastSeconds: Int, mediumSeconds: Int, slowMiles: Double) {
        fastWindowSeconds = TimeInterval(fastSeconds)
        mediumWindowSeconds = TimeInterval(mediumSeconds)
        slowWindowMeters = slowMiles * 1609.34  // Convert miles to meters
    }

    public func addSample(distance: Double, timestamp: Date = Date()) {
        guard distance.isFinite, distance >= 0 else { return }

        defer {
            lastDistance = distance
            lastTimestamp = timestamp
        }

        guard let previousDistance = lastDistance,
              let previousTimestamp = lastTimestamp else {
            // Need at least two samples to compute pace
            return
        }

        let deltaDistance = distance - previousDistance
        let deltaTime = timestamp.timeIntervalSince(previousTimestamp)

        guard deltaDistance >= minimumDistanceDelta,
              deltaTime >= minimumTimeDelta else {
            return
        }

        let speed = deltaDistance / deltaTime
        let sample = GPSSample(timestamp: timestamp, speed: speed, cumulativeDistance: distance)
        guard sample.isValid else { return }

        samples.append(sample)
        purgeOldSamples()

        // Publish fast pace for real-time updates
        if let pace = calculateSmoothedPace(windowDuration: fastWindowSeconds) {
            paceSubject.send(pace)
        }
    }

    public func reset() {
        samples.removeAll()
        lastDistance = nil
        lastTimestamp = nil
        paceSubject.send(nil)
    }

    // MARK: - Helpers

    private func purgeOldSamples() {
        // Keep samples for longest window
        // Need at least 1 mile of distance data (could take up to ~15 min at 15:00/mile pace)
        // Use time-based cutoff of 20 minutes to be safe
        let maxWindow: TimeInterval = 20 * 60 // 20 minutes
        let cutoff = Date().addingTimeInterval(-maxWindow)
        samples.removeAll { $0.timestamp < cutoff }
    }

    private func calculateSmoothedPace(windowDuration: TimeInterval) -> Pace? {
        guard !samples.isEmpty else { return nil }

        // Filter samples within the specified window
        // Use the last sample's timestamp as reference, not current time
        guard let lastSampleTime = samples.last?.timestamp else { return nil }
        let cutoff = lastSampleTime.addingTimeInterval(-windowDuration)
        let windowSamples = samples.filter { $0.timestamp >= cutoff }

        guard windowSamples.count >= minSamples else { return nil }
        let filtered = removeOutliers(from: windowSamples)
        guard filtered.count >= minSamples else { return nil }
        return weightedAveragePace(from: filtered)
    }

    /// Calculate pace based on distance window (e.g., last 1 mile)
    /// During the first mile (when total distance < window), uses all data from start
    private func calculateDistanceBasedPace(distanceWindow: Double) -> Pace? {
        guard !samples.isEmpty else { return nil }

        // Get current distance
        guard let currentDistance = samples.last?.cumulativeDistance else { return nil }

        // Calculate cutoff distance
        // If we haven't covered the full window yet, use all data from start (cutoff = 0)
        let cutoffDistance = max(0, currentDistance - distanceWindow)

        // Get samples within the distance window
        let windowSamples = samples.filter { $0.cumulativeDistance >= cutoffDistance }

        guard windowSamples.count >= minSamples else { return nil }

        // Calculate actual distance and time covered by these samples
        guard let firstSample = windowSamples.first,
              let lastSample = windowSamples.last else { return nil }

        let distanceCovered = lastSample.cumulativeDistance - firstSample.cumulativeDistance
        let timeTaken = lastSample.timestamp.timeIntervalSince(firstSample.timestamp)

        guard distanceCovered > 0, timeTaken > 0 else { return nil }

        // Calculate pace as time per meter, then convert to Pace
        let secondsPerMeter = timeTaken / distanceCovered
        return Pace(secondsPerMeter: secondsPerMeter)
    }

    private func removeOutliers(from samples: [GPSSample]) -> [GPSSample] {
        let sortedSeconds = samples
            .map(\.secondsPerMeter)
            .sorted()

        guard !sortedSeconds.isEmpty else { return samples }

        let median: Double
        if sortedSeconds.count % 2 == 0 {
            let mid = sortedSeconds.count / 2
            median = (sortedSeconds[mid - 1] + sortedSeconds[mid]) / 2.0
        } else {
            median = sortedSeconds[sortedSeconds.count / 2]
        }

        let threshold = median * outlierThreshold

        return samples.filter {
            abs($0.secondsPerMeter - median) <= threshold
        }
    }

    private func weightedAveragePace(from samples: [GPSSample]) -> Pace? {
        guard !samples.isEmpty else { return nil }

        var weightedSum: Double = 0
        var totalWeight: Double = 0

        for (index, sample) in samples.sorted(by: { $0.timestamp < $1.timestamp }).enumerated() {
            let weight = Double(index + 1)
            weightedSum += sample.secondsPerMeter * weight
            totalWeight += weight
        }

        guard totalWeight > 0 else { return nil }
        let secondsPerMeter = weightedSum / totalWeight
        return Pace(secondsPerMeter: secondsPerMeter)
    }

    // MARK: - Pace Status

    public func paceStatus(
        targetPace: Pace,
        tolerance: Int
    ) -> PaceStatus {
        guard let current = currentPace else {
            return .onTarget
        }

        let deviation = current.totalSeconds - targetPace.totalSeconds
        if abs(deviation) <= tolerance {
            return .onTarget
        } else if deviation > 0 {
            return .tooSlow(deviation: deviation)
        } else {
            return .tooFast(deviation: abs(deviation))
        }
    }
}
