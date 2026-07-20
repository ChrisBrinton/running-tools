import SwiftUI
import PaceRunnerShared

/// Reusable on-watch "quick create" flow for building a `RunConfiguration`
/// without the phone. Presented as a sheet from both `PreWorkoutView` (the
/// "New" button on an existing run) and `ConfigurationSelectionView` (so the
/// Workouts list is never a dead-end when there are no configs yet).
///
/// Steps: 0 = pick distance, 1 = pick pace, 2 = review segments / create.
/// Pro users can chain multiple segments; free users create a single segment.
struct QuickCreateRunView: View {
    let settings: AppSettings
    /// Called with the finished configuration. The host is responsible for
    /// persisting/selecting it. This view dismisses itself first.
    let onCreate: (RunConfiguration) -> Void

    @EnvironmentObject var entitlementManager: EntitlementManager
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var pendingDistance: Double?
    @State private var segments: [(distance: Double, pace: NamedPace)] = []

    var body: some View {
        NavigationStack {
            List {
                if step == 0 {
                    Section(header: Text("Pick Distance")) {
                        ForEach(settings.commonDistances, id: \.self) { distance in
                            Button {
                                pendingDistance = distance
                                step = 1
                            } label: {
                                Text(formatDistance(distance))
                                    .font(.headline)
                            }
                        }
                    }
                } else if step == 1 {
                    Section(header: Text("Pick Pace")) {
                        ForEach(settings.namedPaces) { namedPace in
                            Button {
                                guard let dist = pendingDistance else { return }
                                segments.append((distance: dist, pace: namedPace))
                                pendingDistance = nil
                                step = 2
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(namedPace.name)
                                        .font(.headline)
                                    Text("\(namedPace.pace.formatted)/mi")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Section(header: Text("Segments")) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                            HStack {
                                Text(formatDistance(seg.distance))
                                    .font(.headline)
                                Spacer()
                                Text(seg.pace.name)
                                    .foregroundStyle(.secondary)
                                Text(seg.pace.pace.formatted)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if entitlementManager.isPro {
                        Section {
                            Button {
                                // Add another segment — back to distance pick
                                step = 0
                            } label: {
                                Label("Add Segment", systemImage: "plus.circle.fill")
                            }
                        }
                    }

                    Section {
                        Button {
                            finish()
                        } label: {
                            Text("Create")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .tint(.green)
                    }
                }
            }
            .navigationTitle(step == 0 ? "Distance" : step == 1 ? "Pace" : "New Run")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func finish() {
        guard !segments.isEmpty else { return }

        let config: RunConfiguration
        if segments.count == 1 {
            let seg = segments[0]
            let name = AppSettings.derivedConfigName(distanceMiles: seg.distance, paceName: seg.pace.name)
            config = RunConfiguration(
                name: name,
                distance: Distance(miles: seg.distance),
                targetPace: seg.pace.pace,
                cadenceOffset: 0,
                paceTolerance: settings.defaultTolerance,
                autoEndRun: true
            )
        } else {
            let runSegments = segments.map { seg in
                RunSegment(
                    distance: Distance(miles: seg.distance),
                    pace: seg.pace.pace,
                    label: seg.pace.name
                )
            }
            let name = AppSettings.derivedSegmentConfigName(segments: runSegments)
            config = RunConfiguration(
                name: name,
                segments: runSegments,
                cadenceOffset: 0,
                paceTolerance: settings.defaultTolerance,
                autoEndRun: true
            )
        }

        dismiss()
        onCreate(config)
    }

    private func formatDistance(_ miles: Double) -> String {
        if miles == miles.rounded() {
            return String(format: "%.0f mi", miles)
        } else {
            return String(format: "%.1f mi", miles)
        }
    }
}
