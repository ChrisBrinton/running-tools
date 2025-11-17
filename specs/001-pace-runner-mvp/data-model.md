# Data Model: PaceRunner MVP

**Date**: 2025-11-17
**Branch**: 001-pace-runner-mvp

## Overview

This document defines all data models for the PaceRunner MVP. Models are implemented in the Shared target for reuse across iOS and watchOS apps. All models conform to Codable for UserDefaults persistence.

---

## Core Models

### 1. Pace

Represents running pace as minutes and seconds per mile.

**Fields**:
- `minutes: Int` - Whole minutes (e.g., 8 for 8:30/mile)
- `seconds: Int` - Remaining seconds 0-59 (e.g., 30 for 8:30/mile)

**Computed Properties**:
- `totalSeconds: Int` - Total seconds per mile (minutes × 60 + seconds)
- `secondsPerMeter: Double` - Pace in seconds per meter (for GPS calculations)
- `formatted: String` - Display format "8:30"

**Validation**:
- Pace range: 4:00 to 20:00 per mile (240-1200 seconds)
- Seconds must be 0-59

**Operations**:
- Equatable, Comparable (for pace comparisons)
- Initializers: `init(minutes:seconds:)`, `init(totalSeconds:)`, `init(secondsPerMeter:)`

**Swift Schema**:
```swift
struct Pace: Codable, Equatable, Comparable {
    let minutes: Int
    let seconds: Int

    var totalSeconds: Int {
        minutes * 60 + seconds
    }

    var secondsPerMeter: Double {
        Double(totalSeconds) / 1609.34  // meters per mile
    }

    var formatted: String {
        String(format: "%d:%02d", minutes, seconds)
    }

    init(minutes: Int, seconds: Int) {
        precondition(240...1200 ~= minutes * 60 + seconds, "Pace must be 4:00-20:00")
        precondition(0...59 ~= seconds, "Seconds must be 0-59")
        self.minutes = minutes
        self.seconds = seconds
    }

    init(totalSeconds: Int) {
        self.init(minutes: totalSeconds / 60, seconds: totalSeconds % 60)
    }

    static func < (lhs: Pace, rhs: Pace) -> Bool {
        lhs.totalSeconds < rhs.totalSeconds  // Faster pace has fewer seconds
    }
}
```

---

### 2. Distance

Represents distance in miles with support for fractional values.

**Fields**:
- `miles: Double` - Distance in miles (e.g., 26.2, 10.0)

**Computed Properties**:
- `meters: Double` - Distance in meters
- `kilometers: Double` - Distance in kilometers
- `formatted: String` - Display format with 1 decimal place

**Validation**:
- Distance range: 0.1 to 50.0 miles

**Swift Schema**:
```swift
struct Distance: Codable, Equatable {
    let miles: Double

    var meters: Double {
        miles * 1609.34
    }

    var kilometers: Double {
        miles * 1.60934
    }

    var formatted: String {
        String(format: "%.1f mi", miles)
    }

    init(miles: Double) {
        precondition(0.1...50.0 ~= miles, "Distance must be 0.1-50.0 miles")
        self.miles = miles
    }

    init(meters: Double) {
        self.init(miles: meters / 1609.34)
    }
}
```

---

### 3. RunConfiguration

Represents a saved workout plan with per-mile pace targets.

**Fields**:
- `id: UUID` - Unique identifier
- `name: String` - User-provided name (1-50 characters)
- `distance: Distance` - Total distance
- `milePaces: [Pace]` - Ordered array of pace targets (one per mile)
- `baseCadence: Int` - Target cadence in SPM (160-200, default 180)
- `paceTolerance: Int` - Acceptable deviation in seconds (default 5)
- `createdAt: Date` - Creation timestamp
- `modifiedAt: Date` - Last modification timestamp

**Computed Properties**:
- `averagePace: Pace` - Average of all mile paces
- `estimatedDuration: TimeInterval` - Total time based on mile paces
- `totalMiles: Int` - Ceiling of distance (for fractional marathons)

**Validation**:
- Name: 1-50 characters
- Distance: 0.1-50.0 miles
- milePaces.count must equal ceil(distance.miles)
- baseCadence: 160-200 SPM
- paceTolerance: 1-30 seconds

