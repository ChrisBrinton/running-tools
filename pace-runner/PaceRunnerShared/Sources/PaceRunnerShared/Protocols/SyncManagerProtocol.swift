import Foundation
import Combine

/// Protocol for iPhone-Watch data synchronization
///
/// SyncManager handles:
/// - Configuration sync (iPhone → Watch)
/// - Settings sync (iPhone → Watch)
/// - Workout summary sync (Watch → iPhone)
/// - Bi-directional sync status updates
///
/// Constitution: <2 second sync when reachable, non-blocking
public protocol SyncManagerProtocol: AnyObject {
    /// Publisher for sync status updates
    var syncStatusPublisher: AnyPublisher<SyncStatus, Never> { get }

    /// Send configuration to counterpart device
    /// - Parameter configuration: Run configuration to sync
    func syncConfiguration(_ configuration: RunConfiguration)

    /// Delete configuration on counterpart device
    /// - Parameter id: Configuration ID to delete
    func deleteConfiguration(id: UUID)

    /// Send all configurations to counterpart device, replacing its storage
    /// Use for initial sync or manual "sync all" action
    /// - Parameter configurations: All configurations to sync
    func syncAllConfigurations(_ configurations: [RunConfiguration])

    /// Force sync configurations with direct sendMessage and completion callback
    /// Used when user manually taps sync — gives clear success/failure feedback
    func forceSyncAllConfigurations(_ configurations: [RunConfiguration], completion: @escaping (SyncStatus) -> Void)

    /// Send app settings to counterpart device
    /// - Parameter settings: App settings to sync
    func syncSettings(_ settings: AppSettings)

    /// Send workout summary to counterpart device (queued via transferUserInfo)
    /// - Parameter summary: Workout summary to sync
    func syncWorkoutSummary(_ summary: WorkoutSummary)

    /// Force sync a workout using sendMessage (requires both apps active)
    /// - Returns: true if message was sent
    @discardableResult
    func forceSyncWorkoutSummary(_ summary: WorkoutSummary) -> Bool

    /// Activate Watch Connectivity session
    func activate()

    /// Manually check for pending content (iOS only)
    func checkForPendingContent()

    /// Request pending workouts from watch (iOS only)
    /// Completion returns (success, watchReachable)
    func requestPendingWorkouts(completion: @escaping (Bool, Bool) -> Void)

    /// Send acknowledgment that a workout was received
    func sendWorkoutSyncAck(workoutID: UUID)

    /// Whether the watch is currently reachable
    var isWatchReachable: Bool { get }

    /// Sync Pro entitlement status to counterpart device (iPhone → Watch)
    /// - Parameter isPro: Whether the user has Pro unlocked
    func syncEntitlements(isPro: Bool)

    /// Send reset-all command to counterpart device, clearing all data
    func sendResetAll()

    /// Request counterpart device to send all configs, settings, etc.
    /// Returns true if reachable and message sent
    @discardableResult
    func requestAllData() -> Bool

    /// Sync debug log text to counterpart device
    func syncDebugLog(_ logText: String, workoutID: UUID?)
}

/// Sync status for UI feedback
public enum SyncStatus: Equatable {
    case notActivated
    case activated
    case syncing
    case synced           // Confirmed delivered (got ack from counterpart)
    case queued           // Queued via transferUserInfo (watch not reachable)
    case failed(String)
}
