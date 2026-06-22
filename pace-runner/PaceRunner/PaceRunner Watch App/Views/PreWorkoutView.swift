import SwiftUI
import PaceRunnerShared

struct PreWorkoutView: View {
    let configuration: RunConfiguration
    let startAction: () -> Void
    let changeAction: (() -> Void)?
    let newRunAction: ((RunConfiguration) -> Void)?

    @State private var showingQuickCreate = false
    @State private var quickCreateStep = 0  // 0=distance, 1=pace, 2=summary
    @State private var quickCreateDistance: Double?
    @State private var quickCreatePace: NamedPace?
    @State private var segments: [(distance: Double, pace: NamedPace)] = []
    @State private var settings = AppSettings.load()
    @EnvironmentObject var entitlementManager: EntitlementManager

    private let settingsSyncedPublisher = NotificationCenter.default.publisher(for: .settingsSynced)

    var body: some View {
        VStack(spacing: 8) {
            Text(configuration.name)
                .font(.headline)

            if configuration.isMultiSegment, let segments = configuration.segments {
                // Show segment summary for multi-segment configs
                VStack(spacing: 2) {
                    ForEach(segments) { segment in
                        HStack(spacing: 4) {
                            Text(segment.distance.formatted)
                                .font(.caption2)
                            Text(segment.label)
                                .font(.caption2)
                                .bold()
                            Text("@\(segment.pace.formatted)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Text(String(format: "%.1f miles", configuration.distance.miles))
                        .font(.subheadline)
                    Text(configuration.milePaces.first?.formatted ?? "--:--")
                        .font(.subheadline)
                        .bold()
                }
            }

            Button("Start", action: startAction)
                .buttonStyle(.borderedProminent)

            HStack(spacing: 8) {
                if newRunAction != nil {
                    Button {
                        quickCreateStep = 0
                        quickCreateDistance = nil
                        segments = []
                        showingQuickCreate = true
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                }

                if let changeAction {
                    Button("Change", action: changeAction)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal)
        .onReceive(settingsSyncedPublisher) { notification in
            if let syncedSettings = notification.object as? AppSettings {
                settings = syncedSettings
            } else {
                settings = AppSettings.load()
            }
        }
        .sheet(isPresented: $showingQuickCreate) {
            quickCreateSheet
        }
    }

    // MARK: - Quick Create Sheet

    private var quickCreateSheet: some View {
        NavigationStack {
            List {
                if quickCreateStep == 0 {
                    // Step 0: Pick distance
                    Section(header: Text("Pick Distance")) {
                        ForEach(settings.commonDistances, id: \.self) { distance in
                            Button {
                                quickCreateDistance = distance
                                quickCreateStep = 1
                            } label: {
                                Text(formatQuickDistance(distance))
                                    .font(.headline)
                            }
                        }
                    }
                } else if quickCreateStep == 1 {
                    // Step 1: Pick pace
                    Section(header: Text("Pick Pace")) {
                        ForEach(settings.namedPaces) { namedPace in
                            Button {
                                guard let dist = quickCreateDistance else { return }
                                segments.append((distance: dist, pace: namedPace))
                                quickCreateDistance = nil
                                quickCreateStep = 2
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
                    // Step 2: Summary with option to add more segments
                    Section(header: Text("Segments")) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { index, seg in
                            HStack {
                                Text(formatQuickDistance(seg.distance))
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
                                // Add another segment — go back to distance pick
                                quickCreateStep = 0
                            } label: {
                                Label("Add Segment", systemImage: "plus.circle.fill")
                            }
                        }
                    }

                    Section {
                        Button {
                            finishQuickCreate()
                        } label: {
                            Text("Create")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .tint(.green)
                    }
                }
            }
            .navigationTitle(quickCreateStep == 0 ? "Distance" : quickCreateStep == 1 ? "Pace" : "New Run")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingQuickCreate = false
                    }
                }
            }
        }
    }

    private func finishQuickCreate() {
        guard !segments.isEmpty else { return }

        let config: RunConfiguration
        if segments.count == 1 {
            // Single segment — create simple config
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
            // Multi-segment
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

        showingQuickCreate = false
        newRunAction?(config)
    }

    private func formatQuickDistance(_ miles: Double) -> String {
        if miles == miles.rounded() {
            return String(format: "%.0f mi", miles)
        } else {
            return String(format: "%.1f mi", miles)
        }
    }
}

#Preview {
    PreWorkoutView(configuration: RunConfiguration(
        name: "Preview Run",
        distance: Distance(miles: 5),
        targetPace: Pace(minutes: 8, seconds: 0),
        cadenceOffset: 0,
        paceTolerance: 5
    ), startAction: {}, changeAction: {}, newRunAction: { _ in })
}
