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

    private let windowSize: TimeInterval = 10    // seconds
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
        let sample = GPSSample(timestamp: timestamp, speed: speed)
        guard sample.isValid else { return }

        samples.append(sample)
        purgeOldSamples()

        if let pace = calculateSmoothedPace() {
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
        let cutoff = Date().addingTimeInterval(-windowSize)
        samples.removeAll { $0.timestamp < cutoff }
    }

    private func calculateSmoothedPace() -> Pace? {
        guard samples.count >= minSamples else { return nil }
        let filtered = removeOutliers(from: samples)
        guard filtered.count >= minSamples else { return nil }
        return weightedAveragePace(from: filtered)
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
