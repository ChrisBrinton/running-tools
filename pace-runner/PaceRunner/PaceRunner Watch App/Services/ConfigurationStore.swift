import Foundation
import Combine
import PaceRunnerShared

final class ConfigurationStore: ObservableObject {
    @Published private(set) var configurations: [RunConfiguration] = []
    @Published var selectedConfiguration: RunConfiguration?
    @Published var syncStatus: SyncStatus = .notActivated

    private let storageKey = "configurations"
    private let syncManager: SyncManagerProtocol
    private var cancellables = Set<AnyCancellable>()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(syncManager: SyncManagerProtocol = SyncManager()) {
        self.syncManager = syncManager
        loadConfigurations()
        selectedConfiguration = configurations.first

        syncManager.activate()
        syncManager.syncStatusPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$syncStatus)

        NotificationCenter.default.publisher(for: .configurationSynced)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let config = notification.object as? RunConfiguration {
                    self?.handleSyncedConfiguration(config)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .configurationDeleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let id = notification.object as? UUID {
                    self?.handleDeletedConfiguration(id: id)
                }
            }
            .store(in: &cancellables)
    }

    func select(_ configuration: RunConfiguration) {
        selectedConfiguration = configuration
    }

    func clearSelection() {
        selectedConfiguration = nil
    }

    private func loadConfigurations() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? decoder.decode([RunConfiguration].self, from: data),
              !decoded.isEmpty else {
            configurations = [Self.sampleConfiguration]
            return
        }
        configurations = decoded
        selectedConfiguration = configurations.first
    }

    private func saveConfigurations() {
        if let data = try? encoder.encode(configurations) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func handleSyncedConfiguration(_ configuration: RunConfiguration) {
        removeSampleIfNeeded()
        if let index = configurations.firstIndex(where: { $0.id == configuration.id }) {
            configurations[index] = configuration
        } else {
            configurations.append(configuration)
        }
        saveConfigurations()
        if selectedConfiguration == nil {
            selectedConfiguration = configuration
        }
    }

    private func handleDeletedConfiguration(id: UUID) {
        configurations.removeAll { $0.id == id }
        saveConfigurations()
        if selectedConfiguration?.id == id {
            selectedConfiguration = configurations.first
        }
    }

    private func removeSampleIfNeeded() {
        if configurations.count == 1,
           configurations.first?.name == Self.sampleConfiguration.name {
            configurations.removeAll()
        }
    }

    private static var sampleConfiguration: RunConfiguration {
        RunConfiguration(
            name: "Preview Run",
            distance: Distance(miles: 5),
            targetPace: Pace(minutes: 8, seconds: 0),
            baseCadence: 180,
            paceTolerance: 5
        )
    }
}
