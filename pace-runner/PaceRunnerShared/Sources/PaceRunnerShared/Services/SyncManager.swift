import Foundation
import WatchConnectivity
import Combine

/// Watch Connectivity synchronization manager
///
/// Handles bidirectional data sync between iPhone and Apple Watch:
/// - iPhone → Watch: Run configurations
/// - Watch → iPhone: Workout summaries
///
/// Uses three WatchConnectivity transfer methods:
/// - sendMessage: Immediate delivery when reachable (<2s latency)
/// - transferUserInfo: Queued delivery when not reachable
/// - transferFile: Large file transfer (workout summaries with splits)
///
/// Constitution compliance:
/// - <2s sync: Uses sendMessage when reachable
/// - Non-blocking: All transfers async, doesn't block UI
/// - Offline-capable: Queued transfers work without connectivity
///
/// Reference: specs/001-pace-runner-mvp/contracts/watchconnectivity.md
@available(iOS 9.0, watchOS 2.0, *)
public class SyncManager: NSObject, SyncManagerProtocol {

    // MARK: - Published Properties

    private let syncStatusSubject = CurrentValueSubject<SyncStatus, Never>(.notActivated)
    public var syncStatusPublisher: AnyPublisher<SyncStatus, Never> {
        syncStatusSubject.eraseToAnyPublisher()
    }

    // MARK: - Private Properties

    private let session: WCSession?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // Message types
    private enum MessageType: String {
        case configurationUpdate = "configurationUpdate"
        case configurationDelete = "configurationDelete"
        case configurationSyncAll = "configurationSyncAll"
        case settingsSync = "settingsSync"
        case workoutSummary = "workoutSummary"
    }

    private let loggerPrefix = "[SyncManager]"

    // MARK: - Initialization

    public override init() {
        // Check if WatchConnectivity is supported
        if WCSession.isSupported() {
            self.session = WCSession.default
        } else {
            self.session = nil
        }

        super.init()

        // Set delegate
        session?.delegate = self
    }

    // MARK: - Public Methods

    public func activate() {
        guard let session = session else {
            let message = "WatchConnectivity not supported"
            syncStatusSubject.send(.failed(message))
            return
        }

        session.activate()
    }

    public func syncConfiguration(_ configuration: RunConfiguration) {
        guard let session = session else {
            print("\(loggerPrefix) syncConfiguration: missing WCSession")
            return
        }

        do {
            // Encode configuration
            let configData = try encoder.encode(configuration)

            // Create message
            let message: [String: Any] = [
                "type": MessageType.configurationUpdate.rawValue,
                "data": configData
            ]

            // Send immediately if reachable, otherwise queue
            if session.isReachable {
                syncStatusSubject.send(.syncing)

                session.sendMessage(message, replyHandler: { _ in
                    self.syncStatusSubject.send(.synced)
                }, errorHandler: { error in
                    self.syncStatusSubject.send(.failed(error.localizedDescription))
                    // Fallback to queued transfer
                    self.queueConfiguration(message)
                })
            } else {
                // Queue for later delivery
                queueConfiguration(message)
            }

        } catch {
            syncStatusSubject.send(.failed("Encoding failed: \(error)"))
        }
    }

