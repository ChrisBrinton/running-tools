import Foundation
import Combine
import SwiftUI
import PaceRunnerShared

/// ObservableObject for managing run configurations
///
/// Responsibilities:
/// - Load/save configurations from UserDefaults
/// - Provide CRUD operations
/// - Sync configurations to Watch via SyncManager
/// - Observe sync status
///
/// Constitution compliance:
/// - Workout Independence: Stores locally in UserDefaults
/// - User Experience Consistency: Single source of truth for configs
@MainActor
class ConfigurationStore: ObservableObject {

    // MARK: - Published Properties

    /// All saved configurations
    @Published var configurations: [RunConfiguration] = []

    /// Current sync status
    @Published var syncStatus: SyncStatus = .notActivated

    // MARK: - Private Properties

    private let syncManager: SyncManagerProtocol
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cancellables = Set<AnyCancellable>()
    private var needsInitialSync = true

    private static let storageKey = "configurations"

    // MARK: - Initialization

    init(syncManager: SyncManagerProtocol = SyncManager()) {
        self.syncManager = syncManager

        // Subscribe to sync status
        syncManager.syncStatusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.syncStatus = status
                if status == .activated {
                    self?.syncAllConfigurationsIfNeeded()
                }
            }
            .store(in: &cancellables)

        // Listen for configuration sync notifications
        NotificationCenter.default.publisher(for: .configurationSynced)
            .sink { [weak self] notification in
                if let config = notification.object as? RunConfiguration {
                    self?.handleSyncedConfiguration(config)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .configurationDeleted)
            .sink { [weak self] notification in
                if let id = notification.object as? UUID {
                    self?.handleDeletedConfiguration(id: id)
                }
            }
            .store(in: &cancellables)

        // Adopt the merged union the SyncManager produces when the watch syncs
        // its configs to us. Without this the phone's in-memory list diverged
        // from what SyncManager persisted (the phone kept showing its own set
        // while storage held the merge) — the bug that made watch-created
        // configs seem not to arrive.
        NotificationCenter.default.publisher(for: .configurationsReplacedAll)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let configs = notification.object as? [RunConfiguration] {
                    self?.handleReplacedAllConfigurations(configs)
                }
            }
            .store(in: &cancellables)

        // Load configurations from storage
        loadConfigurations()
        syncAllConfigurationsIfNeeded()
    }

    // MARK: - Public Methods

    /// Creates a new configuration
    func createConfiguration(_ configuration: RunConfiguration) {
        configurations.append(configuration)
        saveConfigurations()
        syncAllConfigurations()
    }

    /// Updates an existing configuration
    func updateConfiguration(_ configuration: RunConfiguration) {
        if let index = configurations.firstIndex(where: { $0.id == configuration.id }) {
            configurations[index] = configuration
            saveConfigurations()
            syncAllConfigurations()
        }
    }

    /// Deletes a configuration
    func deleteConfiguration(_ configuration: RunConfiguration) {
        configurations.removeAll { $0.id == configuration.id }
        saveConfigurations()
        // Propagate the delete as a tombstone, NOT as a full-set replace:
        // under merge sync a shorter set no longer deletes anything on the peer,
        // so an explicit deletion is the only thing that removes it there.
        syncManager.deleteConfiguration(id: configuration.id)
    }

    /// Duplicates a configuration with a new name
    func duplicateConfiguration(_ configuration: RunConfiguration, newName: String) {
        let duplicate = RunConfiguration(
            name: newName,
            distance: configuration.distance,
            milePaces: configuration.milePaces,
            cadenceOffset: configuration.cadenceOffset,
            paceTolerance: configuration.paceTolerance,
            metronomeMinVolume: configuration.metronomeMinVolume,
            metronomeMaxVolume: configuration.metronomeMaxVolume,
            autoEndRun: configuration.autoEndRun
        )
        createConfiguration(duplicate)
    }

    /// Moves configurations from one position to another
    func moveConfigurations(from source: IndexSet, to destination: Int) {
        configurations.move(fromOffsets: source, toOffset: destination)
        saveConfigurations()
        syncAllConfigurations()
    }

    /// Clears all configurations (used by debug reset)
    func resetAll() {
        configurations = []
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    // MARK: - Private Methods

    private func loadConfigurations() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let configs = try? decoder.decode([RunConfiguration].self, from: data) else {
            // No saved configurations, start with empty array
            configurations = []
            return
        }
        configurations = configs
    }

    private func syncAllConfigurationsIfNeeded() {
        guard needsInitialSync else { return }
        needsInitialSync = false
        // Never let the automatic activation/initial sync push an EMPTY set:
        // `syncAllConfigurations` is a full REPLACE on the watch, so an empty
        // push from a fresh/not-yet-loaded phone silently wipes configs the
        // user just created on the watch. Only explicit user actions
        // (deleteConfiguration → syncAllConfigurations) may clear the watch.
        guard !configurations.isEmpty else {
            print("[ConfigurationStore] skipping initial sync — no local configs to push")
            return
        }
        syncAllConfigurations()
    }

    /// Syncs all configurations to watch, replacing watch storage
    func syncAllConfigurations() {
        syncManager.syncAllConfigurations(configurations)
    }

    /// Manual force sync — tries direct sendMessage, reports result clearly
    func forceSyncToWatch() {
        syncStatus = .syncing
        syncManager.forceSyncAllConfigurations(configurations) { [weak self] result in
            DispatchQueue.main.async {
                self?.syncStatus = result
            }
        }
    }

    private func saveConfigurations() {
        if let data = try? encoder.encode(configurations) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        // Mirror to the home server. Cheap (small JSON) and only fires
        // when the publisher is configured.
        let snapshot = configurations
        Task { @MainActor in
            await HealthKitPublisher.shared.publishConfigurations(snapshot)
        }
    }

    private func handleSyncedConfiguration(_ configuration: RunConfiguration) {
        if let index = configurations.firstIndex(where: { $0.id == configuration.id }) {
            // Update existing
            configurations[index] = configuration
        } else {
            // Add new
            configurations.append(configuration)
        }
        saveConfigurations()
    }

    private func handleDeletedConfiguration(id: UUID) {
        configurations.removeAll { $0.id == id }
        saveConfigurations()
    }

    /// Adopts the merged union produced by SyncManager. Persists locally (and
    /// mirrors to the server) but does NOT re-sync — that would echo endlessly.
    private func handleReplacedAllConfigurations(_ newConfigurations: [RunConfiguration]) {
        configurations = newConfigurations
        saveConfigurations()
    }
}
