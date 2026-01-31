# HealthKit Export Integration Contract

**Framework**: HealthKit
**Platform**: iOS 17.0+
**Purpose**: Observe workout completions, extract detailed workout data for export

## Contract Tests Required

Contract tests verify that PaceRunner correctly uses HealthKit APIs to detect new workouts, query associated data (heart rate, route, cadence), and handle permissions, errors, and edge cases.

---

## 1. Observer Query Registration

### Test: Register Workout Observer
**Given**: App has launched with HealthKit permissions granted
**When**: `WorkoutExportService` registers `HKObserverQuery` for `HKObjectType.workoutType()`
**Then**:
- Observer query is created with correct sample type
- Background delivery is enabled via `healthStore.enableBackgroundDelivery(for:frequency:)`
- Frequency is `.immediate` for timely export
- Observer handler fires when new workout is saved to HealthKit
- Return success

**Error Cases**:
- Permission not granted → Observer fails silently, no crash
- Background delivery entitlement missing → Log warning, observer still works in foreground

---

### Test: Observer Fires on Workout Completion
**Given**: Active workout observer registered
**When**: A new `HKWorkout` of type `.running` is saved to HealthKit
**Then**:
- Observer handler invoked with completion handler
- Completion handler called after processing to allow background task to end
- Query returns workout(s) newer than last processed date

**Edge Cases**:
- Multiple workouts saved simultaneously → Process all new workouts
- Non-running workout saved (e.g., cycling) → Filter out, skip export
- Observer fires but no new workouts found → No-op, call completion

---

## 2. Workout Query

### Test: Query Recent Running Workouts
**Given**: HealthKit contains running workouts
**When**: `WorkoutDataExtractor` queries workouts since last export
**Then**:
- `HKSampleQuery` returns workouts sorted by start date (descending)
- Filter: `HKQuery.predicateForWorkouts(with: .running)`
- Also matches `.walking` workouts if marked as running in source app
- Returns workout UUID, start/end dates, duration, distance, energy burned
- Return up to 10 most recent workouts

---

### Test: Query Single Workout by UUID
**Given**: Known workout UUID from observer trigger
**When**: `WorkoutDataExtractor` queries specific workout
**Then**:
- `HKSampleQuery` with UUID predicate returns exact workout
- All workout metadata accessible
- Source app name available via `workout.sourceRevision.source.name`
- Indoor/outdoor flag via `workout.workoutActivityType` and metadata

---

## 3. Heart Rate Data Extraction

### Test: Query Heart Rate Samples
**Given**: Workout with heart rate data (Apple Watch HR sensor)
**When**: `WorkoutDataExtractor` queries `HKQuantityType(.heartRate)` between workout start and end
**Then**:
- Returns `[HKQuantitySample]` sorted by start date
- Each sample provides BPM via `sample.quantity.doubleValue(for: .count().unitDivided(by: .minute()))`
- Samples are timestamped relative to workout start
- Typical frequency: 1 sample every 3-5 seconds

**Computed Values**:
- Average HR: arithmetic mean of all samples
- Max HR: highest BPM value
- Min HR: lowest BPM value (excluding warm-up first 60 seconds)
- Resting HR: query `HKQuantityType(.restingHeartRate)` for most recent value

---

### Test: Calculate Heart Rate Zones
**Given**: Array of HR samples and max HR (user-provided or age-estimated)
**When**: `HeartRateZoneCalculator` processes samples
**Then**:
- Zone boundaries computed from max HR:
  - Zone 1 (Recovery): < 60% max HR
  - Zone 2 (Easy): 60-70% max HR
  - Zone 3 (Tempo): 70-80% max HR
  - Zone 4 (Threshold): 80-90% max HR
  - Zone 5 (Max): > 90% max HR
- Time-in-zone calculated by summing inter-sample intervals per zone
- Results returned as `[HeartRateZone]` with zone number, label, and minutes

**Edge Cases**:
- No HR data → Return nil for heart rate section
- Single HR sample → All time assigned to one zone
- Max HR not set → Use 220-age estimate, fallback to 190 if age unknown

---

## 4. Route Data Extraction

### Test: Query Workout Route
**Given**: Outdoor running workout with GPS route
**When**: `WorkoutDataExtractor` queries `HKWorkoutRoute` associated with workout
**Then**:
- `HKSampleQuery` for `HKSeriesType.workoutRoute()` returns route object(s)
- Route associated with workout via `HKQuery.predicateForObjects(from: workout)`

