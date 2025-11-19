import Foundation
import Combine

/// Protocol for workout session management
///
/// WorkoutManager orchestrates:
/// - HealthKit workout session
/// - GPS tracking via GPSManager
/// - Pace calculation via PaceCalculator
/// - Audio feedback via AudioEngine
/// - Real-time state updates
///
/// Constitution: Non-blocking, <200ms GPS → UI pipeline
public protocol WorkoutManagerProtocol: AnyObject {
    /// Publisher for workout state updates
    var statePublisher: AnyPublisher<WorkoutState, Never> { get }

    /// Current workout state
    var currentState: WorkoutState? { get }

    /// Start workout with configuration
    /// - Parameter configuration: Run configuration
    func startWorkout(with configuration: RunConfiguration) throws

    /// Pause workout
    func pauseWorkout() throws

    /// Resume paused workout
    func resumeWorkout() throws

    /// End workout and return summary
    /// - Returns: Workout summary
    func endWorkout() throws -> WorkoutSummary

    /// Cancel workout (discard data)
    func cancelWorkout()
}
