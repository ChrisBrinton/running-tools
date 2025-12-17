import Foundation
import HealthKit
import Combine
import PaceRunnerShared

/// Workout session orchestrator
///
/// Coordinates all services for workout execution:
/// - HealthKit: Workout session and sample recording
/// - GPSManager: Distance and location tracking
/// - PaceCalculator: Real-time pace smoothing
/// - AudioEngine: Tempo beats and voice alerts
///
/// Constitution compliance:
/// - <200ms GPS → UI: Direct state updates, no async transforms
/// - Non-blocking: All operations async, doesn't block UI
/// - Battery efficient: Coordinates services to minimize overhead
///
/// Reference: specs/001-pace-runner-mvp/plan.md (WorkoutManager service)
class WorkoutManager: NSObject, WorkoutManagerProtocol {

    // MARK: - Published Properties

    private let stateSubject = CurrentValueSubject<WorkoutState?, Never>(nil)
    var statePublisher: AnyPublisher<WorkoutState, Never> {
        stateSubject
            .compactMap { $0 }
            .eraseToAnyPublisher()
    }

    var currentState: WorkoutState? {
        stateSubject.value
    }

    // MARK: - Dependencies

    private let healthStore: HKHealthStore
    private let gpsManager: GPSManagerProtocol
    private let paceCalculator: PaceCalculatorProtocol
    private let audioEngine: AudioEngineProtocol
    private let mileTracker: MileTracker
    private let isHealthKitAvailable: Bool
    private let settingsProvider: () -> AppSettings

    // MARK: - Private Properties

    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var cancellables = Set<AnyCancellable>()

    private var startTime: Date?

    // Lock to prevent race conditions between location and pace updates
    private let stateLock = NSLock()

    // Flag to prevent multiple completion announcements
    private var hasAnnouncedCompletion = false

    // MARK: - Initialization

    init(
        healthStore: HKHealthStore = HKHealthStore(),
        gpsManager: GPSManagerProtocol,
        paceCalculator: PaceCalculatorProtocol,
        audioEngine: AudioEngineProtocol,
        mileTracker: MileTracker = MileTracker(),
        settingsProvider: @escaping () -> AppSettings = { AppSettings.load() }
    ) {
        self.healthStore = healthStore
        self.gpsManager = gpsManager
        self.paceCalculator = paceCalculator
        self.audioEngine = audioEngine
        self.mileTracker = mileTracker
        self.isHealthKitAvailable = HKHealthStore.isHealthDataAvailable()
        self.settingsProvider = settingsProvider

        super.init()
    }

    // MARK: - Workout Control

    func startWorkout(with configuration: RunConfiguration) throws {
        let settings = settingsProvider()

        // Create workout session only if NOT in companion mode
        // In companion mode, user starts workout via native Workout app
        var session: HKWorkoutSession?
        var builder: HKLiveWorkoutBuilder?

        if isHealthKitAvailable && !settings.companionMode {
            let workoutConfig = HKWorkoutConfiguration()
            workoutConfig.activityType = .running
            workoutConfig.locationType = .outdoor

            let createdSession = try HKWorkoutSession(
                healthStore: healthStore,
                configuration: workoutConfig
            )
            createdSession.delegate = self
            session = createdSession

            let createdBuilder = createdSession.associatedWorkoutBuilder()
            createdBuilder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: workoutConfig
            )
            createdBuilder.delegate = self
            builder = createdBuilder
        }

        workoutSession = session
        workoutBuilder = builder

        // Initialize state
        var state = WorkoutState(configuration: configuration)
        state.status = .running
        stateSubject.send(state)
        startTime = Date()

        // Setup services
        do {
            try audioEngine.setup()
            // Set volume from settings
            audioEngine.setMasterVolume(settings.masterVolume)
            audioEngine.setBeatVolume(settings.beatVolume)
        } catch {
            print("AudioEngine setup failed: \(error)")
        }
        mileTracker.reset()
        paceCalculator.reset()