    public func deleteConfiguration(id: UUID) {
        guard let session = session else {
            return
        }

        let message: [String: Any] = [
            "type": MessageType.configurationDelete.rawValue,
            "id": id.uuidString
        ]

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo(message)
        }
    }

    /// Syncs all configurations at once, replacing watch storage entirely
    /// Use this for initial sync or manual "sync all" button
    public func syncAllConfigurations(_ configurations: [RunConfiguration]) {
        guard let session = session else {
            print("\(loggerPrefix) syncAllConfigurations: missing WCSession")
            return
        }

        print("\(loggerPrefix) syncAllConfigurations: syncing \(configurations.count) configs")

        do {
            let configData = try encoder.encode(configurations)

            let message: [String: Any] = [
                "type": MessageType.configurationSyncAll.rawValue,
                "data": configData
            ]

            if session.isReachable {
                print("\(loggerPrefix) syncAllConfigurations: session reachable, sending message")
                syncStatusSubject.send(.syncing)

                session.sendMessage(message, replyHandler: { _ in
                    print("\(self.loggerPrefix) syncAllConfigurations: success")
                    self.syncStatusSubject.send(.synced)
                }, errorHandler: { error in
                    print("\(self.loggerPrefix) syncAllConfigurations: error - \(error)")
                    self.syncStatusSubject.send(.failed(error.localizedDescription))
                    // Fallback to application context
                    self.sendViaApplicationContext(message)
                })
            } else {
                print("\(loggerPrefix) syncAllConfigurations: session not reachable, using application context")
                sendViaApplicationContext(message)
            }

        } catch {
            print("\(loggerPrefix) syncAllConfigurations: encoding failed - \(error)")
            syncStatusSubject.send(.failed("Encoding failed: \(error)"))
        }
    }

    /// Syncs app settings to the counterpart device (iPhone → Watch)
    public func syncSettings(_ settings: AppSettings) {
        guard let session = session else {
            print("\(loggerPrefix) syncSettings: missing WCSession")
            return
        }

        print("\(loggerPrefix) syncSettings: syncing settings")

        do {
            let settingsData = try encoder.encode(settings)

            let message: [String: Any] = [
                "type": MessageType.settingsSync.rawValue,
                "data": settingsData
            ]

            if session.isReachable {
                print("\(loggerPrefix) syncSettings: session reachable, sending message")
                syncStatusSubject.send(.syncing)

                session.sendMessage(message, replyHandler: { _ in
                    print("\(self.loggerPrefix) syncSettings: success")
                    self.syncStatusSubject.send(.synced)
                }, errorHandler: { error in
                    print("\(self.loggerPrefix) syncSettings: error - \(error)")
                    self.syncStatusSubject.send(.failed(error.localizedDescription))
                    // Fallback to application context
                    self.sendSettingsViaApplicationContext(settingsData)
                })
            } else {
                print("\(loggerPrefix) syncSettings: session not reachable, using application context")
                sendSettingsViaApplicationContext(settingsData)
            }

        } catch {
            print("\(loggerPrefix) syncSettings: encoding failed - \(error)")
            syncStatusSubject.send(.failed("Encoding failed: \(error)"))
        }
    }

    private func sendSettingsViaApplicationContext(_ settingsData: Data) {
        let message: [String: Any] = [
            "type": MessageType.settingsSync.rawValue,
            "data": settingsData
        ]
        do {
            try session?.updateApplicationContext(message)
            print("\(loggerPrefix) sendSettingsViaApplicationContext: success")
            syncStatusSubject.send(.synced)
        } catch {
            print("\(loggerPrefix) sendSettingsViaApplicationContext: failed - \(error)")
            syncStatusSubject.send(.failed("Context update failed: \(error)"))
        }
    }

    private func sendViaApplicationContext(_ message: [String: Any]) {
        do {
            try session?.updateApplicationContext(message)
            print("\(loggerPrefix) updateApplicationContext: success")
            syncStatusSubject.send(.synced)
        } catch {
            print("\(loggerPrefix) updateApplicationContext: failed - \(error)")
            syncStatusSubject.send(.failed("Context update failed: \(error)"))
        }
    }

    public func syncWorkoutSummary(_ summary: WorkoutSummary) {
        guard let session = session else {
            print("\(loggerPrefix) syncWorkoutSummary: missing WCSession")
            return
        }

        do {
            // Encode summary to JSON
            encoder.dateEncodingStrategy = .iso8601
            let jsonData = try encoder.encode(summary)

            let message: [String: Any] = [
                "type": MessageType.workoutSummary.rawValue,
                "id": summary.id.uuidString,
                "data": jsonData
            ]

            // Try sendMessage first (immediate, requires reachability)
            if session.isReachable {
                print("\(loggerPrefix) syncWorkoutSummary: sending via message (reachable)")
                session.sendMessage(message, replyHandler: nil, errorHandler: { [weak self] error in
                    // Fall back to transferUserInfo (queued, supports multiple)
                    print("\(self?.loggerPrefix ?? "") syncWorkoutSummary: message failed, using transferUserInfo: \(error)")
                    session.transferUserInfo(message)
                })
            } else {
                // Not reachable - use transferUserInfo (queued, supports multiple summaries)
                // Note: Don't use updateApplicationContext as it only stores ONE value
                print("\(loggerPrefix) syncWorkoutSummary: not reachable, using transferUserInfo")
                session.transferUserInfo(message)
            }

        } catch {
            print("\(loggerPrefix) syncWorkoutSummary: failed - \(error)")
            syncStatusSubject.send(.failed("Workout sync failed: \(error)"))
        }
    }

    // MARK: - Private Methods

    private func queueConfiguration(_ message: [String: Any]) {
        session?.transferUserInfo(message)
        syncStatusSubject.send(.synced) // Queued, will deliver later
    }
    
    /// Manually check for pending content (iOS only)
    /// Call this when user manually refreshes to check for queued transfers
    public func checkForPendingContent() {
        #if os(iOS)
        guard let session = session else { return }
        
        // Process outstanding userInfo transfers
        for transfer in session.outstandingUserInfoTransfers {
            handleReceivedMessage(transfer.userInfo)
        }
        #endif
    }
}

