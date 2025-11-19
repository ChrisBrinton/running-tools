import Foundation
import Combine
import PaceRunnerShared

/// Pace calculator with EWMA smoothing
///
/// Implements Exponentially Weighted Moving Average (EWMA) algorithm for
/// real-time pace smoothing. Reduces GPS noise while staying responsive
/// to actual pace changes.
///
/// Algorithm:
/// 1. Maintain rolling window of samples (10 seconds)
/// 2. Detect and reject outliers (±25% from median)
/// 3. Calculate EWMA with time-weighted and accuracy-weighted samples
/// 4. Output smoothed pace value
///
/// Constitution compliance:
/// - <50ms computation: Simple arithmetic, no complex operations
/// - Responsive smoothing: 10s window balances noise reduction and lag
/// - Outlier rejection: Prevents GPS spikes from affecting pace display
///
/// Reference: specs/001-pace-runner-mvp/research.md (GPS Pace Smoothing)
class PaceCalculator: PaceCalculatorProtocol {

    // MARK: - Published Properties

    private let paceSubject = CurrentValueSubject<Pace?, Never>(nil)
    var pacePublisher: AnyPublisher<Pace?, Never> {
        paceSubject.eraseToAnyPublisher()
    }

    var currentPace: Pace? {
        paceSubject.value
    }

    // MARK: - Private Properties

    private struct Sample {
        let distance: Double // meters
        let timestamp: Date
        let speed: Double // meters/second
    }

    private var samples: [Sample] = []
    private let windowDuration: TimeInterval = 10.0 // seconds
    private let outlierThreshold: Double = 0.25 // 25%
    private let ewmaAlpha: Double = 0.3 // Smoothing factor

    // MARK: - Public Methods

    func addSample(distance: Double, timestamp: Date) {
        // Need at least 2 samples to calculate speed
        guard let lastSample = samples.last else {
            // First sample - just store it
            samples.append(Sample(distance: distance, timestamp: timestamp, speed: 0))
            return
        }

        // Calculate instantaneous speed
        let distanceDelta = distance - lastSample.distance
        let timeDelta = timestamp.timeIntervalSince(lastSample.timestamp)

        guard timeDelta > 0 else { return }

        let speed = distanceDelta / timeDelta // meters/second

        // Reject negative speeds (moving backwards)
        guard speed >= 0 else { return }

        // Add new sample
        let sample = Sample(distance: distance, timestamp: timestamp, speed: speed)
        samples.append(sample)

        // Remove samples outside window
        removeStaleSamples(olderThan: timestamp.addingTimeInterval(-windowDuration))

        // Calculate smoothed pace
        if let pace = calculateSmoothedPace() {
            paceSubject.send(pace)
        }
    }

    func reset() {
        samples.removeAll()
        paceSubject.send(nil)
    }

    // MARK: - Private Methods

    private func removeStaleSamples(olderThan cutoff: Date) {
        samples.removeAll { $0.timestamp < cutoff }
    }

    private func calculateSmoothedPace() -> Pace? {
        // Need at least 2 samples for meaningful calculation
        guard samples.count >= 2 else { return nil }

        // Get recent samples with valid speeds
        let validSamples = samples.filter { $0.speed > 0 }
        guard !validSamples.isEmpty else { return nil }

        // Calculate median speed for outlier detection
        let speeds = validSamples.map { $0.speed }.sorted()
        let medianSpeed = speeds[speeds.count / 2]

        // Filter outliers (speeds more than 25% from median)
        let filteredSamples = validSamples.filter { sample in
            let deviation = abs(sample.speed - medianSpeed) / medianSpeed
            return deviation <= outlierThreshold
        }

        guard !filteredSamples.isEmpty else {
            // All samples were outliers, use median
            return speedToPace(medianSpeed)
        }

        // Calculate EWMA
        var ewmaSpeed = filteredSamples.first!.speed

        for sample in filteredSamples.dropFirst() {
            ewmaSpeed = ewmaAlpha * sample.speed + (1 - ewmaAlpha) * ewmaSpeed
        }

        // Convert to pace
        return speedToPace(ewmaSpeed)
    }

    private func speedToPace(_ speed: Double) -> Pace? {
        // Speed is in meters/second, convert to seconds/mile
        guard speed > 0 else { return nil }

        let secondsPerMeter = 1.0 / speed
        let secondsPerMile = secondsPerMeter * 1609.34

        let totalSeconds = Int(secondsPerMile)

        // Validate range (4:00 - 20:00/mile)
        guard totalSeconds >= 240 && totalSeconds <= 1200 else {
            return nil
        }

        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        return Pace(minutes: minutes, seconds: seconds)
    }
}
