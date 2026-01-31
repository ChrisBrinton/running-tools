# Implementation Plan: Post-Workout Auto-Export

**Branch**: `002-workout-export` | **Date**: 2025-01-29 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/002-workout-export/spec.md`

## Summary

Post-Workout Auto-Export automatically captures detailed workout data when a running workout completes on Apple Watch and exports it as structured JSON (and optional plain text) to iCloud Drive. The export includes workout summary, heart rate data with zone calculations, per-mile splits with HR, route data with elevation, and additional metrics (cadence, VO2 Max). An `HKObserverQuery` with background delivery triggers the export pipeline, and deduplication ensures each workout is exported exactly once.

Technical approach combines HealthKit observer queries for auto-triggering, anchored queries for efficient data extraction, `HKWorkoutRouteQuery` for GPS route data, and `FileManager` ubiquity container APIs for iCloud Drive output. All data processing happens on-device; iCloud Drive provides seamless file sync to the user's other devices for downstream AI coaching consumption.

## Technical Context

**Language/Version**: Swift 5.9+
**Primary Dependencies**:
- HealthKit (workout observation, data extraction, heart rate, route queries)
- CoreLocation (route point processing from HKWorkoutRoute)
- Foundation (JSON encoding, FileManager for iCloud Drive)

**Storage**:
- UserDefaults (exported workout UUID tracking for deduplication)
- iCloud Drive (output JSON and text files via FileManager ubiquity container)
- Local Documents directory (fallback when iCloud unavailable)

**Testing**:
- XCTest (unit tests for formatters, zone calculation, deduplication)
- Contract tests for HealthKit observer and route queries
- Integration tests for full export pipeline

**Target Platform**:
- iOS 17.0+ (iPhone app — export runs on iPhone where HealthKit data syncs from Watch)
- Background delivery entitlement required

**Project Type**: Extension of existing PaceRunner iOS app

**Performance Goals**:
- Export processing: <10 seconds from trigger to file written
- Memory: <20MB during export (route data can be large)
- Background execution: Complete within iOS background task time limit

**Constraints**:
- Must not interfere with active workout on Watch
- iCloud Drive availability not guaranteed (graceful fallback to local)
- HealthKit permissions must be requested before first export
- Background delivery requires explicit entitlement in Xcode

**Scale/Scope**:
- Target: 1-5 exports per week per user
- Route data: Up to 50,000 GPS points per marathon (sampled to ~5,000)
- Output file size: ~100KB-500KB JSON per workout
- Code estimate: ~1,500-2,500 LOC Swift

## Constitution Check

*GATE: Must pass before implementation. Re-check after design.*

### Principle I: Native Performance First
✅ **PASS** - All code in Swift using native HealthKit and Foundation frameworks. No third-party dependencies. JSON encoding via Foundation's JSONEncoder.

### Principle II: Test-Driven Development (NON-NEGOTIABLE)
✅ **PASS** - Plan includes unit tests for formatters, zone calculations, deduplication logic, and contract tests for HealthKit observer/route queries.

### Principle III: User Experience Consistency
✅ **PASS** - Export is automatic and invisible. User doesn't need to interact. Output files appear in iCloud Drive without user action.

### Principle IV: Battery Life as a Feature
✅ **PASS** - Export triggers only on workout completion (not polling). Background delivery is event-driven. Processing is one-time per workout.

### Principle V: Workout Independence, Cloud-Enabled Analytics
✅ **PASS** - Export runs independently after workout completion. iCloud Drive output enables downstream analytics without requiring a custom cloud service. Local fallback ensures data is never lost.

**GATE RESULT: ✅ ALL CHECKS PASS** - Proceed to implementation.

## Project Structure

### Documentation (this feature)

```text
specs/002-workout-export/
├── spec.md                          # Feature specification (completed)
├── plan.md                          # This file (implementation plan)
├── tasks.md                         # Task breakdown with priorities
├── contracts/
│   └── healthkit-export.md          # HealthKit export integration contract
└── draft-implementation/            # Draft Swift code for review
    ├── WorkoutExportService.swift   # Main export orchestrator
    ├── WorkoutDataExtractor.swift   # HealthKit data extraction
    ├── WorkoutExportFormatter.swift # JSON + plain text formatting
    ├── ExportFileWriter.swift       # iCloud Drive file output
    └── ExportModels.swift           # Export-specific data models
```

### Source Code (integration points)

```text
pace-runner/
├── PaceRunnerShared/
│   └── Sources/PaceRunnerShared/
│       └── Services/
│           ├── WorkoutExportService.swift     # Main export orchestrator
│           ├── WorkoutDataExtractor.swift     # HealthKit data extraction
│           ├── WorkoutExportFormatter.swift   # JSON + text formatters
│           └── ExportFileWriter.swift         # iCloud Drive writer
│       └── Models/
│           └── ExportModels.swift             # Export data structures
│
├── PaceRunner/
│   └── PaceRunner/
│       ├── PaceRunnerApp.swift                # ADD: register observer on launch
│       └── SettingsView.swift                 # ADD: export settings section
│
└── Tests/
    └── PaceRunnerSharedTests/
        ├── WorkoutExportFormatterTests.swift  # Format validation
        ├── HeartRateZoneTests.swift           # Zone calculation
        ├── ExportDeduplicationTests.swift     # UUID tracking
        └── ExportFileWriterTests.swift        # File path/naming
```

**Structure Decision**: Export service lives in `PaceRunnerShared` so it can be shared between iOS and watchOS targets if needed. The observer query registration happens in the iPhone app since HealthKit background delivery is iOS-only. Export models are separate from workout models to avoid coupling the export schema to the runtime data model.

## Complexity Tracking

### C1: HKWorkoutRouteQuery async iteration
**Complexity**: Route data extraction requires `HKWorkoutRouteQuery` which delivers CLLocation batches asynchronously via a handler that's called multiple times until `done` is true. This requires careful state management.
**Justification**: Required by HealthKit API — no simpler alternative exists for accessing route GPS data.
**Mitigation**: Wrap in async/await continuation for cleaner control flow.

### C2: Background delivery timing
**Complexity**: `HKObserverQuery` background delivery may fire with a delay (minutes to hours on iOS). The export must handle stale workout data gracefully.
**Justification**: iOS background execution model doesn't guarantee immediate delivery. This is a platform constraint.
**Mitigation**: Store exported UUIDs persistently. On each trigger, process ALL unexported running workouts, not just the latest one.

### C3: iCloud Drive availability
**Complexity**: iCloud container may not be available (user not signed in, iCloud disabled, no network). Must handle gracefully with local fallback.
**Justification**: User may not have iCloud enabled. Export should still work.
**Mitigation**: Check `FileManager.default.url(forUbiquityContainerIdentifier:)` — if nil, fall back to local Documents directory. Log which path was used.
