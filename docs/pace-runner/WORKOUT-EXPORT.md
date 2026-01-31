# Workout Export — Architecture & Implementation Guide

**Feature**: Post-Workout Auto-Export
**Spec**: `specs/002-workout-export/spec.md`
**Branch**: `002-workout-export`
**Status**: Design complete, implementation pending

---

## Overview

The Workout Export feature automatically captures detailed workout data when a running workout completes and exports it as structured JSON (+ optional plain text) to iCloud Drive. The primary consumer is a downstream AI coaching assistant that analyzes run performance. The system is event-driven, battery-efficient, and resilient to missing data.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    iPhone App (iOS 17+)                       │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  PaceRunnerApp.swift                                     │ │
│  │  └── WorkoutExportService.registerObserver() on launch   │ │
│  └─────────────────────┬───────────────────────────────────┘ │
│                        │                                      │
│  ┌─────────────────────▼───────────────────────────────────┐ │
│  │  WorkoutExportService (orchestrator)                     │ │
│  │  ├── HKObserverQuery (background delivery)               │ │
│  │  ├── ExportDeduplicationStore (UUID tracking)            │ │
│  │  ├── WorkoutDataExtractor (HealthKit queries)            │ │
│  │  ├── WorkoutExportFormatter (JSON + text)                │ │
│  │  └── ExportFileWriter (iCloud Drive / local fallback)    │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  Output Files                                            │ │
│  │  ├── iCloud Drive/Workouts/run-2026-01-28-160000.json   │ │
│  │  └── iCloud Drive/Workouts/run-2026-01-28-160000.txt    │ │
│  └─────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

## Data Flow

### Export Pipeline (Event-Driven)

```
HKObserverQuery fires (workout saved to HealthKit)
    │
    ▼
Filter: is it a running workout?
    │ yes
    ▼
Dedup check: already exported this UUID?
    │ no
    ▼
WorkoutDataExtractor
    ├── Query workout summary (UUID, dates, distance, calories)
    ├── Query heart rate samples → compute zones
    ├── Query workout route → extract CLLocations
    │   └── Compute mile splits from route
    │   └── Compute elevation gain/loss
    ├── Query cadence (step count)
    └── Query VO2 Max (most recent)
    │
    ▼
WorkoutExportFormatter
    ├── Build WorkoutExport model
    ├── Encode to JSON (spec-compliant schema)
    └── Format plain text summary
    │
    ▼
ExportFileWriter
    ├── Check iCloud Drive availability
    ├── Create Workouts/ directory if needed
    ├── Write .json file
    ├── Write .txt file (optional)
    └── Fall back to Documents/ if iCloud unavailable
    │
    ▼
ExportDeduplicationStore.markExported(uuid)
```

### Timing

- **Observer trigger**: HealthKit background delivery (may delay minutes to hours)
- **Export processing**: <10 seconds from trigger to files written
- **Background task**: Must complete within iOS background execution limit
- **Dedup scan**: On each trigger, process ALL unexported running workouts (not just latest)

## Component Design

### WorkoutExportService

The central orchestrator. Registered once on app launch. Stateless between exports.

```swift
class WorkoutExportService {
    // Dependencies
    let healthStore: HKHealthStore
    let extractor: WorkoutDataExtractor
    let formatter: WorkoutExportFormatter
    let fileWriter: ExportFileWriter
    let dedupStore: ExportDeduplicationStore
    
    // Lifecycle
    func registerObserver()           // Called once on app launch
    func processNewWorkouts()         // Called by observer or manually
    func exportWorkout(_ workout: HKWorkout) async throws  // Single workout pipeline
}
```

**Key behaviors**:
- Registers `HKObserverQuery` with background delivery for `workoutType()`
- On observer fire: queries all running workouts since last export
- Skips already-exported UUIDs (dedup)
- Exports each new workout through the full pipeline
- Logs success/failure for each export

### WorkoutDataExtractor

Handles all HealthKit queries. Uses async/await for clean composition.

```swift
class WorkoutDataExtractor {
    let healthStore: HKHealthStore
    
    func extractWorkoutSummary(_ workout: HKWorkout) -> WorkoutSummaryExport
    func extractHeartRate(start: Date, end: Date) async throws -> HeartRateData?
    func extractRoute(for workout: HKWorkout) async throws -> RouteData?
    func extractSplits(from locations: [CLLocation], hrSamples: [HKQuantitySample], start: Date) -> [SplitData]
    func extractCadence(start: Date, end: Date) async throws -> Int?
    func extractVO2Max() async throws -> Double?
}
```

