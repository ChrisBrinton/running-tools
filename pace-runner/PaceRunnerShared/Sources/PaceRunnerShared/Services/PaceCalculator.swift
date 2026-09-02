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

    /// All accepted observations, stamped in **moving time** (wall-clock minus
    /// accumulated paused time). Every window is a pure function over this one
    /// array — the time-based windows slice it by `timestamp`, the master window
    /// slices it by `cumulativeDistance`. There is no separate per-window state.
    private var samples: [GPSSample] = []
    /// Last accepted cumulative distance, in ADJUSTED terms (raw minus
    /// `distanceOffset`).
    private var lastAcceptedDistance: Double?
    /// Last accepted RAW cumulative distance as fed in — the anchor used to
    /// absorb the distance that accrues across a pause.
    private var lastAcceptedRawDistance: Double?
    /// Last accepted sample time, in moving-time coordinates.
    private var lastAcceptedTimestamp: Date?

    /// Total excluded time to subtract from incoming wall-clock timestamps so
    /// the sample stream is continuous in moving time. Incremented by
    /// `notePauseGap` (pauses) and by the invalid-speed guard in `addSample`
    /// (glitch spans are excised from both axes); this is the single source of
    /// truth for excluded-time accounting in the calculator.
    private var pauseOffset: TimeInterval = 0

    /// Total distance that accrued while paused, subtracted from incoming
    /// cumulative distance. Symmetric to `pauseOffset`: the time axis excludes
    /// paused time, so the distance axis must too, or the distance-based master
    /// window computes Δdistance-with-pause over Δtime-without-pause and reports
    /// a phantom fast pace until the pre-pause samples age out (~1 mile). The
    /// GPS path avoids the jump via `breakContinuity`, but the HealthKit path
    /// keeps counting distance through a pause, so this is the general guard.
    private var distanceOffset: Double = 0

    /// Set by `notePauseGap`; the next accepted sample re-anchors the distance
    /// axis (absorbs the pause's distance) exactly once.
    private var awaitingResumeRebase: Bool = false

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

    /// Moving-time span covered by the retained samples.
    ///
    /// Samples are stored in moving-time coordinates, so this excludes paused
    /// and excised-glitch time. Sample retention (20 min) is far longer than any
    /// configurable time window, so this is a valid "has the window filled?"
    /// signal for the windows themselves.
    public var movingTimeSpan: TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.timestamp.timeIntervalSince(first.timestamp)
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

        // First sample after a resume: absorb whatever distance accrued during
        // the pause so the internal distance axis stays continuous with the
        // pre-pause anchor. Done exactly once, before any delta is computed.
        if awaitingResumeRebase {
            if let anchorRaw = lastAcceptedRawDistance {
                distanceOffset += distance - anchorRaw
            }
            awaitingResumeRebase = false
        }

        // Convert to moving time + adjusted distance up front so everything
        // downstream (baseline, stored sample, window slicing) operates in a
        // single pause-excluded coordinate system on both axes.
        let movingTimestamp = timestamp.addingTimeInterval(-pauseOffset)
        let adjustedDistance = distance - distanceOffset

        // First sample: just record baseline, don't compute pace yet
        guard let previousDistance = lastAcceptedDistance,
              let previousTimestamp = lastAcceptedTimestamp else {
            lastAcceptedDistance = adjustedDistance
            lastAcceptedRawDistance = distance
            lastAcceptedTimestamp = movingTimestamp
            return
        }

        let deltaDistance = adjustedDistance - previousDistance
        let deltaTime = movingTimestamp.timeIntervalSince(previousTimestamp)

        // A sample stamped BEHIND the accepted baseline means the moving-time
        // mapping shifted underneath us — the classic case is samples that were
        // accepted DURING a pause (stamped before `notePauseGap` advanced the
        // offset), which leaves every post-resume sample ~pauseDuration in the
        // past. Rejecting them would freeze every window until wall clock
        // caught up (minutes). Instead, treat this sample as the authoritative
        // "now": excise the pause-era samples stamped ahead of it, erase their
        // distance from the adjusted axis (it was covered in zero moving time),
        // and re-anchor the baseline so the stream recovers on the next sample.
        if deltaTime < 0 {
            samples.removeAll { $0.timestamp > movingTimestamp }
            let retainedCumulative = samples.last?.cumulativeDistance ?? 0
            if adjustedDistance > retainedCumulative {
                distanceOffset += adjustedDistance - retainedCumulative
            }
            lastAcceptedDistance = distance - distanceOffset
            lastAcceptedRawDistance = distance
            lastAcceptedTimestamp = movingTimestamp
            return
        }

        // Only accept samples with meaningful deltas
        // IMPORTANT: Do NOT update lastAccepted* when rejecting — the next
        // accepted sample must compute speed from the last accepted baseline
        guard deltaDistance >= minimumDistanceDelta,
              deltaTime >= minimumTimeDelta else {
            return
        }

        let speed = deltaDistance / deltaTime
        let sample = GPSSample(timestamp: movingTimestamp, speed: speed, cumulativeDistance: adjustedDistance)
        guard sample.isValid else {
            // A physically impossible speed is a distance glitch (GPS jump or
            // a catch-up burst of HK samples). Excise the glitch span from
            // BOTH axes — its distance and its time — exactly like a pause:
            // simply returning would smear that distance into the next
            // accepted sample as a phantom-fast mega-delta (historically a
            // full minute of fast-window swing), while excising only the
            // distance would leave dead time that biases the windows slow.
            // The baselines stay put; the next sample lands contiguously.
            distanceOffset += deltaDistance
            pauseOffset += deltaTime
            lastAcceptedRawDistance = distance
            return
        }

        // Now update the accepted baseline
        lastAcceptedDistance = adjustedDistance
        lastAcceptedRawDistance = distance
        lastAcceptedTimestamp = movingTimestamp

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

        // Advance the moving-time offset by the paused interval. Every sample
        // that arrives after resume is stamped `wallClock - pauseOffset`, so it
        // lands contiguously with the pre-pause history already stored in
        // moving time — the break is squeezed out of the timeline. The existing
        // history is preserved as-is (the master window needs up to a full mile
        // of samples); nothing is rewritten. Contrast with the old approach,
        // which re-stamped the entire array on every resume (O(n), and mutated
        // already-committed samples).
        pauseOffset += pauseDuration

        // Re-anchor the distance axis on the next sample. We deliberately KEEP
        // lastAccepted* as the pre-pause anchor: the first post-resume sample
        // absorbs the pause's distance into `distanceOffset` (see addSample),
        // keeping both axes continuous so no phantom pace is produced.
        awaitingResumeRebase = true
    }

    public func reset() {
        samples.removeAll()
        lastAcceptedDistance = nil
        lastAcceptedRawDistance = nil
        lastAcceptedTimestamp = nil
        pauseOffset = 0
        distanceOffset = 0
        awaitingResumeRebase = false
        previousFastPace = nil
        previousMediumPace = nil
        previousSlowPace = nil
        paceSubject.send(nil)
    }

    // MARK: - Helpers

    private func purgeOldSamples() {
        // Keep samples for the longest window. The master (distance) window may
        // need up to ~1 mile of history (~15 min at 15:00/mile), so retain a
        // generous 20 minutes of MOVING time.
        //
        // Anchor the cutoff to the newest sample, not `Date()`: samples are
        // stamped in moving time, so wall-clock `Date()` drifts ahead of them by
        // the paused total and would purge too aggressively after a long break.
        // Anchoring to the newest sample also means a stall in updates can't
        // silently evict the whole history.
        guard let newest = samples.last?.timestamp else { return }
        let maxWindow: TimeInterval = 20 * 60 // 20 minutes
        let cutoff = newest.addingTimeInterval(-maxWindow)
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