        // Configure pace calculator windows from settings
        paceCalculator.configureWindows(
            fastSeconds: settings.fastAverageSeconds,
            mediumSeconds: settings.mediumAverageSeconds,
            slowMiles: settings.slowAverageMiles
        )

        // Subscribe to GPS updates
        subscribeToGPS()

        // Subscribe to pace updates
        subscribeToPace()

        // Start session
        if let session = session {
            session.startActivity(with: Date())
        }
        if let builder = builder {
            try builder.beginCollection(withStart: Date()) { success, error in
                if let error = error {
                    print("Failed to start workout builder: \(error)")
                }
            }
        }

        // Setup GPS filtering callback for debug sounds
        if settings.gpsFilterDebugSounds, let gps = gpsManager as? GPSManager {
            gps.onLocationFiltered = { [weak self] in
                self?.audioEngine.playDebugSound()
            }
            // Play 3 clicks at startup to confirm audio is working
            audioEngine.playDebugSoundsStartup()
        } else if let gps = gpsManager as? GPSManager {
            gps.onLocationFiltered = nil
        }

        // Start GPS tracking
        gpsManager.startTracking()

        // Start tempo beats at effective BPM (calculated from stride + offset)
        do {
            let effectiveBPM = configuration.effectiveBPM(settings: settings)
            // Configure emphasis beat settings before starting
            audioEngine.configureEmphasisBeat(
                enabled: settings.emphasisBeatEnabled,
                interval: settings.emphasisBeatInterval,
                audioBeatsEnabled: settings.audioBeatsEnabled
            )
            try audioEngine.startTempoBeats(bpm: effectiveBPM)
            // Start silent during grace period (will turn on when grace period ends)
            audioEngine.setMetronomeVolume(0.0)
        } catch {
            print("AudioEngine failed to start tempo beats: \(error)")
        }
    }

    func pauseWorkout() throws {
        guard var state = stateSubject.value else {
            throw WorkoutManagerError.noActiveWorkout
        }

        workoutSession?.pause()
        gpsManager.stopTracking()
        audioEngine.stopTempoBeats()

        state.status = .paused
        stateSubject.send(state)
    }

    func resumeWorkout() throws {
        guard var state = stateSubject.value else {
            throw WorkoutManagerError.noActiveWorkout
        }

        workoutSession?.resume()
        gpsManager.startTracking()
        let effectiveBPM = state.configuration.effectiveBPM(settings: settingsProvider())
        try audioEngine.startTempoBeats(bpm: effectiveBPM)

        // Set metronome volume based on grace period status
        // If grace period is over, turn on full volume; otherwise stay silent
        if state.isInGracePeriod {
            audioEngine.setMetronomeVolume(0.0)
        } else {
            audioEngine.setMetronomeVolume(1.0)
        }

        state.status = .running
        stateSubject.send(state)
    }

    func endWorkout() throws -> WorkoutSummary {
        guard var state = currentState else {
            throw WorkoutManagerError.noActiveWorkout
        }

        // Stop services
        gpsManager.stopTracking()
        audioEngine.stopTempoBeats()
        audioEngine.teardown()
        mileTracker.reset()

        // End session
        workoutSession?.end()

        workoutBuilder?.endCollection(withEnd: Date()) { _, error in
            if let error = error {
                print("Failed to end workout builder: \(error)")
            }
        }

        workoutBuilder?.finishWorkout { _, error in
            if let error = error {
                print("Failed to finish workout: \(error)")
            }
        }

        // Update state to ended
        state.status = .ended
        stateSubject.send(state)

        // Create summary
        let summary = state.toSummary()

        // Cleanup
        cleanup()

        return summary
    }

    func cancelWorkout() {
        // Stop services without saving
        gpsManager.stopTracking()
        audioEngine.stopTempoBeats()
        mileTracker.reset()
        audioEngine.teardown()

        // Discard session
        workoutSession?.end()

        // Cleanup
        cleanup()
        stateSubject.send(nil)
    }

    // MARK: - GPS Subscription

    private func subscribeToGPS() {
        gpsManager.locationPublisher
            .sink { [weak self] location in
                self?.handleLocationUpdate()
            }
            .store(in: &cancellables)
    }

    private func handleLocationUpdate() {
        // Get data outside lock to avoid deadlock
        // Apply pace calibration factor to GPS distance
        let rawDistance = gpsManager.totalDistance
        let calibrationFactor = settingsProvider().distanceCalibrationFactor()
        let distance = rawDistance * calibrationFactor
        let timestamp = Date()

        // Add sample to pace calculator BEFORE acquiring lock
        // (addSample triggers pacePublisher which calls handlePaceUpdate)
        paceCalculator.addSample(distance: distance, timestamp: timestamp)

        // Now synchronize state updates
        var shouldAutoEnd = false
        stateLock.lock()

        guard var state = stateSubject.value,
              state.status == .running else {
            stateLock.unlock()
            return
        }

        // Update state
        let elapsedTime = timestamp.timeIntervalSince(startTime ?? timestamp)
        state.distanceCovered = distance
        state.elapsedTime = elapsedTime

        // Update mile tracker
        handleMileTracking(state: &state, distance: distance)

        // Check for auto-end when distance is reached
        if state.progress >= 1.0 && state.configuration.autoEndRun && !hasAnnouncedCompletion {
            shouldAutoEnd = true
            hasAnnouncedCompletion = true
        }

        // Publish updated state
        stateSubject.send(state)
        stateLock.unlock()

        // Handle auto-end outside the lock to avoid deadlock
        if shouldAutoEnd {
            handleAutoEnd()
        }
    }

    // MARK: - Pace Subscription

    private func subscribeToPace() {
        paceCalculator.pacePublisher
            .sink { [weak self] pace in
                self?.handlePaceUpdate(pace)
            }
            .store(in: &cancellables)
    }

    private func handlePaceUpdate(_ pace: Pace?) {
        // Synchronize state updates to prevent race conditions
        stateLock.lock()
        defer { stateLock.unlock() }

        guard var state = stateSubject.value,
              state.status == .running else {
            return
        }

        state.currentPace = pace

        // Update pace windows using new Fast/Medium/Slow naming
        let lastMilePace = state.mileSplits.last?.actualPace
        state.paceWindows = PaceWindows(
            slowPace: paceCalculator.slowPace,      // Master pace (distance-based)
            mediumPace: paceCalculator.mediumPace,  // Medium rolling avg
            fastPace: paceCalculator.fastPace,      // Fast rolling avg
            lastMilePace: lastMilePace
        )

        // Grace period handling
        handleGracePeriod(state: &state, pace: pace)

        // Update metronome volume and alerts based on pace deviation
        if state.isInGracePeriod {
            // During grace period - always silent, no alerts
            audioEngine.setMetronomeVolume(0.0)
        } else {
            // Metronome always on at full volume (beatVolume from settings controls gain)
            audioEngine.setMetronomeVolume(1.0)

            // Generate voice alert based on cascading pace windows
            // Priority: split (urgent) > 3min (medium) > 1min (minor)
            if let message = cascadingVoiceAlert(
                paceWindows: state.paceWindows,
                targetPace: state.targetPace,
                tolerance: state.configuration.paceTolerance
            ) {
                audioEngine.playVoiceAlert(message)
            }
        }

        stateSubject.send(state)
    }

    private func handleGracePeriod(state: inout WorkoutState, pace: Pace?) {
        guard state.isInGracePeriod else { return }

        // Check if movement has started (pace indicates speed > threshold)
        if state.gracePeriodStartTime == nil, let pace = pace {
            // Pace exists means we're moving - calculate speed from pace
            // At 20:00 min/mile (very slow), speed is ~0.8 m/s
            let speedMps = 1609.34 / Double(pace.totalSeconds)
            if speedMps >= WorkoutState.movementThreshold {
                state.gracePeriodStartTime = Date()
                print("WorkoutManager: Movement detected, grace period started")
            }
        }

        // Check if grace period has expired
        if state.isGracePeriodExpired {
            state.isInGracePeriod = false
            print("WorkoutManager: Grace period ended, alerts enabled")
        }
    }

    // MARK: - Auto End

    private func handleAutoEnd() {
        guard let state = currentState else { return }

        // Calculate final split pace and average pace
        let finalSplitPace = state.splitPace?.formatted ?? "unknown"

        // Calculate average pace for entire workout
        let avgPace: String
        if state.distanceCovered > 0 && state.elapsedTime > 0 {
            let secondsPerMeter = state.elapsedTime / state.distanceCovered
            if let pace = Pace(secondsPerMeter: secondsPerMeter) {
                avgPace = pace.formatted
            } else {
                avgPace = "unknown"
            }
        } else {
            avgPace = "unknown"
        }

        // Announce completion with paces (important - bypasses throttle, queues if speaking)
        let announcement = "Workout complete. Split pace \(finalSplitPace). Average pace \(avgPace)"
        audioEngine.playImportantAlert(announcement)

        // End the workout after a delay to let the announcement play
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            do {
                _ = try self?.endWorkout()
            } catch {
                print("WorkoutManager: Failed to auto-end workout: \(error)")
            }
        }
    }

    // MARK: - Voice Alert Helpers

    /// Generates cascading voice alert based on pace window hierarchy with smart filtering
    ///
    /// Hierarchy (slow → medium → fast):
    /// - Slow (master) out of tolerance → "Speed up" / "Slow down" (urgent)
    /// - Slow in tolerance, medium out → "Speed up some" / "Slow down some" (medium)
    /// - Slow & medium in tolerance, fast out → "Speed up a little" / "Slow down a little" (minor)
    ///
    /// Smart filtering:
    /// - If master pace is FASTER than target → skip all "speed up" cues (you're ahead)
    /// - If master pace is SLOWER than target → skip all "slow down" cues (you're behind)
    /// - If fast pace is faster/on-target (cyan/magenta) → skip "speed up" cues
    /// - If fast pace is slower/on-target (yellow/red) → skip "slow down" cues
    ///
    /// - Parameters:
    ///   - paceWindows: Current pace windows with slow/medium/fast paces
    ///   - targetPace: Target pace for current mile
    ///   - tolerance: Pace tolerance in seconds
    /// - Returns: Appropriate voice message, or nil if filtered or all in tolerance
    private func cascadingVoiceAlert(
        paceWindows: PaceWindows,
        targetPace: Pace,
        tolerance: Int
    ) -> String? {
        // Helper to check if a pace is out of tolerance and get direction
        func checkDeviation(_ pace: Pace?) -> (isOut: Bool, isSpeedUp: Bool)? {
            guard let pace = pace else { return nil }
            let deviation = pace.totalSeconds - targetPace.totalSeconds
            let isOut = abs(deviation) > tolerance
            let isSpeedUp = deviation > 0  // Positive deviation = too slow = need to speed up
            return (isOut, isSpeedUp)
        }

        // Determine filtering based on master (slow) pace
        let masterFaster = paceWindows.isMasterFasterThanTarget(targetPace)
        let masterSlower = paceWindows.isMasterSlowerThanTarget(targetPace)

        // Determine filtering based on fast pace
        let fastFaster = paceWindows.isFastPaceFasterThanTarget(targetPace, tolerance: tolerance)
        let fastSlower = paceWindows.isFastPaceSlowerThanTarget(targetPace, tolerance: tolerance)

        // Helper to apply filtering and return message
        func filteredMessage(isSpeedUp: Bool, urgency: String) -> String? {
            let direction = isSpeedUp ? "Speed up" : "Slow down"
            let message = urgency.isEmpty ? direction : "\(direction) \(urgency)"

            // Filter based on master pace direction
            if masterFaster && isSpeedUp {
                // Master is fast, skip "speed up" (you're already ahead)
                return nil
            }
            if masterSlower && !isSpeedUp {
                // Master is slow, skip "slow down" (you're already behind)
                return nil
            }

            // Filter based on fast pace direction
            if fastFaster && isSpeedUp {
                // Fast pace shows you're running fast, skip "speed up"
                return nil
            }
            if fastSlower && !isSpeedUp {
                // Fast pace shows you're running slow, skip "slow down"
                return nil
            }

            return message
        }

        // Check slow (master) pace first
        if let slowCheck = checkDeviation(paceWindows.slowPace), slowCheck.isOut {
            return filteredMessage(isSpeedUp: slowCheck.isSpeedUp, urgency: "")
        }

        // Slow is in tolerance, check medium pace
        if let mediumCheck = checkDeviation(paceWindows.mediumPace), mediumCheck.isOut {
            return filteredMessage(isSpeedUp: mediumCheck.isSpeedUp, urgency: "some")
        }

        // Slow and medium in tolerance, check fast pace
        if let fastCheck = checkDeviation(paceWindows.fastPace), fastCheck.isOut {
            return filteredMessage(isSpeedUp: fastCheck.isSpeedUp, urgency: "a little")
        }

        // All in tolerance - no alert
        return nil
    }

    // MARK: - Mile Markers

    private func handleMileTracking(state: inout WorkoutState, distance: Double) {
        if let completedMile = mileTracker.updateDistance(distance), completedMile > 0 {
            // Get split pace (should always exist when completing a mile)
            let splitPace = state.splitPace

            if let pace = splitPace {
                // Record the split for the completed mile
                let split = MileSplit(
                    mileNumber: completedMile,
                    actualPace: pace,
                    targetPace: state.targetPace,
                    distance: Distance(miles: 1.0)
                )
                state.recordMileSplit(split)

                // Announce mile completion with pace if enabled (important - bypasses throttle)
                let settings = settingsProvider()
                if settings.announceMileMarkers {
                    let paceFormatted = pace.formatted
                    audioEngine.playImportantAlert("Mile \(completedMile) complete. Pace \(paceFormatted)")
                }
            } else {
                // Fallback: announce without pace if splitPace calculation failed
                print("WorkoutManager: Warning - splitPace was nil at mile \(completedMile)")
                let settings = settingsProvider()
                if settings.announceMileMarkers {
                    audioEngine.playImportantAlert("Mile \(completedMile) complete")
                }
            }

            // Reset split tracking for next mile
            state.currentMileSplitStart = distance
            state.currentMileSplitStartTime = state.elapsedTime
        }

        state.currentMile = mileTracker.mileIndex + 1
    }

    // MARK: - Cleanup

    private func cleanup() {
        cancellables.removeAll()
        workoutSession = nil
        workoutBuilder = nil
        startTime = nil
        mileTracker.reset()
        hasAnnouncedCompletion = false

        paceCalculator.reset()
        gpsManager.resetDistance()
    }

    // MARK: - Errors

    enum WorkoutManagerError: Error {
        case noActiveWorkout
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {

    func workoutSession(_ workoutSession: HKWorkoutSession,
                       didChangeTo toState: HKWorkoutSessionState,
                       from fromState: HKWorkoutSessionState,
                       date: Date) {
        // Handle session state changes
        switch toState {
        case .running:
            if var state = stateSubject.value {
                state.status = .running
                stateSubject.send(state)
            }

        case .paused:
            if var state = stateSubject.value {
                state.status = .paused
                stateSubject.send(state)
            }

        case .ended:
            // CRITICAL: Stop ALL audio when session ends (for any reason)
            // This includes when another app (like native Workout) takes over
            audioEngine.stopTempoBeats()
            audioEngine.teardown()
            gpsManager.stopTracking()

            if var state = stateSubject.value {
                state.status = .ended
                stateSubject.send(state)
            }

        default:
            break
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession,
                       didFailWithError error: Error) {
        print("Workout session failed: \(error)")

        // CRITICAL: Stop ALL audio on failure
        audioEngine.stopTempoBeats()
        audioEngine.teardown()
        gpsManager.stopTracking()

        if var state = stateSubject.value {
            state.status = .ended
            stateSubject.send(state)
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                       didCollectDataOf collectedTypes: Set<HKSampleType>) {
        // HealthKit collected samples (heart rate, etc.)
        // We handle distance via GPS, so nothing to do here for MVP
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Workout events collected (pause, resume, etc.)
    }
}
