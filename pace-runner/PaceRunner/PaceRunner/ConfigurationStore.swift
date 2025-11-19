import Foundation
import Combine
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

    private static let storageKey = "run_configurations"

    // MARK: - Initialization

    init(syncManager: SyncManagerProtocol = SyncManager()) {
        self.syncManager = syncManager

        // Activate sync
        syncManager.activate()

        // Subscribe to sync status
        syncManager.syncStatusPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$syncStatus)

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

        // Load configurations from storage
        loadConfigurations()
    }

    // MARK: - Public Methods

    /// Creates a new configuration
    func createConfiguration(_ configuration: RunConfiguration) {
        configurations.append(configuration)
        saveConfigurations()
        syncManager.syncConfiguration(configuration)
    }

    /// Updates an existing configuration
    func updateConfiguration(_ configuration: RunConfiguration) {
        if let index = configurations.firstIndex(where: { $0.id == configuration.id }) {
            configurations[index] = configuration
            saveConfigurations()
            syncManager.syncConfiguration(configuration)
        }
    }

    /// Deletes a configuration
    func deleteConfiguration(_ configuration: RunConfiguration) {
        configurations.removeAll { $0.id == configuration.id }
        saveConfigurations()
        syncManager.deleteConfiguration(id: configuration.id)
    }

    /// Duplicates a configuration with a new name
    func duplicateConfiguration(_ configuration: RunConfiguration, newName: String) {
        let duplicate = RunConfiguration(
            name: newName,
            distance: configuration.distance,
            milePaces: configuration.milePaces,
            baseCadence: configuration.baseCadence,
            paceTolerance: configuration.paceTolerance
        )
        createConfiguration(duplicate)
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

    private func saveConfigurations() {
        if let data = try? encoder.encode(configurations) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
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
}
