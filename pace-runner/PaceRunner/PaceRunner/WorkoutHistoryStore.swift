import Foundation
import Combine
import PaceRunnerShared

/// Stores and observes workout summaries received from the watch.
///
/// Responsibilities:
/// - Load persisted summaries from `UserDefaults`
/// - Persist updates locally for offline access
/// - Respond to `.workoutSummarySynced` notifications emitted by `SyncManager`
@MainActor
final class WorkoutHistoryStore: ObservableObject {

    // MARK: - Published Properties

    /// Chronological list of workouts (most recent first).
    @Published private(set) var summaries: [WorkoutSummary] = []

    // MARK: - Private Properties

    private let notificationCenter: NotificationCenter
    private let syncManager: SyncManagerProtocol?
    private var cancellable: AnyCancellable?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private static let storageKey = "workoutSummaries"

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

    /// Reloads persisted summaries from storage.
    func reload() {
        // Check for pending sync content from watch
        syncManager?.checkForPendingContent()

        // Reload local storage
        loadSummaries()
    }

    /// Removes a summary from the history.
    /// - Parameter summary: The workout to delete.
    func delete(_ summary: WorkoutSummary) {
        summaries.removeAll { $0.id == summary.id }
        persist()
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
        cancellable = notificationCenter.publisher(for: .workoutSummarySynced)
            .compactMap { $0.object as? WorkoutSummary }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] summary in
                self?.handleSyncedSummary(summary)
            }
    }

    private func handleSyncedSummary(_ summary: WorkoutSummary) {
        if let index = summaries.firstIndex(where: { $0.id == summary.id }) {
            summaries[index] = summary
        } else {
            summaries.insert(summary, at: 0)
        }
        persist()
    }

    private func persist() {
        // Keep data sorted so history view remains chronological
        summaries.sort { $0.startTime > $1.startTime }
        if let data = try? encoder.encode(summaries) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
