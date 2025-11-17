# WatchConnectivity Integration Contract

**Framework**: WatchConnectivity
**Platforms**: iOS 17.0+ (iPhone), watchOS 10.0+ (Apple Watch)
**Purpose**: Synchronize run configurations and workout summaries between devices

## Contract Tests Required

Contract tests verify correct integration with WatchConnectivity APIs for bidirectional data sync between paired iPhone and Apple Watch.

---

## 1. Session Setup and Activation

### Test: Initialize WatchConnectivity Session (iPhone)
**Given**: iPhone app launch
**When**: SyncManager calls `WCSession.default.activate()`
**Then**:
- Session delegate receives `session(_:activationDidCompleteWith:error:)`
- Activation state = `.activated`
- `isPaired` = true (if watch paired)
- `isWatchAppInstalled` = true (if watch app installed)
- Return success

---

### Test: Initialize WatchConnectivity Session (Watch)
**Given**: Watch app launch
**When**: SyncManager calls `WCSession.default.activate()`
**Then**:
- Session delegate receives activation callback
- Activation state = `.activated`
- `isReachable` indicates if iPhone in range
- Return success

---

## 2. Configuration Sync (iPhone → Watch)

### Test: Send Configuration via Message (Immediate)
**Given**: iPhone and watch reachable (in Bluetooth/WiFi range)
**When**: User creates/edits configuration on iPhone
**Then**:
- SyncManager calls `sendMessage(_:replyHandler:errorHandler:)`
- Watch receives message via `session(_:didReceiveMessage:)`
- Watch saves configuration to UserDefaults
- Reply confirms successful save
- Total latency <2 seconds (constitution requirement)

**Message Format**:
```swift
[
    "type": "configurationUpdate",
    "action": "create" | "update" | "delete",
    "data": Data // JSON-encoded RunConfiguration
]
```

---

### Test: Queue Configuration via UserInfo (Not Reachable)
**Given**: Watch not reachable
**When**: User creates configuration on iPhone
**Then**:
- SyncManager calls `transferUserInfo(_:)`
- Transfer queued for delivery
- Watch receives when next reachable via `session(_:didReceiveUserInfo:)`
- Sync status shows "Pending" on iPhone
- Multiple transfers batched efficiently

---

### Test: Delete Configuration Sync
**Given**: Configuration exists on both devices
**When**: User deletes configuration on iPhone
**Then**:
- Delete message sent to watch
- Watch removes configuration from UserDefaults
- Configuration removed from watch selection screen
- Sync within 2 seconds if reachable

---

## 3. Workout Summary Sync (Watch → iPhone)

### Test: Transfer Workout Summary via File
**Given**: User completes workout on watch
**When**: Watch app saves WorkoutSummary
**Then**:
- Watch calls `transferFile(_:metadata:)`
- File contains JSON-encoded WorkoutSummary
- iPhone receives via `session(_:didReceive:)`
- iPhone saves to UserDefaults
- Summary appears in history view
- Transfer happens in background

**File Format**:
```swift
// File: workout-{UUID}.json
{
    "id": "UUID",
    "configurationName": "Marathon - Even",
    "startTime": "ISO8601 timestamp",
    "endTime": "ISO8601 timestamp",
    "totalDistance": { "miles": 26.2 },
    "averagePace": { "minutes": 7, "seconds": 58 },
    "mileSplits": [...]
}
```

---

## 4. Reachability and Connection State

### Test: Detect Reachability Changes
**Given**: Active WCSession on both devices
**When**: Watch moves out of Bluetooth/WiFi range
**Then**:
- `isReachable` changes to false
- Delegate receives `sessionReachabilityDidChange(_:)`
- SyncManager switches from messages to userInfo transfers
- UI updates sync status indicator

---

### Test: Reconnection After Disconnect
**Given**: Watch was unreachable
**When**: Watch returns to range
**Then**:
- `isReachable` changes to true
- Queued userInfo transfers automatically delivered
- Delegate receives pending data
- Sync status updates to "Synced"

---

## 5. Error Handling

### Test: Send Message When Not Reachable
**Given**: Watch not in range
**When**: Attempt `sendMessage(_:replyHandler:errorHandler:)`
**Then**:
- Error handler called with `.notReachable` error
- SyncManager falls back to `transferUserInfo(_:)`
- User sees "Sync pending" status
- No data loss

---

### Test: Transfer Fails Due to Watch App Not Installed
**Given**: Paired watch without PaceRunner app installed
**When**: Attempt to send configuration
**Then**:
- `isWatchAppInstalled` = false
- Transfer fails immediately
- UI displays "Install watch app" message
- Sync retries after app installed

---

### Test: Handle File Transfer Errors
**Given**: Network interruption during file transfer
**When**: Watch transfers large workout file
**Then**:
- Transfer retries automatically
- Delegate receives error via `session(_:didFinish:error:)`
- UI shows retry option
- User can manually retry failed transfers

---

## 6. Data Consistency

### Test: Prevent Duplicate Configuration Sync
**Given**: Configuration already exists on watch
**When**: iPhone sends update with same ID
**Then**:
- Watch compares `modifiedAt` timestamps
- Only applies update if newer
- Prevents overwriting newer data with stale updates
- Maintains data consistency

