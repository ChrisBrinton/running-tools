# Tasks: PaceRunner Marathon Training App

**Input**: Design documents from `/specs/001-pace-runner-mvp/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: TDD is NON-NEGOTIABLE per constitution. All test tasks included and MUST be completed before implementation.

**Organization**: Tasks grouped by user story to enable independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3, US4)
- Include exact file paths in descriptions

## Path Conventions

Mobile dual-platform structure (per plan.md):
- **Shared**: `pace-runner/PaceRunner-Shared/`
- **iOS**: `pace-runner/PaceRunner-iOS/`
- **Watch**: `pace-runner/PaceRunner-Watch/`
- **Tests**: `pace-runner/PaceRunner-Tests/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Xcode project initialization and basic structure

- [ ] T001 Create Xcode project with watchOS App template named "PaceRunner" in pace-runner/
- [ ] T002 Add iOS app target "PaceRunner-iOS" to Xcode project
- [ ] T003 [P] Add shared framework target "PaceRunner-Shared" for iOS and watchOS
- [ ] T004 [P] Configure HealthKit capability for Watch App target
- [ ] T005 [P] Configure Location capability for Watch App target
- [ ] T006 [P] Configure Background Modes (Audio) capability for Watch App target
- [ ] T007 [P] Add Info.plist usage descriptions for Location and HealthKit
- [ ] T008 [P] Create directory structure for Shared (Models, Extensions, Protocols)
- [ ] T009 [P] Create directory structure for iOS (Views, ViewModels, Services)
- [ ] T010 [P] Create directory structure for Watch (Views, ViewModels, Services)
- [ ] T011 [P] Create directory structure for Tests (Unit, Contract, Integration)
- [ ] T012 [P] Configure SwiftLint with .swiftlint.yml (constitution: no warnings allowed)
- [ ] T013 [P] Add Run Script build phase for SwiftLint to all targets

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core models and protocols that ALL user stories depend on

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

### Shared Models (Foundation)

- [ ] T014 [P] Create Pace model in pace-runner/PaceRunner-Shared/Models/Pace.swift (minutes, seconds, totalSeconds, validation 4:00-20:00)
- [ ] T015 [P] Create Distance model in pace-runner/PaceRunner-Shared/Models/Distance.swift (miles, meters, kilometers, validation 0.1-50.0)
- [ ] T016 [P] Create RunConfiguration model in pace-runner/PaceRunner-Shared/Models/RunConfiguration.swift (id, name, distance, milePaces, baseCadence, paceTolerance, timestamps)
- [ ] T017 [P] Create MileSplit model in pace-runner/PaceRunner-Shared/Models/MileSplit.swift (mileNumber, startTime, endTime, actualDistance, averagePace, targetPace, deviation)
- [ ] T018 [P] Create WorkoutSummary model in pace-runner/PaceRunner-Shared/Models/WorkoutSummary.swift (id, configurationID, configurationName, start/end times, totalDistance, averagePace, mileSplits)

### Unit Tests for Foundation Models

- [ ] T019 [P] Unit test for Pace model in pace-runner/PaceRunner-Tests/Unit/Models/PaceTests.swift (initialization, validation, conversions, Comparable)
- [ ] T020 [P] Unit test for Distance model in pace-runner/PaceRunner-Tests/Unit/Models/DistanceTests.swift (conversions, validation, formatting)
- [ ] T021 [P] Unit test for RunConfiguration model in pace-runner/PaceRunner-Tests/Unit/Models/RunConfigurationTests.swift (validation, computed properties, Codable round-trip)

**Checkpoint**: Foundation models complete and tested - user story implementation can now begin

---

## Phase 3: User Story 2 - Create Run Configuration (Priority: P1)

**Goal**: Runner can create, edit, and sync workout configurations from iPhone to Watch

**Independent Test**: Create config on iPhone → Sync to Watch (appears <2s) → Select on Watch → Delete on iPhone → Disappears from Watch

**Why First**: US1 (workouts) requires configurations to exist. US2 provides the configurations needed by US1.

### Contract Tests for US2

> **TDD: Write these tests FIRST, ensure they FAIL before implementation**

