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

    /// Publisher for the tri-domain (configs / settings / history) watch-sync snapshot.
    /// Reflects a true "fully synced" state using a dirty-latch model: a domain is
    /// only "synced" while the peer has confirmed the current content and no local
    /// change has happened since.
    var syncSnapshotPublisher: AnyPublisher<WatchSyncSnapshot, Never> { get }

    /// Force a full resync of every domain (configs, settings, entitlements, and —
    /// on the watch — pending run history). Invoked when the user taps the status icon.
    func forceFullResync()

    /// Set the watch's local count of unsynced workouts. Drives the history domain of
    /// the snapshot on watchOS and is echoed to the phone via a `historyStatus` message.
    /// On iOS this is a no-op for local state.
    func setLocalHistoryPending(_ count: Int)

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

/// Connection state of the counterpart Apple Watch / iPhone.
public enum WatchConnection: Equatable {
    /// No paired watch, or the watch app is not installed (iOS only).
    case noWatch
    /// Paired + installed, but the counterpart is not currently reachable.
    case notReachable
    /// Counterpart is reachable right now.
    case reachable
}

/// A snapshot of the tri-domain watch-sync state (configs, settings, history)
/// plus connection and in-flight/error status. Drives the status indicator UI.
///
/// Uses a dirty-latch model: each `*Synced` flag is true only while the peer has
/// confirmed the exact current content (matching fingerprint) and no local change
/// has invalidated it since.
public struct WatchSyncSnapshot: Equatable {
    public var connection: WatchConnection
    public var configsSynced: Bool
    public var settingsSynced: Bool
    public var historySynced: Bool
    public var isSyncing: Bool
    public var lastError: String?

    /// True only when all three domains are confirmed synced.
    public var isFullySynced: Bool { configsSynced && settingsSynced && historySynced }

    public init(
        connection: WatchConnection = .notReachable,
        configsSynced: Bool = false,
        settingsSynced: Bool = false,
        historySynced: Bool = false,
        isSyncing: Bool = false,
        lastError: String? = nil
    ) {
        self.connection = connection
        self.configsSynced = configsSynced
        self.settingsSynced = settingsSynced
        self.historySynced = historySynced
        self.isSyncing = isSyncing
        self.lastError = lastError
    }
}