---

### Test: Extract Route Points
**Given**: `HKWorkoutRoute` object from query
**When**: `HKWorkoutRouteQuery` iterates route locations
**Then**:
- Handler called multiple times with `[CLLocation]` batches
- Handler called with `done: true` on final batch
- Each `CLLocation` provides: latitude, longitude, altitude, timestamp
- All locations collected into single array

**Async Pattern**:
```swift
func extractRoute(from route: HKWorkoutRoute) async throws -> [CLLocation] {
    try await withCheckedThrowingContinuation { continuation in
        var allLocations: [CLLocation] = []
        let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
            if let error = error {
                continuation.resume(throwing: error)
                return
            }
            if let locations = locations {
                allLocations.append(contentsOf: locations)
            }
            if done {
                continuation.resume(returning: allLocations)
            }
        }
        healthStore.execute(query)
    }
}
```

---

### Test: Calculate Elevation
**Given**: Array of `CLLocation` with altitude data
**When**: Elevation calculator processes locations
**Then**:
- Elevation gain: sum of positive altitude deltas between consecutive points
- Elevation loss: sum of negative altitude deltas (absolute value)
- Filter noise: ignore altitude changes < 1 meter between consecutive points
- Convert to feet for output (× 3.28084)

**Edge Cases**:
- Indoor workout (no route) → Return nil for route section
- Route with no altitude data → Omit elevation, keep lat/lon points
- Very long route (50,000+ points) → Downsample to every 5-10 seconds

---

## 5. Per-Mile Split Calculation

### Test: Calculate Mile Splits from Route
**Given**: Array of `CLLocation` from workout route, sorted by timestamp
**When**: `WorkoutDataExtractor` computes mile boundaries
**Then**:
- Accumulate distance between consecutive points via `location.distance(from:)`
- When accumulated distance crosses mile boundary (1609.34m), record split
- For each split:
  - Mile number (1-based)
  - Pace (elapsed time / distance for that mile)
  - Elapsed time from workout start
  - Average HR during that mile's time window
- Final partial mile included if > 0.1 miles

**Edge Cases**:
- Treadmill (no route data) → Try `HKWorkoutEvent` distance markers, or omit splits
- Very short workout (< 1 mile) → Single partial split
- GPS drift at start → First split may be slightly inaccurate

---

### Test: Associate HR with Splits
**Given**: Mile split time boundaries and HR sample array
**When**: Computing per-mile average HR
**Then**:
- Filter HR samples within each mile's time range [splitStart, splitEnd]
- Calculate arithmetic mean of BPM values
- Return as `avgHR` in split data

---

## 6. Additional Metrics

### Test: Query Running Cadence
**Given**: Workout with Apple Watch cadence data
**When**: `WorkoutDataExtractor` queries `HKQuantityType(.stepCount)` for workout period
**Then**:
- Sum total steps between workout start and end
- Calculate average cadence: (total steps / duration in minutes) ÷ 2 (steps per foot)
- Actually: cadence = total steps / duration in minutes (already steps/min)
- Return as integer SPM

---

### Test: Query VO2 Max
**Given**: User has recent VO2 Max measurement
**When**: `WorkoutDataExtractor` queries `HKQuantityType(.vo2Max)`
**Then**:
- Query most recent sample (not limited to workout period)
- Return value in mL/kg/min
- Return nil if no VO2 Max data available

---

## 7. Deduplication

### Test: Track Exported Workout UUIDs
**Given**: Fresh `ExportDeduplicationStore`
**When**: Workout UUID is marked as exported
**Then**:
- UUID persisted to UserDefaults
- `isExported(uuid:)` returns true for marked UUID
- Persists across app restart (re-init from UserDefaults)

---

### Test: Skip Already-Exported Workouts
**Given**: Workout UUID already marked as exported
**When**: Observer query fires and includes that workout
**Then**:
- Export pipeline checks dedup store
- Skips workout, does not re-export
- No duplicate file written

---

### Test: Clear Old Entries
**Given**: 100+ exported UUIDs stored
**When**: Cleanup runs (e.g., on app launch)
**Then**:
- Remove entries older than 90 days
- Recent entries preserved
- Storage size stays bounded

---

## 8. Permissions

