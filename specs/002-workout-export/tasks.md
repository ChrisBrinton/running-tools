# Tasks: Post-Workout Auto-Export

**Input**: Design documents from `/specs/002-workout-export/`
**Prerequisites**: plan.md, spec.md, contracts/healthkit-export.md

**Tests**: TDD is NON-NEGOTIABLE per constitution. All test tasks included and MUST be completed before implementation.

**Organization**: Tasks grouped by functional area to enable incremental implementation and testing.

## Format: `[ID] [P?] Description`

- **[P]**: Can run in parallel (different files, no dependencies)

## Path Conventions

- **Shared**: `pace-runner/PaceRunnerShared/Sources/PaceRunnerShared/`
- **iOS App**: `pace-runner/PaceRunner/PaceRunner/`
- **Tests**: `pace-runner/PaceRunnerShared/Tests/PaceRunnerSharedTests/`

---

## Phase 1: Foundation (Models & Contracts)

**Purpose**: Define export data structures and HealthKit integration contracts

### Export Models

- [ ] T001 [P] Create `ExportModels.swift` in Shared/Models/ defining `WorkoutExport`, `HeartRateData`, `HeartRateZone`, `SplitData`, `RouteData`, `RoutePoint`, `ExtraMetrics` structs — all Codable
- [ ] T002 [P] Create `HeartRateZoneCalculator` in Shared/Services/ — 5-zone model with configurable max HR, time-in-zone calculation from HR samples
- [ ] T003 [P] Create `ExportDeduplicationStore` in Shared/Services/ — UUID tracking via UserDefaults, check/mark exported, clear old entries

### Contract Tests

> **TDD: Write these tests FIRST, ensure they FAIL before implementation**

- [ ] T004 [P] Contract test for HKObserverQuery in Tests/ — verify observer fires on new workout, background delivery registration
- [ ] T005 [P] Contract test for HKWorkoutRouteQuery in Tests/ — verify route data extraction, CLLocation batch processing, completion handling
- [ ] T006 [P] Contract test for HealthKit sample queries in Tests/ — verify heart rate, cadence, VO2 Max queries between workout start/end dates

### Unit Tests for Models

- [ ] T007 [P] Unit test for `HeartRateZoneCalculator` — zone boundaries, time-in-zone calculation, edge cases (no HR data, single sample)
- [ ] T008 [P] Unit test for `ExportDeduplicationStore` — mark/check exported, persistence across reinit, clear old entries
- [ ] T009 [P] Unit test for `ExportModels` — Codable round-trip for all export structs, JSON output matches spec format

**Checkpoint**: Models defined, contracts specified, TDD tests written and failing

---

## Phase 2: Data Extraction

**Purpose**: Extract workout data from HealthKit into export models

- [ ] T010 Create `WorkoutDataExtractor` service in Shared/Services/ — main extraction orchestrator
- [ ] T011 [P] Implement workout summary extraction — UUID, dates, duration, distance, calories, pace, source, indoor/outdoor
- [ ] T012 [P] Implement heart rate extraction — query HR samples, compute avg/max/min, calculate zones
- [ ] T013 Implement per-mile split extraction — query workout route, compute mile boundaries, calculate split pace and HR per mile
- [ ] T014 Implement route data extraction — `HKWorkoutRouteQuery` → CLLocation array → RoutePoint array with elevation gain/loss
- [ ] T015 [P] Implement extra metrics extraction — cadence, VO2 Max, stride length queries
- [ ] T016 Implement treadmill fallback — handle missing route data, use distance events for splits if available

### Unit Tests for Extraction

- [ ] T017 [P] Unit test for split calculation logic — mile boundary detection from CLLocation array, pace computation per segment
- [ ] T018 [P] Unit test for elevation calculation — gain/loss from altitude array, handling of GPS altitude noise
- [ ] T019 [P] Unit test for route point sampling — downsample large route to reasonable interval (every 5-10 seconds)

**Checkpoint**: HealthKit data extraction complete and tested with mocks

---

## Phase 3: Formatting & Output

**Purpose**: Format extracted data as JSON and plain text, write to iCloud Drive

### Formatters

- [ ] T020 [P] Create `WorkoutExportFormatter` in Shared/Services/ — JSON encoding with spec-compliant schema (version, exportedAt, nested objects)
- [ ] T021 [P] Implement plain text summary formatter — human-readable .txt output matching spec format (emoji, splits table, zones)
- [ ] T022 [P] Create `ExportFileWriter` in Shared/Services/ — iCloud Drive output, local fallback, directory creation, filename generation

