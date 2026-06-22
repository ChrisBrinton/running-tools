import SwiftUI
import PaceRunnerShared

struct iOSWorkoutContainerView: View {
    @StateObject private var viewModel: WorkoutViewModel
    private let onExit: () -> Void

    init(
        configuration: RunConfiguration,
        workoutManager: WorkoutManagerProtocol,
        syncManager: SyncManagerProtocol?,
        onExit: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: WorkoutViewModel(
            workoutManager: workoutManager,
            configuration: configuration,
            syncManager: syncManager
        ))
        self.onExit = onExit
    }

    var body: some View {
        ZStack {
            workoutContent
                .transition(.opacity)

            if viewModel.isShowingPauseOverlay {
                iOSPauseOverlayView(
                    resumeAction: viewModel.resume,
                    endAction: viewModel.end
                )
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var workoutContent: some View {
        switch viewModel.state.status {
        case .waitingForGPS:
            iOSPreWorkoutView(
                configuration: viewModel.state.configuration,
                startAction: { viewModel.start() },
                changeAction: exitWorkout
            )

        case .running, .paused:
            iOSActiveWorkoutView(viewModel: viewModel)

        case .ended:
            if viewModel.isShowingSummary {
                iOSWorkoutSummaryView(summary: viewModel.state.toSummary()) {
                    exitWorkout()
                }
            } else {
                iOSPreWorkoutView(
                    configuration: viewModel.state.configuration,
                    startAction: { viewModel.start() },
                    changeAction: exitWorkout
                )
            }

        @unknown default:
            iOSPreWorkoutView(
                configuration: viewModel.state.configuration,
                startAction: { viewModel.start() },
                changeAction: exitWorkout
            )
        }
    }

    private func exitWorkout() {
        viewModel.cancel()
        onExit()
    }
}