- [ ] T022 [P] [US2] Contract test for WatchConnectivity send/receive in pace-runner/PaceRunner-Tests/Contract/WatchConnectivityContractTests.swift (test session activation, message send, userInfo transfer, file transfer)

### Implementation for US2 - iPhone App (Configuration Management)

- [ ] T023 [P] [US2] Create DataManager service in pace-runner/PaceRunner-iOS/Services/DataManager.swift (save/load/delete configurations using UserDefaults with Codable)
- [ ] T024 [P] [US2] Create SyncManager service in pace-runner/PaceRunner-iOS/Services/SyncManager.swift (WatchConnectivity session, sendMessage for immediate sync, transferUserInfo for queued sync)
- [ ] T025 [US2] Create ConfigurationListViewModel in pace-runner/PaceRunner-iOS/ViewModels/ConfigurationListViewModel.swift (@Published configurations, loadConfigurations, createConfiguration, deleteConfiguration, syncToWatch methods)
- [ ] T026 [US2] Create ConfigurationEditorViewModel in pace-runner/PaceRunner-iOS/ViewModels/ConfigurationEditorViewModel.swift (@Published configuration state, applyPaceStrategy methods for even/progressive/custom, validation logic)
- [ ] T027 [US2] Create ConfigurationListView in pace-runner/PaceRunner-iOS/Views/Configuration/ConfigurationListView.swift (List of configs, navigation to detail, swipe-to-delete, sync status indicators)
- [ ] T028 [US2] Create ConfigurationEditorView in pace-runner/PaceRunner-iOS/Views/Configuration/ConfigurationEditorView.swift (name field, distance picker, pace strategy selector, base pace input, save/cancel buttons)
- [ ] T029 [US2] Create MilePaceEditorView in pace-runner/PaceRunner-iOS/Views/Configuration/MilePaceEditorView.swift (list/chart toggle, individual mile pace editing, quick apply buttons for even/progressive)

### Implementation for US2 - Watch App (Configuration Selection)

- [ ] T030 [P] [US2] Create DataManager service in pace-runner/PaceRunner-Watch/Services/DataManager.swift (load synced configurations from UserDefaults, read-only on watch)
- [ ] T031 [US2] Create ConfigurationSelectionView in pace-runner/PaceRunner-Watch/Views/ConfigurationSelectionView.swift (scrollable list, shows name/distance/pace, tap to select, sync indicator)

### Integration Test for US2

- [ ] T032 [US2] Integration test for configuration sync flow in pace-runner/PaceRunner-Tests/Integration/ConfigurationSyncIntegrationTests.swift (create on iPhone → verify on Watch, delete on iPhone → verify removed from Watch, measure <2s latency)

**Checkpoint**: User Story 2 complete - configurations can be created on iPhone and synced to Watch

---

## Phase 4: User Story 1 - Complete Training Run with Pace Guidance (Priority: P1) 🎯 MVP

**Goal**: Runner completes outdoor workout with real-time GPS pace tracking, audio tempo beats, and voice alerts

**Independent Test**: Start workout on Watch (no iPhone needed) → Run 1 mile outdoors → Receive tempo beats + voice alerts → End workout → See summary with split

**Why After US2**: Requires configurations from US2 to be available for selection

### Contract Tests for US1

> **TDD: Write these tests FIRST, ensure they FAIL before implementation**

- [ ] T033 [P] [US1] Contract test for HealthKit in pace-runner/PaceRunner-Tests/Contract/HealthKitContractTests.swift (start session, pause, resume, end, save workout, permissions)
- [ ] T034 [P] [US1] Contract test for CoreLocation in pace-runner/PaceRunner-Tests/Contract/CoreLocationContractTests.swift (start updates, quality filtering, distance calculation, error handling)
- [ ] T035 [P] [US1] Contract test for AVFoundation in pace-runner/PaceRunner-Tests/Contract/AVFoundationContractTests.swift (audio session config, beat scheduling, voice synthesis, background playback)

### Implementation for US1 - GPS & Pace Calculation