**HealthKit query patterns**:
- **Heart rate**: `HKSampleQuery` with date predicate for workout period
- **Route**: `HKSampleQuery` for `workoutRoute()` → `HKWorkoutRouteQuery` for CLLocations
- **Cadence**: `HKStatisticsQuery` for step count during workout
- **VO2 Max**: `HKSampleQuery` with limit 1, sorted by date descending

### WorkoutExportFormatter

Pure functions — no HealthKit dependency, easily testable.

```swift
struct WorkoutExportFormatter {
    func formatJSON(_ export: WorkoutExport) throws -> Data
    func formatPlainText(_ export: WorkoutExport) -> String
}
```

**JSON schema**: Matches spec exactly — version "1.0", ISO 8601 dates, nested workout/heartRate/splits/route/extras objects.

**Plain text**: Human-readable summary with emoji headers, aligned splits, HR zone table.

### ExportFileWriter

Handles file system operations with iCloud Drive as primary and local Documents as fallback.

```swift
struct ExportFileWriter {
    func writeExport(json: Data, text: String?, workoutDate: Date) throws -> URL
    func outputDirectory() -> URL  // iCloud or local
    func filename(for date: Date, extension ext: String) -> String  // run-YYYY-MM-DD-HHMMSS
}
```

**iCloud Drive path**: `<ubiquity-container>/Documents/Workouts/run-YYYY-MM-DD-HHMMSS.json`
**Local fallback**: `<app-documents>/Workouts/run-YYYY-MM-DD-HHMMSS.json`

### ExportDeduplicationStore

Simple UUID tracking backed by UserDefaults.

```swift
class ExportDeduplicationStore {
    func isExported(_ uuid: UUID) -> Bool
    func markExported(_ uuid: UUID)
    func pruneOldEntries(olderThan days: Int = 90)
}
```

## Data Models

### Export Schema (v1.0)

```swift
struct WorkoutExport: Codable {
    let version: String                 // "1.0"
    let exportedAt: Date                // ISO 8601
    let workout: WorkoutSummaryExport
    let heartRate: HeartRateData?       // nil if no HR data
    let splits: [SplitData]             // empty if no route
    let route: RouteData?               // nil if indoor
    let extras: ExtraMetrics?           // nil if no additional data
}

struct WorkoutSummaryExport: Codable {
    let uuid: String
    let type: String                    // "outdoor_run" | "indoor_run"
    let startDate: Date
    let endDate: Date
    let duration: Int                   // seconds
    let distance: Double                // miles
    let distanceUnit: String            // "mi"
    let calories: Int                   // kcal
    let avgPace: String                 // "7:52"
    let avgPaceSeconds: Int             // 472
}

struct HeartRateData: Codable {
    let avg: Int
    let max: Int
    let min: Int
    let zones: [HeartRateZone]
    let samples: [HRSample]            // { t: ISO8601, bpm: Int }
}

struct HeartRateZone: Codable {
    let zone: Int                       // 1-5
    let label: String                   // "Recovery", "Easy", etc.
    let minutes: Int
}

struct SplitData: Codable {
    let mile: Int
    let pace: String                    // "7:45"
    let paceSeconds: Int                // 465
    let avgHR: Int?
    let elapsed: String                 // "7:45" (cumulative)
}

struct RouteData: Codable {
    let elevationGain: Int              // feet
    let elevationLoss: Int              // feet
    let elevationUnit: String           // "ft"
    let points: [RoutePoint]            // downsampled to every 5-10s
}

struct RoutePoint: Codable {
    let lat: Double
    let lon: Double
    let alt: Double
    let t: Date                         // ISO 8601
}

struct ExtraMetrics: Codable {
    let avgCadence: Int?
    let vo2Max: Double?
}
```

## Integration Points

### App Launch (PaceRunnerApp.swift)

```swift
// In PaceRunnerApp.init():
let exportService = WorkoutExportService()
exportService.registerObserver()
```

**Additional HealthKit permissions** needed (read-only):
- Heart rate, resting heart rate
- VO2 Max
- Step count (for cadence)
- Running stride length
- Workout route

