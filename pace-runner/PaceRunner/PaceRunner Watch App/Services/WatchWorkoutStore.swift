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

        // Listen for reachability via notification
        NotificationCenter.default.publisher(for: .watchConnectivityReachable)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.retryPendingSyncs()
            }
            .store(in: &cancellables)

        // Listen for phone requesting workouts
        NotificationCenter.default.publisher(for: .phoneRequestedWorkouts)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.sendAllWorkoutsToPhone()
            }
            .store(in: &cancellables)

        // Listen for sync acknowledgments from phone
        NotificationCenter.default.publisher(for: .workoutSyncAckReceived)
            .receive(on: DispatchQueue.main)
            .compactMap { $0.object as? UUID }
            .sink { [weak self] workoutID in
                self?.markAsSynced(workoutID)
            }
            .store(in: &cancellables)

        // Listen for workout endings (covers both manual and auto-end paths)
        NotificationCenter.default.publisher(for: .workoutDidEnd)
            .receive(on: DispatchQueue.main)
            .compactMap { $0.object as? WorkoutSummary }
            .sink { [weak self] summary in
                print("[WatchWorkoutStore] Received workoutDidEnd notification")
                self?.save(summary)
            }
            .store(in: &cancellables)

        // Listen for reset-all command from iPhone
        NotificationCenter.default.publisher(for: .resetAllReceived)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.summaries = []
                self?.syncedIDs = []
                UserDefaults.standard.removeObject(forKey: Self.summariesKey)
                UserDefaults.standard.removeObject(forKey: Self.syncedIDsKey)
                self?.reportPendingHistory()
                print("[WatchWorkoutStore] Reset all data")
            }
            .store(in: &cancellables)

        // Listen for a forced full resync request (user tapped the status icon)
        NotificationCenter.default.publisher(for: .forceResyncRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.retryPendingSyncs()
            }
            .store(in: &cancellables)

        // Retry unsynced workouts shortly after launch (session may need time to activate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.retryPendingSyncs()
        }

        // Seed the sync manager with our current pending-history count.
        reportPendingHistory()

        print("\(logPrefix) Initialized: \(summaries.count) stored, \(unsyncedSummaries.count) unsynced")
    }

    /// Push the current unsynced-workout count into the SyncManager so the
    /// tri-domain snapshot (and the phone) can reflect history-sync state.
    private func reportPendingHistory() {
        syncManager.setLocalHistoryPending(unsyncedSummaries.count)
    }

    // MARK: - Public API

    /// Saves a workout summary locally and attempts to sync to phone.
    ///
    /// The full `debugLog` is intentionally stripped before persistence and
    /// sync — verbose GPS workouts can produce >1MB of debug events, which
    /// caused crashes on small watch memory (UserDefaults OOM) and oversize
    /// WatchConnectivity payloads. The log is preserved separately via
    /// `WorkoutManager.saveDebugLog()` (UserDefaults `lastDebugLog`) and
    /// synced via `SyncManager.syncDebugLog`.
    ///
    /// - Parameter summary: The workout summary to save
    func save(_ summary: WorkoutSummary) {
        let lean = summary.withoutDebugLog()
        if !summaries.contains(where: { $0.id == lean.id }) {
            summaries.insert(lean, at: 0)
            persistSummaries()
            reportPendingHistory()
            print("\(logPrefix) Saved workout locally (debug log stripped): \(lean.id)")
        }

        // Attempt to sync to phone
        syncToPhone(lean)
    }

    /// Marks a summary as successfully synced.
    /// Called when we receive confirmation from phone.
    func markAsSynced(_ id: UUID) {
        syncedIDs.insert(id)
        persistSyncedIDs()
        reportPendingHistory()
        print("\(logPrefix) Marked as synced: \(id)")
    }

    /// Returns summaries that haven't been synced yet.
    var unsyncedSummaries: [WorkoutSummary] {
        summaries.filter { !syncedIDs.contains($0.id) }
    }

    /// Retry syncing all unsynced workouts using sendMessage when reachable,
    /// falling back to transferUserInfo otherwise.
    func retryPendingSyncs() {
        let pending = unsyncedSummaries
        guard !pending.isEmpty else { return }

        // Prefer sendMessage (force sync) since transferUserInfo has proven unreliable
        if syncManager.isWatchReachable {
            print("\(logPrefix) Retrying sync for \(pending.count) unsynced workouts via sendMessage (reachable)")
            for summary in pending {
                _ = syncManager.forceSyncWorkoutSummary(summary)
            }
        } else {
            print("\(logPrefix) Retrying sync for \(pending.count) unsynced workouts via transferUserInfo (not reachable)")
            for summary in pending {
                syncToPhone(summary)
            }
        }
    }

    /// Force sync all workouts using sendMessage (requires both apps active).
    /// Returns (sent, total) count for UI feedback.
    func forceSync() -> (sent: Int, total: Int) {
        let all = summaries
        guard !all.isEmpty else {
            print("\(logPrefix) forceSync: no workouts to sync")
            return (0, 0)
        }

        print("\(logPrefix) forceSync: attempting sendMessage for \(all.count) workouts")
        var sentCount = 0
        for summary in all {
            if syncManager.forceSyncWorkoutSummary(summary) {
                sentCount += 1
            }
        }
        print("\(logPrefix) forceSync: sent \(sentCount)/\(all.count)")
        return (sentCount, all.count)
    }

    /// Deletes a workout from local storage.
    func delete(_ summary: WorkoutSummary) {
        summaries.removeAll { $0.id == summary.id }
        syncedIDs.remove(summary.id)
        persistSummaries()
        persistSyncedIDs()
        reportPendingHistory()
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
        // Try sendMessage first (reliable when reachable), fall back to transferUserInfo
        if syncManager.isWatchReachable {
            print("\(logPrefix) Syncing to phone via sendMessage: \(summary.id)")
            _ = syncManager.forceSyncWorkoutSummary(summary)
        } else {
            print("\(logPrefix) Queuing sync via transferUserInfo (not reachable): \(summary.id)")
            syncManager.syncWorkoutSummary(summary)
        }
        // Don't mark as synced here - wait for acknowledgment from phone
    }

    /// Send all workouts to phone (called when phone requests them).
    /// Uses sendMessage since phone must be reachable to have sent the request.
    private func sendAllWorkoutsToPhone() {
        print("\(logPrefix) Phone requested workouts, sending \(summaries.count) total via sendMessage")

        for summary in summaries {
            _ = syncManager.forceSyncWorkoutSummary(summary)
        }
    }

    private static let loadInProgressKey = "watchWorkoutStore_loadInProgress"

    private func loadSummaries() {
        // Crash-recovery tombstone: if the last launch died while decoding
        // summaries (OOM from oversize blobs kills the process — no catch
        // possible), the flag below will still be set when we get here.
        // Treat the stored blob as corrupt and start clean instead of
        // crashing again in an infinite loop.
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.loadInProgressKey) {
            print("\(logPrefix) Previous launch crashed during summary load — clearing corrupt blob")
            defaults.removeObject(forKey: Self.summariesKey)
            defaults.set(false, forKey: Self.loadInProgressKey)
            defaults.synchronize()
            return
        }

        guard let data = defaults.data(forKey: Self.summariesKey) else {
            print("\(logPrefix) No local summaries found")
            return
        }

        // Set tombstone, decode, then clear. If the decode crashes the process,
        // the next launch will see the tombstone and wipe the data.
        defaults.set(true, forKey: Self.loadInProgressKey)
        defaults.synchronize()

        do {
            summaries = try decoder.decode([WorkoutSummary].self, from: data)
            summaries.sort { $0.startTime > $1.startTime }
            print("\(logPrefix) Loaded \(summaries.count) local summaries")
        } catch {
            print("\(logPrefix) Failed to decode summaries: \(error)")
            // Decode threw — corrupt data. Drop it so we don't re-crash.
            defaults.removeObject(forKey: Self.summariesKey)
        }

        defaults.set(false, forKey: Self.loadInProgressKey)
        defaults.synchronize()
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

