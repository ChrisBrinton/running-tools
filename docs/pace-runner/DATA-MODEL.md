# Data Model Specification

## Overview

PaceRunner uses simple, Codable Swift structs for data persistence via UserDefaults. All models are shared between iOS and WatchOS targets.

## Core Data Models

### RunConfiguration

Represents a configured run with per-mile pace targets.

```swift
struct RunConfiguration: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var distance: Distance  // Total planned distance
    var milePaces: [MilePace]  // Pace target for each mile
    var baseCadence: Int  // Target steps per minute (default: 180)
    var paceToleranceSeconds: Int  // Alert threshold (default: 5)
    var createdAt: Date
    var lastModified: Date
    
    init(
        id: UUID = UUID(),
        name: String,
        distance: Distance,
        milePaces: [MilePace],
        baseCadence: Int = 180,
        paceToleranceSeconds: Int = 5
    ) {
        self.id = id
        self.name = name
        self.distance = distance
        self.milePaces = milePaces
        self.baseCadence = baseCadence
        self.paceToleranceSeconds = paceToleranceSeconds
        self.createdAt = Date()
        self.lastModified = Date()
    }
    
    // Helper: Get pace for specific mile number (1-indexed)
    func pace(forMile mileNumber: Int) -> Pace? {
        guard mileNumber > 0 && mileNumber <= milePaces.count else { return nil }
        return milePaces[mileNumber - 1].pace
    }
    
    // Helper: Validate configuration
    var isValid: Bool {
        !name.isEmpty &&
        distance.miles > 0 &&
        !milePaces.isEmpty &&
        milePaces.count == Int(distance.miles.rounded(.up)) &&
        baseCadence >= 160 && baseCadence <= 200
    }
}
```

### MilePace

Represents the pace target for a specific mile.

```swift
struct MilePace: Codable, Identifiable, Equatable {
    let id: UUID
    let mileNumber: Int  // 1-indexed
    var pace: Pace
    
    init(id: UUID = UUID(), mileNumber: Int, pace: Pace) {
        self.id = id
        self.mileNumber = mileNumber
        self.pace = pace
    }
}
```

### Pace

Represents running pace in minutes and seconds per mile.

```swift
struct Pace: Codable, Equatable, Comparable {
    let minutes: Int
    let seconds: Int
    
    init(minutes: Int, seconds: Int) {
        // Normalize: if seconds >= 60, roll over to minutes
        let totalSeconds = minutes * 60 + seconds
        self.minutes = totalSeconds / 60
        self.seconds = totalSeconds % 60
    }
    
    // Initialize from total seconds
    init(totalSeconds: Int) {
        self.minutes = totalSeconds / 60
        self.seconds = totalSeconds % 60
    }
    
    // Initialize from seconds per meter (CoreLocation speed)
    init(secondsPerMeter: Double) {
        let metersPerMile = 1609.34
        let secondsPerMile = secondsPerMeter * metersPerMile
        self.init(totalSeconds: Int(secondsPerMile))
    }
    
    // Convert to total seconds
    var totalSeconds: Int {
        minutes * 60 + seconds
    }
    
    // Convert to seconds per meter for CoreLocation
    var secondsPerMeter: Double {
        let metersPerMile = 1609.34
        return Double(totalSeconds) / metersPerMile
    }
    
    // Convert to speed in mph
    var milesPerHour: Double {
        3600.0 / Double(totalSeconds)
    }
    
    // Formatted string: "7:30"
    var formatted: String {
        String(format: "%d:%02d", minutes, seconds)
    }
    
    // Comparable conformance
    static func < (lhs: Pace, rhs: Pace) -> Bool {
        lhs.totalSeconds < rhs.totalSeconds
    }
    
    // Check if pace is within tolerance of target
    func isWithinTolerance(of target: Pace, toleranceSeconds: Int) -> Bool {
        abs(self.totalSeconds - target.totalSeconds) <= toleranceSeconds
    }
}
```

### Distance

Represents distance in miles with fractional support.

```swift
struct Distance: Codable, Equatable, Comparable {
    let miles: Double
    
    init(miles: Double) {
        self.miles = max(0, miles)
    }
    
    init(meters: Double) {
        self.miles = meters / 1609.34
    }
    
    var meters: Double {
        miles * 1609.34
    }
    
    var kilometers: Double {
        miles * 1.60934
    }
    
    var formatted: String {
        String(format: "%.2f mi", miles)
    }
    
    // Comparable conformance
    static func < (lhs: Distance, rhs: Distance) -> Bool {
        lhs.miles < rhs.miles
    }
}
```

