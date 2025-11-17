# HealthKit Integration Contract

**Framework**: HealthKit
**Platform**: watchOS 10.0+
**Purpose**: Workout session management and data persistence

## Contract Tests Required

Contract tests verify that PaceRunner correctly integrates with HealthKit APIs and handles framework behaviors, errors, and state transitions.

---

## 1. Workout Session Lifecycle

### Test: Start Workout Session
**Given**: User has granted HealthKit permissions
**When**: WorkoutManager calls `HKHealthStore.startWorkoutSession(_:)`
**Then**:
- HKWorkoutSession state transitions to `.running`
- Delegate receives `workoutSession(_:didChangeTo:from:date:)`
- Session startDate is set to current time
- Return success

**Error Cases**:
- Permission denied → Throw `.errorAuthorizationNotDetermined`
- Session already running → Throw `.errorInvalidArgument`

---

### Test: Pause Workout Session
**Given**: Active workout session in `.running` state
**When**: WorkoutManager calls `session.pause()`
**Then**:
- State transitions to `.paused`
- Delegate receives state change callback
- GPS location updates continue (HealthKit doesn't stop CoreLocation)
- Return success

---

### Test: Resume Workout Session
**Given**: Paused workout session
**When**: WorkoutManager calls `session.resume()`
**Then**:
- State transitions to `.running`
- Delegate receives state change callback
- Elapsed time calculation accounts for pause duration
- Return success

---

### Test: End Workout Session
**Given**: Active or paused workout session
**When**: WorkoutManager calls `session.end()`
**Then**:
- State transitions to `.ended`
- Delegate receives state change callback
- Session can no longer be resumed
- Return success

---

## 2. Workout Data Persistence

### Test: Save Completed Workout
**Given**: Ended workout session with metadata
**When**: WorkoutManager saves HKWorkout
**Then**:
- Workout object created with `.running` activity type
- Start/end dates match session times
- Total distance saved as HKQuantity (meters)
- Metadata includes configuration name and mile splits (JSON)
- Workout queryable via HKSampleQuery
- Return success

**Required Metadata**:
```swift
[
    "configurationName": String,
    "mileSplits": Data // JSON-encoded [MileSplit]
]
```

---

### Test: Query Recent Workouts
**Given**: Multiple saved workouts in HealthKit
**When**: App queries workouts with HKSampleQuery
**Then**:
- Returns workouts sorted by start date (descending)
- Metadata correctly decoded
- Distance values in meters
- Return up to 50 most recent workouts

---

## 3. Permissions and Authorization

### Test: Request Permissions
**Given**: Fresh app install
**When**: App calls `HKHealthStore.requestAuthorization(toShare:read:)`
**Then**:
- Permission dialog presented to user
- After grant: `.sharingAuthorized` for workout type
- After denial: `.sharingDenied`

**Types to Request**:
- Share: `HKObjectType.workoutType()`
- Read: `HKObjectType.workoutType()`, `HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)`

---

### Test: Check Authorization Status
**Given**: Permissions previously requested
**When**: App calls `authorizationStatus(for:)`
**Then**:
- Returns `.sharingAuthorized` if granted
- Returns `.sharingDenied` if denied
- Returns `.notDetermined` if never asked

---

## 4. Error Handling

### Test: Save Fails When Unauthorized
**Given**: HealthKit permission denied
**When**: Attempt to save HKWorkout
**Then**:
- Throws `.errorAuthorizationDenied`
- No workout data persisted
- UI displays permission request prompt

---

### Test: Session Fails on Unsupported Device
**Given**: Running on iOS Simulator (HealthKit not fully supported)
**When**: Start workout session
**Then**:
- Returns error or degraded functionality warning
- App continues with local data only (no HealthKit save)

---

## 5. Background Execution

### Test: Workout Continues in Background
**Given**: Active workout session
**When**: Watch screen turns off or app moves to background
**Then**:
- HKWorkoutSession remains active
- State callbacks continue to fire
- GPS location updates continue (managed by CoreLocation)
- Workout data accumulated correctly

---

## 6. Edge Cases

### Test: Concurrent Workout Prevention
**Given**: Existing active workout session
**When**: Attempt to start second workout session
**Then**:
- Throws `.errorInvalidArgument`
- Original session unaffected
- UI displays error message

---

### Test: App Crash During Workout
**Given**: Active workout session
**When**: App process terminates unexpectedly
**Then**:
- On app restart: Session marked as `.ended` by system
- Partial data may be recoverable via query
- App displays recovery options to user

---

### Test: Very Long Workout
**Given**: Workout lasting >6 hours
**When**: User completes workout normally
**Then**:
- All data persisted correctly
- No overflow in duration calculations
- Mile splits array handles 26+ entries

---

## Mock Strategy for Unit Tests

```swift
protocol HealthKitStore {
    func requestAuthorization(toShare: Set<HKSampleType>?,
                            read: Set<HKObjectType>?,
                            completion: @escaping (Bool, Error?) -> Void)
    func save(_ object: HKObject, withCompletion: @escaping (Bool, Error?) -> Void)
    func execute(_ query: HKQuery)
}

class MockHealthKitStore: HealthKitStore {
    var authorizationGranted = true
    var savedWorkouts: [HKWorkout] = []
    var shouldFailSave = false

    func requestAuthorization(...) {
        completion(authorizationGranted, nil)
    }

    func save(_ object: HKObject, withCompletion: @escaping (Bool, Error?) -> Void) {
        if shouldFailSave {
            withCompletion(false, HKError(.errorAuthorizationDenied))
        } else if let workout = object as? HKWorkout {
            savedWorkouts.append(workout)
            withCompletion(true, nil)
        }
    }
}
```

---

## Real Device Testing Requirements

HealthKit contract tests MUST include real device validation:

1. **Apple Watch Series 6+ running watchOS 10.0+**
2. **Test Cases**:
   - Complete 1-mile outdoor walk/run
   - Verify workout saved to Health app
   - Pause/resume during workout
   - Force quit app mid-workout, verify recovery
3. **Validation**:
   - Check Health app for workout entry
   - Verify distance matches GPS track
   - Confirm metadata accessible via iPhone Health app

---

## Performance Requirements

- **Authorization request**: <1 second UI response
- **Workout save**: <500ms (asynchronous, non-blocking)
- **Query execution**: <200ms for 50 workouts
- **Memory**: <5MB for workout session object

---

## Constitution Compliance

✅ **Native Performance**: HealthKit APIs are native iOS framework
✅ **Local Storage**: All data stored on-device
✅ **No Network**: HealthKit operates entirely offline
✅ **Battery Efficient**: Workout sessions designed for long-duration tracking
