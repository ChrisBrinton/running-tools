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

    /// App settings for display formatting
    let settings: AppSettings

    init(
        workoutManager: WorkoutManagerProtocol,
        configuration: RunConfiguration,
        syncManager: SyncManagerProtocol? = nil,
        settings: AppSettings = AppSettings.load()
    ) {
        self.workoutManager = workoutManager
        self.syncManager = syncManager
        self.settings = settings
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

    // MARK: - Pace Window Labels

    /// Label for slow (master) pace window based on settings
    var slowPaceLabel: String {
        let miles = settings.slowAverageMiles
        if miles == 1.0 {
            return "1mi"
        } else if miles == floor(miles) {
            return "\(Int(miles))mi"
        } else {
            return String(format: "%.1fmi", miles)
        }
    }

    /// Label for medium pace window based on settings
    var mediumPaceLabel: String {
        "\(settings.mediumAverageSeconds)s"
    }

    /// Label for fast pace window based on settings
    var fastPaceLabel: String {
        "\(settings.fastAverageSeconds)s"
    }
}
