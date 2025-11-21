import SwiftUI
import PaceRunnerShared

struct ActiveWorkoutView: View {
    @ObservedObject var viewModel: WorkoutViewModel

    var body: some View {
        VStack(spacing: 8) {
            Text(viewModel.formattedPace())
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(colorForPaceStatus())

            HStack {
                label(title: "Target", value: viewModel.state.targetPace.formatted)
                label(title: "Dist", value: viewModel.formattedDistance())
                label(title: "Time", value: viewModel.formattedTime())
            }

            ProgressView(value: viewModel.state.progress)

            Button("Pause") {
                viewModel.pause()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private func label(title: String, value: String) -> some View {
        VStack {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
        }
    }

    private func colorForPaceStatus() -> Color {
        guard let withinTolerance = viewModel.state.isWithinTolerance else {
            return .primary
        }
        return withinTolerance ? .green : .yellow
    }
}

#Preview {
    let config = RunConfiguration(
        name: "Preview Run",
        distance: Distance(miles: 5),
        targetPace: Pace(minutes: 8, seconds: 0),
        baseCadence: 180,
        paceTolerance: 5
    )
    ActiveWorkoutView(viewModel: WorkoutViewModel(
        workoutManager: WorkoutManagerPreview(),
        configuration: config
    ))
}
