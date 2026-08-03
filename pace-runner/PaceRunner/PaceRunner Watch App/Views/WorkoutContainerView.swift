import SwiftUI
import PaceRunnerShared

struct WorkoutContainerView: View {
    @StateObject private var viewModel: WorkoutViewModel
    private let onExit: () -> Void
    private let onNewRun: ((RunConfiguration) -> Void)?
    private let syncStatusModel: WatchSyncStatusModel?

    init(
        configuration: RunConfiguration,
        workoutManager: WorkoutManagerProtocol,
        syncManager: SyncManagerProtocol?,
        workoutStore: WatchWorkoutStore? = nil,
        syncStatusModel: WatchSyncStatusModel? = nil,
        onExit: @escaping () -> Void,
        onNewRun: ((RunConfiguration) -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: WorkoutViewModel(
            workoutManager: workoutManager,
            configuration: configuration,
            syncManager: syncManager
        ))
        self.onExit = onExit
        self.onNewRun = onNewRun
        self.syncStatusModel = syncStatusModel
    }

    var body: some View {
        ZStack {
            workoutContent
                .transition(.opacity)

            pauseOverlay
        }
    }

    @ViewBuilder
    private var workoutContent: some View {
        switch viewModel.state.status {
        case .waitingForGPS:
            preWorkout

        case .running, .paused:
            ActiveWorkoutView(viewModel: viewModel)

        case .ended:
            if viewModel.isShowingSummary {
                WorkoutSummaryView(summary: viewModel.state.toSummary()) {
                    exitWorkout()
                }
            } else {
                preWorkout
            }

        @unknown default:
            preWorkout
        }
    }

    private var preWorkout: some View {
        PreWorkoutView(
            configuration: viewModel.state.configuration,
            startAction: { viewModel.start() },
            changeAction: exitWorkout,
            newRunAction: onNewRun,
            syncStatusModel: syncStatusModel
        )
    }

    @ViewBuilder
    private var pauseOverlay: some View {
        if viewModel.isShowingPauseOverlay {
            PauseOverlayView(
                resumeAction: viewModel.resume,
                endAction: viewModel.end
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.3))
            .transition(.opacity)
        }
    }

    private func exitWorkout() {
        viewModel.cancel()
        onExit()
    }
}

#Preview {
    let config = RunConfiguration(
        name: "Preview Run",
        distance: Distance(miles: 5),
        targetPace: Pace(minutes: 8, seconds: 0),
        cadenceOffset: 0,
        paceTolerance: 5
    )
    WorkoutContainerView(configuration: config, workoutManager: WorkoutManagerPreview(), syncManager: nil, onExit: {})
}
