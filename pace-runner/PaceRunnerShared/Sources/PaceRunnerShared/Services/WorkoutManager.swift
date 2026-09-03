import Foundation
import HealthKit
import Combine

/// Workout session orchestrator
///
/// Coordinates all services for workout execution:
/// - HealthKit: Workout session (watchOS only) and authorization
/// - GPSManager: Distance and location tracking
/// - PaceCalculator: Real-time pace smoothing
/// - AudioEngine: Tempo beats and voice alerts
///
/// Platform notes:
/// - watchOS: Uses HKWorkoutSession to keep app alive during workouts.
///   Supports companion mode (running alongside native Workout app).
/// - iOS: No HKWorkoutSession — relies on background location/audio modes.
///   Companion mode is not applicable on iOS.
///
/// Constitution compliance:
/// - <200ms GPS → UI: Direct state updates, no async transforms
/// - Non-blocking: All operations async, doesn't block UI
/// - Battery efficient: Coordinates services to minimize overhead
public final class WorkoutManager: NSObject, WorkoutManagerProtocol {

    // MARK: - Published Properties

    private let stateSubject = CurrentValueSubject<WorkoutState?, Never>(nil)
    public var statePublisher: AnyPublisher<WorkoutState, Never> {
        stateSubject
            .compactMap { $0 }
            .eraseToAnyPublisher()
    }

    public var currentState: WorkoutState? {
        stateSubject.value
    }

    // MARK: - Dependencies

    private let healthStore: HKHealthStore
    private let gpsManager: GPSManagerProtocol
    private let paceCalculator: PaceCalculatorProtocol
    private let audioEngine: AudioEngineProtocol
    private let mileTracker: MileTracker
    private let isHealthKitAvailable: Bool
    private let altimeter = BarometricAltimeter()
    private let settingsProvider: () -> AppSettings

    // MARK: - Private Properties

    #if os(watchOS)
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    #endif
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

    /// Anchored query for HealthKit heart rate samples
    private var heartRateQuery: HKAnchoredObjectQuery?

    /// Current heart rate in BPM (0 = no data yet)
    private var currentHeartRate: Double = 0

    /// Heart rate samples collected during the current mile (for averaging per split)
    private var currentMileHeartRateSamples: [Double] = []

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
    /// Written under `healthKitDistanceLock` so the HealthKit sample callback
    /// (background queue) can read a consistent value.
    private var pauseStartTime: Date?

    /// Closed pause intervals for this workout. The HealthKit anchored query
    /// keeps delivering pedometer distance through a pause (and a post-resume
    /// delivery can still carry pause-era samples), so every incoming sample is
    /// checked against these intervals and dropped if it overlaps one — the
    /// Workout app excludes pause-time distance, and so must we, or totals,
    /// splits, and the pace windows all drift fast. Guarded by
    /// `healthKitDistanceLock`.
    private var completedPauseIntervals: [DateInterval] = []

    /// Query for finding active workouts in companion mode
    private var activeWorkoutQuery: HKSampleQuery?

    /// Timer for periodic recheck of active workouts (in case Workout app starts after PaceRunner)
    private var workoutRecheckTimer: Timer?

    /// Number of workout rechecks performed
    private var workoutRecheckCount: Int = 0

    /// Total number of HealthKit sample deliveries received
    private var healthKitSampleDeliveryCount: Int = 0

    /// Total number of individual HealthKit distance samples processed
    private var healthKitTotalSampleCount: Int = 0

    /// Last quarter-mile marker logged (to avoid duplicate logs)
    private var lastLoggedQuarterMile: Int = 0

    /// Last GPS course logged (for turn detection in verbose logging)
    private var lastLoggedCourse: Double = -1

    /// Maximum number of rechecks to perform (at 5s intervals = 30s total window)
    private let maxWorkoutRechecks = 6

    /// When true, HealthKit distance has been deemed unreliable for this session
    /// and GPS is used for pace calculation instead
    private var healthKitFallbackToGPS = false

    /// Timestamp of last segment transition — voice alerts resume after grace period from this
    private var lastSegmentTransitionTime: Date?

    // Lock to prevent race conditions between location and pace updates
    private let stateLock = NSLock()

    // Flag to prevent multiple completion announcements
    private var hasAnnouncedCompletion = false

    /// Logged once per neutral hold, when the metronome stops holding neutral
    /// and starts directing faster/slower.
    private var hasLoggedMetronomeDirectionStart = false

    /// Pace change between consecutive segments, in seconds per mile, that counts
    /// as "the pace varies a lot" and warrants treating the transition like the
    /// start of a new run. A warm-up→tempo jump is far past this; drift between
    /// two similar segments is not.
    private static let segmentResetPaceDeltaSeconds = 20

    /// Share of a segment's estimated duration the neutral hold may consume.
    /// Without this cap a short interval would be neutral end to end, since the
    /// shortest averaging window (120s default) outlasts the segment itself.
    private static let neutralHoldSegmentFraction: Double = 0.5

    /// Elapsed time of the last `[windows]` diagnostic entry.
    private var lastWindowLogElapsed: TimeInterval = -.infinity

    /// Log `[windows]` on every pace update until this elapsed time. Set after a
    /// resume so the post-pause behavior is captured at full resolution rather
    /// than at the throttled cadence.
    private var windowBurstLogUntilElapsed: TimeInterval = 0

    /// Throttled cadence for the `[windows]` diagnostic, in seconds of moving time.
    private static let windowLogIntervalSeconds: TimeInterval = 15

    /// How long to log every update after a resume.
    private static let windowBurstAfterResumeSeconds: TimeInterval = 120

    /// Set inside the state lock when a transition warrants clearing the pace
    /// windows; acted on after the lock is released. `paceCalculator.reset()`
    /// publishes synchronously into `handlePaceUpdate`, which takes the same
    /// non-recursive lock — calling it inside would deadlock.
    private var pendingPaceWindowReset = false

    /// True while the current segment is running on windows that were cleared at
    /// its transition. Voice then waits for the refill instead of a flat 30s.
    private var windowsResetForCurrentSegment = false

    /// Debug log for capturing timing and sync events
    private var debugLog = DebugLog()

    // MARK: - Initialization

    public init(
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

        // Request HealthKit authorization at init so it's ready before first workout
        if isHealthKitAvailable {
            requestHealthKitAuthorization()
        }
    }

    /// Requests HealthKit authorization for reading distance and workout data.
    /// Must be called before any HealthKit queries will succeed.
    private func requestHealthKitAuthorization() {
        let typesToRead: Set<HKObjectType> = [
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.heartRate),
            HKObjectType.workoutType()
        ]

