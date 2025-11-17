# Sync Protocol Specification

## Overview

PaceRunner uses WatchConnectivity framework to synchronize data between iPhone and Apple Watch. The protocol is designed for reliability, handling both immediate and background transfers.

## WatchConnectivity Architecture

### Session Setup

```swift
// Both phone and watch must initialize session
class SyncManager: NSObject, WCSessionDelegate {
    static let shared = SyncManager()
    private var session: WCSession?
    
    func setupSession() {
        guard WCSession.isSupported() else {
            print("WatchConnectivity not supported")
            return
        }
        
        session = WCSession.default
        session?.delegate = self
        session?.activate()
    }
    
    // MARK: - WCSessionDelegate
    
    func session(_ session: WCSession, 
                activationDidCompleteWith state: WCSessionActivationState, 
                error: Error?) {
        if let error = error {
            print("Session activation failed: \(error)")
            return
        }
        
        switch state {
        case .activated:
            print("WCSession activated")
            checkForPendingSyncs()
        case .inactive, .notActivated:
            print("WCSession not active")
        @unknown default:
            break
        }
    }
    
    // iOS only - handle session state changes
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {
        print("Session became inactive")
    }
    
    func sessionDidDeactivate(_ session: WCSession) {
        print("Session deactivated")
        // Re-activate for new Apple Watch
        session.activate()
    }
    #endif
}
```

## Message Types

### Message Type Enum

```swift
enum MessageType: String, Codable {
    // Phone → Watch
    case syncConfiguration
    case syncAllConfigurations
    case deleteConfiguration
    
    // Watch → Phone
    case workoutCompleted
    case workoutSummary
    case syncRequest
    
    // Bi-directional
    case ping
    case acknowledgment
}
```

### Message Structure

All messages follow a common structure:

```swift
struct SyncMessage: Codable {
    let type: MessageType
    let timestamp: Date
    let messageId: UUID
    let payload: Data  // Encoded payload
    
    init(type: MessageType, payload: Codable) throws {
        self.type = type
        self.timestamp = Date()
        self.messageId = UUID()
        
        let encoder = JSONEncoder()
        self.payload = try encoder.encode(payload)
    }
    
    func decodePayload<T: Codable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: payload)
    }
}
```

## Sync Operations

### 1. Configuration Sync (Phone → Watch)

**When**: User creates/edits configuration on phone

**Method**: `transferUserInfo()` - Background transfer, queued

**Payload**:
```swift
struct ConfigurationSyncPayload: Codable {
    let configuration: RunConfiguration
    let syncTimestamp: Date
}
```

**Phone Implementation**:
```swift
func syncConfiguration(_ config: RunConfiguration) {
    guard let session = session, session.isReachable else {
        queueForLaterSync(config)
        return
    }
    
    do {
        let payload = ConfigurationSyncPayload(
            configuration: config,
            syncTimestamp: Date()
        )
        
        let message = try SyncMessage(
            type: .syncConfiguration,
            payload: payload
        )
        
        // Use transferUserInfo for background transfer
        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        
        session.transferUserInfo([
            "message": data
        ])
        
        // Update sync status
        updateSyncStatus(for: config.id, status: .syncing)
        
    } catch {
        print("Failed to sync configuration: \(error)")
        queueForLaterSync(config)
    }
}
```

**Watch Implementation**:
```swift
func session(_ session: WCSession, 
            didReceiveUserInfo userInfo: [String: Any]) {
    guard let messageData = userInfo["message"] as? Data else { return }
    
    do {
        let decoder = JSONDecoder()
        let message = try decoder.decode(SyncMessage.self, from: messageData)
        
        switch message.type {
        case .syncConfiguration:
            let payload = try message.decodePayload(
                ConfigurationSyncPayload.self
            )
            handleConfigurationSync(payload)
            
        case .syncAllConfigurations:
            let payload = try message.decodePayload(
                AllConfigurationsSyncPayload.self
            )
            handleAllConfigurationsSync(payload)
            
        default:
            print("Unexpected message type: \(message.type)")
        }
        
        // Send acknowledgment
        sendAcknowledgment(for: message.messageId)
        
    } catch {
        print("Failed to process user info: \(error)")
    }
}

private func handleConfigurationSync(_ payload: ConfigurationSyncPayload) {
    let dataStore = UserDefaultsStore()
    
    do {
        // Load existing configurations
        var configs = try dataStore.load(
            [RunConfiguration].self,
            forKey: UserDefaultsKeys.activeRunConfigurations
        ) ?? []
        
        // Update or add configuration
        if let index = configs.firstIndex(where: { 
            $0.id == payload.configuration.id 
        }) {
            configs[index] = payload.configuration
        } else {
            configs.append(payload.configuration)
        }
        
        // Save updated list
        try dataStore.save(configs, 
            forKey: UserDefaultsKeys.activeRunConfigurations)
        
        print("Configuration synced: \(payload.configuration.name)")
        
    } catch {
        print("Failed to save configuration: \(error)")
    }
}
```

