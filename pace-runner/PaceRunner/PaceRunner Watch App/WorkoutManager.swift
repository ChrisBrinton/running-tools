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

    /// Whether to use HealthKit distance vs GPS distance
    private var useHealthKitDistance: Bool = false

    /// Anchored query for HealthKit distance samples (used in companion mode)
    private var distanceQuery: HKAnchoredObjectQuery?

    /// Accumulated distance from HealthKit samples (meters)
    private var healthKitAccumulatedDistance: Double = 0

    /// Anchor for tracking which samples we've already processed
    private var distanceQueryAnchor: HKQueryAnchor?

    /// Lock for thread-safe access to healthKitAccumulatedDistance
    private let healthKitDistanceLock = NSLock()

    /// Whether we've synced our start time with HealthKit's first sample
    /// In companion mode, we wait for the first sample to establish the "real" start time
    private var hasHealthKitStartTimeSync: Bool = false

    /// The effective start time (may be adjusted when first HealthKit sample arrives)
    private var startTime: Date?

    /// The user's tap time (when they pressed Start in PaceRunner)
    private var userTapTime: Date?

    /// Total time spent paused (seconds) - excluded from elapsed time calculation
    private var totalPausedDuration: TimeInterval = 0

    /// When the current pause started (nil if not paused)
    private var pauseStartTime: Date?

    /// Query for finding active workouts in companion mode
    private var activeWorkoutQuery: HKSampleQuery?

    /// Timer for periodic recheck of active workouts (in case Workout app starts after PaceRunner)
    private var workoutRecheckTimer: Timer?

    /// Number of workout rechecks performed
    private var workoutRecheckCount: Int = 0

    /// Maximum number of rechecks to perform
    private let maxWorkoutRechecks = 3

    // Lock to prevent race conditions between location and pace updates
    private let stateLock = NSLock()

    // Flag to prevent multiple completion announcements
    private var hasAnnouncedCompletion = false

    /// Debug log for capturing timing and sync events
    private var debugLog = DebugLog()

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

        // Initialize fresh debug log for this workout
        debugLog = DebugLog()
        debugLog.logTiming("Workout started", data: [
            "config": configuration.name,
            "targetDistance": String(format: "%.2f", configuration.distance.miles),
            "companionMode": String(settings.companionMode),
            "useHealthKitDistance": String(settings.useHealthKitDistance),
            "paceCalibrationSeconds": String(settings.paceCalibrationSeconds),
            "calibrationFactor": String(format: "%.4f", settings.distanceCalibrationFactor())
        ])

        // Debug: log calibration settings at workout start
        print("WorkoutManager.startWorkout: paceCalibrationSeconds=\(settings.paceCalibrationSeconds)")
        print("WorkoutManager.startWorkout: distanceCalibrationFactor=\(settings.distanceCalibrationFactor())")
        print("WorkoutManager.startWorkout: strideLengthInches=\(settings.strideLengthInches)")

        // Set distance source based on settings
        // Use HealthKit distance in both modes when setting is enabled
        useHealthKitDistance = settings.useHealthKitDistance
        print("WorkoutManager.startWorkout: useHealthKitDistance=\(useHealthKitDistance), companionMode=\(settings.companionMode)")

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

        // Record when user tapped start
        userTapTime = Date()

        // In companion mode with HealthKit distance, we'll sync start time with first sample
        // This ensures our timing matches the Workout app's timing
        let isCompanionWithHealthKit = settings.companionMode && useHealthKitDistance
        hasHealthKitStartTimeSync = !isCompanionWithHealthKit  // Already synced if not using companion+HK

        // Use tap time initially; will be adjusted when first HealthKit sample arrives in companion mode
        startTime = userTapTime
        print("WorkoutManager: userTapTime=\(userTapTime!), isCompanionWithHealthKit=\(isCompanionWithHealthKit)")

        // Log tap time for debug
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        debugLog.logTiming("User tapped Start", data: [
            "tapTime": dateFormatter.string(from: userTapTime!),
            "needsHealthKitSync": String(isCompanionWithHealthKit)
        ])

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

        // Start HealthKit distance query if enabled
        // In companion mode, this queries samples from the Workout app
        // In standalone mode, this queries samples from our own workout session
        if useHealthKitDistance && isHealthKitAvailable {
            startHealthKitDistanceQuery()

            // In companion mode, start periodic rechecks for workouts that might start after PaceRunner
            // This handles the case where user starts PaceRunner during Workout app's countdown
            if settings.companionMode {
                startWorkoutRecheckTimer()
            }
        }

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
            // Start metronome immediately at full volume
            audioEngine.setMetronomeVolume(1.0)
        } catch {
            print("AudioEngine failed to start tempo beats: \(error)")
        }
    }

    func pauseWorkout() throws {
        guard var state = stateSubject.value else {
            throw WorkoutManagerError.noActiveWorkout
        }

        // Record when pause started
        pauseStartTime = Date()
        print("WorkoutManager: Paused at \(pauseStartTime!)")

        // Log pause event
        debugLog.logPause("Workout paused", data: [
            "elapsedTime": String(format: "%.1f", state.elapsedTime),
            "distance": String(format: "%.3f", state.distanceCovered / 1609.34)
        ])

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

        // Calculate how long we were paused and add to total
        if let pauseStart = pauseStartTime {
            let pauseDuration = Date().timeIntervalSince(pauseStart)
            totalPausedDuration += pauseDuration
            print("WorkoutManager: Resumed after \(String(format: "%.1f", pauseDuration))s pause, total paused: \(String(format: "%.1f", totalPausedDuration))s")

            // Log resume event
            debugLog.logPause("Workout resumed", data: [
                "pauseDuration": String(format: "%.1f", pauseDuration),
                "totalPausedDuration": String(format: "%.1f", totalPausedDuration)
            ])
        }
        pauseStartTime = nil

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

        // Log workout end
        debugLog.logTiming("Workout ended", data: [
            "elapsedTime": String(format: "%.1f", state.elapsedTime),
            "totalDistance": String(format: "%.4f", state.distanceCovered / 1609.34),
            "totalPausedDuration": String(format: "%.1f", totalPausedDuration),
            "milesCompleted": String(state.mileSplits.count)
        ])

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

        // Create summary with debug log
        let summary = state.toSummary(debugLog: debugLog)

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

    // MARK: - HealthKit Distance Query

    /// Starts an anchored object query to receive real-time distance samples from HealthKit
    /// Works in both standalone mode (our own workout) and companion mode (Workout app's samples)
    private func startHealthKitDistanceQuery() {
        let distanceType = HKQuantityType(.distanceWalkingRunning)

        // Reset accumulated distance
        healthKitDistanceLock.lock()
        healthKitAccumulatedDistance = 0
        healthKitDistanceLock.unlock()

        // Create predicate for samples from workout start time onwards
        let predicate = HKQuery.predicateForSamples(
            withStart: startTime ?? Date(),
            end: nil,
            options: .strictStartDate
        )

        let query = HKAnchoredObjectQuery(
            type: distanceType,
            predicate: predicate,
            anchor: distanceQueryAnchor,
            limit: HKObjectQueryNoLimit
        ) { [weak self] query, samples, deletedObjects, newAnchor, error in
            self?.processDistanceSamples(samples, newAnchor: newAnchor, error: error)
        }

        // Set update handler to receive new samples as they arrive
        query.updateHandler = { [weak self] query, samples, deletedObjects, newAnchor, error in
            self?.processDistanceSamples(samples, newAnchor: newAnchor, error: error)
        }

        distanceQuery = query
        healthStore.execute(query)
        print("WorkoutManager: Started HealthKit distance query")
    }

    /// Processes distance samples from HealthKit query
    private func processDistanceSamples(_ samples: [HKSample]?, newAnchor: HKQueryAnchor?, error: Error?) {
        if let error = error {
            print("WorkoutManager: HealthKit distance query error: \(error)")
            return
        }

        // Update anchor for next query
        distanceQueryAnchor = newAnchor

        guard let quantitySamples = samples as? [HKQuantitySample], !quantitySamples.isEmpty else {
            return
        }

        // On first sample, sync our start time with the Workout app's timing
        if !hasHealthKitStartTimeSync {
            syncStartTimeWithHealthKit(samples: quantitySamples)
        }

        // Sum up the distance from new samples
        var newDistance: Double = 0
        for sample in quantitySamples {
            let meters = sample.quantity.doubleValue(for: .meter())
            newDistance += meters
        }

        // Update accumulated distance thread-safely
        healthKitDistanceLock.lock()
        healthKitAccumulatedDistance += newDistance
        let totalDistance = healthKitAccumulatedDistance
        healthKitDistanceLock.unlock()

        print("WorkoutManager: HealthKit distance update: +\(String(format: "%.1f", newDistance))m, total=\(String(format: "%.1f", totalDistance))m")
    }

    /// Syncs our start time with the first HealthKit sample's timestamp
    /// This ensures our elapsed time matches the Workout app when in companion mode
    private func syncStartTimeWithHealthKit(samples: [HKQuantitySample]) {
        // First, try to find the active workout and use its start time (more accurate)
        queryActiveWorkoutStartTime { [weak self] workoutStartTime in
            guard let self = self else { return }

            let syncTime: Date
            if let workoutStart = workoutStartTime {
                // Use the actual workout start time
                syncTime = workoutStart
                print("WorkoutManager: Using active workout start time")
            } else {
                // Fall back to first sample's start date
                let earliestSample = samples.min(by: { $0.startDate < $1.startDate })
                guard let firstSampleTime = earliestSample?.startDate else { return }
                syncTime = firstSampleTime
                print("WorkoutManager: Using first sample start time (no active workout found)")
            }

            self.applyStartTimeSync(syncTime)
        }
    }

    /// Queries HealthKit for an active running workout to get its start time
    private func queryActiveWorkoutStartTime(completion: @escaping (Date?) -> Void) {
        let workoutType = HKObjectType.workoutType()

        // Look for workouts that started recently (within last 5 minutes of our tap time)
        let fiveMinutesAgo = (userTapTime ?? Date()).addingTimeInterval(-300)
        let predicate = HKQuery.predicateForSamples(
            withStart: fiveMinutesAgo,
            end: nil,
            options: .strictStartDate
        )

        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        let query = HKSampleQuery(
            sampleType: workoutType,
            predicate: predicate,
            limit: 5,
            sortDescriptors: [sortDescriptor]
        ) { [weak self] _, samples, error in
            if let error = error {
                print("WorkoutManager: Active workout query error: \(error)")
                completion(nil)
                return
            }

            // Find a running workout that's still in progress (no end date or end date in future)
            if let workouts = samples as? [HKWorkout] {
                for workout in workouts {
                    // Check if it's a running workout that's still in progress
                    // A workout is "in progress" if its end date is very close to now (within 30 seconds)
                    // or if the duration suggests it's still running
                    if workout.workoutActivityType == .running {
                        let timeSinceEnd = Date().timeIntervalSince(workout.endDate)
                        // If the workout ended less than 30 seconds ago, consider it still active
                        // (HealthKit may update endDate as workout progresses)
                        if timeSinceEnd < 30 {
                            print("WorkoutManager: Found active workout starting at \(workout.startDate)")
                            completion(workout.startDate)
                            return
                        }
                    }
                }
            }

            print("WorkoutManager: No active running workout found")
            completion(nil)
        }

        activeWorkoutQuery = query
        healthStore.execute(query)
    }

    /// Applies the synced start time
    private func applyStartTimeSync(_ syncTime: Date) {
        let oldStartTime = startTime ?? Date()
        let timeDiff = syncTime.timeIntervalSince(oldStartTime)

        print("WorkoutManager: Syncing start time with HealthKit")
        print("  - User tap time: \(userTapTime ?? Date())")
        print("  - Sync time: \(syncTime)")
        print("  - Time difference: \(String(format: "%.1f", timeDiff))s")

        // Log sync event
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        debugLog.logSync("Start time synced", data: [
            "oldStartTime": dateFormatter.string(from: oldStartTime),
            "newStartTime": dateFormatter.string(from: syncTime),
            "timeDiffSeconds": String(format: "%.3f", timeDiff),
            "userTapTime": dateFormatter.string(from: userTapTime ?? Date())
        ])

        // Update start time to match HealthKit
        startTime = syncTime

        // Reset pace calculator so it starts fresh from the synced time
        paceCalculator.reset()

        // Reset mile tracker
        mileTracker.reset()

        hasHealthKitStartTimeSync = true
        print("WorkoutManager: Start time synced to HealthKit workout")
    }

    /// Stops the HealthKit distance query
    private func stopHealthKitDistanceQuery() {
        if let query = distanceQuery {
            healthStore.stop(query)
            distanceQuery = nil
            print("WorkoutManager: Stopped HealthKit distance query")
        }
    }

    // MARK: - Workout Recheck Timer

    /// Starts a timer to periodically check for active workouts that might start after PaceRunner
    /// Fires at 5s intervals, up to 3 times (checking at 5s, 10s, 15s)
    private func startWorkoutRecheckTimer() {
        workoutRecheckCount = 0
        print("WorkoutManager: Starting workout recheck timer (will check at 5s, 10s, 15s)")

        // Run on main thread for timer
        DispatchQueue.main.async { [weak self] in
            self?.workoutRecheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.performWorkoutRecheck()
            }
        }
    }

    /// Stops the workout recheck timer
    private func stopWorkoutRecheckTimer() {
        workoutRecheckTimer?.invalidate()
        workoutRecheckTimer = nil
    }

    /// Performs a recheck for active workouts that might have started after PaceRunner
    private func performWorkoutRecheck() {
        workoutRecheckCount += 1
        print("WorkoutManager: Performing workout recheck #\(workoutRecheckCount)")

        // Stop if we've done enough rechecks
        if workoutRecheckCount >= maxWorkoutRechecks {
            print("WorkoutManager: Max rechecks reached, stopping timer")
            stopWorkoutRecheckTimer()
            return
        }

        // Query for active workouts
        queryActiveWorkoutStartTime { [weak self] workoutStartTime in
            guard let self = self,
                  let workoutStart = workoutStartTime,
                  let currentStartTime = self.startTime,
                  let tapTime = self.userTapTime else {
                return
            }

            // Check if this workout started AFTER our current sync time
            // but still within a reasonable window of when the user tapped start (20 seconds)
            let workoutStartedAfterSync = workoutStart > currentStartTime
            let workoutWithinWindow = workoutStart.timeIntervalSince(tapTime) < 20

            if workoutStartedAfterSync && workoutWithinWindow {
                print("WorkoutManager: Found newer workout that started after PaceRunner")
                print("  - Current sync time: \(currentStartTime)")
                print("  - New workout start: \(workoutStart)")
                self.applyStartTimeSync(workoutStart)

                // Found a good match, stop rechecking
                DispatchQueue.main.async {
                    self.stopWorkoutRecheckTimer()
                }
            }
        }
    }

    /// Gets HealthKit distance - from workout builder (standalone) or accumulated samples (companion)
    private func getHealthKitDistance() -> Double? {
        // First try workout builder (standalone mode)
        if let builder = workoutBuilder {
            let distanceType = HKQuantityType(.distanceWalkingRunning)
            if let statistics = builder.statistics(for: distanceType),
               let sum = statistics.sumQuantity() {
                return sum.doubleValue(for: .meter())
            }
        }

        // Fall back to accumulated samples from query (companion mode)
        healthKitDistanceLock.lock()
        let distance = healthKitAccumulatedDistance
        healthKitDistanceLock.unlock()

        // Return nil if no distance accumulated yet
        return distance > 0 ? distance : nil
    }

    private func handleLocationUpdate() {
        // Get data outside lock to avoid deadlock
        let settings = settingsProvider()
        let timestamp = Date()

        // Choose distance source based on settings
        let rawDistance: Double
        let distanceSource: String

        if useHealthKitDistance, let hkDistance = getHealthKitDistance() {
            // Use HealthKit distance (matches Apple Workout app)
            rawDistance = hkDistance
            distanceSource = "HealthKit"
        } else {
            // Use GPS distance with our own calculation
            rawDistance = gpsManager.totalDistance
            distanceSource = "GPS"
        }

        // Apply pace calibration factor
        let calibrationFactor = settings.distanceCalibrationFactor()
        let distance = rawDistance * calibrationFactor

        // Debug logging for calibration (log every ~0.1 miles)
        let rawMiles = rawDistance / 1609.34
        if Int(rawMiles * 10) % 10 == 0 && Int(rawMiles * 10) > 0 {
            let calibratedMiles = distance / 1609.34
            print("WorkoutManager.calibration: source=\(distanceSource), paceCalibrationSeconds=\(settings.paceCalibrationSeconds), factor=\(calibrationFactor)")
            print("WorkoutManager.calibration: rawMiles=\(String(format: "%.3f", rawMiles)), calibratedMiles=\(String(format: "%.3f", calibratedMiles))")
        }

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

        // Update state - subtract paused time from elapsed time
        let rawElapsedTime = timestamp.timeIntervalSince(startTime ?? timestamp)
        let elapsedTime = rawElapsedTime - totalPausedDuration
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

        // Metronome always on at full volume (beatVolume from settings controls gain)
        // Beats play from workout start, voice alerts wait for grace period to end
        audioEngine.setMetronomeVolume(1.0)

        // Voice alerts only after:
        // 1. Grace period ends
        // 2. Medium pace average has filled up (enough data for reliable alerts)
        let settings = settingsProvider()
        let mediumAverageFilled = state.elapsedTime >= Double(settings.mediumAverageSeconds)

        if !state.isInGracePeriod && mediumAverageFilled {
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

                // Log mile completion for debug
                debugLog.logMile("Mile \(completedMile) complete", data: [
                    "mileNumber": String(completedMile),
                    "splitPace": pace.formatted,
                    "targetPace": state.targetPace.formatted,
                    "elapsedTime": String(format: "%.1f", state.elapsedTime),
                    "totalDistance": String(format: "%.4f", distance / 1609.34)
                ])

                // Announce mile completion with pace if enabled (important - bypasses throttle)
                let settings = settingsProvider()
                if settings.announceMileMarkers {
                    let paceFormatted = pace.formatted
                    audioEngine.playImportantAlert("Mile \(completedMile) complete. Pace \(paceFormatted)")
                }
            } else {
                // Fallback: announce without pace if splitPace calculation failed
                print("WorkoutManager: Warning - splitPace was nil at mile \(completedMile)")

                // Log mile completion without pace
                debugLog.logMile("Mile \(completedMile) complete (no pace)", data: [
                    "mileNumber": String(completedMile),
                    "elapsedTime": String(format: "%.1f", state.elapsedTime),
                    "totalDistance": String(format: "%.4f", distance / 1609.34)
                ])

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
        userTapTime = nil
        mileTracker.reset()
        hasAnnouncedCompletion = false
        useHealthKitDistance = false
        hasHealthKitStartTimeSync = false

        // Reset pause tracking
        totalPausedDuration = 0
        pauseStartTime = nil

        // Stop workout recheck timer
        stopWorkoutRecheckTimer()
        workoutRecheckCount = 0

        // Stop HealthKit queries and reset accumulated distance
        stopHealthKitDistanceQuery()
        if let query = activeWorkoutQuery {
            healthStore.stop(query)
            activeWorkoutQuery = nil
        }
        healthKitDistanceLock.lock()
        healthKitAccumulatedDistance = 0
        distanceQueryAnchor = nil
        healthKitDistanceLock.unlock()

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