- [ ] T036 [P] [US1] Create GPSSample struct in pace-runner/PaceRunner-Watch/Services/PaceCalculator.swift (timestamp, location, speed - internal type)
- [ ] T037 [P] [US1] Create PaceCalculator service in pace-runner/PaceRunner-Watch/Services/PaceCalculator.swift (EWMA smoothing, outlier rejection, 10s window, getCurrentPace, addSample, reset methods)
- [ ] T038 [P] [US1] Create GPSManager service in pace-runner/PaceRunner-Watch/Services/GPSManager.swift (CLLocationManager wrapper, configure for fitness, validate samples, process locations, accumulate distance)
- [ ] T039 [P] [US1] Create MileTracker service in pace-runner/PaceRunner-Watch/Services/MileTracker.swift (detect mile boundaries, track current mile, calculate progress in mile)

### Implementation for US1 - Audio Engine

- [ ] T040 [P] [US1] Create AudioEngine service in pace-runner/PaceRunner-Watch/Services/AudioEngine.swift (AVAudioEngine setup, generate beat buffer, sample-accurate scheduling, startTempo, stopTempo, playAlert methods)
- [ ] T041 [P] [US1] Implement tempo beat generation in AudioEngine (pre-compute 10ms 800Hz sine wave buffer, configure audio session for .playback + .mixWithOthers + .duckOthers)
- [ ] T042 [P] [US1] Implement voice alerts in AudioEngine (AVSpeechSynthesizer, throttling to max 1 per 30s, mile completion announcements, pace deviation alerts)

### Implementation for US1 - Workout Session Management

- [ ] T043 [US1] Create WorkoutSession class in pace-runner/PaceRunner-Shared/Models/WorkoutSession.swift (@Published properties for state/currentMile/mileSplits/totalDistance/currentPace, ObservableObject for SwiftUI binding)
- [ ] T044 [US1] Create WorkoutManager service in pace-runner/PaceRunner-Watch/Services/WorkoutManager.swift (HealthKit session, coordinate GPS/Audio/Pace services, selectConfiguration, startWorkout, pauseWorkout, resumeWorkout, endWorkout, handle state transitions)
- [ ] T045 [US1] Implement didReceiveLocation callback in WorkoutManager (update distance, pass to PaceCalculator, detect mile boundaries, check pace status, trigger voice alerts)
- [ ] T046 [US1] Implement handleMileTransition in WorkoutManager (save split, update current mile, announce completion, adjust tempo for new target pace if progressive)

### Implementation for US1 - Watch UI

- [ ] T047 [P] [US1] Create WorkoutViewModel in pace-runner/PaceRunner-Watch/ViewModels/WorkoutViewModel.swift (@Published state from WorkoutManager, expose start/pause/resume/end actions, format pace/distance/time for display)
- [ ] T048 [P] [US1] Create PreWorkoutView in pace-runner/PaceRunner-Watch/Views/PreWorkoutView.swift (config summary, GPS status indicator, Start button disabled until GPS ready)
- [ ] T049 [P] [US1] Create ActiveWorkoutView in pace-runner/PaceRunner-Watch/Views/ActiveWorkoutView.swift (large current pace display, target pace, distance, time, mile progress, color-coded pace status green/yellow/red, swipeable layouts)
- [ ] T050 [P] [US1] Create PauseOverlayView in pace-runner/PaceRunner-Watch/Views/PauseOverlayView.swift (Resume button, End Workout button with confirmation)
- [ ] T051 [P] [US1] Create WorkoutSummaryView in pace-runner/PaceRunner-Watch/Views/WorkoutSummaryView.swift (total distance/time/avg pace, scrollable mile splits with deviations, Done button, save to HealthKit on appear)

### Unit Tests for US1 Services

- [ ] T052 [P] [US1] Unit test for PaceCalculator in pace-runner/PaceRunner-Tests/Unit/Services/PaceCalculatorTests.swift (EWMA calculation, outlier rejection, window behavior, performance <50ms)
- [ ] T053 [P] [US1] Unit test for MileTracker in pace-runner/PaceRunner-Tests/Unit/Services/MileTrackerTests.swift (boundary detection, progress calculation, reset)
- [ ] T054 [P] [US1] Unit test for AudioEngine in pace-runner/PaceRunner-Tests/Unit/Services/AudioEngineTests.swift (beat generation, BPM changes, alert throttling)