### 2. Sync All Configurations (Phone → Watch)

**When**: User taps "Sync All" or initial setup

**Method**: `transferUserInfo()` - Background transfer

**Payload**:
```swift
struct AllConfigurationsSyncPayload: Codable {
    let configurations: [RunConfiguration]
    let syncTimestamp: Date
}
```

**Implementation**:
```swift
// Phone
func syncAllConfigurations() {
    let dataStore = UserDefaultsStore()
    
    do {
        let configs = try dataStore.load(
            [RunConfiguration].self,
            forKey: UserDefaultsKeys.runConfigurations
        ) ?? []
        
        let payload = AllConfigurationsSyncPayload(
            configurations: configs,
            syncTimestamp: Date()
        )
        
        let message = try SyncMessage(
            type: .syncAllConfigurations,
            payload: payload
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        
        session?.transferUserInfo(["message": data])
        
    } catch {
        print("Failed to sync all configurations: \(error)")
    }
}

// Watch
private func handleAllConfigurationsSync(
    _ payload: AllConfigurationsSyncPayload
) {
    let dataStore = UserDefaultsStore()
    
    do {
        // Replace all configurations
        try dataStore.save(
            payload.configurations,
            forKey: UserDefaultsKeys.activeRunConfigurations
        )
        
        print("Synced \(payload.configurations.count) configurations")
        
    } catch {
        print("Failed to save configurations: \(error)")
    }
}
```

### 3. Delete Configuration (Phone → Watch)

**When**: User deletes configuration on phone

**Method**: `sendMessage()` - Immediate if reachable

**Payload**:
```swift
struct DeleteConfigurationPayload: Codable {
    let configurationId: UUID
}
```

**Implementation**:
```swift
// Phone
func deleteConfiguration(_ id: UUID) {
    guard let session = session else { return }
    
    do {
        let payload = DeleteConfigurationPayload(configurationId: id)
        let message = try SyncMessage(
            type: .deleteConfiguration,
            payload: payload
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        
        if session.isReachable {
            // Immediate delivery
            session.sendMessage(
                ["message": data],
                replyHandler: { reply in
                    print("Delete confirmed")
                },
                errorHandler: { error in
                    print("Delete failed: \(error)")
                    self.queueDeleteForLater(id)
                }
            )
        } else {
            // Queue for later
            queueDeleteForLater(id)
        }
        
    } catch {
        print("Failed to send delete message: \(error)")
    }
}

// Watch
func session(_ session: WCSession, 
            didReceiveMessage message: [String: Any],
            replyHandler: @escaping ([String: Any]) -> Void) {
    guard let messageData = message["message"] as? Data else {
        replyHandler(["error": "Invalid message"])
        return
    }
    
    do {
        let decoder = JSONDecoder()
        let syncMessage = try decoder.decode(SyncMessage.self, from: messageData)
        
        if syncMessage.type == .deleteConfiguration {
            let payload = try syncMessage.decodePayload(
                DeleteConfigurationPayload.self
            )
            handleDeleteConfiguration(payload)
            replyHandler(["status": "success"])
        }
        
    } catch {
        replyHandler(["error": error.localizedDescription])
    }
}

private func handleDeleteConfiguration(
    _ payload: DeleteConfigurationPayload
) {
    let dataStore = UserDefaultsStore()
    
    do {
        var configs = try dataStore.load(
            [RunConfiguration].self,
            forKey: UserDefaultsKeys.activeRunConfigurations
        ) ?? []
        
        configs.removeAll { $0.id == payload.configurationId }
        
        try dataStore.save(
            configs,
            forKey: UserDefaultsKeys.activeRunConfigurations
        )
        
        print("Configuration deleted: \(payload.configurationId)")
        
    } catch {
        print("Failed to delete configuration: \(error)")
    }
}
```

### 4. Workout Completed (Watch → Phone)

**When**: User finishes workout on watch

**Method**: `transferFile()` - Reliable background transfer

**Payload**: WorkoutSummary as JSON file