        healthStore.requestAuthorization(toShare: nil, read: typesToRead) { success, error in
            if let error = error {
                print("WorkoutManager: HealthKit authorization error: \(error)")
            } else {
                print("WorkoutManager: HealthKit authorization result: \(success)")
            }
        }
    }

    // MARK: - Workout Control

    public func startWorkout(with configuration: RunConfiguration) throws {
        let settings = settingsProvider()

        // Initialize fresh debug log for this workout
        debugLog = DebugLog()
        debugLog.logTiming("Workout started", data: [
            "config": configuration.name,
            "targetDistance": String(format: "%.2f", configuration.distance.miles),
            "companionMode": String(settings.companionMode),
            "useHealthKitDistance": String(settings.useHealthKitDistance),
            "paceCalibrationSeconds": String(settings.paceCalibrationSeconds),
            "calibrationFactor": String(format: "%.4f", settings.distanceCalibrationFactor()),
            "isMultiSegment": String(configuration.isMultiSegment),
            "segmentCount": String(configuration.segments?.count ?? 0)
        ])

        // Save debug log immediately so there's always at least a "started" entry
        saveDebugLog()

        // Check and log HealthKit authorization status
        if isHealthKitAvailable {
            let distanceStatus = healthStore.authorizationStatus(for: HKQuantityType(.distanceWalkingRunning))
            let heartRateStatus = healthStore.authorizationStatus(for: HKQuantityType(.heartRate))
            let workoutStatus = healthStore.authorizationStatus(for: HKObjectType.workoutType())

            let statusName: (HKAuthorizationStatus) -> String = { status in
                switch status {
                case .notDetermined: return "notDetermined"
                case .sharingDenied: return "sharingDenied"
                case .sharingAuthorized: return "sharingAuthorized"
                @unknown default: return "unknown(\(status.rawValue))"
                }
            }

            debugLog.logSync("HealthKit authorization status", data: [
                "distance": statusName(distanceStatus),
                "heartRate": statusName(heartRateStatus),
                "workout": statusName(workoutStatus),
                "isAvailable": "true"
            ])

            // If any permission is not determined, request it
            if distanceStatus == .notDetermined || heartRateStatus == .notDetermined || workoutStatus == .notDetermined {
                debugLog.logSync("Requesting HealthKit authorization (some permissions not determined)")
                requestHealthKitAuthorization()
            }
        } else {
            debugLog.logSync("HealthKit authorization status", data: [
                "isAvailable": "false"
            ])
        }

        // Debug: log calibration settings at workout start
        print("WorkoutManager.startWorkout: paceCalibrationSeconds=\(settings.paceCalibrationSeconds)")
        print("WorkoutManager.startWorkout: distanceCalibrationFactor=\(settings.distanceCalibrationFactor())")
        print("WorkoutManager.startWorkout: strideLengthInches=\(settings.strideLengthInches)")

        // Set distance source based on settings
        // Use HealthKit distance in both modes when setting is enabled
        useHealthKitDistance = settings.useHealthKitDistance
        print("WorkoutManager.startWorkout: useHealthKitDistance=\(useHealthKitDistance), companionMode=\(settings.companionMode)")

        // Create workout session only if NOT in companion mode (watchOS only)
        // In companion mode, user starts workout via native Workout app.
        // On iOS, we don't use HKWorkoutSession — background location/audio modes keep the app alive.
        #if os(watchOS)
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
        #endif

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

        // Start session (watchOS only)
        #if os(watchOS)
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
        #endif

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

        // Configure GPS distance method and verbose logging
        if let gps = gpsManager as? GPSManager {
            gps.setActiveMethod(settings.distanceCalcMethod)
            gps.runShadowCalculators = settings.verboseGPSLogging
            if settings.verboseGPSLogging {
                gps.onLocationProcessed = { [weak self] detail in
                    self?.logGPSDetail(detail)
                }
            } else {
                gps.onLocationProcessed = nil
            }
        }

        // Start barometric altimeter for diagnostic logging (always — small cost,
        // and we may want the data even when verbose GPS is off).
        altimeter.start()

        // Start GPS tracking
        gpsManager.startTracking()

        // Start HealthKit distance query if enabled
        // In companion mode, this queries samples from the Workout app
        // In standalone mode, this queries samples from our own workout session
        if useHealthKitDistance && isHealthKitAvailable {
            debugLog.logSync("Starting HealthKit distance tracking", data: [
                "companionMode": String(settings.companionMode),
                "isHealthKitAvailable": String(isHealthKitAvailable)
            ])
            startHealthKitDistanceQuery()
            startHeartRateQuery()

            // In companion mode, start periodic rechecks for workouts that might start after PaceRunner
            // This handles the case where user starts PaceRunner during Workout app's countdown
            if settings.companionMode {
                debugLog.logSync("Starting workout recheck timer (companion mode)")
                startWorkoutRecheckTimer()
            }
        } else {
            debugLog.logSync("HealthKit distance tracking NOT started", data: [
                "useHealthKitDistance": String(useHealthKitDistance),
                "isHealthKitAvailable": String(isHealthKitAvailable)
            ])
        }

        // Start tempo beats at effective BPM (calculated from stride + offset)
        // For multi-segment configs, use first segment's pace/offset for initial BPM
        do {
            let effectiveBPM: Int
            if let firstSegment = configuration.segments?.first {
                let baseBPM = settings.calculateBaseBPM(for: firstSegment.pace, strideLengthOverride: firstSegment.strideLengthInches ?? configuration.strideLengthInches)
                effectiveBPM = baseBPM + firstSegment.cadenceOffset
            } else {
                effectiveBPM = configuration.effectiveBPM(settings: settings)
            }
            // Configure emphasis beat settings before starting
            audioEngine.configureEmphasisBeat(
                enabled: settings.emphasisBeatEnabled,
                interval: settings.emphasisBeatInterval,
                audioBeatsEnabled: settings.audioBeatsEnabled
            )
            // Begin neutral: the opening beats demonstrate footfall rhythm, they
            // do not direct pace. handlePaceUpdate lifts this once the shortest
            // window has filled — but no pace update has arrived yet, so the
            // starting state has to be set here.
            audioEngine.setEmphasisBeatsSuppressed(true)
            audioEngine.setEmphasisBeatMode(0)
            try audioEngine.startTempoBeats(bpm: effectiveBPM)
            // Start metronome immediately at full volume
            audioEngine.setMetronomeVolume(1.0)
        } catch {
            print("AudioEngine failed to start tempo beats: \(error)")
        }
    }

    public func pauseWorkout() throws {
        guard var state = stateSubject.value else {
            throw WorkoutManagerError.noActiveWorkout
        }

        // Record when pause started (locked: read from the HK sample callback)
        healthKitDistanceLock.lock()
        pauseStartTime = Date()
        healthKitDistanceLock.unlock()
        print("WorkoutManager: Paused at \(pauseStartTime!)")

        // Log pause event
        debugLog.logPause("Workout paused", data: [
            "elapsedTime": String(format: "%.1f", state.elapsedTime),
            "distance": String(format: "%.3f", state.distanceCovered / 1609.34)
        ])

        #if os(watchOS)
        workoutSession?.pause()
        #endif
        gpsManager.stopTracking()
        audioEngine.stopTempoBeats()

        state.status = .paused
        stateSubject.send(state)
    }

    public func resumeWorkout() throws {
        guard var state = stateSubject.value else {
            throw WorkoutManagerError.noActiveWorkout
        }

        // Calculate how long we were paused and add to total
        if let pauseStart = pauseStartTime {
            let resumeTime = Date()
            let pauseDuration = resumeTime.timeIntervalSince(pauseStart)
            totalPausedDuration += pauseDuration
            print("WorkoutManager: Resumed after \(String(format: "%.1f", pauseDuration))s pause, total paused: \(String(format: "%.1f", totalPausedDuration))s")

            // Close out the pause interval BEFORE clearing pauseStartTime so a
            // concurrent HK delivery never sees "not paused" for a span that
            // was actually paused.
            healthKitDistanceLock.lock()
            completedPauseIntervals.append(DateInterval(start: pauseStart, end: resumeTime))
            pauseStartTime = nil
            healthKitDistanceLock.unlock()

            // Keep the rolling pace windows from counting the pause as running
            // time — slide their history forward so the master (distance-based)
            // average doesn't get dragged slow by the break.
            paceCalculator.notePauseGap(pauseDuration)

            // Capture every update for the next two minutes — the window
            // straddling the pause boundary is where a post-resume jump shows.
            windowBurstLogUntilElapsed =
                (stateSubject.value?.elapsedTime ?? 0) + Self.windowBurstAfterResumeSeconds
            lastWindowLogElapsed = -.infinity

            // Log resume event
            debugLog.logPause("Workout resumed", data: [
                "pauseDuration": String(format: "%.1f", pauseDuration),
                "totalPausedDuration": String(format: "%.1f", totalPausedDuration)
            ])
        }

        #if os(watchOS)
        workoutSession?.resume()
        #endif
        // Drop the GPS reference point BEFORE re-enabling updates so the first
        // post-resume fix can't draw a straight-line chord across the break
        // (phantom distance that would also corrupt any moving-average window
        // straddling the pause). Accumulated distance is preserved.
        gpsManager.breakContinuity()
        gpsManager.startTracking()
        let settings = settingsProvider()
        let effectiveBPM: Int
        if let segment = state.currentSegment {
            let baseBPM = settings.calculateBaseBPM(for: segment.pace, strideLengthOverride: segment.strideLengthInches ?? state.configuration.strideLengthInches)
            effectiveBPM = baseBPM + segment.cadenceOffset
        } else {
            effectiveBPM = state.configuration.effectiveBPM(settings: settings)
        }
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

    public func endWorkout() throws -> WorkoutSummary {
        guard var state = currentState else {
            throw WorkoutManagerError.noActiveWorkout
        }

        // Log workout end with HealthKit summary
        let hkDist = getHealthKitDistance()
        let gpsDist = gpsManager.totalDistance
        debugLog.logTiming("Workout ended", data: [
            "elapsedTime": String(format: "%.1f", state.elapsedTime),
            "totalDistance": String(format: "%.4f", state.distanceCovered / 1609.34),
            "totalPausedDuration": String(format: "%.1f", totalPausedDuration),
            "milesCompleted": String(state.mileSplits.count),
            "distanceSource": (useHealthKitDistance && !healthKitFallbackToGPS) ? "HealthKit" : "GPS",
            "hkFallbackToGPS": String(healthKitFallbackToGPS),
            "hkDistanceMiles": hkDist.map { String(format: "%.3f", $0 / 1609.34) } ?? "nil",
            "gpsDistanceMiles": String(format: "%.3f", gpsDist / 1609.34),
            "hkDeliveries": String(healthKitSampleDeliveryCount),
            "hkTotalSamples": String(healthKitTotalSampleCount)
        ])

        // Stop services
        altimeter.stop()
        gpsManager.stopTracking()
        audioEngine.stopTempoBeats()
        audioEngine.teardown()
        mileTracker.reset()

        // End session (watchOS only)
        #if os(watchOS)
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
        #endif

        // Update state to ended
        state.status = .ended
        stateSubject.send(state)

        // Create summary with debug log
        let settings = settingsProvider()
        let summary = state.toSummary(debugLog: debugLog, settings: settings)

        // Save debug log persistently FIRST (keyed by summary.id) so receivers
        // of the notification can already find it on disk.
        saveDebugLog(for: summary.id)

        // Post notification so WatchWorkoutStore can save regardless of end path
        // (covers both manual end via ViewModel and auto-end via handleAutoEnd)
        NotificationCenter.default.post(name: .workoutDidEnd, object: summary)

        // Cleanup
        cleanup()

        return summary
    }

    public func cancelWorkout() {
        // Stop services without saving
        altimeter.stop()
        gpsManager.stopTracking()
        audioEngine.stopTempoBeats()
        mileTracker.reset()
        audioEngine.teardown()

        // Discard session (watchOS only)
        #if os(watchOS)
        workoutSession?.end()
        #endif

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

        let queryStartTime = startTime ?? Date()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        debugLog.logSync("HealthKit distance query starting", data: [
            "queryStartTime": dateFormatter.string(from: queryStartTime),
            "hasHealthKitStartTimeSync": String(hasHealthKitStartTimeSync)
        ])

        // Create predicate for samples from workout start time onwards
        let predicate = HKQuery.predicateForSamples(
            withStart: queryStartTime,
            end: nil,
            options: .strictStartDate
        )

        let query = HKAnchoredObjectQuery(
            type: distanceType,
            predicate: predicate,
            anchor: distanceQueryAnchor,
            limit: HKObjectQueryNoLimit
        ) { [weak self] query, samples, deletedObjects, newAnchor, error in
            self?.processDistanceSamples(samples, newAnchor: newAnchor, error: error, isInitial: true)
        }

        // Set update handler to receive new samples as they arrive
        query.updateHandler = { [weak self] query, samples, deletedObjects, newAnchor, error in
            self?.processDistanceSamples(samples, newAnchor: newAnchor, error: error, isInitial: false)
        }

        distanceQuery = query
        healthStore.execute(query)
        print("WorkoutManager: Started HealthKit distance query from \(queryStartTime)")
    }

    /// Processes distance samples from HealthKit query
    private func processDistanceSamples(_ samples: [HKSample]?, newAnchor: HKQueryAnchor?, error: Error?, isInitial: Bool = false) {
        if let error = error {
            print("WorkoutManager: HealthKit distance query error: \(error)")
            debugLog.logSync("HealthKit query error", data: [
                "error": error.localizedDescription,
                "isInitial": String(isInitial)
            ])
            return
        }

        // Update anchor for next query
        distanceQueryAnchor = newAnchor

        guard let quantitySamples = samples as? [HKQuantitySample], !quantitySamples.isEmpty else {
            if isInitial {
                debugLog.logSync("HealthKit initial query returned no samples", data: [
                    "hasHealthKitStartTimeSync": String(hasHealthKitStartTimeSync)
                ])
            }
            return
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Log first batch of samples with details
        if !hasHealthKitStartTimeSync {
            let sampleDetails = quantitySamples.prefix(3).map { sample in
                let meters = sample.quantity.doubleValue(for: .meter())
                return "start=\(dateFormatter.string(from: sample.startDate)),dist=\(String(format: "%.1f", meters))m"
            }.joined(separator: "; ")

            debugLog.logSync("First HealthKit samples received", data: [
                "sampleCount": String(quantitySamples.count),
                "isInitial": String(isInitial),
                "hasHealthKitStartTimeSync": String(hasHealthKitStartTimeSync),
                "samples": sampleDetails
            ])
        }

        // On first sample, sync our start time with the Workout app's timing
        if !hasHealthKitStartTimeSync {
            syncStartTimeWithHealthKit(samples: quantitySamples)
        }

        // Snapshot pause bookkeeping; an in-progress pause counts as an
        // open-ended interval. (This callback runs on a background queue.)
        healthKitDistanceLock.lock()
        var pauseIntervals = completedPauseIntervals
        if let openPauseStart = pauseStartTime {
            pauseIntervals.append(DateInterval(start: openPauseStart, end: .distantFuture))
        }
        healthKitDistanceLock.unlock()

        // Sum up the distance from new samples and find the latest sample
        // timestamp. Samples that overlap a pause are dropped entirely: the
        // pedometer keeps writing distanceWalkingRunning while the session is
        // paused, and counting that walking corrupts totals, splits, and the
        // pace windows (the Workout app excludes it too).
        var newDistance: Double = 0
        var droppedPausedDistance: Double = 0
        var latestSampleEndDate: Date?
        for sample in quantitySamples {
            let meters = sample.quantity.doubleValue(for: .meter())
            let span = DateInterval(start: sample.startDate, end: sample.endDate)
            if pauseIntervals.contains(where: { $0.intersects(span) }) {
                droppedPausedDistance += meters
                continue
            }
            newDistance += meters
            if let current = latestSampleEndDate {
                if sample.endDate > current { latestSampleEndDate = sample.endDate }
            } else {
                latestSampleEndDate = sample.endDate
            }
        }

        if droppedPausedDistance > 0 {
            debugLog.logDistance("Dropped paused-time HK distance", data: [
                "droppedMeters": String(format: "%.1f", droppedPausedDistance),
                "keptMeters": String(format: "%.1f", newDistance),
                "samples": String(quantitySamples.count)
            ])
        }

        // Track delivery stats
        healthKitSampleDeliveryCount += 1
        healthKitTotalSampleCount += quantitySamples.count

        // Update accumulated distance thread-safely
        healthKitDistanceLock.lock()
        healthKitAccumulatedDistance += newDistance
        let totalDistance = healthKitAccumulatedDistance
        healthKitDistanceLock.unlock()

        // Feed pace calculator directly from HK distance using HK timestamps
        // This ensures pace calculations use HK-consistent distance and timing
        // (GPS callbacks handle UI state updates but don't feed pace when using HK)
        if useHealthKitDistance, let hkTimestamp = latestSampleEndDate {
            let settings = settingsProvider()
            let calibratedDistance = totalDistance * settings.distanceCalibrationFactor()
            paceCalculator.addSample(distance: calibratedDistance, timestamp: hkTimestamp)
        }

        print("WorkoutManager: HealthKit distance update: +\(String(format: "%.1f", newDistance))m, total=\(String(format: "%.1f", totalDistance))m (delivery #\(healthKitSampleDeliveryCount), \(quantitySamples.count) samples)")
    }

    /// Syncs our start time with the first HealthKit sample's timestamp
    /// This ensures our elapsed time matches the Workout app when in companion mode
    private func syncStartTimeWithHealthKit(samples: [HKQuantitySample]) {
        debugLog.logSync("Attempting start time sync", data: [
            "sampleCount": String(samples.count)
        ])

        // First, try to find the active workout and use its start time (more accurate)
        queryActiveWorkoutStartTime { [weak self] workoutStartTime in
            guard let self = self else { return }

            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let syncTime: Date
            if let workoutStart = workoutStartTime {
                // Use the actual workout start time
                syncTime = workoutStart
                print("WorkoutManager: Using active workout start time")
                self.debugLog.logSync("Using active workout start time", data: [
                    "workoutStartTime": dateFormatter.string(from: workoutStart)
                ])
            } else {
                // Fall back to first sample's start date
                let earliestSample = samples.min(by: { $0.startDate < $1.startDate })
                guard let firstSampleTime = earliestSample?.startDate else {
                    self.debugLog.logSync("No active workout and no sample start date - sync failed")
                    return
                }
                syncTime = firstSampleTime
                print("WorkoutManager: Using first sample start time (no active workout found)")
                self.debugLog.logSync("Falling back to first sample start time", data: [
                    "sampleStartTime": dateFormatter.string(from: firstSampleTime)
                ])
            }

            self.applyStartTimeSync(syncTime)
        }
    }

    /// Queries HealthKit for an active running workout to get its start time
    private func queryActiveWorkoutStartTime(completion: @escaping (Date?) -> Void) {
        let workoutType = HKObjectType.workoutType()

        // Look for workouts that started recently (within last 5 minutes of our tap time)
        let tapTime = userTapTime ?? Date()
        let fiveMinutesAgo = tapTime.addingTimeInterval(-300)

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        debugLog.logSync("Querying for active workouts", data: [
            "searchWindowStart": dateFormatter.string(from: fiveMinutesAgo),
            "tapTime": dateFormatter.string(from: tapTime)
        ])

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
                self?.debugLog.logSync("Active workout query error", data: [
                    "error": error.localizedDescription
                ])
                completion(nil)
                return
            }

            // Find a running workout that's still in progress
            if let workouts = samples as? [HKWorkout] {
                self?.debugLog.logSync("Active workout query results", data: [
                    "workoutsFound": String(workouts.count),
                    "types": workouts.map { "\($0.workoutActivityType.rawValue)" }.joined(separator: ",")
                ])

                for workout in workouts {
                    let timeSinceEnd = Date().timeIntervalSince(workout.endDate)
                    let isRunning = workout.workoutActivityType == .running

                    self?.debugLog.logSync("Evaluating workout", data: [
                        "type": String(workout.workoutActivityType.rawValue),
                        "isRunning": String(isRunning),
                        "startDate": dateFormatter.string(from: workout.startDate),
                        "endDate": dateFormatter.string(from: workout.endDate),
                        "timeSinceEnd": String(format: "%.1f", timeSinceEnd),
                        "isActive": String(timeSinceEnd < 30)
                    ])

                    if isRunning && timeSinceEnd < 30 {
                        print("WorkoutManager: Found active workout starting at \(workout.startDate)")
                        completion(workout.startDate)
                        return
                    }
                }
            } else {
                self?.debugLog.logSync("Active workout query: no workouts in result")
            }

            print("WorkoutManager: No active running workout found")
            self?.debugLog.logSync("No active running workout found")
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

    // MARK: - Heart Rate Query

    /// Starts an anchored object query to receive real-time heart rate samples from HealthKit
    private func startHeartRateQuery() {
        let heartRateType = HKQuantityType(.heartRate)
        let queryStartTime = startTime ?? Date()

        let predicate = HKQuery.predicateForSamples(
            withStart: queryStartTime,
            end: nil,
            options: .strictStartDate
        )

        let query = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: predicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, _, error in
            self?.processHeartRateSamples(samples, error: error)
        }

        query.updateHandler = { [weak self] _, samples, _, _, error in
            self?.processHeartRateSamples(samples, error: error)
        }

        heartRateQuery = query
        healthStore.execute(query)
        print("WorkoutManager: Started HealthKit heart rate query from \(queryStartTime)")
    }

    /// Processes heart rate samples from HealthKit query
    private func processHeartRateSamples(_ samples: [HKSample]?, error: Error?) {
        if let error = error {
            print("WorkoutManager: HealthKit heart rate query error: \(error)")
            return
        }

        guard let quantitySamples = samples as? [HKQuantitySample], !quantitySamples.isEmpty else {
            return
        }

        // Get the most recent HR sample's BPM
        let beatsPerMinuteUnit = HKUnit.count().unitDivided(by: .minute())
        if let latestSample = quantitySamples.last {
            let bpm = latestSample.quantity.doubleValue(for: beatsPerMinuteUnit)
            currentHeartRate = bpm

            // Collect samples for per-mile averaging
            for sample in quantitySamples {
                let sampleBPM = sample.quantity.doubleValue(for: beatsPerMinuteUnit)
                currentMileHeartRateSamples.append(sampleBPM)
            }

            print("WorkoutManager: Heart rate update: \(Int(bpm)) BPM (\(quantitySamples.count) samples)")
        }
    }

    /// Stops the HealthKit heart rate query
    private func stopHeartRateQuery() {
        if let query = heartRateQuery {
            healthStore.stop(query)
            heartRateQuery = nil
            print("WorkoutManager: Stopped HealthKit heart rate query")
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

        debugLog.logSync("Workout recheck #\(workoutRecheckCount)", data: [
            "maxRechecks": String(maxWorkoutRechecks),
            "hasHealthKitStartTimeSync": String(hasHealthKitStartTimeSync)
        ])

        // If HK samples have started arriving, we're good — stop rechecking
        if healthKitSampleDeliveryCount > 0 {
            debugLog.logSync("Workout recheck: HK samples arriving, stopping rechecks", data: [
                "hkDeliveries": String(healthKitSampleDeliveryCount)
            ])
            stopWorkoutRecheckTimer()
            return
        }

        // Stop if we've done enough rechecks
        if workoutRecheckCount >= maxWorkoutRechecks {
            print("WorkoutManager: Max rechecks reached (\(maxWorkoutRechecks)), stopping timer")

            // No HK workout found and no samples arrived — fall back to GPS
            if !hasHealthKitStartTimeSync && healthKitSampleDeliveryCount == 0 {
                healthKitFallbackToGPS = true
                debugLog.logSync("Workout recheck: max rechecks reached (\(maxWorkoutRechecks)), no HK data — falling back to GPS for pace")
                print("WorkoutManager: No HK workout found and no samples — using GPS for pace calculator")
            } else {
                debugLog.logSync("Workout recheck: max rechecks reached, stopping")
            }

            stopWorkoutRecheckTimer()
            return
        }

        // Query for active workouts
        queryActiveWorkoutStartTime { [weak self] workoutStartTime in
            guard let self = self,
                  let workoutStart = workoutStartTime,
                  let currentStartTime = self.startTime,
                  let tapTime = self.userTapTime else {
                self?.debugLog.logSync("Workout recheck: no active workout or missing state")
                return
            }

            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            // Check if this workout started AFTER our current sync time
            // but still within a reasonable window of when the user tapped start (20 seconds)
            let workoutStartedAfterSync = workoutStart > currentStartTime
            let workoutWithinWindow = workoutStart.timeIntervalSince(tapTime) < 20

            self.debugLog.logSync("Workout recheck evaluation", data: [
                "workoutStart": dateFormatter.string(from: workoutStart),
                "currentStartTime": dateFormatter.string(from: currentStartTime),
                "tapTime": dateFormatter.string(from: tapTime),
                "startedAfterSync": String(workoutStartedAfterSync),
                "withinWindow": String(workoutWithinWindow),
                "timeSinceTap": String(format: "%.1f", workoutStart.timeIntervalSince(tapTime))
            ])

            if workoutStartedAfterSync && workoutWithinWindow {
                print("WorkoutManager: Found newer workout that started after PaceRunner")
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
        // First try workout builder (watchOS standalone mode)
        #if os(watchOS)
        if let builder = workoutBuilder {
            let distanceType = HKQuantityType(.distanceWalkingRunning)
            if let statistics = builder.statistics(for: distanceType),
               let sum = statistics.sumQuantity() {
                return sum.doubleValue(for: .meter())
            }
        }
        #endif

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

        // Log distance source every ~0.25 miles to debug log
        let calibratedMiles = distance / 1609.34
        let quarterMileMarker = Int(calibratedMiles * 4)
        if quarterMileMarker > 0 && quarterMileMarker != lastLoggedQuarterMile {
            lastLoggedQuarterMile = quarterMileMarker

            // Also capture what HealthKit would have returned
            let hkDist = getHealthKitDistance()
            let hkMiles = hkDist.map { $0 / 1609.34 }
            let gpsMiles = gpsManager.totalDistance / 1609.34

            debugLog.logDistance("Distance source check", data: [
                "miles": String(format: "%.2f", calibratedMiles),
                "source": distanceSource,
                "hkMiles": hkMiles.map { String(format: "%.3f", $0) } ?? "nil",
                "gpsMiles": String(format: "%.3f", gpsMiles),
                "calibrationFactor": String(format: "%.4f", calibrationFactor),
                "hkDeliveries": String(healthKitSampleDeliveryCount),
                "hkTotalSamples": String(healthKitTotalSampleCount)
            ])
        }

        // Feed pace calculator from GPS when:
        // 1. Not using HealthKit distance, OR
        // 2. HK fallback flag set (recheck timer expired without finding matching workout), OR
        // 3. Using HK distance but no samples have arrived yet (early fallback before timer expires)
        // When HK IS delivering normally, pace samples are fed from HK callbacks with HK timestamps.
        let useGPSForPace = !useHealthKitDistance
            || healthKitFallbackToGPS
            || (useHealthKitDistance && healthKitSampleDeliveryCount == 0)
        if useGPSForPace {
            paceCalculator.addSample(distance: distance, timestamp: timestamp)
        }

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
        state.currentHeartRate = currentHeartRate > 0 ? Int(currentHeartRate) : nil

        // Update mile tracker and segment tracker
        handleMileTracking(state: &state, distance: distance)
        handleSegmentTracking(state: &state, distance: distance)

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

        // Likewise outside the lock: resetting the calculator publishes a nil
        // pace synchronously, which re-enters handlePaceUpdate.
        if pendingPaceWindowReset {
            pendingPaceWindowReset = false
            restartPaceWindowsForSegmentTransition()
        }
    }

    /// Clears the pace windows so a new segment starts from a clean slate, and
    /// re-arms the neutral hold so guidance stays quiet until the shortest
    /// window has refilled.
    private func restartPaceWindowsForSegmentTransition() {
        // handlePaceUpdate reads these under the lock, and pace samples can be
        // delivered from the HealthKit path on another thread.
        stateLock.lock()
        windowsResetForCurrentSegment = true
        hasLoggedMetronomeDirectionStart = false
        let label = stateSubject.value?.currentSegment?.label ?? "unknown"
        let targetPace = stateSubject.value?.targetPace.formatted ?? "nil"
        stateLock.unlock()

        debugLog.log(category: "segment", message: "Pace windows restarted for new segment", data: [
            "segment": label,
            "targetPace": targetPace
        ])

        // Demonstrate immediately rather than waiting for the next pace update.
        audioEngine.setEmphasisBeatsSuppressed(true)
        audioEngine.setEmphasisBeatMode(0)

        // restartTimeWindows, NOT reset(): reset() also discards the sample
        // history the distance-based master window needs, which blanked the
        // rolling-mile readout so it duplicated the current mile split.
        paceCalculator.restartTimeWindows()
    }

    /// How long guidance holds neutral before it starts directing pace.
    ///
    /// Normally the shortest averaging window, so direction is only ever driven
    /// by a window that has actually filled. Capped at a fraction of the current
    /// segment's estimated duration so short intervals still get guidance.
    private func neutralHoldSeconds(state: WorkoutState, settings: AppSettings) -> Double {
        let shortestWindow = Double(settings.fastAverageSeconds)

        guard let segment = state.currentSegment else { return shortestWindow }
        let estimatedDuration = segment.distance.meters * segment.pace.secondsPerMeter
        guard estimatedDuration > 0 else { return shortestWindow }

        return min(shortestWindow, estimatedDuration * Self.neutralHoldSegmentFraction)
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

        let previousFastPace = state.paceWindows.fastPace
        state.currentPace = pace

        // Update pace windows using new Fast/Medium/Slow naming
        let lastMilePace = state.mileSplits.last?.actualPace
        state.paceWindows = PaceWindows(
            slowPace: paceCalculator.slowPace,      // Master pace (distance-based)
            mediumPace: paceCalculator.mediumPace,  // Medium rolling avg
            fastPace: paceCalculator.fastPace,      // Fast rolling avg
            lastMilePace: lastMilePace
        )

        // Detect GPS pace spikes (likely from sharp turns)
        // Log when fast avg changes by more than 5s in a single update.
        // Suppressed when verbose GPS logging is on — raw [gps] samples already
        // give us the full picture and the spike entries become redundant noise.
        if !settingsProvider().verboseGPSLogging,
           let prevFast = previousFastPace, let newFast = state.paceWindows.fastPace {
            let fastDelta = newFast.totalSeconds - prevFast.totalSeconds
            if abs(fastDelta) >= 5 {
                let direction = fastDelta > 0 ? "slower" : "faster"
                debugLog.log(category: "gps-spike", message: "Fast pace spike: \(direction) by \(abs(fastDelta))s", data: [
                    "prevFast": prevFast.formatted,
                    "newFast": newFast.formatted,
                    "delta": "\(fastDelta)s",
                    "medium": state.paceWindows.mediumPace?.formatted ?? "nil",
                    "slow": state.paceWindows.slowPace?.formatted ?? "nil",
                    "distance": String(format: "%.3f", state.distanceCovered / 1609.34),
                    "elapsed": String(format: "%.0f", state.elapsedTime)
                ])
            }
        }

        // Grace period handling
        handleGracePeriod(state: &state, pace: pace)

        let settings = settingsProvider()

        logPaceWindowsIfDue(state: state, settings: settings)

        // Hold the metronome neutral until the shortest averaging window has
        // actually filled. A window reports a pace once it has `minSamples`
        // (3) samples, so without this gate the metronome starts directing
        // faster/slower a few seconds into the run, off a handful of GPS points.
        let neutralHold = neutralHoldSeconds(state: state, settings: settings)
        let shortestWindowFilled = paceCalculator.movingTimeSpan >= neutralHold

        if shortestWindowFilled && !hasLoggedMetronomeDirectionStart {
            hasLoggedMetronomeDirectionStart = true
            debugLog.log(category: "metronome", message: "Neutral hold ended, pace direction enabled", data: [
                "neutralHold": String(format: "%.0fs", neutralHold),
                "shortestWindow": "\(settings.fastAverageSeconds)s",
                "movingTimeSpan": String(format: "%.0fs", paceCalculator.movingTimeSpan),
                "segment": state.currentSegment?.label ?? "none",
                "elapsed": String(format: "%.0f", state.elapsedTime)
            ])
        }

        // While holding neutral the beat demonstrates footfall rhythm, so every
        // beat sounds the same — mode 0 alone is not enough, it still plays the
        // distinct emphasis tone.
        audioEngine.setEmphasisBeatsSuppressed(!shortestWindowFilled)

        // Adaptive metronome volume and pitch based on pace deviation
        // When off (or still holding neutral), the metronome is at full volume
        // with normal pitch and no directional emphasis.
        if settings.adaptiveMetronomeVolume, shortestWindowFilled, let mediumPace = state.paceWindows.mediumPace {
            let signedDeviation = mediumPace.totalSeconds - state.targetPace.totalSeconds
            let deviation = abs(signedDeviation)
            audioEngine.updateVolumeForDeviation(
                deviationSeconds: deviation,
                toleranceSeconds: state.effectivePaceTolerance,
                maxDeviationSeconds: state.effectivePaceTolerance * 3,
                minVolume: state.configuration.metronomeMinVolume,
                maxVolume: state.configuration.metronomeMaxVolume
            )

            // Emphasis beat direction: upbeat when too slow, downbeat when too fast
            if deviation > state.effectivePaceTolerance {
                let mode = signedDeviation > 0 ? 1 : -1  // 1=speed up, -1=slow down
                audioEngine.setEmphasisBeatMode(mode)
            } else {
                audioEngine.setEmphasisBeatMode(0)
            }
        } else {
            audioEngine.setMetronomeVolume(1.0)
            audioEngine.setEmphasisBeatMode(0)
        }

        // Voice alerts only after:
        // 1. Grace period ends
        // 2. Medium pace average has filled up (enough data for reliable alerts)
        let mediumAverageFilled = state.elapsedTime >= Double(settings.mediumAverageSeconds)

        // Grace period after segment transitions for pace averages to adjust.
        // When the windows were cleared for this segment there is no history to
        // "adjust" — wait for the same refill the metronome waits for, so the two
        // start directing together instead of ~90s apart.
        let segmentGracePeriodActive: Bool
        if windowsResetForCurrentSegment {
            segmentGracePeriodActive = !shortestWindowFilled
        } else if let transitionTime = lastSegmentTransitionTime {
            segmentGracePeriodActive = Date().timeIntervalSince(transitionTime) < 30.0
        } else {
            segmentGracePeriodActive = false
        }

        if !state.isInGracePeriod && mediumAverageFilled && !segmentGracePeriodActive {
            // Generate voice alert based on cascading pace windows
            // Priority: split (urgent) > 3min (medium) > 1min (minor)
            if let message = cascadingVoiceAlert(
                paceWindows: state.paceWindows,
                targetPace: state.targetPace,
                tolerance: state.effectivePaceTolerance
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
        let finalSplitPace = state.splitPace?.spoken ?? "unknown"

        // Calculate average pace for entire workout
        let avgPace: String
        if state.distanceCovered > 0 && state.elapsedTime > 0 {
            let secondsPerMeter = state.elapsedTime / state.distanceCovered
            if let pace = Pace(secondsPerMeter: secondsPerMeter) {
                avgPace = pace.spoken
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
    /// Emits a `[windows]` entry carrying every pace readout AND what each
    /// window is actually spanning.
    ///
    /// Added because a run where the rolling mile and the mile split appeared
    /// locked together could not be diagnosed after the fact: the log recorded
    /// GPS samples and quarter-mile checkpoints, but on a HealthKit-driven run
    /// those are not what the calculator consumes, and no window values were
    /// recorded at all. `masterWindowMeters` is the decisive field — a rolling
    /// mile spanning well under a mile is computing over the same data as the
    /// current split, which looks identical to steady running from the paces
    /// alone.
    private func logPaceWindowsIfDue(state: WorkoutState, settings: AppSettings) {
        let elapsed = state.elapsedTime
        let inBurst = elapsed <= windowBurstLogUntilElapsed
        guard inBurst || elapsed - lastWindowLogElapsed >= Self.windowLogIntervalSeconds else {
            return
        }
        lastWindowLogElapsed = elapsed

        let d = paceCalculator.windowDiagnostics
        let windows = state.paceWindows
        debugLog.log(category: "windows", message: "Pace windows", data: [
            "elapsed": String(format: "%.0f", elapsed),
            "miles": String(format: "%.3f", state.distanceCovered / 1609.34),
            "split": state.splitPace?.formatted ?? "nil",
            "rollingMile": windows.slowPace?.formatted ?? "nil",
            "medium": windows.mediumPace?.formatted ?? "nil",
            "fast": windows.fastPace?.formatted ?? "nil",
            // The separator between "steady running" and "window not filled".
            "masterSpanMi": String(format: "%.3f", d.masterWindowMeters / 1609.34),
            "masterSpanSec": String(format: "%.0f", d.masterWindowSeconds),
            "masterSamples": String(d.masterWindowSamples),
            "fastSamples": String(d.fastWindowSamples),
            "sampleCount": String(d.sampleCount),
            "movingTimeSpan": String(format: "%.0f", d.movingTimeSpan),
            "mileStartMi": String(format: "%.3f", state.currentMileSplitStart / 1609.34),
            "source": useHealthKitDistance && !healthKitFallbackToGPS ? "HealthKit" : "GPS",
            "burst": inBurst ? "1" : "0"
        ])
    }

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

    // MARK: - Segment Tracking

    private func handleSegmentTracking(state: inout WorkoutState, distance: Double) {
        guard let segments = state.configuration.segments,
              state.currentSegmentIndex < segments.count - 1 else { return }

        let boundaries = state.configuration.segmentBoundaryDistances()
        let currentBoundary = boundaries[state.currentSegmentIndex]

        if distance >= currentBoundary {
            let completedSegment = segments[state.currentSegmentIndex]
            state.currentSegmentIndex += 1
            state.segmentDistanceStart = currentBoundary

            let nextSegment = segments[state.currentSegmentIndex]

            // Voice announce segment transition (spoken form — never `formatted`)
            let paceSpoken = nextSegment.pace.spoken
            audioEngine.playImportantAlert("\(completedSegment.label) complete. Starting \(nextSegment.label) at \(paceSpoken)")

            // A large pace change means the previous segment's pace history is
            // actively misleading — the medium window (240s default) would keep
            // reporting warm-up pace minutes into a tempo block. Restart the
            // windows so the new segment converges like the start of a new run.
            let paceDelta = abs(nextSegment.pace.totalSeconds - completedSegment.pace.totalSeconds)
            if paceDelta >= Self.segmentResetPaceDeltaSeconds {
                pendingPaceWindowReset = true
            } else {
                windowsResetForCurrentSegment = false
            }

            // Update metronome BPM if cadence changes
            let settings = settingsProvider()
            let configStride = state.configuration.strideLengthInches
            let oldBPM = settings.calculateBaseBPM(for: completedSegment.pace, strideLengthOverride: completedSegment.strideLengthInches ?? configStride) + completedSegment.cadenceOffset
            let newBPM = settings.calculateBaseBPM(for: nextSegment.pace, strideLengthOverride: nextSegment.strideLengthInches ?? configStride) + nextSegment.cadenceOffset
            if oldBPM != newBPM {
                try? audioEngine.updateTempo(bpm: newBPM)
            }

            // Record segment transition time for voice alert grace period (30s)
            lastSegmentTransitionTime = Date()

            // Also reset mile split tracking for clean splits in the new segment
            state.currentMileSplitStart = distance
            state.currentMileSplitStartTime = state.elapsedTime

            debugLog.logTiming("Segment transition", data: [
                "from": "\(state.currentSegmentIndex - 1) (\(completedSegment.label))",
                "to": "\(state.currentSegmentIndex) (\(nextSegment.label))",
                "distance": String(format: "%.3f", distance / 1609.34)
            ])

            print("WorkoutManager: Segment transition \(state.currentSegmentIndex - 1) → \(state.currentSegmentIndex): \(completedSegment.label) → \(nextSegment.label)")
            // Note: pace calculator is NOT reset — the 30s voice alert grace period
            // suppresses cues while old data washes out naturally from the windows.
            // Resetting caused deadlocks/crashes on real hardware.
        }
    }

    // MARK: - Mile Markers

    private func handleMileTracking(state: inout WorkoutState, distance: Double) {
        if let completedMile = mileTracker.updateDistance(distance), completedMile > 0 {
            // Get split pace (should always exist when completing a mile)
            let splitPace = state.splitPace

            if let pace = splitPace {
                // Compute average heart rate for this mile
                let avgHR: Int? = currentMileHeartRateSamples.isEmpty ? nil :
                    Int(currentMileHeartRateSamples.reduce(0, +) / Double(currentMileHeartRateSamples.count))
                currentMileHeartRateSamples = []

                // Record the split for the completed mile
                let split = MileSplit(
                    mileNumber: completedMile,
                    actualPace: pace,
                    targetPace: state.targetPace,
                    distance: Distance(miles: 1.0),
                    averageHeartRate: avgHR
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
                    let paceSpoken = pace.spoken
                    audioEngine.playImportantAlert("Mile \(completedMile) complete. Pace \(paceSpoken)")
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

    /// Logs detailed GPS sample info when verbose logging is enabled.
    /// One entry per CLLocation (accepted or rejected) so we can correlate
    /// real-world events (turns, stops, GPS hiccups) with our distance math.
    private func logGPSDetail(_ detail: LocationProcessedDetail) {
        let loc = detail.location
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0

        var data: [String: String] = [
            "t": String(format: "%.1f", elapsed),
            "lat": String(format: "%.6f", loc.coordinate.latitude),
            "lon": String(format: "%.6f", loc.coordinate.longitude),
            "acc": String(format: "%.1f", loc.horizontalAccuracy),
            "speed": String(format: "%.2f", loc.speed),         // m/s from chip; -1 if unknown
            "course": String(format: "%.0f", loc.course),       // degrees from chip; -1 if unknown
            "delta": String(format: "%.2f", detail.deltaMeters),
            "totalM": String(format: "%.1f", detail.cumulativeMeters),
            // Altitude diagnostics
            "alt": String(format: "%.1f", loc.altitude),
            "vAcc": String(format: "%.1f", loc.verticalAccuracy)
        ]
        if let baroAlt = altimeter.relativeAltitudeMeters {
            data["baroRel"] = String(format: "%.2f", baroAlt)
        }
        if let pressure = altimeter.pressureKPa {
            data["pressKPa"] = String(format: "%.3f", pressure)
        }
        // When shadow calculators are running, log each method's delta/total
        // so the active vs alternate methods can be compared sample-by-sample.
        if let results = detail.methodResults {
            for r in results {
                let prefix = r.method.rawValue
                data["\(prefix).d"] = String(format: "%.2f", r.delta)
                data["\(prefix).t"] = String(format: "%.1f", r.total)
            }
        }
        if let reason = detail.rejectionReason {
            data["rejected"] = reason
        }
        debugLog.log(category: detail.accepted ? "gps" : "gps-rej",
                     message: detail.accepted ? "sample" : "rejected",
                     data: data)

        // Auto-detect significant heading changes and emit a turn marker
        if loc.course >= 0 {
            if lastLoggedCourse >= 0 {
                var deltaDeg = abs(loc.course - lastLoggedCourse)
                if deltaDeg > 180 { deltaDeg = 360 - deltaDeg }
                if deltaDeg >= 60 {
                    debugLog.log(category: "gps-turn",
                                 message: "heading change",
                                 data: [
                                    "t": String(format: "%.1f", elapsed),
                                    "from": String(format: "%.0f", lastLoggedCourse),
                                    "to": String(format: "%.0f", loc.course),
                                    "delta": String(format: "%.0f", deltaDeg),
                                    "atDistance": String(format: "%.3f mi", detail.cumulativeMeters / 1609.34)
                                 ])
                }
            }
            lastLoggedCourse = loc.course
        }
    }

    /// Saves the current debug log to the file-based DebugLogStore, keyed by
    /// workout ID. We deliberately do NOT mirror into UserDefaults — verbose-GPS
    /// logs are 1–2 MB and writing them to `standard.plist` bloats the plist
    /// that watchOS deserializes on every app launch (caused failed-to-relaunch
    /// loops).
    private func saveDebugLog(for workoutID: UUID? = nil) {
        let text = debugLog.exportAsText()
        if let id = workoutID {
            _ = DebugLogStore.shared.save(text, for: id)
        }
        print("WorkoutManager: Debug log saved (\(debugLog.events.count) events) for \(workoutID?.uuidString ?? "no-id")")
    }

    /// Returns the last saved debug log text from the file-based store, or nil.
    public static func loadLastDebugLog() -> String? {
        return DebugLogStore.shared.loadLast()
    }

    private func cleanup() {
        cancellables.removeAll()
        #if os(watchOS)
        workoutSession = nil
        workoutBuilder = nil
        #endif
        startTime = nil
        userTapTime = nil
        mileTracker.reset()
        hasAnnouncedCompletion = false
        hasLoggedMetronomeDirectionStart = false
        lastWindowLogElapsed = -.infinity
        windowBurstLogUntilElapsed = 0
        pendingPaceWindowReset = false
        windowsResetForCurrentSegment = false
        useHealthKitDistance = false
        hasHealthKitStartTimeSync = false
        healthKitFallbackToGPS = false
        lastSegmentTransitionTime = nil

        // Reset pause tracking
        totalPausedDuration = 0
        healthKitDistanceLock.lock()
        pauseStartTime = nil
        completedPauseIntervals = []
        healthKitDistanceLock.unlock()

        // Stop workout recheck timer
        stopWorkoutRecheckTimer()
        workoutRecheckCount = 0
        healthKitSampleDeliveryCount = 0
        healthKitTotalSampleCount = 0
        lastLoggedQuarterMile = 0
        lastLoggedCourse = -1

        // Stop HealthKit queries and reset accumulated distance
        stopHeartRateQuery()
        currentHeartRate = 0
        currentMileHeartRateSamples = []
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

// MARK: - HKWorkoutSessionDelegate (watchOS only)

#if os(watchOS)
extension WorkoutManager: HKWorkoutSessionDelegate {

    public func workoutSession(_ workoutSession: HKWorkoutSession,
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
            altimeter.stop()
            gpsManager.stopTracking()

            if var state = stateSubject.value {
                // If workout was running when session ended unexpectedly,
                // save the summary so we don't lose data
                if state.status == .running || state.status == .paused {
                    debugLog.logTiming("Session ended unexpectedly", data: [
                        "previousStatus": "\(state.status)",
                        "distance": String(format: "%.3f", state.distanceCovered / 1609.34),
                        "elapsed": String(format: "%.0f", state.elapsedTime)
                    ])

                    let settings = settingsProvider()
                    let summary = state.toSummary(debugLog: debugLog, settings: settings)
                    saveDebugLog(for: summary.id)
                    NotificationCenter.default.post(name: .workoutDidEnd, object: summary)
                }

                state.status = .ended
                stateSubject.send(state)
            }

        default:
            break
        }
    }

    public func workoutSession(_ workoutSession: HKWorkoutSession,
                       didFailWithError error: Error) {
        print("Workout session failed: \(error)")

        // CRITICAL: Stop ALL audio on failure
        audioEngine.stopTempoBeats()
        audioEngine.teardown()
        altimeter.stop()
        gpsManager.stopTracking()

        if var state = stateSubject.value {
            state.status = .ended
            stateSubject.send(state)
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate (watchOS only)

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {

    public func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                       didCollectDataOf collectedTypes: Set<HKSampleType>) {
        // HealthKit collected samples (heart rate, etc.)
        // We handle distance via GPS, so nothing to do here for MVP
    }

    public func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Workout events collected (pause, resume, etc.)
    }
}
#endif

// MARK: - Notifications

extension Notification.Name {
    public static let workoutDidEnd = Notification.Name("workoutDidEnd")
}