---

### Test: Handle Configuration ID Conflicts
**Given**: Configuration deleted on iPhone but update queued
**When**: Watch receives update for deleted configuration
**Then**:
- Watch checks if configuration exists on iPhone
- If deleted: Ignore update and remove from watch
- If exists: Apply update normally

---

## 7. Performance Requirements

### Test: Message Send Latency
**Given**: Reachable watch
**When**: Send configuration update message
**Then**:
- Message delivered within 1 second
- Reply received within 2 seconds total
- Meets <2 second sync requirement (constitution)

---

### Test: File Transfer Performance
**Given**: Workout summary with 26 mile splits (~5KB JSON)
**When**: Transfer file from watch to iPhone
**Then**:
- Transfer initiates immediately
- Completes within 10 seconds
- Does not block workout end flow
- Background transfer doesn't impact battery

---

### Test: Batch Transfer Efficiency
**Given**: 10 configurations to sync
**When**: iPhone transfers all to watch
**Then**:
- WatchConnectivity batches multiple userInfo transfers
- Total transfer time <30 seconds
- Watch receives all configurations
- No duplicate transmissions

---

## 8. Edge Cases

### Test: Sync During Active Workout
**Given**: User running workout on watch
**When**: iPhone sends configuration update
**Then**:
- Update queued until after workout
- Active workout not interrupted
- Configuration available after workout ends
- Constitution: No blocking during workout

---

### Test: Concurrent Modifications
**Given**: Configuration edited on iPhone and deleted simultaneously
**When**: Both changes sync to watch
**Then**:
- Last-write-wins strategy (by timestamp)
- Delete takes precedence if newest
- No corrupted state
- UI reflects final state

---

### Test: First Launch Sync
**Given**: Fresh watch app install
**When**: iPhone has 20 existing configurations
**Then**:
- All configurations transferred via userInfo
- Watch displays sync progress
- Configurations available for workout within 1 minute
- No timeout errors

---

### Test: Watch Storage Full
**Given**: Watch storage nearly full
**When**: Attempt to sync large workout file
**Then**:
- Delegate receives storage error
- UI prompts user to free space
- Sync retries after space freed
- No data corruption

---

## Mock Strategy for Unit Tests

```swift
protocol ConnectivitySession {
    var delegate: WCSessionDelegate? { get set }
    var isReachable: Bool { get }
    var isPaired: Bool { get }

    func sendMessage(_ message: [String: Any],
                    replyHandler: @escaping ([String: Any]) -> Void,
                    errorHandler: @escaping (Error) -> Void)
    func transferUserInfo(_ userInfo: [String: Any]) -> WCSessionUserInfoTransfer
    func transferFile(_ file: URL, metadata: [String: Any]?) -> WCSessionFileTransfer
}

class MockConnectivitySession: ConnectivitySession {
    var delegate: WCSessionDelegate?
    var isReachable: Bool = true
    var isPaired: Bool = true

    var sentMessages: [[String: Any]] = []
    var transferredUserInfo: [[String: Any]] = []
    var transferredFiles: [URL] = []

    func sendMessage(_ message: [String: Any],
                    replyHandler: @escaping ([String: Any]) -> Void,
                    errorHandler: @escaping (Error) -> Void) {
        if isReachable {
            sentMessages.append(message)
            replyHandler(["status": "success"])
        } else {
            errorHandler(WCError(.sessionNotActivated))
        }
    }

    func transferUserInfo(_ userInfo: [String: Any]) -> WCSessionUserInfoTransfer {
        transferredUserInfo.append(userInfo)
        return MockUserInfoTransfer()
    }

    // Test helpers
    func simulateReceiveMessage(_ message: [String: Any]) {
        delegate?.session?(WCSession.default, didReceiveMessage: message)
    }

    func simulateReachabilityChange(reachable: Bool) {
        isReachable = reachable
        delegate?.sessionReachabilityDidChange?(WCSession.default)
    }
}
```

---

## Real Device Testing Requirements

WatchConnectivity contract tests MUST include real device validation:

1. **Paired iPhone + Apple Watch**
2. **Test Cases**:
   - Create configuration on iPhone, verify appears on watch <2 seconds
   - Complete workout on watch, verify summary on iPhone within 1 minute
   - Move watch out of range, verify queued sync when reconnected
   - Delete configuration on iPhone, verify removed from watch
3. **Validation**:
   - Use Xcode Console to monitor WCSession logs
   - Verify no dropped messages or lost transfers
   - Confirm sync works over both Bluetooth and WiFi

---

## Performance Benchmarks

- **Message latency (reachable)**: <1 second
- **Total sync time**: <2 seconds (constitution requirement)
- **File transfer**: <10 seconds for 5KB workout
- **Batch transfer**: <30 seconds for 10 configurations
- **Background transfer**: No impact on active workout

---

## Constitution Compliance

✅ **Non-Blocking**: Sync operations async, don't block workout execution
✅ **Offline Operation**: Queued transfers work without immediate connectivity
✅ **Local First**: Data persists locally before sync attempt
✅ **<2 Second Sync**: Message-based sync meets latency requirement