**Swift Schema**:
```swift
struct RunConfiguration: Codable, Identifiable {
    let id: UUID
    var name: String
    var distance: Distance
    var milePaces: [Pace]
    var baseCadence: Int
    var paceTolerance: Int
    let createdAt: Date
    var modifiedAt: Date

    var averagePace: Pace {
        let totalSeconds = milePaces.reduce(0) { $0 + $1.totalSeconds }
        return Pace(totalSeconds: totalSeconds / milePaces.count)
    }

    var estimatedDuration: TimeInterval {
        TimeInterval(milePaces.reduce(0) { $0 + $1.totalSeconds })
    }

    var totalMiles: Int {
        Int(ceil(distance.miles))
    }

    init(id: UUID = UUID(), name: String, distance: Distance, milePaces: [Pace],
         baseCadence: Int = 180, paceTolerance: Int = 5) {
        precondition(1...50 ~= name.count, "Name must be 1-50 characters")
        precondition(milePaces.count == Int(ceil(distance.miles)), "One pace per mile required")
        precondition(160...200 ~= baseCadence, "Cadence must be 160-200 SPM")
        precondition(1...30 ~= paceTolerance, "Tolerance must be 1-30 seconds")

        self.id = id
        self.name = name
        self.distance = distance
        self.milePaces = milePaces
        self.baseCadence = baseCadence
        self.paceTolerance = paceTolerance
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
}
```

---

### 4. MileSplit

Represents performance statistics for one completed mile.

**Fields**:
- `mileNumber: Int` - Mile index (1-based)
- `startTime: Date` - When mile started
- `endTime: Date` - When mile completed
- `actualDistance: Double` - GPS-measured distance in meters
- `averagePace: Pace` - Calculated pace for this mile
- `targetPace: Pace` - Intended pace from configuration
- `deviation: Int` - Seconds faster (negative) or slower (positive) than target

**Computed Properties**:
- `duration: TimeInterval` - Time to complete mile
- `isOnTarget: Bool` - Deviation within tolerance (±5 seconds)

**Swift Schema**:
```swift
struct MileSplit: Codable {
    let mileNumber: Int
    let startTime: Date
    let endTime: Date
    let actualDistance: Double  // meters
    let averagePace: Pace
    let targetPace: Pace

    var deviation: Int {
        averagePace.totalSeconds - targetPace.totalSeconds
    }

    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    var isOnTarget: Bool {
        abs(deviation) <= 5  // Within ±5 seconds
    }
}
```

---

### 5. WorkoutSession

Represents an active workout in progress (watch only, not persisted).

**Fields**:
- `id: UUID` - Session identifier
- `configurationID: UUID` - Reference to RunConfiguration
- `state: SessionState` - Current state (active/paused/ended)
- `startTime: Date` - Workout start time
- `pauseTime: Date?` - When paused (nil if active)
- `currentMile: Int` - Current mile number (1-based)
- `mileSplits: [MileSplit]` - Completed mile splits
- `totalDistance: Double` - GPS-measured total distance in meters
- `currentPace: Pace?` - Real-time smoothed pace

**Computed Properties**:
- `elapsedTime: TimeInterval` - Total active time (excluding pauses)
- `averagePace: Pace?` - Overall pace from completed splits

**State Machine**:
```swift
enum SessionState: Codable {
    case active
    case paused
    case ended
}
```

**Swift Schema**:
```swift
class WorkoutSession: ObservableObject {
    enum State: Codable {
        case active, paused, ended
    }

    let id: UUID
    let configurationID: UUID
    @Published var state: State
    let startTime: Date
    @Published var pauseTime: Date?
    @Published var currentMile: Int
    @Published var mileSplits: [MileSplit]
    @Published var totalDistance: Double  // meters
    @Published var currentPace: Pace?

    var elapsedTime: TimeInterval {
        if let pauseTime = pauseTime {
            return pauseTime.timeIntervalSince(startTime)
        } else {
            return Date().timeIntervalSince(startTime)
        }
    }

    var averagePace: Pace? {
        guard !mileSplits.isEmpty else { return nil }
        let totalSeconds = mileSplits.reduce(0) { $0 + $1.averagePace.totalSeconds }
        return Pace(totalSeconds: totalSeconds / mileSplits.count)
    }

    init(configurationID: UUID) {
        self.id = UUID()
        self.configurationID = configurationID
        self.state = .active
        self.startTime = Date()
        self.currentMile = 1
        self.mileSplits = []
        self.totalDistance = 0
    }
}
```

---

### 6. WorkoutSummary

Represents a completed workout (persisted and synced).

**Fields**:
- `id: UUID` - Unique identifier
- `configurationID: UUID?` - Original configuration (nil if config deleted)
- `configurationName: String` - Snapshot of config name
- `startTime: Date` - Workout start
- `endTime: Date` - Workout end
- `totalDistance: Distance` - Final distance
- `averagePace: Pace` - Overall pace
- `mileSplits: [MileSplit]` - All mile splits

