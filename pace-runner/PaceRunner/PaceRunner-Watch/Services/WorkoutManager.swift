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
    private let isHealthKitAvailable: Bool
    private let mileTracker: MileTracker

    // MARK: - Private Properties

    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var cancellables = Set<AnyCancellable>()

    private var startTime: Date?

    // MARK: - Initialization

    init(
        healthStore: HKHealthStore = HKHealthStore(),
        gpsManager: GPSManagerProtocol,
        paceCalculator: PaceCalculatorProtocol,
        audioEngine: AudioEngineProtocol,
        mileTracker: MileTracker = MileTracker()
    ) {
        self.healthStore = healthStore
        self.gpsManager = gpsManager
        self.paceCalculator = paceCalculator
        self.audioEngine = audioEngine
        self.mileTracker = mileTracker
        self.isHealthKitAvailable = HKHealthStore.isHealthDataAvailable()

        super.init()
    }

    // MARK: - Workout Control

    func startWorkout(with configuration: RunConfiguration) throws {
        // Create workout configuration
        var session: HKWorkoutSession?
        var builder: HKLiveWorkoutBuilder?

        if isHealthKitAvailable {
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
        try audioEngine.setup()
        mileTracker.reset()
        paceCalculator.reset()

        // Subscribe to GPS updates
        subscribeToGPS()

        // Subscribe to pace updates
        subscribeToPace()

        // Start session
        if let session = session {
            session.startActivity(with: Date())
        }
        if let builder = builder {
            try builder.beginCollection(withStart: Date()) { _, error in
                if let error = error {
                    print("Failed to start workout builder: \(error)")
                }
            }
        }

        // Start GPS tracking
        gpsManager.startTracking()

        // Start tempo beats at base cadence
        try audioEngine.startTempoBeats(bpm: configuration.baseCadence)
    }

    func pauseWorkout() throws {
        guard workoutSession != nil else {
            throw WorkoutManagerError.noActiveWorkout
        }

        workoutSession?.pause()
        gpsManager.stopTracking()
        audioEngine.stopTempoBeats()

        // Update state
        if var state = stateSubject.value {
            state.status = .paused
            stateSubject.send(state)
        }
    }

    func resumeWorkout() throws {
        guard let state = currentState else {
            throw WorkoutManagerError.noActiveWorkout
        }

        workoutSession?.resume()
        gpsManager.startTracking()
        try audioEngine.startTempoBeats(bpm: state.configuration.baseCadence)

        // Update state
        if var state = stateSubject.value {
            state.status = .running
            stateSubject.send(state)
        }
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
        guard var state = stateSubject.value,
              state.status == .running else {
            return
        }

        // Get updated distance from GPS manager
        let distance = gpsManager.totalDistance
        let timestamp = Date()

        let elapsedTime = timestamp.timeIntervalSince(startTime ?? timestamp)
        state.distanceCovered = distance
        state.elapsedTime = elapsedTime

        paceCalculator.addSample(distance: distance, timestamp: timestamp)
        handleMileTracking(state: &state, distance: distance)

        stateSubject.send(state)
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
        guard var state = stateSubject.value else { return }

        state.currentPace = pace

        // Check pace deviation
        if let deviation = state.paceDeviation,
           let isWithinTolerance = state.isWithinTolerance,
           !isWithinTolerance {
            // Pace is outside tolerance - trigger alert
            let message = deviation > 0 ? "Speed up" : "Slow down"
            audioEngine.playVoiceAlert(message)
        }

        stateSubject.send(state)
    }

    // MARK: - Mile Markers

    private func handleMileTracking(state: inout WorkoutState, distance: Double) {
        if let completedMile = mileTracker.updateDistance(distance),
           completedMile > 0,
           let pace = state.currentPace {
            let split = MileSplit(
                mileNumber: completedMile,
                actualPace: pace,
                targetPace: state.targetPace,
                distance: Distance(miles: 1.0)
            )
            state.recordMileSplit(split)
            audioEngine.playVoiceAlert("Mile \(completedMile) complete")
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
        // Publish error via GPS error publisher (or create dedicated error publisher)
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