### Unit Tests for Formatters

- [ ] T023 [P] Unit test for JSON formatter — verify output matches spec JSON schema, version field, ISO 8601 dates, proper nesting
- [ ] T024 [P] Unit test for plain text formatter — verify output format, emoji, alignment, missing data handling
- [ ] T025 [P] Unit test for file writer — path generation, directory creation, fallback behavior, filename format (run-YYYY-MM-DD-HHMMSS)

**Checkpoint**: Formatters produce correct output, file writer handles iCloud/local paths

---

## Phase 4: Orchestration & Integration

**Purpose**: Wire everything together with HKObserverQuery and integrate into the app

### Export Service

- [ ] T026 Create `WorkoutExportService` in Shared/Services/ — orchestrates observer registration, extraction, formatting, writing, deduplication
- [ ] T027 Implement HKObserverQuery registration with background delivery — filter for running workouts, process new + any previously missed workouts
- [ ] T028 Implement export pipeline — query workout → check dedup → extract data → format → write files → mark exported
- [ ] T029 Add error handling and logging — surface HealthKit permission errors, log export success/failure, handle partial data gracefully

### App Integration

- [ ] T030 Update `PaceRunnerApp.swift` (iOS) — register export observer on app launch, request additional HealthKit read permissions
- [ ] T031 [P] Update `SettingsView.swift` — add export settings section: auto-export toggle, max HR override, export format preference
- [ ] T032 [P] Add export-related properties to `AppSettings` — maxHROverride, autoExportEnabled, exportFormat (json/both)

### Integration Tests

- [ ] T033 Integration test for full export pipeline — mock HealthKit → extract → format → verify file output matches spec
- [ ] T034 Integration test for deduplication — export same workout twice → verify only one file created
- [ ] T035 Integration test for missing data — workout with no route (treadmill) → verify export succeeds without route section

**Checkpoint**: Full export pipeline working end-to-end

---

## Phase 5: Polish & Edge Cases

**Purpose**: Handle edge cases and ensure robustness

- [ ] T036 [P] Handle workouts with no heart rate data — omit HR section gracefully, don't fail export
- [ ] T037 [P] Handle very large route data — downsample GPS points to keep file size reasonable (<500KB)
- [ ] T038 [P] Handle concurrent exports — prevent duplicate processing if observer fires multiple times
- [ ] T039 [P] Add HealthKit permission check on first export — surface clear error if permissions not granted
- [ ] T040 [P] Add export status notification — post notification when export completes for potential UI indicator
- [ ] T041 Verify background delivery works on real device — test with real workout completion, verify export fires

**Checkpoint**: Feature complete, edge cases handled, ready for integration

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Foundation)**: No dependencies — start immediately
- **Phase 2 (Extraction)**: Depends on Phase 1 models
- **Phase 3 (Formatting)**: Depends on Phase 1 models (can parallel with Phase 2)
- **Phase 4 (Orchestration)**: Depends on Phases 2 and 3
- **Phase 5 (Polish)**: Depends on Phase 4

### Critical Path

```
Phase 1: Models + Contracts
    ↓
Phase 2: Data Extraction ──┐
Phase 3: Formatting ────────┤  (parallel)
    ↓                       ↓
Phase 4: Orchestration + Integration
    ↓
Phase 5: Polish + Edge Cases
```

### Parallel Opportunities

**Within Phase 1**:
- T001-T003: All models parallel
- T004-T006: All contract tests parallel
- T007-T009: All unit tests parallel

**Within Phase 2**:
- T011, T012, T015: Summary, HR, extras extraction parallel
- T017-T019: All extraction unit tests parallel

**Within Phase 3**:
- T020-T022: All formatters parallel
- T023-T025: All formatter tests parallel

**Within Phase 5**:
- T036-T040: All edge cases parallel

---

## Task Summary

**Total Tasks**: 41
- **Phase 1 (Foundation)**: 9 tasks
- **Phase 2 (Extraction)**: 10 tasks
- **Phase 3 (Formatting)**: 6 tasks
- **Phase 4 (Orchestration)**: 7 tasks
- **Phase 5 (Polish)**: 6 tasks + real device test

**Test Tasks**: 14 (contract + unit + integration)
**Parallel Tasks**: 27 marked [P] (66% parallelizable)

**Estimated LOC**: ~2,000 lines Swift (services + models + tests)
