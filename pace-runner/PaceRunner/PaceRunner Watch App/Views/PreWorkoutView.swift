import SwiftUI
import PaceRunnerShared

struct PreWorkoutView: View {
    let configuration: RunConfiguration
    let startAction: () -> Void
    let changeAction: (() -> Void)?
    let newRunAction: ((RunConfiguration) -> Void)?
    var syncStatusModel: WatchSyncStatusModel? = nil

    @State private var showingQuickCreate = false
    @State private var settings = AppSettings.load()
    @EnvironmentObject var entitlementManager: EntitlementManager

    private let settingsSyncedPublisher = NotificationCenter.default.publisher(for: .settingsSynced)

    var body: some View {
        VStack(spacing: 8) {
            if let syncStatusModel {
                WatchSyncStatusView(model: syncStatusModel)
            }

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
            QuickCreateRunView(settings: settings) { config in
                newRunAction?(config)
            }
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