### Integration Test for US1

- [ ] T055 [US1] Integration test for complete workout flow in pace-runner/PaceRunner-Tests/Integration/WorkoutFlowIntegrationTests.swift (select config → start → GPS updates → pace calc → mile transition → end → summary, verify HealthKit save)
- [ ] T056 [US1] Integration test for GPS-to-pace pipeline in pace-runner/PaceRunner-Tests/Integration/GPSToPaceIntegrationTests.swift (mock GPS stream → verify smoothed pace output, latency <200ms, distance accuracy ±2%)

**Checkpoint**: User Story 1 complete - full workout execution with audio guidance works on Watch

---

## Phase 5: User Story 3 - View Workout History and Performance (Priority: P2)

**Goal**: Runner reviews completed workouts on iPhone, analyzes mile splits, identifies pace trends

**Independent Test**: Complete 3 workouts on Watch → View history on iPhone → Tap workout → See splits → Export summary

**Why After US1**: Requires completed workouts from US1 to display

### Implementation for US3 - Watch to iPhone Sync

- [ ] T057 [US3] Extend SyncManager in pace-runner/PaceRunner-iOS/Services/SyncManager.swift (add didReceiveFile handler to receive WorkoutSummary JSON from Watch, save to UserDefaults)
- [ ] T058 [US3] Add transferWorkoutSummary method to Watch DataManager in pace-runner/PaceRunner-Watch/Services/DataManager.swift (encode WorkoutSummary to JSON file, use WCSession.transferFile after workout ends)

### Implementation for US3 - iPhone History UI

- [ ] T059 [P] [US3] Create WorkoutHistoryViewModel in pace-runner/PaceRunner-iOS/ViewModels/WorkoutHistoryViewModel.swift (@Published workouts array, loadWorkouts, deleteWorkout, groupedWorkouts by month)
- [ ] T060 [P] [US3] Create WorkoutHistoryView in pace-runner/PaceRunner-iOS/Views/History/WorkoutHistoryView.swift (grouped list by month, workout cards show date/distance/pace/performance, pull-to-refresh for sync, swipe-to-delete)
- [ ] T061 [P] [US3] Create WorkoutDetailView in pace-runner/PaceRunner-iOS/Views/History/WorkoutDetailView.swift (summary stats, performance breakdown, scrollable mile splits with bar chart indicators, Share button)

### Integration Test for US3

- [ ] T062 [US3] Integration test for workout history sync in pace-runner/PaceRunner-Tests/Integration/WorkoutHistorySyncIntegrationTests.swift (complete workout on Watch → verify summary arrives on iPhone within 1 minute → verify displays correctly in history list → verify deletion)

**Checkpoint**: User Story 3 complete - workout history viewable and analyzable on iPhone

---

## Phase 6: User Story 4 - Adjust Tempo Cadence and Audio Preferences (Priority: P3)

**Goal**: Runner customizes cadence (170-200 SPM), audio volume, and toggles voice alerts

**Independent Test**: Change cadence to 170 SPM on iPhone → Start workout on Watch → Verify tempo at 170 BPM → Toggle voice alerts off → Verify only tempo plays

**Why Last**: Personalization feature, not required for core functionality

### Implementation for US4 - Settings Management

- [ ] T063 [P] [US4] Extend RunConfiguration model to persist audio settings (already has baseCadence and paceTolerance, verify these sync properly)
- [ ] T064 [P] [US4] Create SettingsView in pace-runner/PaceRunner-iOS/Views/Settings/SettingsView.swift (cadence slider 160-200 SPM, tolerance slider 1-30 sec, audio alerts toggle, tempo beats toggle, volume slider)
- [ ] T065 [US4] Extend WorkoutManager to apply audio settings from configuration (pass baseCadence to AudioEngine.startTempo, respect voice alert toggle when checking pace status)
- [ ] T066 [US4] Add volume control to ActiveWorkoutView using Digital Crown (detect crown rotation, call AudioEngine.setVolume, show volume indicator overlay)

### Integration Test for US4

- [ ] T067 [US4] Integration test for settings application in pace-runner/PaceRunner-Tests/Integration/SettingsIntegrationTests.swift (change settings on iPhone → sync to Watch → start workout → verify tempo matches cadence, verify alerts respect toggle)

