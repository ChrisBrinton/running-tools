import SwiftUI
import PaceRunnerShared

struct iOSActiveWorkoutView: View {
    @ObservedObject var viewModel: WorkoutViewModel

    var body: some View {
        VStack(spacing: 20) {
            // Segment label for multi-segment configs
            if let segment = viewModel.state.currentSegment {
                Text(segment.label)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.purple)
                    .clipShape(Capsule())
            }

            // Big distance and time at top
            HStack(spacing: 0) {
                bigStat(title: "Distance", value: viewModel.formattedDistance())
                bigStat(title: "Time", value: viewModel.formattedTime())
            }

            // Pace grid (2x2)
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    paceWindow(label: "Split", pace: viewModel.state.paceWindows.splitPace)
                    paceWindow(label: viewModel.slowPaceLabel, pace: viewModel.state.paceWindows.slowPace)
                }
                HStack(spacing: 12) {
                    paceWindow(label: viewModel.mediumPaceLabel, pace: viewModel.state.paceWindows.mediumPace)
                    paceWindow(label: viewModel.fastPaceLabel, pace: viewModel.state.paceWindows.fastPace)
                }
            }

            // Target pace and HR
            HStack(spacing: 16) {
                miniStat(title: "Target", value: viewModel.state.targetPace.formatted)
                miniStat(title: "HR", value: viewModel.formattedHeartRate())
            }

            // Progress bar
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: viewModel.state.progress)
                    .tint(.green)
                HStack {
                    Text(String(format: "%.2f / %.2f mi",
                                viewModel.state.distanceCovered / 1609.34,
                                viewModel.state.configuration.distance.miles))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(viewModel.state.progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Big pause button
            Button {
                viewModel.pause()
            } label: {
                HStack {
                    Image(systemName: "pause.fill")
                    Text("Pause")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }

    private func bigStat(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
        }
        .frame(maxWidth: .infinity)
    }

    private func miniStat(title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospaced())
                .fontWeight(.medium)
        }
    }

    private func paceWindow(label: String, pace: Pace?) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(pace?.formatted ?? "--:--")
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(colorForPace(pace))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func colorForPace(_ pace: Pace?) -> Color {
        guard let pace = pace else { return .gray }
        let deviation = pace.totalSeconds - viewModel.state.targetPace.totalSeconds
        let absDeviation = abs(deviation)
        let tolerance = viewModel.state.effectivePaceTolerance

        if absDeviation <= tolerance {
            return .green
        } else if absDeviation <= tolerance * 2 {
            return deviation > 0 ? .yellow : .cyan
        } else {
            return deviation > 0 ? .red : .purple
        }
    }
}