### WorkoutSession

Represents an active workout session (watch only).

```swift
struct WorkoutSession: Codable, Identifiable {
    let id: UUID
    let configurationId: UUID
    let configurationName: String
    var startTime: Date
    var endTime: Date?
    var state: SessionState
    var currentMile: Int  // 1-indexed
    var mileSplits: [MileSplit]
    var totalDistance: Distance
    var averagePace: Pace?
    
    init(configuration: RunConfiguration) {
        self.id = UUID()
        self.configurationId = configuration.id
        self.configurationName = configuration.name
        self.startTime = Date()
        self.endTime = nil
        self.state = .active
        self.currentMile = 1
        self.mileSplits = []
        self.totalDistance = Distance(miles: 0)
        self.averagePace = nil
    }
    
    enum SessionState: String, Codable {
        case active
        case paused
        case ended
    }
    
    // Helper: Get current target pace
    func currentTargetPace(from config: RunConfiguration) -> Pace? {
        config.pace(forMile: currentMile)
    }
    
    // Helper: Calculate elapsed time
    var elapsedTime: TimeInterval {
        if let end = endTime {
            return end.timeIntervalSince(startTime)
        }
        return Date().timeIntervalSince(startTime)
    }
}
```

### MileSplit

Represents completed mile statistics.

```swift
struct MileSplit: Codable, Identifiable {
    let id: UUID
    let mileNumber: Int  // 1-indexed
    let startTime: Date
    let endTime: Date
    let distance: Distance  // Actual distance (may be slightly over 1.0)
    let averagePace: Pace
    let targetPace: Pace
    
    init(
        id: UUID = UUID(),
        mileNumber: Int,
        startTime: Date,
        endTime: Date,
        distance: Distance,
        averagePace: Pace,
        targetPace: Pace
    ) {
        self.id = id
        self.mileNumber = mileNumber
        self.startTime = startTime
        self.endTime = endTime
        self.distance = distance
        self.averagePace = averagePace
        self.targetPace = targetPace
    }
    
    // Helper: Duration of this mile
    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
    
    // Helper: Difference from target
    var paceDeviation: Int {
        averagePace.totalSeconds - targetPace.totalSeconds
    }
    
    // Helper: Formatted deviation string
    var deviationFormatted: String {
        let deviation = paceDeviation
        if deviation > 0 {
            return "+\(deviation)s"
        } else if deviation < 0 {
            return "\(deviation)s"
        } else {
            return "On pace"
        }
    }
}
```

### GPSSample

Represents a single GPS location sample (watch runtime only, not persisted).

```swift
struct GPSSample {
    let timestamp: Date
    let coordinate: CLLocationCoordinate2D
    let altitude: Double
    let speed: Double  // meters per second
    let horizontalAccuracy: Double  // meters
    let course: Double  // degrees
    
    init(from location: CLLocation) {
        self.timestamp = location.timestamp
        self.coordinate = location.coordinate
        self.altitude = location.altitude
        self.speed = location.speed
        self.horizontalAccuracy = location.horizontalAccuracy
        self.course = location.course
    }
    
    // Convert speed to pace
    var pace: Pace {
        guard speed > 0 else { return Pace(minutes: 99, seconds: 59) }
        let secondsPerMeter = 1.0 / speed
        return Pace(secondsPerMeter: secondsPerMeter)
    }
    
    // Check if GPS sample is valid for pace calculation
    var isValid: Bool {
        horizontalAccuracy > 0 &&
        horizontalAccuracy < 50 &&  // Within 50 meters
        speed >= 0
    }
}
```

### WorkoutSummary

Summary data transferred back to phone after workout.

```swift
struct WorkoutSummary: Codable, Identifiable {
    let id: UUID
    let configurationId: UUID
    let configurationName: String
    let startTime: Date
    let endTime: Date
    let totalDistance: Distance
    let averagePace: Pace
    let mileSplits: [MileSplit]
    
    init(from session: WorkoutSession) {
        self.id = session.id
        self.configurationId = session.configurationId
        self.configurationName = session.configurationName
        self.startTime = session.startTime
        self.endTime = session.endTime ?? Date()
        self.totalDistance = session.totalDistance
        self.averagePace = session.averagePace ?? Pace(minutes: 0, seconds: 0)
        self.mileSplits = session.mileSplits
    }
    
    // Helper: Total duration
    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
    
    // Helper: Formatted duration "1:23:45"
    var durationFormatted: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}
```

