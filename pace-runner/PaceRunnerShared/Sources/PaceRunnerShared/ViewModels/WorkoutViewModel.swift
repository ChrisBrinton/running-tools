import Foundation
import Combine

/// Bridges `WorkoutManager` state to SwiftUI views.
///
/// Used on both watchOS and iOS. Saving workout history is handled by
/// listening to `.workoutDidEnd` notifications elsewhere — this view model
/// just bridges the workout manager state.
public final class WorkoutViewModel: ObservableObject {
    @Published public private(set) var state: WorkoutState

    @Published public var isShowingSummary: Bool = false
    @Published public var isShowingPauseOverlay: Bool = false

    private let workoutManager: WorkoutManagerProtocol
    private let syncManager: SyncManagerProtocol?
    private var cancellables = Set<AnyCancellable>()

    /// App settings for display formatting
    public let settings: AppSettings

    public init(
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

    public func start() {
        do {
            try workoutManager.startWorkout(with: state.configuration)
        } catch {
            print("WorkoutViewModel.start error: \(error)")
        }
    }

    public func pause() {
        do {
            print("WorkoutViewModel.pause() invoked")
            try workoutManager.pauseWorkout()
            isShowingPauseOverlay = true
            print("WorkoutViewModel: isShowingPauseOverlay -> true")
        } catch {
            print("WorkoutViewModel.pause error: \(error)")
        }
    }

    public func resume() {
        do {
            print("WorkoutViewModel.resume() invoked")
            try workoutManager.resumeWorkout()
            isShowingPauseOverlay = false
            print("WorkoutViewModel: isShowingPauseOverlay -> false")
        } catch {
            print("WorkoutViewModel.resume error: \(error)")
        }
    }

    public func end() {
        do {
            print("WorkoutViewModel.end() invoked")
            // endWorkout() posts .workoutDidEnd notification
            // History stores listen for it and save automatically
            // (covers both this manual path and auto-end path)
            _ = try workoutManager.endWorkout()
            isShowingSummary = true
        } catch {
            print("WorkoutViewModel.end error: \(error)")
        }
    }

    public func cancel() {
        workoutManager.cancelWorkout()
        isShowingSummary = false
        isShowingPauseOverlay = false
        state = WorkoutState(configuration: state.configuration)
    }

    public func formattedPace() -> String {
        state.currentPace?.formatted ?? "--:--"
    }

    public func formattedDistance() -> String {
        Distance(meters: state.distanceCovered).formatted
    }

    public func formattedTime() -> String {
        let minutes = Int(state.elapsedTime) / 60
        let seconds = Int(state.elapsedTime) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    public func formattedHeartRate() -> String {
        if let hr = state.currentHeartRate {
            return "\(hr)"
        }
        return "---"
    }

    // MARK: - Pace Window Labels

    /// Label for slow (master) pace window based on settings
    public var slowPaceLabel: String {
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
    public var mediumPaceLabel: String {
        "\(settings.mediumAverageSeconds)s"
    }

    /// Label for fast pace window based on settings
    public var fastPaceLabel: String {
        "\(settings.fastAverageSeconds)s"
    }
}