// MARK: - WCSessionDelegate

@available(iOS 9.0, watchOS 2.0, *)
extension SyncManager: WCSessionDelegate {

    public func session(_ session: WCSession,
                activationDidCompleteWith activationState: WCSessionActivationState,
                error: Error?) {
        print("\(loggerPrefix) activationDidComplete: state=\(activationState.rawValue), error=\(String(describing: error))")
        if let error = error {
            syncStatusSubject.send(.failed(error.localizedDescription))
        } else {
            syncStatusSubject.send(.activated)
        }
    }

    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {
        // iOS only - watch switched
    }

    public func sessionDidDeactivate(_ session: WCSession) {
        // iOS only - reactivate for new watch
        session.activate()
    }
    #endif

    public func sessionReachabilityDidChange(_ session: WCSession) {
        // Reachability changed - sync status may update
        if session.isReachable {
            syncStatusSubject.send(.activated)
        }
    }

    // MARK: - Message Receiving

    public func session(_ session: WCSession,
                didReceiveApplicationContext applicationContext: [String : Any]) {
        print("\(loggerPrefix) didReceiveApplicationContext: \(applicationContext.keys)")
        handleReceivedMessage(applicationContext)
    }

    public func session(_ session: WCSession,
                didReceiveMessage message: [String : Any]) {
        print("\(loggerPrefix) didReceiveMessage: \(message.keys)")
        handleReceivedMessage(message)
    }

    public func session(_ session: WCSession,
                didReceiveMessage message: [String : Any],
                replyHandler: @escaping ([String : Any]) -> Void) {
        print("\(loggerPrefix) didReceiveMessage (with reply): \(message.keys)")
        handleReceivedMessage(message)
        replyHandler(["status": "ok"])
    }

    public func session(_ session: WCSession,
                didReceiveUserInfo userInfo: [String: Any]) {
        print("\(loggerPrefix) didReceiveUserInfo: \(userInfo.keys)")
        handleReceivedMessage(userInfo)
    }

    public func session(_ session: WCSession,
                didReceive file: WCSessionFile) {
        handleReceivedFile(file)
    }

