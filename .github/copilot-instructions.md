# AI Agent Instructions for PaceRunner

## Project Overview

PaceRunner is an iOS/watchOS marathon training app with GPS pace tracking and audio tempo guidance. The codebase follows strict TDD, dependency injection via protocols, and a "constitution" defining performance/quality requirements.

**Key Architecture**: Unified Xcode project (`pace-runner/PaceRunner/PaceRunner.xcodeproj`) with three targets: iOS phone app (configuration), watchOS app (workout execution), and shared Swift package (`PaceRunner-Shared/`). Watch app operates 100% independently during workouts—all sync happens pre/post-run via WatchConnectivity.

## Critical Workflows

### Building & Testing
```bash
# Open project
cd pace-runner/PaceRunner && xed PaceRunner.xcodeproj

# Build iOS + Watch targets (simulator)
xcodebuild -scheme "PaceRunner" -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build

# Run shared model tests
xcodebuild test -scheme "PaceRunner-Shared" -destination 'platform=iOS Simulator,name=iPhone 15 Pro'

# Run Watch app + contract tests
xcodebuild test -scheme "PaceRunner Watch App" -destination 'platform=watchOS Simulator,name=Apple Watch Series 9 (45mm)'

# Lint (required before commits; build script enforces)
swiftlint
```

### Testing Philosophy
- **TDD Mandatory**: Write failing test first, then implementation (see `AGENTS.md`).
- **Contract Tests**: Stub HealthKit, CoreLocation, AVFoundation, WatchConnectivity framework behaviors in `PaceRunnerTests/*ContractTests.swift`. Extend when Apple APIs change.
- **Coverage**: Exhaustive for shared math/services (`PaceRunner-SharedTests/`), UI logic via ViewModel tests, E2E via `*UITests` targets.
- **Pre-PR**: Run both iOS/Watch simulator tests + on-device smoke tests (real hardware). Document results in PR description.

## Code Organization & Conventions

### Module Boundaries
- **`PaceRunner-Shared/`**: Data models (`RunConfiguration`, `WorkoutSummary`), protocols (`*Protocol.swift`), shared utilities. Used by both iOS and Watch targets.
- **`PaceRunner/`**: iPhone UI (SwiftUI), configuration CRUD, WatchConnectivity sender.
- **`PaceRunner Watch App/`**: Watch UI, workout orchestration (`WorkoutManager`), GPS/audio services, WatchConnectivity receiver.
- **`workout-sync-service/`**: Future cloud service boundary (documentation only; not yet implemented).

### Naming & Style
- **Swift 5.9+**, 4-space indentation, strict SwiftLint (no force unwraps, no unused code).
- **Protocols**: Suffix with `Protocol` (e.g., `GPSManagerProtocol`, `AudioEngineProtocol`).
- **File organization**: `Services/`, `Models/`, `Protocols/`, `Views/`, `ViewModels/`. Filename = type name.
- **Immutability**: Prefer `struct` + `enum`. Use `class` only when reference semantics required (e.g., `ObservableObject`).
- **Dependency injection**: All services injected via protocol, enabling test mocks (see `WorkoutManager` initializer).
- **Access control**: Explicit `public`/`private`. Shared package types are `public`.

### Constitution Compliance Comments
Every service includes header comments documenting:
1. Constitution requirements met (e.g., "<200ms GPS → UI latency").
2. References to specs (`specs/001-pace-runner-mvp/`) or docs (`docs/pace-runner/`).

Example from `WorkoutManager.swift`:
```swift
/// Constitution compliance:
/// - <200ms GPS → UI: Direct state updates, no async transforms
/// - Non-blocking: All operations async, doesn't block UI
/// - Battery efficient: Coordinates services to minimize overhead
///
/// Reference: specs/001-pace-runner-mvp/plan.md (WorkoutManager service)
```

## Documentation & Specifications

### Spec-Driven Development
Long-form architecture lives in `docs/pace-runner/` (ARCHITECTURE.md, DATA-MODEL.md, SYNC-PROTOCOL.md, etc.). Executable specs/plans in `specs/001-pace-runner-mvp/` (SpecKit-generated).

When implementing features:
1. Read relevant docs (`docs/pace-runner/ARCHITECTURE.md` for system design, `SYNC-PROTOCOL.md` for WatchConnectivity).
2. Reference contract tests (`specs/001-pace-runner-mvp/contracts/`) for framework usage patterns.
3. Update constitution compliance comments in code headers.

### Key Architectural Patterns

#### Watch Independence
Watch app stores run configurations locally (UserDefaults) after pre-workout sync from iPhone. All GPS tracking, pace calculation, and audio generation happen on-watch with zero phone dependency during workouts. Post-workout, summary transfers back to iPhone.

#### Service Coordination
`WorkoutManager` orchestrates four services via protocols:
- `GPSManagerProtocol`: CoreLocation wrapper, publishes location updates.
- `PaceCalculatorProtocol`: Smooths GPS noise (10s rolling window, outlier rejection).
- `AudioEngineProtocol`: Generates tempo beats (AVAudioEngine) + voice alerts (AVSpeechSynthesizer).
- HealthKit session: Records workout samples, manages background execution.

Data flows: `GPSManager` → `PaceCalculator` → `WorkoutManager` → `AudioEngine`. All via Combine publishers to meet <200ms latency constitution requirement.

#### GPS Smoothing Algorithm
Located in `PaceCalculator.swift`. Uses 10-second rolling average with >20% deviation outlier rejection. Falls back to HealthKit's derived pace if GPS unavailable (tunnels, urban canyons). See `docs/pace-runner/GPS-ALGORITHM.md` for math details.

## Commit & Pull Request Standards

- **Conventional Commits**: `feat: watch audio tempo engine`, `fix: healthkit exporter retry`.
- **Branch naming**: `[issue-number]-short-slug` (e.g., `042-gps-smoothing`).
- **PR requirements**: 
  - Summary + spec references (`docs/pace-runner/...` or `specs/...`).
  - Simulator + device test logs/screenshots.
  - `swiftlint` output (must pass).
  - Constitution compliance note (any trade-offs require explicit justification).

## Common Pitfalls

1. **Don't break watch independence**: Never add phone-dependent code in watch app workout flows. Sync happens via WatchConnectivity before/after workouts only.
2. **Respect contract test boundaries**: Framework mocks live in `*ContractTests.swift`. Don't stub HealthKit/CoreLocation in business logic tests—inject protocol mocks instead.
3. **Protocol suffix required**: All protocols must end in `Protocol` to pass linting and match team convention.
4. **Constitution violations block PRs**: Performance requirements (<200ms GPS latency, 6hr battery) are non-negotiable. Profile before submitting.
5. **Shared package scope**: `PaceRunner-Shared/` is for models/protocols only. Don't add UI or platform-specific code (SwiftUI, HealthKit) there.

## Quick Reference

- **Active targets**: `PaceRunner` (iOS), `PaceRunner Watch App`, `PaceRunner-Shared` (Swift Package).
- **Entry points**: `PaceRunnerApp.swift` (iOS), `PaceRunner Watch App/PaceRunnerApp.swift` (Watch).
- **Core services**: `WorkoutManager`, `GPSManager`, `PaceCalculator`, `AudioEngine` (all protocol-based).
- **Data models**: `RunConfiguration`, `WorkoutSummary`, `Pace`, `Distance` (in Shared package).
- **Test targets**: `PaceRunner-SharedTests`, `PaceRunnerTests` (contract tests), `PaceRunner Watch AppTests`, `*UITests`.
