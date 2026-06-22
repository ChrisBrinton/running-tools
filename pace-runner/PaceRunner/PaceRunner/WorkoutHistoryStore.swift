import Foundation
import Combine
import UserNotifications
import PaceRunnerShared

/// Sync status for workout history
enum WorkoutSyncStatus: Equatable {
    case idle
    case syncing
    case success(count: Int)
    case failed(String)
    case watchNotReachable
}

/// Stores and observes workout summaries received from the watch.
///
/// Responsibilities:
/// - Load persisted summaries from `UserDefaults`
/// - Persist updates locally for offline access
/// - Respond to `.workoutSummarySynced` notifications emitted by `SyncManager`
/// - Request pending workouts from watch on demand
@MainActor
final class WorkoutHistoryStore: ObservableObject {

    // MARK: - Published Properties

    /// Chronological list of workouts (most recent first).
    @Published private(set) var summaries: [WorkoutSummary] = []

    /// Current sync status for UI feedback
    @Published private(set) var syncStatus: WorkoutSyncStatus = .idle

    // MARK: - Private Properties

    private let notificationCenter: NotificationCenter
    private let syncManager: SyncManagerProtocol?
    private var cancellables = Set<AnyCancellable>()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private static let storageKey = "workoutSummaries"

    /// Track count before sync to report how many were added
    private var countBeforeSync: Int = 0

    // MARK: - Initialization

    init(
        initialSummaries: [WorkoutSummary] = [],
        notificationCenter: NotificationCenter = .default,
        syncManager: SyncManagerProtocol? = nil
    ) {
        self.notificationCenter = notificationCenter
        self.syncManager = syncManager
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601

        if initialSummaries.isEmpty {
            loadSummaries()
        } else {
            summaries = initialSummaries.sorted { $0.startTime > $1.startTime }
        }

        observeSummaries()
    }

    // MARK: - Public API

    /// Reloads persisted summaries from storage and requests workouts from watch.
    func reload() {
        // Track count before sync
        countBeforeSync = summaries.count

        // Reload local storage first
        loadSummaries()

        // Check for pending sync content from watch
        syncManager?.checkForPendingContent()

        // Request pending workouts from watch
        requestWorkoutsFromWatch()
    }

    /// Request workouts from watch with status feedback
    func requestWorkoutsFromWatch() {
        guard let syncManager = syncManager else {
            syncStatus = .failed("Sync not available")
            return
        }

        countBeforeSync = summaries.count
        syncStatus = .syncing

        syncManager.requestPendingWorkouts { [weak self] success, watchReachable in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if !watchReachable {
                    self.syncStatus = .watchNotReachable
                    // Clear status after delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if case .watchNotReachable = self.syncStatus {
                            self.syncStatus = .idle
                        }
                    }
                } else if success {
                    // Wait a moment for any incoming workouts to be processed
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        let newCount = self.summaries.count - self.countBeforeSync
                        self.syncStatus = .success(count: max(0, newCount))
                        // Clear status after delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            if case .success = self.syncStatus {
                                self.syncStatus = .idle
                            }
                        }
                    }
                } else {
                    self.syncStatus = .failed("Sync failed")
                    // Clear status after delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if case .failed = self.syncStatus {
                            self.syncStatus = .idle
                        }
                    }
                }
            }
        }
    }

    /// Removes a summary from the history.
    /// - Parameter summary: The workout to delete.
    func delete(_ summary: WorkoutSummary) {
        summaries.removeAll { $0.id == summary.id }
        persist()
    }

    /// Clears all workout history (used by debug reset)
    func resetAll() {
        summaries = []
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    // MARK: - Private Helpers

    private func loadSummaries() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? decoder.decode([WorkoutSummary].self, from: data) else {
            summaries = []
            return
        }

        summaries = decoded.sorted { $0.startTime > $1.startTime }
    }

    private func observeSummaries() {
        // From watch sync
        notificationCenter.publisher(for: .workoutSummarySynced)
            .compactMap { $0.object as? WorkoutSummary }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] summary in
                self?.handleSyncedSummary(summary)
            }
            .store(in: &cancellables)

        // From iPhone-side workout completion
        notificationCenter.publisher(for: .workoutDidEnd)
            .compactMap { $0.object as? WorkoutSummary }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] summary in
                self?.handleSyncedSummary(summary)
            }
            .store(in: &cancellables)
    }

    private func handleSyncedSummary(_ summary: WorkoutSummary) {
        // Strip embedded debug log before persisting. With verbose GPS the log
        // can exceed 1MB; we already keep it separately as `lastDebugLog` and
        // sync it via the dedicated debug-log message type.
        let lean = summary.withoutDebugLog()
        let isNew = !summaries.contains(where: { $0.id == lean.id })

        if let index = summaries.firstIndex(where: { $0.id == lean.id }) {
            summaries[index] = lean
        } else {
            summaries.insert(lean, at: 0)
        }
        persist()

        // Send local notification for newly synced workouts
        if isNew {
            postSyncNotification(for: lean)
        }
    }

    private func postSyncNotification(for summary: WorkoutSummary) {
        let content = UNMutableNotificationContent()
        content.title = "Workout Synced"
        content.body = "\(summary.configurationName) - \(summary.totalDistance.formatted) in \(summary.formattedDuration) (avg \(summary.averagePace.formatted)/mi)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "workout-sync-\(summary.id.uuidString)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[WorkoutHistoryStore] Notification failed: \(error)")
            }
        }
    }

    private func persist() {
        // Keep data sorted so history view remains chronological
        summaries.sort { $0.startTime > $1.startTime }
        if let data = try? encoder.encode(summaries) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