**Checkpoint**: User Story 4 complete - full personalization of audio experience

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories and final validation

- [ ] T068 [P] Add error handling for GPS permission denied across all workout screens
- [ ] T069 [P] Add error handling for HealthKit permission denied
- [ ] T070 [P] Add error handling for Watch not reachable during sync (queue for later)
- [ ] T071 [P] Implement GPS signal loss warning in ActiveWorkoutView (display "GPS Lost" when accuracy >50m, resume when restored)
- [ ] T072 [P] Implement battery critical warning in WorkoutManager (monitor battery level, prompt early end if <10%)
- [ ] T073 [P] Add VoiceOver accessibility labels to all interactive elements (constitution requirement)
- [ ] T074 [P] Test dark mode support across all screens (constitution requirement)
- [ ] T075 [P] Add haptic feedback for mile completions and alerts using WKInterfaceDevice.play()
- [ ] T076 [P] Performance profiling with Instruments: validate GPS latency <200ms, pace calc <50ms, audio ±5ms, memory <50MB
- [ ] T077 [P] Battery life validation: 2-hour real-world test, verify <30% drain (6+ hour target)
- [ ] T078 [P] Real device GPS accuracy test: 400m track lap, verify distance within ±2%
- [ ] T079 [P] Real device audio timing test: external metronome comparison, verify ±5ms accuracy
- [ ] T080 Run full SwiftLint pass, fix all warnings (constitution: zero warnings)
- [ ] T081 Update quickstart.md with final setup instructions and troubleshooting

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - start immediately
- **Foundational (Phase 2)**: Depends on Setup - BLOCKS all user stories
- **User Story 2 (Phase 3)**: Depends on Foundational - provides configurations for US1
- **User Story 1 (Phase 4)**: Depends on Foundational + US2 - requires configurations to exist
- **User Story 3 (Phase 5)**: Depends on Foundational + US1 - requires workout data from US1
- **User Story 4 (Phase 6)**: Depends on Foundational + US1 - extends existing workout features
- **Polish (Phase 7)**: Depends on all desired user stories

### Critical Path for MVP (US1 + US2 Only)

```
Setup (Phase 1)
    ↓
Foundational (Phase 2) ← BLOCKING
    ↓
US2: Create Config (Phase 3)
    ↓
US1: Complete Workout (Phase 4) ← MVP COMPLETE
```

### User Story Dependencies

- **US2 (Create Config) - P1**: Independent - can start after Foundational
- **US1 (Complete Workout) - P1**: Depends on US2 (needs configs)
- **US3 (View History) - P2**: Depends on US1 (needs workout data)
- **US4 (Adjust Settings) - P3**: Depends on US1 (extends workout features)

### Within Each User Story

1. Contract tests FIRST (TDD: verify FAIL before implementation)
2. Models/Services (parallel where marked [P])
3. ViewModels (depend on services)
4. Views (depend on ViewModels)
5. Integration tests (verify story complete)

### Parallel Opportunities

**Within Setup (Phase 1)**:
- T003-T013: All parallel (different files)

**Within Foundational (Phase 2)**:
- T014-T018: All models parallel
- T019-T021: All model tests parallel

**Within US2 (Phase 3)**:
- T023-T024: DataManager + SyncManager parallel
- T027-T029: All iPhone views parallel
- T030-T031: Watch views parallel (different target)

**Within US1 (Phase 4)**:
- T033-T035: All contract tests parallel
- T036-T039: GPS services parallel
- T040-T042: Audio services parallel
- T047-T051: All Watch views parallel
- T052-T054: All unit tests parallel

**Within US3 (Phase 5)**:
- T059-T061: All views/ViewModels parallel

**Within US4 (Phase 6)**:
- T063-T064: Settings model + view parallel

**Within Polish (Phase 7)**:
- T068-T079: Most tasks parallel (different concerns)

---

## Parallel Example: User Story 1 (Workout Execution)

