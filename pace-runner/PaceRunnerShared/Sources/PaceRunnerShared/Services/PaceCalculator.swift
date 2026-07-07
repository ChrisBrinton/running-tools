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
    private let minimumDistanceDelta: Double = 0.5 // meters
    private let minimumTimeDelta: TimeInterval = 0.5

    // MARK: - State

    private let paceSubject = CurrentValueSubject<Pace?, Never>(nil)
    private var samples: [GPSSample] = []
    private var lastAcceptedDistance: Double?
    private var lastAcceptedTimestamp: Date?

    // Debug: track previous pace values to detect large jumps
    private var previousFastPace: Pace?
    private var previousMediumPace: Pace?
    private var previousSlowPace: Pace?

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
        calculateTimeBasedPace(windowDuration: fastWindowSeconds)
    }

    /// Medium pace - time-based rolling average (configurable, default 4 min)
    public var mediumPace: Pace? {
        calculateTimeBasedPace(windowDuration: mediumWindowSeconds)
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

        // First sample: just record baseline, don't compute pace yet
        guard let previousDistance = lastAcceptedDistance,
              let previousTimestamp = lastAcceptedTimestamp else {
            lastAcceptedDistance = distance
            lastAcceptedTimestamp = timestamp
            return
        }

        let deltaDistance = distance - previousDistance
        let deltaTime = timestamp.timeIntervalSince(previousTimestamp)

        // Only accept samples with meaningful deltas
        // IMPORTANT: Do NOT update lastAccepted* when rejecting — the next
        // accepted sample must compute speed from the last accepted baseline
        guard deltaDistance >= minimumDistanceDelta,
              deltaTime >= minimumTimeDelta else {
            return
        }

        let speed = deltaDistance / deltaTime
        let sample = GPSSample(timestamp: timestamp, speed: speed, cumulativeDistance: distance)
        guard sample.isValid else { return }

        // Now update the accepted baseline
        lastAcceptedDistance = distance
        lastAcceptedTimestamp = timestamp

        // Debug: log outlier samples (speed > 1 std dev from recent mean)
        logIfOutlier(sample)

        samples.append(sample)
        purgeOldSamples()

        // Publish fast pace for real-time updates
        let newFastPace = calculateTimeBasedPace(windowDuration: fastWindowSeconds)
        if let pace = newFastPace {
            paceSubject.send(pace)
        }

        // Debug: detect and log large jumps in any pace window
        logPaceJumps(newFastPace: newFastPace)
    }

    public func notePauseGap(_ pauseDuration: TimeInterval) {
        guard pauseDuration > 0 else { return }

        // Slide the accumulated history forward by the paused interval so it
        // becomes contiguous, in "moving time", with the samples that arrive
        // after resume. Without this the time-based windows (fast/medium) and
        // especially the distance-based master window compute
        // `timeTaken = last.timestamp - first.timestamp` across a span that
        // includes the pause — inflating pace as if the runner had been
        // crawling for the whole break. Shifting preserves the master window's
        // history (it needs a full mile of samples) rather than discarding it.
        samples = samples.map { sample in
            GPSSample(
                timestamp: sample.timestamp.addingTimeInterval(pauseDuration),
                speed: sample.speed,
                cumulativeDistance: sample.cumulativeDistance
            )
        }

        // Force the first post-resume sample to re-establish the baseline
        // rather than computing a speed across the pause (which would append a
        // spurious near-zero-speed sample).
        lastAcceptedDistance = nil
        lastAcceptedTimestamp = nil
    }

    public func reset() {
        samples.removeAll()
        lastAcceptedDistance = nil
        lastAcceptedTimestamp = nil
        previousFastPace = nil
        previousMediumPace = nil
        previousSlowPace = nil
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

    /// Calculate pace for a time-based window using distance/time approach
    /// (more stable than weighted average of per-sample speeds)
    private func calculateTimeBasedPace(windowDuration: TimeInterval) -> Pace? {
        guard !samples.isEmpty else { return nil }

        guard let lastSampleTime = samples.last?.timestamp else { return nil }
        let cutoff = lastSampleTime.addingTimeInterval(-windowDuration)
        let windowSamples = samples.filter { $0.timestamp >= cutoff }

        guard windowSamples.count >= minSamples else { return nil }

        // Use distance/time calculation (same approach as distance-based window)
        // This is mathematically equivalent to average pace and avoids noise
        // from per-sample instantaneous speed variations
        guard let firstSample = windowSamples.first,
              let lastSample = windowSamples.last else { return nil }

        let distanceCovered = lastSample.cumulativeDistance - firstSample.cumulativeDistance
        let timeTaken = lastSample.timestamp.timeIntervalSince(firstSample.timestamp)

        guard distanceCovered > 0, timeTaken > 0 else { return nil }

        let secondsPerMeter = timeTaken / distanceCovered
        return Pace(secondsPerMeter: secondsPerMeter)
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

    // MARK: - Debug Logging

    /// Log when a new sample's speed deviates significantly from the recent mean
    private func logIfOutlier(_ newSample: GPSSample) {
        // Need enough samples to compute meaningful stats
        guard samples.count >= 10 else { return }

        // Compute mean and std dev of recent sample speeds (secondsPerMeter)
        let recentCount = min(samples.count, 30)
        let recentSamples = samples.suffix(recentCount)
        let speeds = recentSamples.map(\.secondsPerMeter)

        let mean = speeds.reduce(0, +) / Double(speeds.count)
        let variance = speeds.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(speeds.count)
        let stdDev = sqrt(variance)

        guard stdDev > 0 else { return }

        let deviation = abs(newSample.secondsPerMeter - mean)
        if deviation > stdDev {
            let samplePaceSeconds = Int(newSample.secondsPerMeter * 1609.34)
            let meanPaceSeconds = Int(mean * 1609.34)
            let stdDevSeconds = Int(stdDev * 1609.34)
            let sigmas = deviation / stdDev
            print("PaceCalc.OUTLIER: sample=\(formatSeconds(samplePaceSeconds))/mi mean=\(formatSeconds(meanPaceSeconds))/mi stdDev=\(stdDevSeconds)s sigmas=\(String(format: "%.1f", sigmas)) speed=\(String(format: "%.2f", newSample.speed))m/s sampleCount=\(samples.count)")
        }
    }

    /// Log when a computed pace window jumps by more than 15 seconds from its previous value
    private func logPaceJumps(newFastPace: Pace?) {
        let newMediumPace = mediumPace
        let newSlowPace = slowPace

        logJump(label: "FAST", previous: previousFastPace, current: newFastPace)
        logJump(label: "MEDIUM", previous: previousMediumPace, current: newMediumPace)
        logJump(label: "SLOW", previous: previousSlowPace, current: newSlowPace)

        previousFastPace = newFastPace
        previousMediumPace = newMediumPace
        previousSlowPace = newSlowPace
    }

    private func logJump(label: String, previous: Pace?, current: Pace?) {
        guard let prev = previous, let curr = current else { return }
        let jump = abs(curr.totalSeconds - prev.totalSeconds)
        if jump >= 15 {
            print("PaceCalc.JUMP[\(label)]: \(prev.formatted) → \(curr.formatted) (±\(jump)s) sampleCount=\(samples.count)")
        }
    }

    private func formatSeconds(_ totalSeconds: Int) -> String {
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d", m, s)
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
