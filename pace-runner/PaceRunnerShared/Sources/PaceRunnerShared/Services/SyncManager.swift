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
        case requestPendingWorkouts = "requestPendingWorkouts"
        case workoutSyncAck = "workoutSyncAck"
        case pendingWorkoutsResponse = "pendingWorkoutsResponse"
        case entitlementSync = "entitlementSync"
        case resetAll = "resetAll"
        case requestAllData = "requestAllData"
        case debugLog = "debugLog"
        case configSyncAck = "configSyncAck"
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
            let configData = try encoder.encode(configuration)

            let message: [String: Any] = [
                "type": MessageType.configurationUpdate.rawValue,
                "data": configData
            ]

            sendReliably(message, label: "syncConfiguration")

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

        sendReliably(message, label: "deleteConfiguration")
    }

    /// Syncs all configurations at once, replacing watch storage entirely
    /// Use this for initial sync or manual "sync all" button
    public func syncAllConfigurations(_ configurations: [RunConfiguration]) {
        guard let session = session else {
            print("\(loggerPrefix) syncAllConfigurations: missing WCSession")
            syncStatusSubject.send(.failed("WCSession not available"))
            return
        }

        print("\(loggerPrefix) syncAllConfigurations: syncing \(configurations.count) configs")

        do {
            let configData = try encoder.encode(configurations)

            let message: [String: Any] = [
                "type": MessageType.configurationSyncAll.rawValue,
                "data": configData
            ]

            // Use sendReliably for immediate + queued delivery
            sendReliably(message, label: "syncAllConfigurations")

            // Also update applicationContext — this is delivered immediately when
            // the counterpart app next launches, even from cold start.
            // applicationContext only holds one value, so we pack configs into it.
            do {
                try session.updateApplicationContext(message)
                print("\(loggerPrefix) syncAllConfigurations: also updated applicationContext")
            } catch {
                print("\(loggerPrefix) syncAllConfigurations: applicationContext update failed - \(error)")
            }

        } catch {
            print("\(loggerPrefix) syncAllConfigurations: encoding failed - \(error)")
            syncStatusSubject.send(.failed("Encoding failed: \(error)"))
        }
    }

    /// Force sync configurations via sendMessage with direct completion callback.
    /// Used for manual user-initiated sync — gives clear success/failure/timeout.
    public func forceSyncAllConfigurations(_ configurations: [RunConfiguration], completion: @escaping (SyncStatus) -> Void) {
        guard let session = session else {
            completion(.failed("WCSession not available"))
            return
        }

        guard session.activationState == .activated else {
            completion(.failed("WCSession not activated"))
            return
        }

        guard session.isReachable else {
            // Not reachable — still queue it, but tell the user
            do {
                let configData = try encoder.encode(configurations)
                let message: [String: Any] = [
                    "type": MessageType.configurationSyncAll.rawValue,
                    "data": configData
                ]
                session.transferUserInfo(message)
                try session.updateApplicationContext(message)
            } catch {
                // ignore encoding errors for queued path
            }
            completion(.failed("Watch not reachable — queued for later"))
            return
        }

        do {
            let configData = try encoder.encode(configurations)
            let message: [String: Any] = [
                "type": MessageType.configurationSyncAll.rawValue,
                "data": configData
            ]

            var completed = false
            let completionLock = NSLock()

            // Use sendMessage — reply handler confirms WCSession delivered it
            session.sendMessage(message, replyHandler: { _ in
                completionLock.lock()
                guard !completed else { completionLock.unlock(); return }
                completed = true
                completionLock.unlock()

                print("[SyncManager] forceSyncAllConfigurations: delivered via sendMessage")
                // Wait briefly for the configSyncAck to arrive and set .synced
                // The ack is the real confirmation, but the reply means it got through
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    // If ack already set .synced, don't override
                    if self.syncStatusSubject.value != .synced {
                        completion(.synced)
                    } else {
                        completion(.synced)
                    }
                }
            }, errorHandler: { error in
                completionLock.lock()
                guard !completed else { completionLock.unlock(); return }
                completed = true
                completionLock.unlock()

                print("[SyncManager] forceSyncAllConfigurations: sendMessage error - \(error)")
                // Fall back to queue
                session.transferUserInfo(message)
                completion(.failed("Send failed: \(error.localizedDescription) — queued for later"))
            })

            // Timeout after 8 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 8.0) {
                completionLock.lock()
                guard !completed else { completionLock.unlock(); return }
                completed = true
                completionLock.unlock()

                print("[SyncManager] forceSyncAllConfigurations: timeout")
                completion(.failed("Timed out — queued for later"))
            }

        } catch {
            completion(.failed("Encoding failed: \(error.localizedDescription)"))
        }
    }

    /// Requests the counterpart device to send all configs, settings, etc.
    /// Returns true if the message was sent immediately (reachable), false if queued.
    @discardableResult
    public func requestAllData() -> Bool {
        guard let session = session else {
            print("\(loggerPrefix) requestAllData: missing WCSession")
            return false
        }

        let message: [String: Any] = [
            "type": MessageType.requestAllData.rawValue
        ]

        if session.isReachable {
            session.sendMessage(message, replyHandler: { _ in
                print("\(self.loggerPrefix) requestAllData: success via sendMessage")
            }, errorHandler: { error in
                print("\(self.loggerPrefix) requestAllData: sendMessage error, falling back to transferUserInfo - \(error)")
                session.transferUserInfo(message)
            })
            return true
        } else {
            print("\(loggerPrefix) requestAllData: not reachable, queuing via transferUserInfo")
            session.transferUserInfo(message)
            return false
        }
    }

    /// Sends a reset-all command to the counterpart device, clearing all data
    public func sendResetAll() {
        guard let session = session else {
            print("\(loggerPrefix) sendResetAll: missing WCSession")
            return
        }

        let message: [String: Any] = [
            "type": MessageType.resetAll.rawValue
        ]

        sendReliably(message, label: "sendResetAll")
    }

    /// Syncs a debug log string to the counterpart device (Watch → iPhone).
    /// Verbose-GPS logs can be 1MB+, which exceeds `sendMessage`/`transferUserInfo`
    /// payload limits. We write the log to a temp file and use `transferFile`
    /// which handles arbitrary sizes reliably across foreground/background.
    /// If a `workoutID` is supplied, the receiver will save it to DebugLogStore
    /// keyed by that ID so the per-workout map view can find it later.
    public func syncDebugLog(_ logText: String, workoutID: UUID? = nil) {
        guard let session = session else { return }

        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("debugLog-\(UUID().uuidString).txt")
        do {
            try logText.write(to: tmpURL, atomically: true, encoding: .utf8)
        } catch {
            print("\(loggerPrefix) syncDebugLog: failed to write temp file - \(error)")
            return
        }

        var metadata: [String: Any] = [
            "type": MessageType.debugLog.rawValue
        ]
        if let id = workoutID {
            metadata["workoutID"] = id.uuidString
        }

        session.transferFile(tmpURL, metadata: metadata)
        print("\(loggerPrefix) syncDebugLog: queued transferFile (\(logText.count) chars, workoutID=\(workoutID?.uuidString ?? "nil"))")
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

            sendReliably(message, label: "syncSettings")

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

            // Use transferUserInfo as the primary method - it queues reliably
            // and delivers even when apps aren't in foreground.
            // sendMessage requires both apps active which is unreliable after a workout.
            print("\(loggerPrefix) syncWorkoutSummary: queuing via transferUserInfo (id: \(summary.id))")
            session.transferUserInfo(message)

        } catch {
            print("\(loggerPrefix) syncWorkoutSummary: failed - \(error)")
            syncStatusSubject.send(.failed("Workout sync failed: \(error)"))
        }
    }

    /// Force sync a workout using sendMessage (requires both apps active).
    /// Use this for manual sync when user is actively using both devices.
    /// Returns true if the message was sent (not guaranteed delivered).
    public func forceSyncWorkoutSummary(_ summary: WorkoutSummary) -> Bool {
        guard let session = session else {
            print("\(loggerPrefix) forceSyncWorkoutSummary: missing WCSession")
            return false
        }

        guard session.isReachable else {
            print("\(loggerPrefix) forceSyncWorkoutSummary: not reachable")
            return false
        }

        do {
            encoder.dateEncodingStrategy = .iso8601
            let jsonData = try encoder.encode(summary)

            let message: [String: Any] = [
                "type": MessageType.workoutSummary.rawValue,
                "id": summary.id.uuidString,
                "data": jsonData
            ]

            print("\(loggerPrefix) forceSyncWorkoutSummary: sending via sendMessage (id: \(summary.id))")
            session.sendMessage(message, replyHandler: { [weak self] _ in
                print("\(self?.loggerPrefix ?? "") forceSyncWorkoutSummary: delivered \(summary.id)")
            }, errorHandler: { [weak self] error in
                print("\(self?.loggerPrefix ?? "") forceSyncWorkoutSummary: failed \(summary.id) - \(error)")
                // Fall back to transferUserInfo
                print("\(self?.loggerPrefix ?? "") forceSyncWorkoutSummary: falling back to transferUserInfo")
                session.transferUserInfo(message)
            })
            return true
        } catch {
            print("\(loggerPrefix) forceSyncWorkoutSummary: encode failed - \(error)")
            return false
        }
    }

    /// Request pending workouts from the watch (iOS only)
    /// Completion returns (success, watchReachable)
    public func requestPendingWorkouts(completion: @escaping (Bool, Bool) -> Void) {
        guard let session = session else {
            print("\(loggerPrefix) requestPendingWorkouts: missing WCSession")
            completion(false, false)
            return
        }

        let message: [String: Any] = [
            "type": MessageType.requestPendingWorkouts.rawValue
        ]

        guard session.isReachable else {
            print("\(loggerPrefix) requestPendingWorkouts: watch not reachable")
            completion(false, false)
            return
        }

        print("\(loggerPrefix) requestPendingWorkouts: sending request to watch")
        syncStatusSubject.send(.syncing)

        session.sendMessage(message, replyHandler: { [weak self] reply in
            print("\(self?.loggerPrefix ?? "") requestPendingWorkouts: got reply - \(reply)")
            self?.syncStatusSubject.send(.synced)
            completion(true, true)
        }, errorHandler: { [weak self] error in
            print("\(self?.loggerPrefix ?? "") requestPendingWorkouts: error - \(error)")
            self?.syncStatusSubject.send(.failed(error.localizedDescription))
            completion(false, true)
        })
    }

    /// Send acknowledgment that a workout was received (iOS → Watch)
    public func sendWorkoutSyncAck(workoutID: UUID) {
        guard let session = session else { return }

        let message: [String: Any] = [
            "type": MessageType.workoutSyncAck.rawValue,
            "id": workoutID.uuidString
        ]

        if session.isReachable {
            print("\(loggerPrefix) sendWorkoutSyncAck: \(workoutID)")
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        }
    }

    /// Sync Pro entitlement status to counterpart device
    public func syncEntitlements(isPro: Bool) {
        guard let session = session else {
            print("\(loggerPrefix) syncEntitlements: missing WCSession")
            return
        }

        let message: [String: Any] = [
            "type": MessageType.entitlementSync.rawValue,
            "isPro": isPro
        ]

        if session.isReachable {
            print("\(loggerPrefix) syncEntitlements: sending via sendMessage (isPro=\(isPro))")
            session.sendMessage(message, replyHandler: nil, errorHandler: { [weak self] error in
                print("\(self?.loggerPrefix ?? "") syncEntitlements: sendMessage failed - \(error)")
                // Fallback to application context
                try? session.updateApplicationContext(message)
            })
        } else {
            print("\(loggerPrefix) syncEntitlements: using applicationContext (isPro=\(isPro))")
            try? session.updateApplicationContext(message)
        }
    }

    /// Check if watch is reachable
    public var isWatchReachable: Bool {
        session?.isReachable ?? false
    }

    // MARK: - Private Methods

    /// Sends a message reliably: tries sendMessage first (instant), falls back to transferUserInfo (queued).
    /// transferUserInfo is delivered even when the counterpart app isn't active — unlike sendMessage
    /// which requires the counterpart's WCSession to be reachable (app in foreground).
    private func sendReliably(_ message: [String: Any], label: String) {
        guard let session = session else {
            print("\(loggerPrefix) \(label): missing WCSession")
            syncStatusSubject.send(.failed("WCSession not available"))
            return
        }

        if session.isReachable {
            print("\(loggerPrefix) \(label): reachable, trying sendMessage")
            syncStatusSubject.send(.syncing)

            session.sendMessage(message, replyHandler: { _ in
                print("\(self.loggerPrefix) \(label): delivered via sendMessage, waiting for ack")
                // Message delivered — wait for configSyncAck to confirm processing
                // Timeout: if no ack in 10s, show as queued
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    if self?.syncStatusSubject.value == .syncing {
                        print("\(self?.loggerPrefix ?? "") \(label): ack timeout, marking as queued")
                        self?.syncStatusSubject.send(.queued)
                    }
                }
            }, errorHandler: { error in
                print("\(self.loggerPrefix) \(label): sendMessage failed, falling back to transferUserInfo - \(error)")
                session.transferUserInfo(message)
                self.syncStatusSubject.send(.queued)
            })
        } else {
            print("\(loggerPrefix) \(label): not reachable, queuing via transferUserInfo")
            session.transferUserInfo(message)
            syncStatusSubject.send(.queued)
        }
    }

    private func queueConfiguration(_ message: [String: Any]) {
        session?.transferUserInfo(message)
        syncStatusSubject.send(.synced) // Queued, will deliver later
    }
    
    /// Sweep orphaned debug-log temp files from `NSTemporaryDirectory()` and
    /// log the WCSession queue depth. Older builds wrote temp files but never
    /// deleted them, so they piled up over time. Also cancels any *debug-log*
    /// file transfers that are still outstanding from prior sessions — they
    /// are diagnostic-only and shouldn't keep the watch awake retrying.
    /// Workout-summary transfers are preserved (user data must reach the phone).
    public func cleanupStaleSyncState() {
        // 1) Delete orphaned debugLog-*.txt files from previous launches.
        let tmp = NSTemporaryDirectory()
        if let names = try? FileManager.default.contentsOfDirectory(atPath: tmp) {
            var removed = 0
            for name in names where name.hasPrefix("debugLog-") && name.hasSuffix(".txt") {
                let url = URL(fileURLWithPath: tmp).appendingPathComponent(name)
                if (try? FileManager.default.removeItem(at: url)) != nil {
                    removed += 1
                }
            }
            if removed > 0 {
                print("\(loggerPrefix) cleanupStaleSyncState: removed \(removed) orphaned temp file(s)")
            }
        }

        // 2) Cancel outstanding debug-log file transfers (preserve workout summaries).
        guard let session = session else { return }
        let fileXfers = session.outstandingFileTransfers
        let userInfoXfers = session.outstandingUserInfoTransfers
        print("\(loggerPrefix) cleanupStaleSyncState: outstanding files=\(fileXfers.count) userInfo=\(userInfoXfers.count)")
        var cancelled = 0
        for xfer in fileXfers {
            let type = xfer.file.metadata?["type"] as? String
            if type == MessageType.debugLog.rawValue {
                xfer.cancel()
                cancelled += 1
            }
        }
        if cancelled > 0 {
            print("\(loggerPrefix) cleanupStaleSyncState: cancelled \(cancelled) stale debug-log transfer(s)")
        }
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
            print("\(loggerPrefix) sessionReachabilityDidChange: now reachable")
            syncStatusSubject.send(.activated)

            // Post notification for WatchWorkoutStore to retry pending syncs
            NotificationCenter.default.post(name: .watchConnectivityReachable, object: nil)
        } else {
            print("\(loggerPrefix) sessionReachabilityDidChange: not reachable")
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
        let url = fileTransfer.file.fileURL
        if let error = error {
            print("\(loggerPrefix) fileTransfer failed: \(error.localizedDescription)")
        }
        // Clean up the temp file we wrote in syncDebugLog (and any future
        // transferFile sender). WCSession copies the file into its own staging
        // area before sending, so deleting the source here is safe once the
        // transfer is complete (success or final failure). Leaving these in
        // place was the leak — they accumulated in NSTemporaryDirectory and
        // kept the outstanding-transfer queue tied to disk artifacts.
        if url.path.contains(NSTemporaryDirectory()) {
            try? FileManager.default.removeItem(at: url)
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

        case .requestPendingWorkouts:
            handleRequestPendingWorkouts(message)

        case .workoutSyncAck:
            handleWorkoutSyncAck(message)

        case .pendingWorkoutsResponse:
            handlePendingWorkoutsResponse(message)

        case .entitlementSync:
            handleEntitlementSync(message)

        case .resetAll:
            handleResetAll()

        case .requestAllData:
            handleRequestAllData()

        case .debugLog:
            handleDebugLog(message)

        case .configSyncAck:
            handleConfigSyncAck(message)
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

            // Send ack back to sender
            sendConfigSyncAck(configCount: 1)

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

            // Send ack back to sender
            sendConfigSyncAck(configCount: configurations.count)

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

            // Send acknowledgment back to watch
            #if os(iOS)
            sendWorkoutSyncAck(workoutID: summary.id)
            #endif

            // Post notification for UI update
            NotificationCenter.default.post(
                name: .workoutSummarySynced,
                object: summary
            )
        } catch {
            print("\(loggerPrefix) Failed to decode workout summary: \(error)")
        }
    }

    /// Watch: Handle request from phone for pending workouts
    private func handleRequestPendingWorkouts(_ message: [String: Any]) {
        #if os(watchOS)
        print("\(loggerPrefix) handleRequestPendingWorkouts: received request from phone")
        // Post notification so WatchWorkoutStore can respond
        NotificationCenter.default.post(name: .phoneRequestedWorkouts, object: nil)
        #endif
    }

    /// Watch: Handle acknowledgment from phone that workout was received
    private func handleWorkoutSyncAck(_ message: [String: Any]) {
        #if os(watchOS)
        guard let idString = message["id"] as? String,
              let workoutID = UUID(uuidString: idString) else {
            return
        }
        print("\(loggerPrefix) handleWorkoutSyncAck: received ack for \(workoutID)")
        // Post notification so WatchWorkoutStore can mark as synced
        NotificationCenter.default.post(name: .workoutSyncAckReceived, object: workoutID)
        #endif
    }

    /// Phone: Handle response from watch with pending workouts
    private func handlePendingWorkoutsResponse(_ message: [String: Any]) {
        #if os(iOS)
        guard let summariesData = message["data"] as? Data else {
            print("\(loggerPrefix) handlePendingWorkoutsResponse: no data")
            return
        }

        do {
            decoder.dateDecodingStrategy = .iso8601
            let summaries = try decoder.decode([WorkoutSummary].self, from: summariesData)
            print("\(loggerPrefix) handlePendingWorkoutsResponse: received \(summaries.count) workouts")

            for summary in summaries {
                saveWorkoutSummary(summary)
                sendWorkoutSyncAck(workoutID: summary.id)
                NotificationCenter.default.post(name: .workoutSummarySynced, object: summary)
            }
        } catch {
            print("\(loggerPrefix) handlePendingWorkoutsResponse: decode failed - \(error)")
        }
        #endif
    }

    private func handleEntitlementSync(_ message: [String: Any]) {
        guard let isPro = message["isPro"] as? Bool else {
            print("\(loggerPrefix) handleEntitlementSync: missing isPro value")
            return
        }

        print("\(loggerPrefix) handleEntitlementSync: isPro=\(isPro)")

        // Cache in UserDefaults
        UserDefaults.standard.set(isPro, forKey: "entitlement_is_pro")

        // Post notification for EntitlementManager to pick up
        NotificationCenter.default.post(
            name: .entitlementSynced,
            object: isPro
        )
    }

    private func sendConfigSyncAck(configCount: Int) {
        guard let session = session, session.isReachable else {
            // If not reachable, queue the ack
            if let session = session {
                session.transferUserInfo([
                    "type": MessageType.configSyncAck.rawValue,
                    "count": configCount
                ])
            }
            return
        }

        session.sendMessage([
            "type": MessageType.configSyncAck.rawValue,
            "count": configCount
        ], replyHandler: nil, errorHandler: nil)
    }

    private func handleConfigSyncAck(_ message: [String: Any]) {
        let count = message["count"] as? Int ?? 0
        print("\(loggerPrefix) handleConfigSyncAck: watch confirmed \(count) configs received")
        syncStatusSubject.send(.synced)
    }

    private func handleDebugLog(_ message: [String: Any]) {
        guard let text = message["text"] as? String else { return }
        print("\(loggerPrefix) handleDebugLog: received \(text.count) chars (legacy in-message path)")

        // Legacy path — do NOT persist to UserDefaults. Multi-MB strings in
        // standard.plist bloat the plist that the OS loads at app launch.
        // File-based DebugLogStore is the authoritative store; this codepath
        // is only kept for backwards compat with very old senders.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .watchDebugLogReceived, object: text)
        }
    }

    private func handleRequestAllData() {
        print("\(loggerPrefix) handleRequestAllData: counterpart requested all data")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .allDataRequested, object: nil)
        }
    }

    private func handleResetAll() {
        print("\(loggerPrefix) handleResetAll: clearing all local data")

        // Clear all known UserDefaults keys
        let keysToRemove = [
            "configurations",
            "watchWorkoutSummaries",
            "watchWorkoutSyncedIDs",
            "workoutSummaries",
            "workoutSummaries_pending",
            "app_settings",
            "entitlement_is_pro",
            "entitlement_debug_override",
            "lastDebugLog",
            "lastWatchDebugLog",
            "debugLogStore_lastWorkoutID"
        ]
        for key in keysToRemove {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // Clear per-workout debug log files
        DebugLogStore.shared.clearAll()

        // Post notification so stores can reload
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .resetAllReceived, object: nil)
        }
    }

    private func handleReceivedFile(_ file: WCSessionFile) {
        guard let metadata = file.metadata,
              let typeString = metadata["type"] as? String,
              let messageType = MessageType(rawValue: typeString) else {
            return
        }

        switch messageType {
        case .workoutSummary:
            handleReceivedWorkoutSummaryFile(file)
        case .debugLog:
            handleReceivedDebugLogFile(file, metadata: metadata)
        default:
            print("\(loggerPrefix) handleReceivedFile: unhandled type \(typeString)")
        }
    }

    private func handleReceivedWorkoutSummaryFile(_ file: WCSessionFile) {
        do {
            print("\(loggerPrefix) handleReceivedFile metadata: \(file.metadata ?? [:])")
            let data = try Data(contentsOf: file.fileURL)
            decoder.dateDecodingStrategy = .iso8601
            let summary = try decoder.decode(WorkoutSummary.self, from: data)

            print("\(loggerPrefix) received workout summary \(summary.id)")
            saveWorkoutSummary(summary)
            NotificationCenter.default.post(name: .workoutSummarySynced, object: summary)
        } catch {
            print("Failed to decode workout summary: \(error)")
        }
    }

    private func handleReceivedDebugLogFile(_ file: WCSessionFile, metadata: [String: Any]) {
        do {
            let text = try String(contentsOf: file.fileURL, encoding: .utf8)
            print("\(loggerPrefix) handleReceivedDebugLogFile: \(text.count) chars, metadata=\(metadata)")

            // Save to per-workout store if we know the workout ID
            if let idStr = metadata["workoutID"] as? String,
               let workoutID = UUID(uuidString: idStr) {
                _ = DebugLogStore.shared.save(text, for: workoutID)
            }

            // Intentionally NOT mirroring to UserDefaults (`lastWatchDebugLog`)
            // — multi-MB strings in standard.plist were bloating the plist that
            // loads on every launch. DebugLogStore.loadLast() is authoritative.

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .watchDebugLogReceived, object: text)
            }
        } catch {
            print("Failed to read debug log file: \(error)")
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
        let (summaries, loadSuccess) = loadWorkoutSummariesWithStatus()

        // If we failed to load existing summaries, don't overwrite - just save this one separately
        // This prevents data loss when there's a decode issue
        if !loadSuccess {
            print("\(loggerPrefix) saveWorkoutSummary: load failed, saving to backup key to prevent data loss")
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode([summary]) {
                // Save to a separate key so we don't lose the corrupted data
                UserDefaults.standard.set(data, forKey: "workoutSummaries_pending")
            }
            return
        }

        var updatedSummaries = summaries

        // Check for duplicate by ID
        if !updatedSummaries.contains(where: { $0.id == summary.id }) {
            updatedSummaries.append(summary)
        }

        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(updatedSummaries) {
            UserDefaults.standard.set(data, forKey: "workoutSummaries")
            print("\(loggerPrefix) saveWorkoutSummary: saved \(updatedSummaries.count) summaries")
        }
    }

    /// Returns (summaries, loadSuccess) tuple
    /// loadSuccess is false if there was existing data that failed to decode
    private func loadWorkoutSummariesWithStatus() -> ([WorkoutSummary], Bool) {
        guard let data = UserDefaults.standard.data(forKey: "workoutSummaries") else {
            print("\(loggerPrefix) loadWorkoutSummaries: no data in UserDefaults")
            return ([], true)  // No data is OK, not a failure
        }

        decoder.dateDecodingStrategy = .iso8601
        do {
            let summaries = try decoder.decode([WorkoutSummary].self, from: data)
            print("\(loggerPrefix) loadWorkoutSummaries: loaded \(summaries.count) summaries")
            return (summaries, true)
        } catch {
            // Log the error - this is a real problem
            print("\(loggerPrefix) loadWorkoutSummaries: decode failed - \(error)")
            print("\(loggerPrefix) loadWorkoutSummaries: data size was \(data.count) bytes")
            return ([], false)  // Return false to indicate decode failure
        }
    }

    private func loadWorkoutSummaries() -> [WorkoutSummary] {
        return loadWorkoutSummariesWithStatus().0
    }
}

// MARK: - Notifications

extension Notification.Name {
    public static let configurationSynced = Notification.Name("configurationSynced")
    public static let configurationDeleted = Notification.Name("configurationDeleted")
    public static let configurationsReplacedAll = Notification.Name("configurationsReplacedAll")
    public static let settingsSynced = Notification.Name("settingsSynced")
    public static let workoutSummarySynced = Notification.Name("workoutSummarySynced")
    public static let watchConnectivityReachable = Notification.Name("watchConnectivityReachable")
    public static let phoneRequestedWorkouts = Notification.Name("phoneRequestedWorkouts")
    public static let workoutSyncAckReceived = Notification.Name("workoutSyncAckReceived")
    public static let entitlementSynced = Notification.Name("entitlementSynced")
    public static let resetAllReceived = Notification.Name("resetAllReceived")
    public static let allDataRequested = Notification.Name("allDataRequested")
    public static let watchDebugLogReceived = Notification.Name("watchDebugLogReceived")
}
