import SwiftUI
import PaceRunnerShared

struct WorkoutSummaryView: View {
    let summary: WorkoutSummary
    let dismissAction: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("Workout Complete")
                .font(.headline)

            Text("Distance: \(summary.totalDistance.formatted)")
            Text("Avg Pace: \(summary.averagePace.formatted)")

            List(summary.mileSplits, id: \.mileNumber) { split in
                VStack(alignment: .leading) {
                    Text("Mile \(split.mileNumber)")
                    Text(split.actualPace.formatted)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Done", action: dismissAction)
        }
    }
}

#Preview {
    let summary = WorkoutSummary(
        configurationName: "Preview Run",
        startTime: Date(),
        endTime: Date().addingTimeInterval(1800),
        totalDistance: Distance(miles: 5),
        averagePace: Pace(minutes: 8, seconds: 0),
        mileSplits: []
    )
    WorkoutSummaryView(summary: summary, dismissAction: {})
}
