# Implementation Plan: PaceRunner Marathon Training App

**Branch**: `001-pace-runner-mvp` | **Date**: 2025-11-17 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-pace-runner-mvp/spec.md`

## Summary

PaceRunner is a native iOS and watchOS marathon training app that provides real-time pace guidance through GPS tracking, audio tempo beats, and voice alerts. The MVP delivers complete workout execution on Apple Watch (100% offline), configuration management on iPhone, and post-workout analysis. Core value: runners maintain target pace without visual distractions through audio feedback synchronized to their running cadence.

Technical approach combines CoreLocation for GPS processing with custom pace smoothing algorithms, AVFoundation for precise tempo beat generation (±5ms accuracy), and WatchConnectivity for device sync. All data stored locally using UserDefaults and HealthKit per constitution's workout independence principle.

## Technical Context

**Language/Version**: Swift 5.9+
**Primary Dependencies**:
- SwiftUI (declarative UI for iOS 17.0+ and watchOS 10.0+)
- HealthKit (workout session management and data persistence)
- CoreLocation (GPS tracking and pace calculation)
- WatchConnectivity (iPhone-Watch data sync)
- AVFoundation (audio tempo beats and speech synthesis)
- Combine (reactive data flow)

**Storage**:
- UserDefaults (run configurations, app settings)
- HealthKit (workout data, mile splits)
- No database required (simple key-value storage sufficient)

**Testing**:
- XCTest (unit, integration, contract tests)
- Real device testing required (GPS and audio features)
- Instruments profiling for performance validation

**Target Platform**:
- iOS 17.0+ (iPhone for configuration)
- watchOS 10.0+ (Apple Watch for workout execution)

**Project Type**: Mobile (dual-platform iOS/watchOS app)

**Performance Goals**:
- GPS processing: <200ms latency (constitution requirement)
- Pace calculation: <50ms per update (constitution requirement)
- Audio tempo beats: ±5ms timing accuracy (constitution requirement)
- UI refresh: 60fps for smooth pace display
- Sync latency: <2 seconds configuration transfer

**Constraints**:
- Memory: <50MB resident during workout (constitution requirement)
- Battery: 6+ hours GPS + audio (constitution requirement)
- Offline-capable: 100% local workout execution (constitution requirement)
- Touch targets: 44x44pt minimum (constitution requirement)
- Display latency: <200ms GPS update to UI (constitution requirement)

**Scale/Scope**:
- Target users: Individual marathon runners
- Configurations: ~50 saved workouts per user
- Workout history: ~200 completed runs per year
- Concurrent GPS samples: 60 seconds rolling window (~60 samples)
- Code estimate: ~5,000-8,000 LOC Swift

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Principle I: Native Performance First
✅ **PASS** - All runtime code in Swift using native frameworks (SwiftUI, HealthKit, CoreLocation, AVFoundation). No third-party dependencies for core functionality. Performance targets align with constitution: GPS <200ms, pace calc <50ms, audio ±5ms.

### Principle II: Test-Driven Development (NON-NEGOTIABLE)
✅ **PASS** - Plan includes TDD workflow with unit tests for models/services, contract tests for framework boundaries (HealthKit, CoreLocation, WatchConnectivity), and integration tests for complete user journeys. XCTest selected as testing framework.

### Principle III: User Experience Consistency
✅ **PASS** - Watch UI designed for vigorous exercise operation. SwiftUI provides 44pt minimum touch targets. Audio feedback (tempo + voice) allows screen-free operation. San Francisco font, dark mode support, and VoiceOver accessibility per constitution requirements.

### Principle IV: Battery Life as a Feature
✅ **PASS** - GPS optimization strategies planned (throttle to 1Hz when stable, tune accuracy). Display auto-dim after 10 seconds. Minimal audio processing (simple sine wave generation). Target 6+ hours continuous operation aligns with constitution.

### Principle V: Workout Independence, Cloud-Enabled Analytics
✅ **PASS** - Architecture ensures 100% local workout execution. No network requests during workouts. HealthKit as source of truth. Cloud sync explicitly out of scope for MVP per spec assumptions. Future cloud analytics service will be architecturally separate per constitution.

### Performance Standards Compliance
✅ **PASS** - All constitution performance standards addressed:
- GPS: 1 Hz updates, <200ms latency, ±2% distance accuracy
- Audio: ±5ms tempo jitter, <500ms voice alert latency
- Memory: <50MB target
- Battery: 6+ hours target
- UI: <100ms touch response, 60fps scrolling

**GATE RESULT: ✅ ALL CHECKS PASS** - Proceed to Phase 0 research.

## Project Structure

### Documentation (this feature)

```text
specs/001-pace-runner-mvp/
├── spec.md              # Feature specification (completed)
├── plan.md              # This file (implementation plan)
├── research.md          # Phase 0: Research findings (to be generated)
├── data-model.md        # Phase 1: Data models and schemas (to be generated)
├── quickstart.md        # Phase 1: Developer setup guide (to be generated)
├── contracts/           # Phase 1: Framework integration contracts (to be generated)
│   ├── healthkit.md     # HealthKit integration contract
│   ├── corelocation.md  # CoreLocation GPS contract
│   ├── watchconnectivity.md  # Phone-Watch sync contract
│   └── avfoundation.md  # Audio engine contract
└── tasks.md             # Phase 2: Task breakdown (via /speckit.tasks command)
```

### Source Code (repository root)

```text
pace-runner/
├── PaceRunner-iOS/              # iPhone app (configuration)
│   ├── App/
│   │   └── PaceRunnerApp.swift  # App entry point
│   ├── Views/
│   │   ├── Configuration/       # Run configuration screens
│   │   │   ├── ConfigurationListView.swift
│   │   │   ├── ConfigurationEditorView.swift
│   │   │   └── MilePaceEditorView.swift
│   │   ├── History/             # Workout history screens
│   │   │   ├── WorkoutHistoryView.swift
│   │   │   └── WorkoutDetailView.swift
│   │   └── Settings/
│   │       └── SettingsView.swift
│   ├── ViewModels/
│   │   ├── ConfigurationListViewModel.swift
│   │   ├── ConfigurationEditorViewModel.swift
│   │   └── WorkoutHistoryViewModel.swift
│   ├── Services/
│   │   ├── DataManager.swift         # UserDefaults persistence
│   │   └── SyncManager.swift         # WatchConnectivity sync
│   └── Resources/
│       ├── Assets.xcassets
│       └── Info.plist
│
├── PaceRunner-Watch/            # Apple Watch app (workout execution)
│   ├── App/
│   │   └── PaceRunnerWatchApp.swift
│   ├── Views/
│   │   ├── ConfigurationSelectionView.swift
│   │   ├── PreWorkoutView.swift
│   │   ├── ActiveWorkoutView.swift
│   │   ├── PauseOverlayView.swift
│   │   └── WorkoutSummaryView.swift
│   ├── ViewModels/
│   │   └── WorkoutViewModel.swift
│   ├── Services/
│   │   ├── WorkoutManager.swift      # Orchestrates workout session
│   │   ├── GPSManager.swift          # CoreLocation wrapper
│   │   ├── PaceCalculator.swift      # Pace smoothing algorithm
│   │   ├── AudioEngine.swift         # Tempo beats + voice alerts
│   │   ├── MileTracker.swift         # Mile boundary detection
│   │   └── DataManager.swift         # Local persistence
│   └── Resources/
│       ├── Assets.xcassets
│       └── Info.plist
│
├── PaceRunner-Shared/           # Shared code (models, extensions)
│   ├── Models/
│   │   ├── RunConfiguration.swift
│   │   ├── WorkoutSession.swift
│   │   ├── MileSplit.swift
│   │   ├── WorkoutSummary.swift
│   │   ├── Pace.swift
│   │   └── Distance.swift
│   ├── Extensions/
│   │   ├── Date+Extensions.swift
│   │   └── String+Extensions.swift
│   └── Protocols/
│       └── DataStore.swift           # Storage abstraction
│
└── PaceRunner-Tests/            # All test targets
    ├── Unit/
    │   ├── Models/
    │   │   ├── PaceTests.swift
    │   │   ├── DistanceTests.swift
    │   │   └── RunConfigurationTests.swift
    │   ├── Services/
    │   │   ├── PaceCalculatorTests.swift
    │   │   ├── MileTrackerTests.swift
    │   │   └── AudioEngineTests.swift
    │   └── ViewModels/
    │       └── WorkoutViewModelTests.swift
    ├── Contract/
    │   ├── HealthKitContractTests.swift
    │   ├── CoreLocationContractTests.swift
    │   ├── WatchConnectivityContractTests.swift
    │   └── AVFoundationContractTests.swift
    └── Integration/
        ├── ConfigurationSyncIntegrationTests.swift
        ├── WorkoutFlowIntegrationTests.swift
        └── GPSToPaceIntegrationTests.swift
```

**Structure Decision**: Mobile dual-platform architecture selected. Three separate targets (iOS, Watch, Shared) mirror Apple's recommended structure for paired watch apps. Tests organized by type (unit, contract, integration) per TDD constitution requirement. Shared target minimizes code duplication for models and business logic.

## Complexity Tracking

No constitution violations requiring justification. All design choices comply with principles and performance standards.
