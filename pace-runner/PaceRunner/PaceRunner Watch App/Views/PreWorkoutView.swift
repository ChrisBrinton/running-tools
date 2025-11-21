import SwiftUI
import PaceRunnerShared

struct PreWorkoutView: View {
    let configuration: RunConfiguration
    let startAction: () -> Void
    let changeAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Text(configuration.name)
                .font(.headline)
            Text(String(format: "%.1f miles", configuration.distance.miles))
                .font(.subheadline)
            Text("Target pace: \(configuration.milePaces.first?.formatted ?? "--:--")")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Start Workout", action: startAction)
                .buttonStyle(.borderedProminent)

            if let changeAction {
                Button("Change Workout", action: changeAction)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}

#Preview {
    PreWorkoutView(configuration: RunConfiguration(
        name: "Preview Run",
        distance: Distance(miles: 5),
        targetPace: Pace(minutes: 8, seconds: 0),
        baseCadence: 180,
        paceTolerance: 5
    ), startAction: {}, changeAction: {})
}
