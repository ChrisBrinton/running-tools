import SwiftUI
import PaceRunnerShared

/// Top-level Run tab — handles config selection and launches workouts on iPhone
struct iOSRunTabView: View {
    @ObservedObject var configurationStore: ConfigurationStore
    @ObservedObject var syncStatusModel: WatchSyncStatusModel
    let workoutManager: WorkoutManagerProtocol
    let syncManager: SyncManagerProtocol
    @EnvironmentObject var entitlementManager: EntitlementManager

    @State private var selectedConfiguration: RunConfiguration?
    @State private var showingProAlert = false

    var body: some View {
        NavigationStack {
            if let config = selectedConfiguration {
                iOSWorkoutContainerView(
                    configuration: config,
                    workoutManager: workoutManager,
                    syncManager: syncManager,
                    onExit: { selectedConfiguration = nil }
                )
                .navigationBarBackButtonHidden(true)
            } else {
                configList
            }
        }
        .alert("Pro Feature", isPresented: $showingProAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Multi-segment configurations require PaceRunner Pro.")
        }
    }

    private var configList: some View {
        List {
            if configurationStore.configurations.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No Configurations", systemImage: "figure.run")
                    } description: {
                        Text("Create one in the Configurations tab.")
                    }
                }
            } else {
                Section("Choose a Run") {
                    ForEach(configurationStore.configurations) { config in
                        Button {
                            if config.requiresPro && !entitlementManager.isPro {
                                showingProAlert = true
                            } else {
                                selectedConfiguration = config
                            }
                        } label: {
                            configRow(config)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Start a Run")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                WatchSyncStatusView(model: syncStatusModel)
            }
        }
    }

    private func configRow(_ config: RunConfiguration) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(config.name)
                    .font(.headline)
                if config.isMultiSegment, let segments = config.segments {
                    Text("\(segments.count) segments • \(config.distance.formatted)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(config.distance.formatted) @ \(config.averagePace().formatted)/mi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if config.requiresPro && !entitlementManager.isPro {
                Image(systemName: "crown.fill")
                    .foregroundStyle(.yellow)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
