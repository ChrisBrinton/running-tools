import SwiftUI
import PaceRunnerShared

struct iOSWorkoutSummaryView: View {
    let summary: WorkoutSummary
    let dismissAction: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 4) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                    Text("Workout Complete")
                        .font(.title.weight(.bold))
                    Text(summary.configurationName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top)

                // Big stats
                HStack(spacing: 0) {
                    bigStat(title: "Distance", value: summary.totalDistance.formatted)
                    Divider()
                    bigStat(title: "Time", value: summary.formattedDuration)
                    Divider()
                    bigStat(title: "Avg Pace", value: summary.averagePace.formatted)
                }
                .padding(.vertical)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 16))

                // Splits
                if !summary.mileSplits.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mile Splits")
                            .font(.headline)
                        ForEach(summary.mileSplits, id: \.mileNumber) { split in
                            splitRow(split)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                Button(action: dismissAction) {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func splitRow(_ split: MileSplit) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Mile \(split.mileNumber)")
                    .fontWeight(.medium)
                Spacer()
                Text(split.actualPace.formatted)
                    .monospacedDigit()
                Text("(target \(split.targetPace.formatted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(deviationLabel(split.paceDeviation))
                    .font(.caption.monospaced())
                    .foregroundStyle(deviationColor(split.paceDeviation))
            }
            .padding(.vertical, 4)
            Divider()
        }
    }

    private func deviationLabel(_ deviation: Int) -> String {
        deviation >= 0 ? "+\(deviation)s" : "\(deviation)s"
    }

    private func deviationColor(_ deviation: Int) -> Color {
        if deviation == 0 { return .secondary }
        return abs(deviation) < 10 ? .green : .orange
    }

    private func bigStat(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}
