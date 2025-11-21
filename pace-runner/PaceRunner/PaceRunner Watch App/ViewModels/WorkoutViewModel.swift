import Foundation
import Combine
import PaceRunnerShared

/// Bridges `WorkoutManager` state to SwiftUI views.
final class WorkoutViewModel: ObservableObject {
    @Published private(set) var state: WorkoutState

    @Published var isShowingSummary: Bool = false
    @Published var isShowingPauseOverlay: Bool = false

    private let workoutManager: WorkoutManagerProtocol
    private let syncManager: SyncManagerProtocol?
    private var cancellables = Set<AnyCancellable>()

    init(
        workoutManager: WorkoutManagerProtocol,
        configuration: RunConfiguration,
        syncManager: SyncManagerProtocol? = nil
    ) {
        self.workoutManager = workoutManager
        self.syncManager = syncManager
        self.state = WorkoutState(configuration: configuration)
        bindState()
    }

    private func bindState() {
        workoutManager.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                print("WorkoutViewModel state updated: \(newState.status)")
                self?.state = newState
                self?.isShowingSummary = newState.status == .ended
                self?.isShowingPauseOverlay = newState.status == .paused
            }
            .store(in: &cancellables)
    }

    func start() {
        do {
            try workoutManager.startWorkout(with: state.configuration)
        } catch {
            print("WorkoutViewModel.start error: \(error)")
        }
    }

    func pause() {
        do {
            print("WorkoutViewModel.pause() invoked")
            try workoutManager.pauseWorkout()
            isShowingPauseOverlay = true
            print("WorkoutViewModel: isShowingPauseOverlay -> true")
        } catch {
            print("WorkoutViewModel.pause error: \(error)")
        }
    }

    func resume() {
        do {
            print("WorkoutViewModel.resume() invoked")
            try workoutManager.resumeWorkout()
            isShowingPauseOverlay = false
            print("WorkoutViewModel: isShowingPauseOverlay -> false")
        } catch {
            print("WorkoutViewModel.resume error: \(error)")
        }
    }

    func end() {
        do {
            print("WorkoutViewModel.end() invoked")
            let summary = try workoutManager.endWorkout()
            syncManager?.syncWorkoutSummary(summary)
            isShowingSummary = true
        } catch {
            print("WorkoutViewModel.end error: \(error)")
        }
    }

    func cancel() {
        workoutManager.cancelWorkout()
        isShowingSummary = false
        isShowingPauseOverlay = false
        state = WorkoutState(configuration: state.configuration)
    }

    func formattedPace() -> String {
        state.currentPace?.formatted ?? "--:--"
    }

    func formattedDistance() -> String {
        Distance(meters: state.distanceCovered).formatted
    }

    func formattedTime() -> String {
        let minutes = Int(state.elapsedTime) / 60
        let seconds = Int(state.elapsedTime) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