**Computed Properties**:
- `duration: TimeInterval` - Total workout time
- `onTargetMiles: Int` - Count of splits within tolerance
- `performanceSummary: String` - "22 on pace, 2 fast, 2 slow"

**Swift Schema**:
```swift
struct WorkoutSummary: Codable, Identifiable {
    let id: UUID
    let configurationID: UUID?
    let configurationName: String
    let startTime: Date
    let endTime: Date
    let totalDistance: Distance
    let averagePace: Pace
    let mileSplits: [MileSplit]

    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    var onTargetMiles: Int {
        mileSplits.filter { $0.isOnTarget }.count
    }

    var performanceSummary: String {
        let fast = mileSplits.filter { $0.deviation < -5 }.count
        let slow = mileSplits.filter { $0.deviation > 5 }.count
        return "\(onTargetMiles) on pace, \(fast) fast, \(slow) slow"
    }
}
```

---

## Supporting Types

### GPSSample (Internal to PaceCalculator)

**Fields**:
- `timestamp: Date`
- `location: CLLocation`
- `speed: Double` - meters per second

**Purpose**: Internal representation for pace calculation, not persisted.

---

## Data Relationships

```
RunConfiguration (1) ──── (N) WorkoutSummary
       │                          │
       │                          │
       └──> milePaces: [Pace]     └──> mileSplits: [MileSplit]
                                              │
                                              └──> targetPace: Pace
                                              └──> averagePace: Pace

WorkoutSession (runtime only, not persisted)
       │
       ├──> configurationID: UUID (references RunConfiguration)
       └──> mileSplits: [MileSplit]
```

---

## Persistence Strategy

### UserDefaults Storage

**iPhone**:
```swift
// Save configurations
let configs: [RunConfiguration] = [...]
UserDefaults.standard.set(try JSONEncoder().encode(configs), forKey: "run_configurations")

// Save workout summaries
let summaries: [WorkoutSummary] = [...]
UserDefaults.standard.set(try JSONEncoder().encode(summaries), forKey: "workout_summaries")
```

**Watch**:
```swift
// Save synced configurations (read-only on watch)
UserDefaults.standard.set(try JSONEncoder().encode(configs), forKey: "run_configurations")
```

### HealthKit Storage

**Workout Data** (watch saves to HealthKit):
```swift
// HKWorkout with metadata
let workout = HKWorkout(
    activityType: .running,
    start: startTime,
    end: endTime,
    duration: duration,
    totalDistance: HKQuantity(unit: .meter(), doubleValue: totalDistance),
    metadata: [
        "configurationName": "Marathon - Even",
        "mileSplits": try JSONEncoder().encode(mileSplits)
    ]
)
```

---

## Data Flow

### Configuration Creation (iPhone → Watch)
1. User creates RunConfiguration on iPhone
2. Save to UserDefaults
3. Send via WatchConnectivity
4. Watch saves to UserDefaults
5. Available for workout selection

### Workout Execution (Watch)
1. User selects RunConfiguration
2. Create WorkoutSession (in-memory)
3. Track GPS → update totalDistance, currentPace
4. Detect mile boundary → create MileSplit
5. User ends workout → create WorkoutSummary
6. Save WorkoutSummary to HealthKit
7. Queue WorkoutSummary for phone sync

### History Review (Watch → iPhone)
1. WorkoutSummary syncs from watch
2. iPhone saves to UserDefaults
3. Display in history view

---

## Validation Rules Summary

| Model | Field | Validation |
|-------|-------|------------|
| Pace | totalSeconds | 240-1200 (4:00-20:00/mile) |
| Pace | seconds | 0-59 |
| Distance | miles | 0.1-50.0 |
| RunConfiguration | name | 1-50 characters |
| RunConfiguration | milePaces.count | ceil(distance.miles) |
| RunConfiguration | baseCadence | 160-200 SPM |
| RunConfiguration | paceTolerance | 1-30 seconds |
| MileSplit | mileNumber | >= 1 |
| WorkoutSummary | mileSplits | Non-empty array |

---

## Testing Considerations

### Unit Tests
- Pace conversions (minutes/seconds ↔ totalSeconds ↔ secondsPerMeter)
- Distance conversions (miles ↔ meters ↔ kilometers)
- RunConfiguration validation (invalid name, mismatched mile count)
- MileSplit deviation calculations
- WorkoutSummary performance summary

### Property-Based Tests
- Pace round-trip: `Pace(totalSeconds: p.totalSeconds) == p`
- Distance round-trip: `Distance(meters: d.meters).miles ≈ d.miles`

### Codable Tests
- Encode/decode round-trip for all models
- UserDefaults persistence and retrieval
- JSON compatibility for WatchConnectivity transfers