**Implementation**:
```swift
// Watch
func completeWorkout(_ session: WorkoutSession) {
    let summary = WorkoutSummary(from: session)
    
    do {
        // Save workout summary to temporary file
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(summary)
        
        let filename = "workout_\(summary.id.uuidString).json"
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
        
        try data.write(to: fileURL)
        
        // Transfer file to phone
        wcSession?.transferFile(fileURL, metadata: [
            "type": "workoutSummary",
            "workoutId": summary.id.uuidString
        ])
        
        print("Workout file queued for transfer")
        
    } catch {
        print("Failed to transfer workout: \(error)")
    }
}

// Phone
func session(_ session: WCSession, didReceive file: WCSessionFile) {
    guard let type = file.metadata?["type"] as? String,
          type == "workoutSummary" else {
        return
    }
    
    do {
        let data = try Data(contentsOf: file.fileURL)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(WorkoutSummary.self, from: data)
        
        // Save to local storage
        saveWorkoutSummary(summary)
        
        // Update UI
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .workoutReceived,
                object: summary
            )
        }
        
        print("Workout received: \(summary.configurationName)")
        
    } catch {
        print("Failed to process workout file: \(error)")
    }
}
```

### 5. Sync Request (Watch → Phone)

**When**: Watch app launched and needs configurations

**Method**: `sendMessage()` - Immediate

**Payload**:
```swift
struct SyncRequestPayload: Codable {
    let requestType: SyncRequestType
    let timestamp: Date
}

enum SyncRequestType: String, Codable {
    case configurations
    case workoutHistory
}
```

**Implementation**:
```swift
// Watch
func requestConfigurationSync() {
    guard let session = wcSession, session.isReachable else {
        print("Phone not reachable")
        return
    }
    
    do {
        let payload = SyncRequestPayload(
            requestType: .configurations,
            timestamp: Date()
        )
        
        let message = try SyncMessage(
            type: .syncRequest,
            payload: payload
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        
        session.sendMessage(
            ["message": data],
            replyHandler: { reply in
                print("Sync request acknowledged")
            },
            errorHandler: { error in
                print("Sync request failed: \(error)")
            }
        )
        
    } catch {
        print("Failed to send sync request: \(error)")
    }
}

// Phone
func session(_ session: WCSession, 
            didReceiveMessage message: [String: Any],
            replyHandler: @escaping ([String: Any]) -> Void) {
    guard let messageData = message["message"] as? Data else {
        replyHandler(["error": "Invalid message"])
        return
    }
    
    do {
        let decoder = JSONDecoder()
        let syncMessage = try decoder.decode(SyncMessage.self, from: messageData)
        
        if syncMessage.type == .syncRequest {
            let payload = try syncMessage.decodePayload(
                SyncRequestPayload.self
            )
            
            // Respond to sync request
            handleSyncRequest(payload)
            replyHandler(["status": "syncing"])
        }
        
    } catch {
        replyHandler(["error": error.localizedDescription])
    }
}

private func handleSyncRequest(_ payload: SyncRequestPayload) {
    switch payload.requestType {
    case .configurations:
        syncAllConfigurations()
    case .workoutHistory:
        // Not implemented yet
        break
    }
}
```

## Sync Queue Management

### Queued Sync Operations

When watch is not reachable, operations are queued:

```swift
class SyncQueue {
    private var queuedOperations: [QueuedOperation] = []
    
    struct QueuedOperation: Codable {
        let id: UUID
        let type: MessageType
        let payload: Data
        let timestamp: Date
        var retryCount: Int
    }
    
    func enqueue(type: MessageType, payload: Codable) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        
        let operation = QueuedOperation(
            id: UUID(),
            type: type,
            payload: data,
            timestamp: Date(),
            retryCount: 0
        )
        
        queuedOperations.append(operation)
        saveQueue()
    }
    
    func processQueue(session: WCSession) {
        guard !queuedOperations.isEmpty else { return }
        
        var processedIds: [UUID] = []
        
        for operation in queuedOperations {
            if operation.retryCount >= 3 {
                // Max retries reached, remove
                processedIds.append(operation.id)
                continue
            }
            
            do {
                let message = [
                    "message": operation.payload
                ]
                
                if session.isReachable {
                    session.sendMessage(
                        message,
                        replyHandler: { _ in
                            processedIds.append(operation.id)
                        },
                        errorHandler: { error in
                            print("Retry failed: \(error)")
                            self.incrementRetryCount(for: operation.id)
                        }
                    )
                } else {
                    // Use background transfer
                    session.transferUserInfo(message)
                    processedIds.append(operation.id)
                }
                
            } catch {
                print("Failed to process queued operation: \(error)")
                incrementRetryCount(for: operation.id)
            }
        }
        
        // Remove processed operations
        queuedOperations.removeAll { 
            processedIds.contains($0.id) 
        }
        saveQueue()
    }
    
    private func saveQueue() {
        let dataStore = UserDefaultsStore()
        try? dataStore.save(
            queuedOperations,
            forKey: "syncQueue"
        )
    }
    
    private func incrementRetryCount(for id: UUID) {
        if let index = queuedOperations.firstIndex(where: { $0.id == id }) {
            queuedOperations[index].retryCount += 1
            saveQueue()
        }
    }
}
```