## Persistence Layer

### UserDefaultsKeys

Centralized keys for UserDefaults storage.

```swift
enum UserDefaultsKeys {
    // Phone keys
    static let runConfigurations = "runConfigurations"
    static let workoutHistory = "workoutHistory"
    static let lastSyncDate = "lastSyncDate"
    
    // Watch keys
    static let activeRunConfigurations = "activeRunConfigurations"
    static let currentWorkoutSession = "currentWorkoutSession"
    static let selectedConfigurationId = "selectedConfigurationId"
    
    // Shared settings
    static let preferredUnits = "preferredUnits"  // miles or kilometers
    static let audioEnabled = "audioEnabled"
    static let tempoBeatsEnabled = "tempoBeatsEnabled"
}
```

### DataStore Protocol

Protocol for data persistence operations.

```swift
protocol DataStore {
    func save<T: Codable>(_ value: T, forKey key: String) throws
    func load<T: Codable>(_ type: T.Type, forKey key: String) throws -> T?
    func delete(forKey key: String)
}

// Default implementation using UserDefaults
class UserDefaultsStore: DataStore {
    private let defaults: UserDefaults
    
    init(suiteName: String? = nil) {
        if let suiteName = suiteName {
            self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        } else {
            self.defaults = .standard
        }
    }
    
    func save<T: Codable>(_ value: T, forKey key: String) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        defaults.set(data, forKey: key)
    }
    
    func load<T: Codable>(_ type: T.Type, forKey key: String) throws -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: data)
    }
    
    func delete(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}
```

## Data Validation Rules

### RunConfiguration Validation
- Name: 1-50 characters
- Distance: 0.1-50.0 miles
- Mile paces: Must have pace for each mile
- Base cadence: 160-200 SPM
- Pace tolerance: 1-30 seconds

### Pace Validation
- Minimum: 4:00/mile (elite)
- Maximum: 20:00/mile (walking)
- Seconds: 0-59

### Distance Validation
- Minimum: 0.1 miles (161 meters)
- Maximum: 50 miles (marathon+)

## Data Migration

Currently no migration needed (v1.0). Future versions should implement:

```swift
protocol DataMigration {
    var version: Int { get }
    func migrate() throws
}

// Example for future use
class MigrationV1toV2: DataMigration {
    let version = 2
    
    func migrate() throws {
        // Migrate data from v1 to v2 format
    }
}
```

## Sample Data

### Example RunConfiguration for Marathon

```swift
let marathonConfig = RunConfiguration(
    name: "Marathon - Even Pace",
    distance: Distance(miles: 26.2),
    milePaces: (1...27).map { mile in
        MilePace(
            mileNumber: mile,
            pace: Pace(minutes: 8, seconds: 0)
        )
    },
    baseCadence: 180,
    paceToleranceSeconds: 5
)
```

### Example RunConfiguration for Progressive Run

```swift
let progressiveConfig = RunConfiguration(
    name: "10 Mile Progressive",
    distance: Distance(miles: 10),
    milePaces: [
        MilePace(mileNumber: 1, pace: Pace(minutes: 8, seconds: 30)),
        MilePace(mileNumber: 2, pace: Pace(minutes: 8, seconds: 30)),
        MilePace(mileNumber: 3, pace: Pace(minutes: 8, seconds: 15)),
        MilePace(mileNumber: 4, pace: Pace(minutes: 8, seconds: 15)),
        MilePace(mileNumber: 5, pace: Pace(minutes: 8, seconds: 0)),
        MilePace(mileNumber: 6, pace: Pace(minutes: 8, seconds: 0)),
        MilePace(mileNumber: 7, pace: Pace(minutes: 7, seconds: 45)),
        MilePace(mileNumber: 8, pace: Pace(minutes: 7, seconds: 45)),
        MilePace(mileNumber: 9, pace: Pace(minutes: 7, seconds: 30)),
        MilePace(mileNumber: 10, pace: Pace(minutes: 7, seconds: 15)),
    ],
    baseCadence: 180,
    paceToleranceSeconds: 5
)
```
