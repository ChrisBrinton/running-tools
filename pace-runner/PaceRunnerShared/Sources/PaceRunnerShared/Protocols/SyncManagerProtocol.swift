import Foundation
import Combine

/// Protocol for iPhone-Watch data synchronization
///
/// SyncManager handles:
/// - Configuration sync (iPhone → Watch)
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

    /// Send workout summary to counterpart device
    /// - Parameter summary: Workout summary to sync
    func syncWorkoutSummary(_ summary: WorkoutSummary)

    /// Activate Watch Connectivity session
    func activate()
    
    /// Manually check for pending content (iOS only)
    func checkForPendingContent()
}

/// Sync status for UI feedback
public enum SyncStatus: Equatable {
    case notActivated
    case activated
    case syncing
    case synced
    case failed(String)
}