    public func session(_ session: WCSession,
                didFinish fileTransfer: WCSessionFileTransfer,
                error: Error?) {
        if let error = error {
            print("\(loggerPrefix) fileTransfer failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Message Handling

    private func handleReceivedMessage(_ message: [String: Any]) {
        guard let typeString = message["type"] as? String,
              let messageType = MessageType(rawValue: typeString) else {
            return
        }

        switch messageType {
        case .configurationUpdate:
            handleConfigurationUpdate(message)

        case .configurationDelete:
            handleConfigurationDelete(message)

        case .configurationSyncAll:
            handleConfigurationSyncAll(message)

        case .settingsSync:
            handleSettingsSync(message)

        case .workoutSummary:
            handleWorkoutSummaryMessage(message)
        }
    }

    private func handleConfigurationUpdate(_ message: [String: Any]) {
        guard let configData = message["data"] as? Data else {
            return
        }
        do {
            let configuration = try decoder.decode(RunConfiguration.self, from: configData)

            // Save to UserDefaults
            saveConfiguration(configuration)

            // Post notification for UI update
            NotificationCenter.default.post(
                name: .configurationSynced,
                object: configuration
            )

        } catch {
            print("\(loggerPrefix) Failed to decode configuration: \(error)")
        }
    }

    private func handleConfigurationDelete(_ message: [String: Any]) {
        guard let idString = message["id"] as? String,
              let id = UUID(uuidString: idString) else {
            return
        }

        // Delete from UserDefaults
        deleteConfigurationFromStorage(id: id)

        // Post notification for UI update
        NotificationCenter.default.post(
            name: .configurationDeleted,
            object: id
        )
    }

    private func handleConfigurationSyncAll(_ message: [String: Any]) {
        print("\(loggerPrefix) handleConfigurationSyncAll: received message")

        guard let configData = message["data"] as? Data else {
            print("\(loggerPrefix) handleConfigurationSyncAll: no data in message")
            return
        }

        do {
            let configurations = try decoder.decode([RunConfiguration].self, from: configData)
            print("\(loggerPrefix) handleConfigurationSyncAll: decoded \(configurations.count) configs")

            // Replace all configurations in storage
            if let data = try? encoder.encode(configurations) {
                UserDefaults.standard.set(data, forKey: "configurations")
                print("\(loggerPrefix) handleConfigurationSyncAll: saved to UserDefaults")
            }

            // Post notification for UI update with all configs
            NotificationCenter.default.post(
                name: .configurationsReplacedAll,
                object: configurations
            )
            print("\(loggerPrefix) handleConfigurationSyncAll: posted notification")

        } catch {
            print("\(loggerPrefix) handleConfigurationSyncAll: Failed to decode configurations: \(error)")
        }
    }

    private func handleSettingsSync(_ message: [String: Any]) {
        print("\(loggerPrefix) handleSettingsSync: received message")

        guard let settingsData = message["data"] as? Data else {
            print("\(loggerPrefix) handleSettingsSync: no data in message")
            return
        }

        do {
            let settings = try decoder.decode(AppSettings.self, from: settingsData)
            print("\(loggerPrefix) handleSettingsSync: decoded settings")

            // Save settings to UserDefaults
            settings.save()
            print("\(loggerPrefix) handleSettingsSync: saved to UserDefaults")

            // Post notification for any UI that needs to know
            NotificationCenter.default.post(
                name: .settingsSynced,
                object: settings
            )
            print("\(loggerPrefix) handleSettingsSync: posted notification")

        } catch {
            print("\(loggerPrefix) handleSettingsSync: Failed to decode settings: \(error)")
        }
    }

    private func handleWorkoutSummaryMessage(_ message: [String: Any]) {
        guard let summaryData = message["data"] as? Data else {
            return
        }
        
        do {
            decoder.dateDecodingStrategy = .iso8601
            let summary = try decoder.decode(WorkoutSummary.self, from: summaryData)
            
            // Save to UserDefaults
            saveWorkoutSummary(summary)
            
            // Post notification for UI update
            NotificationCenter.default.post(
                name: .workoutSummarySynced,
                object: summary
            )
        } catch {
            print("\(loggerPrefix) Failed to decode workout summary: \(error)")
        }
    }

    private func handleReceivedFile(_ file: WCSessionFile) {
        guard let metadata = file.metadata,
              let typeString = metadata["type"] as? String,
              let messageType = MessageType(rawValue: typeString),
              messageType == .workoutSummary else {
            return
        }

        do {
            print("\(loggerPrefix) handleReceivedFile metadata: \(metadata)")
            let data = try Data(contentsOf: file.fileURL)
            decoder.dateDecodingStrategy = .iso8601
            let summary = try decoder.decode(WorkoutSummary.self, from: data)

            print("\(loggerPrefix) received workout summary \(summary.id)")
            // Save to UserDefaults
            saveWorkoutSummary(summary)

            // Post notification for UI update
            NotificationCenter.default.post(
                name: .workoutSummarySynced,
                object: summary
            )

        } catch {
            print("Failed to decode workout summary: \(error)")
        }
    }

    // MARK: - Storage

    private func saveConfiguration(_ configuration: RunConfiguration) {
        // Load existing configurations
        var configurations = loadConfigurations()

        // Update or append
        if let index = configurations.firstIndex(where: { $0.id == configuration.id }) {
            configurations[index] = configuration
        } else {
            configurations.append(configuration)
        }

        // Save
        if let data = try? encoder.encode(configurations) {
            UserDefaults.standard.set(data, forKey: "configurations")
        }
    }

    private func deleteConfigurationFromStorage(id: UUID) {
        var configurations = loadConfigurations()
        configurations.removeAll { $0.id == id }

        if let data = try? encoder.encode(configurations) {
            UserDefaults.standard.set(data, forKey: "configurations")
        }
    }

    private func loadConfigurations() -> [RunConfiguration] {
        guard let data = UserDefaults.standard.data(forKey: "configurations"),
              let configurations = try? decoder.decode([RunConfiguration].self, from: data) else {
            return []
        }
        return configurations
    }

    private func saveWorkoutSummary(_ summary: WorkoutSummary) {
        var summaries = loadWorkoutSummaries()
        summaries.append(summary)

        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(summaries) {
            UserDefaults.standard.set(data, forKey: "workoutSummaries")
        }
    }

    private func loadWorkoutSummaries() -> [WorkoutSummary] {
        guard let data = UserDefaults.standard.data(forKey: "workoutSummaries") else {
            return []
        }

        decoder.dateDecodingStrategy = .iso8601
        guard let summaries = try? decoder.decode([WorkoutSummary].self, from: data) else {
            return []
        }
        return summaries
    }
}

// MARK: - Notifications

extension Notification.Name {
    public static let configurationSynced = Notification.Name("configurationSynced")
    public static let configurationDeleted = Notification.Name("configurationDeleted")
    public static let configurationsReplacedAll = Notification.Name("configurationsReplacedAll")
    public static let settingsSynced = Notification.Name("settingsSynced")
    public static let workoutSummarySynced = Notification.Name("workoutSummarySynced")
}
