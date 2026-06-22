import SwiftUI
import PaceRunnerShared

struct iOSPreWorkoutView: View {
    let configuration: RunConfiguration
    let startAction: () -> Void
    let changeAction: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Config name
            Text(configuration.name)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // Distance and pace summary
            if configuration.isMultiSegment, let segments = configuration.segments {
                VStack(spacing: 12) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        HStack {
                            Text("\(index + 1).")
                                .foregroundStyle(.secondary)
                            Text(segment.label)
                                .fontWeight(.semibold)
                            Spacer()
                            Text(segment.distance.formatted)
                                .monospacedDigit()
                            Text("@ \(segment.pace.formatted)/mi")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.title3)
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
            } else {
                HStack(spacing: 24) {
                    VStack(spacing: 4) {
                        Text("Distance")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f mi", configuration.distance.miles))
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                    }
                    VStack(spacing: 4) {
                        Text("Target Pace")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(configuration.milePaces.first?.formatted ?? "--:--")
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                    }
                }
            }

            Spacer()

            // Start button
            Button(action: startAction) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Start Workout")
                        .font(.title3.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)

            Button("Change Configuration", action: changeAction)
                .font(.body)
                .padding(.bottom)
        }
    }
}