```bash
# Contract tests together (TDD: write first, verify FAIL):
T033: HealthKit contract test
T034: CoreLocation contract test
T035: AVFoundation contract test

# GPS services together:
T036: GPSSample struct
T037: PaceCalculator service
T038: GPSManager service
T039: MileTracker service

# Audio services together:
T040: AudioEngine service
T041: Tempo beat generation
T042: Voice alerts

# Watch views together:
T048: PreWorkoutView
T049: ActiveWorkoutView
T050: PauseOverlayView
T051: WorkoutSummaryView

# Unit tests together:
T052: PaceCalculator tests
T053: MileTracker tests
T054: AudioEngine tests
```

---

## Implementation Strategy

### MVP First (US1 + US2 Only - Minimum Viable Product)

1. **Phase 1**: Setup (T001-T013) - Xcode project ready
2. **Phase 2**: Foundational (T014-T021) - Core models tested
3. **Phase 3**: US2 (T022-T032) - Configurations work
4. **Phase 4**: US1 (T033-T056) - Workouts work
5. **STOP and VALIDATE**: Real device test - complete outdoor 1-mile run
6. Deploy to TestFlight if validation passes

**MVP Delivers**:
- Create pace targets on iPhone
- Execute guided workouts on Watch
- Audio tempo + voice alerts
- GPS pace tracking
- Mile splits
- HealthKit integration

### Incremental Delivery

1. **Foundation** (Setup + Foundational) → Project structure ready
2. **+US2** (Config Management) → Test config creation/sync → Deploy
3. **+US1** (Workout Execution) → Test complete workout → Deploy (MVP!)
4. **+US3** (History) → Test historical analysis → Deploy
5. **+US4** (Settings) → Test personalization → Deploy
6. **+Polish** → Final hardening → Production release

### Parallel Team Strategy (if multiple developers)

After Foundational phase completes:

- **Developer A**: US2 (Config Management) - Phase 3
- **Developer B**: US1 (Workout Execution) - Phase 4 (blocked on US2 completion)
- **Developer C**: US3 (History) - Phase 5 (blocked on US1 completion)

Or work sequentially in priority order for single developer.

---

## Real Device Testing Requirements

Per constitution and contracts, these features MUST be tested on physical devices:

### Required Hardware
- iPhone running iOS 17.0+ (any model with Bluetooth)
- Apple Watch Series 6+ running watchOS 10.0+ (GPS required)

### Critical Real Device Tests
1. **GPS Accuracy** (T078): 400m track lap, verify distance within ±2% (constitution requirement)
2. **Audio Timing** (T079): Compare to external metronome, verify ±5ms (constitution requirement)
3. **Battery Life** (T077): 2-hour outdoor run, verify <30% drain (6+ hour target)
4. **Performance** (T076): Instruments profiling for latency/memory targets
5. **Complete Workflow** (T055, T056, T062): End-to-end user journeys

### Simulator Limitations
- GPS not available (returns mock Cupertino location)
- HealthKit limited functionality
- Audio timing unreliable
- WatchConnectivity limited

**WARNING**: Do NOT rely on Simulator for GPS, audio, or HealthKit validation. Real device testing is MANDATORY per constitution.

---

## Notes

- **[P] tasks**: Different files/targets, no dependencies - can run in parallel
- **[Story] label**: Maps task to user story (US1, US2, US3, US4) for traceability
- **TDD**: Constitution requires tests BEFORE implementation - verify tests FAIL first
- **Constitution compliance**: All performance targets validated in Phase 7
- **Independent stories**: Each US can be tested independently after implementation
- **Commit strategy**: Commit after each task or logical group
- **Checkpoints**: Stop and validate story independently before moving to next

---

## Task Summary

**Total Tasks**: 81
- **Setup**: 13 tasks
- **Foundational**: 8 tasks
- **US2 (Create Config)**: 11 tasks
- **US1 (Complete Workout)**: 24 tasks (largest - core value)
- **US3 (View History)**: 6 tasks
- **US4 (Adjust Settings)**: 5 tasks
- **Polish**: 14 tasks

**Test Tasks**: 15 (contract + unit + integration)
**Parallel Tasks**: 54 marked [P] (67% parallelizable)

**MVP Scope**: US1 + US2 = 35 tasks (43% of total)
**Full Feature**: All 81 tasks