## Conflict Resolution

### Configuration Conflicts

When same configuration modified on both devices:

```swift
enum ConflictResolution {
    case usePhone  // Phone version wins
    case useWatch  // Watch version wins
    case keepBoth  // Create duplicate
}

func resolveConfigurationConflict(
    phone: RunConfiguration,
    watch: RunConfiguration,
    resolution: ConflictResolution
) -> [RunConfiguration] {
    
    switch resolution {
    case .usePhone:
        return [phone]
        
    case .useWatch:
        return [watch]
        
    case .keepBoth:
        var watchCopy = watch
        watchCopy.id = UUID()
        watchCopy.name = "\(watch.name) (Watch)"
        return [phone, watchCopy]
    }
}
```

**Default Strategy**: Most recent modification wins (based on lastModified date)

## Sync Status Tracking

```swift
enum SyncStatus {
    case synced
    case syncing
    case pending
    case failed(Error)
}

class SyncStatusManager: ObservableObject {
    @Published var configurationStatus: [UUID: SyncStatus] = [:]
    
    func updateStatus(for id: UUID, status: SyncStatus) {
        DispatchQueue.main.async {
            self.configurationStatus[id] = status
        }
    }
    
    func getStatus(for id: UUID) -> SyncStatus {
        configurationStatus[id] ?? .pending
    }
}
```

## Testing Sync Protocol

### Unit Tests

```swift
class SyncProtocolTests: XCTestCase {
    func testConfigurationSyncPayload() throws {
        let config = RunConfiguration(
            name: "Test",
            distance: Distance(miles: 10),
            milePaces: []
        )
        
        let payload = ConfigurationSyncPayload(
            configuration: config,
            syncTimestamp: Date()
        )
        
        let message = try SyncMessage(
            type: .syncConfiguration,
            payload: payload
        )
        
        let decoded = try message.decodePayload(
            ConfigurationSyncPayload.self
        )
        
        XCTAssertEqual(decoded.configuration.id, config.id)
    }
}
```

### Integration Tests

1. **Test Configuration Sync**: Create config on phone, verify appears on watch
2. **Test Workout Transfer**: Complete workout on watch, verify appears on phone
3. **Test Delete Sync**: Delete config on phone, verify removed from watch
4. **Test Queue Processing**: Queue operations when watch not reachable, verify delivery when connected
5. **Test Conflict Resolution**: Modify same config on both devices, verify resolution

## Performance Considerations

### Transfer Sizes
- RunConfiguration: ~1-5 KB (depending on number of miles)
- WorkoutSummary: ~2-10 KB (depending on splits)
- All configurations: Max 100 KB

### Transfer Timing
- `sendMessage()`: Immediate (both devices must be active)
- `transferUserInfo()`: Background, delivered when possible
- `transferFile()`: Background, queued until delivered

### Battery Impact
- Minimize frequent transfers
- Batch configuration updates
- Use background transfers for non-urgent data

## Error Handling

### Common Errors

```swift
enum SyncError: Error {
    case sessionNotActivated
    case watchNotReachable
    case transferFailed
    case dataCorrupted
    case exceededRetryLimit
}
```

### Error Recovery

1. **Session Not Activated**: Wait for activation, queue operations
2. **Watch Not Reachable**: Queue for background transfer
3. **Transfer Failed**: Retry up to 3 times
4. **Data Corrupted**: Log error, request full re-sync

## Security

- All data transferred via WatchConnectivity is encrypted by iOS
- No sensitive user data (passwords, payment info)
- All transfers are local (device to device)
- No external network requests

## Notifications

Post notifications for sync events:

```swift
extension Notification.Name {
    static let configurationSynced = Notification.Name("configurationSynced")
    static let workoutReceived = Notification.Name("workoutReceived")
    static let syncFailed = Notification.Name("syncFailed")
}
```

## Debugging

Enable verbose logging:

```swift
#if DEBUG
let verboseSync = true
#else
let verboseSync = false
#endif

func log(_ message: String) {
    if verboseSync {
        print("[Sync] \(message)")
    }
}
```
