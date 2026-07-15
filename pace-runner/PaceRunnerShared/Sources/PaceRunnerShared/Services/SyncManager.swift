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

    private let snapshotSubject = CurrentValueSubject<WatchSyncSnapshot, Never>(WatchSyncSnapshot())
    public var syncSnapshotPublisher: AnyPublisher<WatchSyncSnapshot, Never> {
        snapshotSubject.eraseToAnyPublisher()
    }

    // MARK: - Private Properties

    private let session: WCSession?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Tri-domain sync state (dirty-latch fingerprints)

    /// Serializes access to the fingerprint / snapshot state below.
    private let snapshotLock = NSLock()

    private var localConfigsFP: String?
    private var lastAckedConfigsFP: String?
    private var localSettingsFP: String?
    private var lastAckedSettingsFP: String?
    /// Watch's own count of unsynced workouts (watchOS only source of truth).
    private var localHistoryPending: Int = 0
    /// Phone's view of the watch's pending-workout count (iOS only; nil = unknown).
    private var peerHistoryPending: Int?
    private var isSyncingFlag: Bool = false
    private var lastErrorText: String?
    private var statusMirror: AnyCancellable?

    // Message types
    private enum MessageType: String {
        case configurationUpdate = "configurationUpdate"
        case configurationDelete = "configurationDelete"
        case configurationSyncAll = "configurationSyncAll"
        case settingsSync = "settingsSync"
        case settingsSyncAck = "settingsSyncAck"
        case historyStatus = "historyStatus"
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

        // Mirror the coarse sync-status stream into the snapshot's error field:
        // a `.failed` surfaces the red "Sync failed" state; any subsequent
        // success (`.synced` / `.activated`) clears it. This is the only writer
        // of `lastErrorText`, so the error state can't get permanently stuck.
        statusMirror = syncStatusSubject.sink { [weak self] status in
            guard let self else { return }
            self.snapshotLock.lock()
            switch status {
            case .failed(let message): self.lastErrorText = message
            case .synced, .activated: self.lastErrorText = nil
            default: break
            }
            self.snapshotLock.unlock()
            self.recomputeSnapshot()
        }
    }

    // MARK: - Fingerprints (deterministic, cross-device stable)

    /// FNV-1a 64-bit hash of a canonical string, rendered as a lowercase hex string.
    /// Deterministic across launches and devices (unlike Swift's `.hashValue`).
    private func fnv1a64Hex(_ string: String) -> String {
        let prime: UInt64 = 0x0000_0100_0000_01B3
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }

    /// Canonical, stable fingerprint of a set of configurations.
    /// Sorted by id so order changes on either device don't matter for equivalence.
    private func configsFingerprint(_ configurations: [RunConfiguration]) -> String {
        let lines = configurations
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { config -> String in
                let paces = config.milePaces.map { String($0.totalSeconds) }.joined(separator: ",")
                let stride = config.strideLengthInches.map { String($0) } ?? "nil"
                let cal = config.paceCalibrationSeconds.map { String($0) } ?? "nil"
                let segs: String
                if let segments = config.segments {
                    segs = segments.map { seg in
                        let sStride = seg.strideLengthInches.map { String($0) } ?? "nil"
                        let sCal = seg.paceCalibrationSeconds.map { String($0) } ?? "nil"
                        return "\(seg.id.uuidString)|\(seg.distance.miles)|\(seg.pace.totalSeconds)|\(seg.label)|\(seg.cadenceOffset)|\(seg.paceTolerance)|\(sStride)|\(sCal)"
                    }.joined(separator: ";")
                } else {
                    segs = "nil"
                }
                return [
                    config.id.uuidString,
                    config.name,
                    String(config.distance.miles),
                    paces,
                    String(config.cadenceOffset),
                    String(config.paceTolerance),
                    String(config.metronomeMinVolume),
                    String(config.metronomeMaxVolume),
                    String(config.autoEndRun),
                    stride,
                    cal,
                    segs
                ].joined(separator: "|")
            }
        return fnv1a64Hex(lines.joined(separator: "\n"))
    }

    /// Canonical, stable fingerprint of app settings. Fixed field order.
    private func settingsFingerprint(_ settings: AppSettings) -> String {
        let commonDistances = settings.commonDistances.map { String($0) }.joined(separator: ",")
        let namedPaces = settings.namedPaces.map { "\($0.name):\($0.pace.totalSeconds)" }.joined(separator: ",")
        let fields: [String] = [
            String(settings.companionMode),
            String(settings.useHealthKitDistance),
            String(settings.audioBeatsEnabled),
            String(settings.voiceAlertsEnabled),
            String(settings.alertThrottleInterval),
            String(settings.adaptiveMetronomeVolume),
            String(settings.masterVolume),
            String(settings.beatVolume),
            String(settings.announceMileMarkers),
            String(settings.debugProOverride),
            String(settings.gpsFilterDebugSounds),
            String(settings.verboseGPSLogging),
            settings.distanceCalcMethod.rawValue,
            String(settings.emphasisBeatEnabled),
            String(settings.emphasisBeatInterval),
            String(settings.useMetricUnits),
            String(settings.showPaceDeviation),
            String(settings.showCadence),
            String(settings.fastAverageSeconds),
            String(settings.mediumAverageSeconds),
            String(settings.slowAverageMiles),
            String(settings.strideLengthInches),
            String(settings.paceCalibrationSeconds),
            String(settings.defaultTolerance),
            commonDistances,
            namedPaces
        ]
        return fnv1a64Hex(fields.joined(separator: "|"))
    }

    // MARK: - Snapshot

    /// Recompute the tri-domain snapshot from current state and emit it.
    /// Safe to call from any thread.
    private func recomputeSnapshot() {
        snapshotLock.lock()

        let configsSynced = lastAckedConfigsFP != nil && lastAckedConfigsFP == localConfigsFP
        let settingsSynced = lastAckedSettingsFP != nil && lastAckedSettingsFP == localSettingsFP

        #if os(watchOS)
        let historySynced = localHistoryPending == 0
        #else
        let historySynced = (peerHistoryPending == 0)
        #endif

        let connection = currentConnection()

        let snapshot = WatchSyncSnapshot(
            connection: connection,
            configsSynced: configsSynced,
            settingsSynced: settingsSynced,
            historySynced: historySynced,
            isSyncing: isSyncingFlag,
            lastError: lastErrorText
        )
        snapshotLock.unlock()

        snapshotSubject.send(snapshot)
    }

    /// Compute the current connection state for this platform.
    private func currentConnection() -> WatchConnection {
        guard let session = session else { return .noWatch }
        #if os(iOS)
        if !session.isPaired || !session.isWatchAppInstalled {
            return .noWatch
        }
        return session.isReachable ? .reachable : .notReachable
        #else
        return session.isReachable ? .reachable : .notReachable
        #endif
    }

    private func setSyncing(_ syncing: Bool) {
        snapshotLock.lock()
        isSyncingFlag = syncing
        snapshotLock.unlock()
        recomputeSnapshot()
    }

    // MARK: - Public Methods

    public func setLocalHistoryPending(_ count: Int) {
        snapshotLock.lock()
        let changed = localHistoryPending != count
        localHistoryPending = count
        snapshotLock.unlock()

        #if os(watchOS)
        if changed {
            sendHistoryStatus(count)
        }
        #endif
        recomputeSnapshot()
    }

    /// Force a full resync of every domain. Tapped status icon calls this.
    public func forceFullResync() {
        setSyncing(true)

        // Push configs + settings + entitlements from local storage.
        let configs = loadConfigurations()
        syncAllConfigurations(configs)

        let settings = AppSettings.load()
        syncSettings(settings)

        let isPro = UserDefaults.standard.bool(forKey: "entitlement_is_pro")
        syncEntitlements(isPro: isPro)

        #if os(watchOS)
        // Re-broadcast history status and retry any pending workouts.
        snapshotLock.lock()
        let pending = localHistoryPending
        snapshotLock.unlock()
        sendHistoryStatus(pending)
        NotificationCenter.default.post(name: .forceResyncRequested, object: nil)
        #else
        // Ask the watch to send its data (configs/settings/workouts) too.
        requestAllData()
        #endif

        // Clear the syncing flag after a short window; acks will refresh the
        // per-domain latches as they arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.setSyncing(false)
        }
    }

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

        // Record the local fingerprint for the dirty-latch model. This is the
        // full-set fingerprint the receiver will ack.
        let fp = configsFingerprint(configurations)
        snapshotLock.lock()
        localConfigsFP = fp
        snapshotLock.unlock()
        recomputeSnapshot()

        do {
            let configData = try encoder.encode(configurations)

            let message: [String: Any] = [
                "type": MessageType.configurationSyncAll.rawValue,
                "data": configData,
                "fingerprint": fp
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

        // Record the local fingerprint for the dirty-latch model.
        let fp = configsFingerprint(configurations)
        snapshotLock.lock()
        localConfigsFP = fp
        snapshotLock.unlock()
        recomputeSnapshot()

        guard session.isReachable else {
            // Not reachable — still queue it, but tell the user
            do {
                let configData = try encoder.encode(configurations)
                let message: [String: Any] = [
                    "type": MessageType.configurationSyncAll.rawValue,
                    "data": configData,
                    "fingerprint": fp
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
                "data": configData,
                "fingerprint": fp
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

        // Record the local settings fingerprint for the dirty-latch model.
        let fp = settingsFingerprint(settings)
        snapshotLock.lock()
        localSettingsFP = fp
        snapshotLock.unlock()
        recomputeSnapshot()

        do {
            let settingsData = try encoder.encode(settings)

            let message: [String: Any] = [
                "type": MessageType.settingsSync.rawValue,
                "data": settingsData,
                "fingerprint": fp
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
        recomputeSnapshot()

        #if os(watchOS)
        // On activation, tell the phone our current pending-history count.
        snapshotLock.lock()
        let pending = localHistoryPending
        snapshotLock.unlock()
        if session.isReachable {
            sendHistoryStatus(pending)
        }
        #endif
    }

    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {
        // iOS only - watch switched
    }

    public func sessionDidDeactivate(_ session: WCSession) {
        // iOS only - reactivate for new watch
        session.activate()
    }

    public func sessionWatchStateDidChange(_ session: WCSession) {
        // Pairing / installed / complication state changed — connection may change.
        print("\(loggerPrefix) sessionWatchStateDidChange: paired=\(session.isPaired) installed=\(session.isWatchAppInstalled)")
        recomputeSnapshot()
    }
    #endif

    public func sessionReachabilityDidChange(_ session: WCSession) {
        // Reachability changed - sync status and connection may update
        if session.isReachable {
            print("\(loggerPrefix) sessionReachabilityDidChange: now reachable")
            syncStatusSubject.send(.activated)

            // Post notification for WatchWorkoutStore to retry pending syncs
            NotificationCenter.default.post(name: .watchConnectivityReachable, object: nil)

            #if os(watchOS)
            // Re-report pending history now that we can reach the phone.
            snapshotLock.lock()
            let pending = localHistoryPending
            snapshotLock.unlock()
            sendHistoryStatus(pending)
            #endif
        } else {
            print("\(loggerPrefix) sessionReachabilityDidChange: not reachable")
        }
        // Update the connection domain of the snapshot in BOTH directions.
        recomputeSnapshot()
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

        case .settingsSyncAck:
            handleSettingsSyncAck(message)

        case .historyStatus:
            handleHistoryStatus(message)

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

            // Ack with the fingerprint of the full stored set after applying the
            // single update, so full-set latching stays consistent.
            let fp = configsFingerprint(loadConfigurations())
            sendConfigSyncAck(configCount: 1, fingerprint: fp)

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

            // The received configs are now our local set — adopt the sender's
            // fingerprint (recomputed from the decoded configs, which is
            // deterministic and matches the sender) so this side also latches
            // as synced once it acks/receives.
            let receivedFP = configsFingerprint(configurations)
            snapshotLock.lock()
            localConfigsFP = receivedFP
            lastAckedConfigsFP = receivedFP
            snapshotLock.unlock()
            recomputeSnapshot()

            // Send ack back to sender, including the fingerprint of what we saved.
            sendConfigSyncAck(configCount: configurations.count, fingerprint: receivedFP)

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

            // Latch our local settings fingerprint to the received settings and
            // ack it back so the sender can mark the settings domain as synced.
            let receivedFP = settingsFingerprint(settings)
            snapshotLock.lock()
            localSettingsFP = receivedFP
            lastAckedSettingsFP = receivedFP
            snapshotLock.unlock()
            recomputeSnapshot()

            sendSettingsSyncAck(fingerprint: receivedFP)

        } catch {
            print("\(loggerPrefix) handleSettingsSync: Failed to decode settings: \(error)")
        }
    }

    private func handleSettingsSyncAck(_ message: [String: Any]) {
        guard let fp = message["fingerprint"] as? String else { return }
        print("\(loggerPrefix) handleSettingsSyncAck: peer confirmed settings fp=\(fp)")
        snapshotLock.lock()
        lastAckedSettingsFP = fp
        snapshotLock.unlock()
        recomputeSnapshot()
    }

    private func handleHistoryStatus(_ message: [String: Any]) {
        #if os(iOS)
        guard let pending = message["pendingCount"] as? Int else { return }
        print("\(loggerPrefix) handleHistoryStatus: watch reports \(pending) pending workouts")
        snapshotLock.lock()
        peerHistoryPending = pending
        snapshotLock.unlock()
        recomputeSnapshot()
        #endif
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

    private func sendConfigSyncAck(configCount: Int, fingerprint: String) {
        let payload: [String: Any] = [
            "type": MessageType.configSyncAck.rawValue,
            "count": configCount,
            "fingerprint": fingerprint
        ]
        guard let session = session, session.isReachable else {
            // If not reachable, queue the ack
            session?.transferUserInfo(payload)
            return
        }
        session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
    }

    private func handleConfigSyncAck(_ message: [String: Any]) {
        let count = message["count"] as? Int ?? 0
        print("\(loggerPrefix) handleConfigSyncAck: peer confirmed \(count) configs received")
        // Backward-compat: keep the .synced SyncStatus behavior.
        syncStatusSubject.send(.synced)

        if let fp = message["fingerprint"] as? String {
            snapshotLock.lock()
            lastAckedConfigsFP = fp
            snapshotLock.unlock()
            recomputeSnapshot()
        }
    }

    private func sendSettingsSyncAck(fingerprint: String) {
        let payload: [String: Any] = [
            "type": MessageType.settingsSyncAck.rawValue,
            "fingerprint": fingerprint
        ]
        guard let session = session, session.isReachable else {
            session?.transferUserInfo(payload)
            return
        }
        session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
    }

    /// Watch → phone: report the current unsynced-workout count.
    private func sendHistoryStatus(_ pendingCount: Int) {
        let payload: [String: Any] = [
            "type": MessageType.historyStatus.rawValue,
            "pendingCount": pendingCount
        ]
        guard let session = session, session.isReachable else {
            session?.transferUserInfo(payload)
            return
        }
        session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
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
    /// Posted on the watch when the user forces a full resync; WatchWorkoutStore
    /// listens to retry pending workout syncs.
    public static let forceResyncRequested = Notification.Name("forceResyncRequested")
}
