import SwiftUI
import PaceRunnerShared

struct WorkoutContainerView: View {
    @StateObject private var viewModel: WorkoutViewModel
    private let onExit: () -> Void

    init(
        configuration: RunConfiguration,
        workoutManager: WorkoutManagerProtocol,
        syncManager: SyncManagerProtocol?,
        workoutStore: WatchWorkoutStore? = nil,
        onExit: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: WorkoutViewModel(
            workoutManager: workoutManager,
            configuration: configuration,
            syncManager: syncManager,
            workoutStore: workoutStore
        ))
        self.onExit = onExit
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
            PreWorkoutView(
                configuration: viewModel.state.configuration,
                startAction: { viewModel.start() },
                changeAction: exitWorkout
            )

        case .running, .paused:
            ActiveWorkoutView(viewModel: viewModel)

        case .ended:
            if viewModel.isShowingSummary {
                WorkoutSummaryView(summary: viewModel.state.toSummary()) {
                    exitWorkout()
                }
            } else {
                PreWorkoutView(
                    configuration: viewModel.state.configuration,
                    startAction: { viewModel.start() },
                    changeAction: exitWorkout
                )
            }

        @unknown default:
            PreWorkoutView(
                configuration: viewModel.state.configuration,
                startAction: { viewModel.start() },
                changeAction: exitWorkout
            )
        }
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
