import Foundation
import Combine
import PaceRunnerShared

/// Stores workout summaries locally on the watch and manages sync to phone.
///
/// Responsibilities:
/// - Persist workout summaries locally (survives app termination)
/// - Track sync status for each workout
/// - Retry syncing unsynced workouts when connectivity is available
final class WatchWorkoutStore: ObservableObject {

    // MARK: - Published Properties

    /// All locally stored workout summaries (most recent first)
    @Published private(set) var summaries: [WorkoutSummary] = []

    /// IDs of summaries that have been successfully synced to phone
    @Published private(set) var syncedIDs: Set<UUID> = []

    // MARK: - Private Properties

    private let syncManager: SyncManagerProtocol
    private var cancellables = Set<AnyCancellable>()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private static let summariesKey = "watchWorkoutSummaries"
    private static let syncedIDsKey = "watchWorkoutSyncedIDs"

    private let logPrefix = "[WatchWorkoutStore]"

    // MARK: - Initialization

    init(syncManager: SyncManagerProtocol) {
        self.syncManager = syncManager
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        loadSummaries()
        loadSyncedIDs()

        // Listen for sync status changes to retry pending syncs
        syncManager.syncStatusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                if case .activated = status {
                    self?.retryPendingSyncs()
                }
            }
            .store(in: &cancellables)

        // Also listen for reachability via notification if available
        NotificationCenter.default.publisher(for: .watchConnectivityReachable)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.retryPendingSyncs()
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Saves a workout summary locally and attempts to sync to phone.
    /// - Parameter summary: The workout summary to save
    func save(_ summary: WorkoutSummary) {
        // Save locally first (ensures data is never lost)
        if !summaries.contains(where: { $0.id == summary.id }) {
            summaries.insert(summary, at: 0)
            persistSummaries()
            print("\(logPrefix) Saved workout locally: \(summary.id)")
        }

        // Attempt to sync to phone
        syncToPhone(summary)
    }

    /// Marks a summary as successfully synced.
    /// Called when we receive confirmation from phone.
    func markAsSynced(_ id: UUID) {
        syncedIDs.insert(id)
        persistSyncedIDs()
        print("\(logPrefix) Marked as synced: \(id)")
    }

    /// Returns summaries that haven't been synced yet.
    var unsyncedSummaries: [WorkoutSummary] {
        summaries.filter { !syncedIDs.contains($0.id) }
    }

    /// Manually trigger sync retry for all unsynced workouts.
    func retryPendingSyncs() {
        let pending = unsyncedSummaries
        guard !pending.isEmpty else { return }

        print("\(logPrefix) Retrying sync for \(pending.count) unsynced workouts")
        for summary in pending {
            syncToPhone(summary)
        }
    }

    /// Deletes a workout from local storage.
    func delete(_ summary: WorkoutSummary) {
        summaries.removeAll { $0.id == summary.id }
        syncedIDs.remove(summary.id)
        persistSummaries()
        persistSyncedIDs()
    }

    /// Deletes workouts that have been synced and are older than the given date.
    /// Keeps unsynced workouts regardless of age.
    func pruneOldSyncedWorkouts(olderThan date: Date) {
        let before = summaries.count
        summaries.removeAll { summary in
            syncedIDs.contains(summary.id) && summary.startTime < date
        }
        let removed = before - summaries.count
        if removed > 0 {
            persistSummaries()
            print("\(logPrefix) Pruned \(removed) old synced workouts")
        }
    }

    // MARK: - Private Helpers

    private func syncToPhone(_ summary: WorkoutSummary) {
        print("\(logPrefix) Attempting sync to phone: \(summary.id)")
        syncManager.syncWorkoutSummary(summary)

        // Optimistically mark as synced after a delay
        // In a production app, you'd want confirmation from the phone
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.markAsSynced(summary.id)
        }
    }

    private func loadSummaries() {
        guard let data = UserDefaults.standard.data(forKey: Self.summariesKey) else {
            print("\(logPrefix) No local summaries found")
            return
        }

        do {
            summaries = try decoder.decode([WorkoutSummary].self, from: data)
            summaries.sort { $0.startTime > $1.startTime }
            print("\(logPrefix) Loaded \(summaries.count) local summaries")
        } catch {
            print("\(logPrefix) Failed to decode summaries: \(error)")
        }
    }

    private func persistSummaries() {
        do {
            let data = try encoder.encode(summaries)
            UserDefaults.standard.set(data, forKey: Self.summariesKey)
        } catch {
            print("\(logPrefix) Failed to encode summaries: \(error)")
        }
    }

    private func loadSyncedIDs() {
        guard let data = UserDefaults.standard.data(forKey: Self.syncedIDsKey),
              let ids = try? decoder.decode([UUID].self, from: data) else {
            return
        }
        syncedIDs = Set(ids)
        print("\(logPrefix) Loaded \(syncedIDs.count) synced IDs")
    }

    private func persistSyncedIDs() {
        if let data = try? encoder.encode(Array(syncedIDs)) {
            UserDefaults.standard.set(data, forKey: Self.syncedIDsKey)
        }
    }
}

