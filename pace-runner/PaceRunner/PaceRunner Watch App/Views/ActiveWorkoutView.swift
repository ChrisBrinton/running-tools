import SwiftUI
import PaceRunnerShared

struct ActiveWorkoutView: View {
    @ObservedObject var viewModel: WorkoutViewModel

    var body: some View {
        VStack(spacing: 8) {
            // 2x2 Pace Grid (Slow=master, Medium, Fast)
            VStack(spacing: 4) {
                HStack(spacing: 12) {
                    paceWindow(label: "Spt", pace: viewModel.state.paceWindows.splitPace)
                    paceWindow(label: viewModel.slowPaceLabel, pace: viewModel.state.paceWindows.slowPace)
                }
                HStack(spacing: 12) {
                    paceWindow(label: viewModel.mediumPaceLabel, pace: viewModel.state.paceWindows.mediumPace)
                    paceWindow(label: viewModel.fastPaceLabel, pace: viewModel.state.paceWindows.fastPace)
                }
            }
            .padding(.vertical, 4)

            // Segment label for multi-segment configs
            if let segment = viewModel.state.currentSegment {
                Text(segment.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.15))
                    .clipShape(Capsule())
            }

            // Stats row
            HStack(spacing: 8) {
                statLabel(title: "Target", value: viewModel.state.targetPace.formatted)
                statLabel(title: "Dist", value: viewModel.formattedDistance())
                statLabel(title: "Time", value: viewModel.formattedTime())
                statLabel(title: "HR", value: viewModel.formattedHeartRate())
            }

            ProgressView(value: viewModel.state.progress)

            Button("Pause") {
                viewModel.pause()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    /// Displays a single pace window with label and color coding
    private func paceWindow(label: String, pace: Pace?) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(pace?.formatted ?? "--:--")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(colorForPace(pace))
        }
        .frame(maxWidth: .infinity)
    }

    /// Small stat label for target/distance/time
    private func statLabel(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
        }
        .frame(maxWidth: .infinity)
    }

    /// Color codes a pace based on its deviation from target
    /// - Green: On target (within tolerance)
    /// - Yellow/Cyan: Slightly off (1-2x tolerance) - Yellow=slow, Cyan=fast
    /// - Red/Purple: Very off (>2x tolerance) - Red=very slow, Purple=very fast
    private func colorForPace(_ pace: Pace?) -> Color {
        guard let pace = pace else {
            return .gray
        }

        // Positive deviation = slower than target, negative = faster
        let deviation = pace.totalSeconds - viewModel.state.targetPace.totalSeconds
        let absDeviation = abs(deviation)
        let tolerance = viewModel.state.effectivePaceTolerance

        if absDeviation <= tolerance {
            // On target
            return .green
        } else if absDeviation <= tolerance * 2 {
            // Slightly off: yellow for slow, cyan for fast
            return deviation > 0 ? .yellow : .cyan
        } else {
            // Very off: red for very slow, purple for very fast
            return deviation > 0 ? .red : .purple
        }
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
    ActiveWorkoutView(viewModel: WorkoutViewModel(
        workoutManager: WorkoutManagerPreview(),
        configuration: config
    ))
}