### Settings (SettingsView.swift)

New section: "Workout Export"
- Toggle: Auto-export enabled (default: on)
- Max HR override (for accurate zone calculation)
- Export format: JSON only / JSON + Text

### AppSettings Extensions

```swift
// New properties on AppSettings:
var autoExportEnabled: Bool        // default: true
var maxHROverride: Int?            // nil = use age-based estimate
var exportFormat: ExportFormat      // .json | .both
```

## Heart Rate Zone Calculation

Standard 5-zone model based on percentage of max HR:

| Zone | Label     | % of Max HR | Purpose              |
|------|-----------|-------------|----------------------|
| 1    | Recovery  | < 60%       | Active recovery      |
| 2    | Easy      | 60-70%      | Base building        |
| 3    | Tempo     | 70-80%      | Aerobic capacity     |
| 4    | Threshold | 80-90%      | Lactate threshold    |
| 5    | Max       | > 90%       | Peak performance     |

**Max HR estimation**: `220 - age` (if age available from HealthKit), otherwise default to 190. User can override in settings.

**Time-in-zone calculation**: For each consecutive pair of HR samples, assign the inter-sample duration to the zone of the first sample's BPM.

## Route Processing

### Downsampling Strategy

Raw route data from a marathon can have 50,000+ GPS points. To keep JSON files under 500KB:

1. **Target interval**: 1 point every 5-10 seconds
2. **Algorithm**: Keep first and last points. Walk through sorted points, keep a point only if ≥5 seconds has elapsed since the last kept point.
3. **Preserve key points**: Always keep points at mile boundaries

### Elevation Calculation

GPS altitude is noisy (±5-10m accuracy). To mitigate:
1. Apply simple moving average (window = 5 points) to altitude data
2. Compute deltas between smoothed consecutive points
3. Ignore deltas < 1m (noise threshold)
4. Sum positive deltas = gain, sum absolute negative deltas = loss
5. Convert meters to feet for output

## Error Handling

| Scenario | Behavior |
|----------|----------|
| HealthKit permissions denied | Log error, surface prompt on next foreground |
| No HR data for workout | Omit `heartRate` section, export continues |
| No route data (treadmill) | Omit `route` and `splits` sections |
| iCloud Drive unavailable | Fall back to local Documents directory |
| Export fails mid-pipeline | Log error, don't mark as exported (will retry) |
| Corrupted workout data | Skip workout, log error, continue with others |
| Background task timeout | Complete as much as possible, retry next trigger |

## Testing Strategy

### Unit Tests (Pure Logic)
- Heart rate zone calculation (edge cases, empty data, single sample)
- Split calculation from location array (mile boundaries, partial miles)
- Elevation calculation (noise filtering, gain/loss)
- Route downsampling (point count, time intervals)
- JSON formatter (schema compliance, optional fields)
- Plain text formatter (format, alignment)
- Deduplication store (mark/check/prune)
- File path generation (iCloud vs local, filename format)

### Contract Tests (HealthKit API)
- Observer registration and delivery
- Workout query by date range
- Heart rate sample query
- Route query and CLLocation extraction
- Step count query
- Permission handling

### Integration Tests (End-to-End)
- Full pipeline: mock workout → extract → format → write → verify file
- Dedup: same workout twice → one file
- Missing data: treadmill workout → export without route
- Large route: 50K points → downsampled output

### Real Device Tests (Required)
- Complete real run → verify export fires
- Background delivery → verify export without opening app
- Compare exported data to Apple Fitness summary
- Verify iCloud Drive sync to other devices

## File Size Budget

| Component | Estimated Size |
|-----------|---------------|
| Workout summary | ~500 bytes |
| Heart rate (5K samples) | ~100KB |
| Splits (26 miles) | ~2KB |
| Route (5K points) | ~200KB |
| Extras | ~100 bytes |
| **Total JSON** | **~300KB** |
| **Plain text** | **~2KB** |

## Future Considerations

- **Batch export**: Export historical workouts on demand (not just new ones)
- **Custom export directory**: Let user choose output location
- **Webhook delivery**: POST JSON to a configured URL for real-time coaching
- **CSV export**: Additional format for spreadsheet analysis
- **Watch-side export**: Run export on Watch directly (no iPhone needed)
- **Encryption**: Encrypt export files for privacy