### Test: Request Export Permissions
**Given**: App needs HealthKit read access for export
**When**: App calls `healthStore.requestAuthorization(toShare:read:)`
**Then**:
- Read types requested:
  - `HKObjectType.workoutType()`
  - `HKQuantityType(.heartRate)`
  - `HKQuantityType(.distanceWalkingRunning)`
  - `HKQuantityType(.activeEnergyBurned)`
  - `HKQuantityType(.stepCount)`
  - `HKQuantityType(.vo2Max)`
  - `HKQuantityType(.restingHeartRate)`
  - `HKQuantityType(.runningStrideLength)`
  - `HKSeriesType.workoutRoute()`
- Share types: none (export is read-only)
- User sees permission dialog on first request

---

### Test: Handle Permission Denied
**Given**: User denies HealthKit read access
**When**: Export observer fires
**Then**:
- Export pipeline detects missing permissions
- Logs clear error message
- Does not crash
- Surfaces permission prompt to user (on next app foreground)

---

## 9. Error Handling

### Test: HealthKit Unavailable
**Given**: Device doesn't support HealthKit (simulator)
**When**: Export service initializes
**Then**:
- `HKHealthStore.isHealthDataAvailable()` returns false
- Export service enters disabled state
- No observer registered
- No crash

---

### Test: Query Returns No Data
**Given**: Workout exists but has no HR or route data (e.g., treadmill with no watch)
**When**: Export pipeline runs
**Then**:
- Missing sections omitted from JSON (no `heartRate`, no `route`, no `splits`)
- Core workout summary still exported (dates, duration, distance)
- Export marked as successful

---

### Test: iCloud Drive Unavailable
**Given**: User not signed into iCloud or iCloud Drive disabled
**When**: Export attempts to write file
**Then**:
- `FileManager.default.url(forUbiquityContainerIdentifier:)` returns nil
- Writer falls back to local Documents directory
- File still written successfully
- Log indicates fallback path

---

## 10. Performance Requirements

- **Observer registration**: <100ms on app launch
- **Full export pipeline**: <10 seconds from trigger to file written
- **Route query**: <5 seconds for marathon-length route (50,000 points)
- **Memory during export**: <20MB peak (route data buffered, then released)
- **Background task**: Complete within iOS background execution limit

---

## Mock Strategy for Unit Tests

```swift
protocol HealthKitStoreProtocol {
    func requestAuthorization(toShare: Set<HKSampleType>?,
                              read: Set<HKObjectType>?,
                              completion: @escaping (Bool, Error?) -> Void)
    func execute(_ query: HKQuery)
    func stop(_ query: HKQuery)
    func enableBackgroundDelivery(for type: HKObjectType,
                                  frequency: HKUpdateFrequency,
                                  withCompletion: @escaping (Bool, Error?) -> Void)
    static func isHealthDataAvailable() -> Bool
}

class MockHealthKitStore: HealthKitStoreProtocol {
    var mockWorkouts: [HKWorkout] = []
    var mockHRSamples: [HKQuantitySample] = []
    var mockRouteLocations: [CLLocation] = []
    var shouldFailAuthorization = false
    
    func execute(_ query: HKQuery) {
        // Route results to appropriate mock data based on query type
        if let sampleQuery = query as? HKSampleQuery {
            // Return mock workouts or HR samples
        }
        if let observerQuery = query as? HKObserverQuery {
            // Fire observer handler
        }
    }
}
```

---

## Real Device Testing Requirements

Export contract tests MUST include real device validation:

1. **iPhone running iOS 17.0+ paired with Apple Watch**
2. **Test Cases**:
   - Complete a real running workout on Watch
   - Wait for export observer to fire on iPhone
   - Verify JSON file appears in iCloud Drive
   - Verify HR data, route data, and splits are populated
   - Complete a treadmill workout → verify export without route data
3. **Background Delivery**:
   - Lock phone, complete workout on watch
   - Verify export fires within minutes (background delivery)
   - Check file appears in iCloud Drive without opening app
4. **Validation**:
   - Compare exported distance to Workout app
   - Compare HR zones to Apple Fitness summary
   - Verify route points match workout route in Health app

---

## Constitution Compliance

✅ **Native Performance**: HealthKit is native iOS framework, no third-party dependencies
✅ **Local Processing**: All data extraction and formatting happens on-device
✅ **Battery Efficient**: Observer-based (event-driven), not polling
✅ **Offline Capable**: Local fallback when iCloud unavailable
✅ **Test-Driven**: Contract tests define expected behavior before implementation
