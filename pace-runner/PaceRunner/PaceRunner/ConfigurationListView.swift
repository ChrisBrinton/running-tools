import SwiftUI
import PaceRunnerShared

/// Main view showing list of run configurations
///
/// Features:
/// - List of all saved configurations
/// - Create new configuration
/// - Edit existing configurations
/// - Delete configurations
/// - Duplicate configurations
/// - Sync status indicator
///
/// Constitution compliance:
/// - User Experience Consistency: Clear, simple list interface
/// - Workout Independence: Works offline, syncs when available
struct ConfigurationListView: View {

    @ObservedObject var store: ConfigurationStore
    @State private var showingNewConfiguration = false
    @State private var configurationToEdit: RunConfiguration?
    @State private var isEditMode = false

    var body: some View {
        NavigationStack {
            Group {
                if store.configurations.isEmpty {
                    emptyState
                } else {
                    configurationList
                }
            }
            .navigationTitle("Run Configurations")
            .environment(\.editMode, isEditMode ? .constant(.active) : .constant(.inactive))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 12) {
                        syncStatusIndicator
                        Button {
                            store.syncAllConfigurations()
                        } label: {
                            Label("Sync to Watch", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingNewConfiguration = true
                        } label: {
                            Label("Add New", systemImage: "plus")
                        }

                        Button {
                            isEditMode.toggle()
                        } label: {
                            if isEditMode {
                                Label("Done Editing", systemImage: "checkmark")
                            } else {
                                Label("Reorder & Delete", systemImage: "arrow.up.arrow.down")
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.title3)
                    }
                }
            }
            .sheet(isPresented: $showingNewConfiguration) {
                ConfigurationDetailView(store: store)
            }
            .sheet(item: $configurationToEdit) { configuration in
                ConfigurationDetailView(
                    store: store,
                    configuration: configuration
                )
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Configurations", systemImage: "figure.run")
        } description: {
            Text("Create your first run configuration to get started")
        } actions: {
            Button("Create Configuration") {
                showingNewConfiguration = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var configurationList: some View {
        List {
            ForEach(store.configurations) { configuration in
                ConfigurationRow(configuration: configuration)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        configurationToEdit = configuration
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            store.deleteConfiguration(configuration)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            store.duplicateConfiguration(
                                configuration,
                                newName: "\(configuration.name) Copy"
                            )
                        } label: {
                            Label("Duplicate", systemImage: "doc.on.doc")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            configurationToEdit = configuration
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
            }
            .onMove { source, destination in
                store.moveConfigurations(from: source, to: destination)
            }
            .onDelete { indexSet in
                for index in indexSet {
                    store.deleteConfiguration(store.configurations[index])
                }
            }
        }
    }

    private var syncStatusIndicator: some View {
        Group {
            switch store.syncStatus {
            case .notActivated:
                Image(systemName: "applewatch.slash")
                    .foregroundStyle(.gray)
            case .activated:
                Image(systemName: "applewatch")
                    .foregroundStyle(.green)
            case .syncing:
                ProgressView()
            case .synced:
                Image(systemName: "checkmark.applewatch")
                    .foregroundStyle(.green)
            case .failed(let message):
                Image(systemName: "exclamationmark.applewatch")
                    .foregroundStyle(.red)
                    .help(message)
            }
        }
        .font(.title3)
    }
}

// MARK: - Configuration Row

struct ConfigurationRow: View {

    let configuration: RunConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(configuration.name)
                .font(.headline)

            HStack(spacing: 16) {
                Label(configuration.distance.formatted, systemImage: "figure.run")
                    .font(.subheadline)

                Label(configuration.averagePace().formatted, systemImage: "gauge.with.dots.needle.67percent")
                    .font(.subheadline)

                if configuration.milePaces.count > 1 {
                    // Show if it's a progressive run
                    let firstPace = configuration.milePaces.first!
                    let lastPace = configuration.milePaces.last!
                    if firstPace != lastPace {
                        Label("Progressive", systemImage: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    MainActor.assumeIsolated {
        ConfigurationListView(store: ConfigurationStore())
    }
}
