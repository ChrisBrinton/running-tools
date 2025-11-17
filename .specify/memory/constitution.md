# PaceRunner Constitution

<!--
Sync Impact Report:
Version: 1.0.0 → 1.1.0 (Added cloud analytics principle)
Modified Principles:
  - Battery Life rationale updated (line 79-84)
  - UI Responsiveness clarified local vs cloud operations (line 109-112)
  - Testing Requirements expanded for cloud API contracts (line 128)
Added Sections:
  - Principle V: Workout Independence, Cloud-Enabled Analytics
Removed Sections: N/A
Templates Requiring Updates:
  ✅ spec-template.md - No changes needed (supports both local and cloud features)
  ✅ plan-template.md - No changes needed (constitution check remains generic)
  ✅ tasks-template.md - No changes needed (supports both architectures)
Follow-up TODOs: None
-->

## Core Principles

### I. Native Performance First

All runtime-critical code MUST be implemented in Swift with native iOS/WatchOS frameworks. PaceRunner operates in demanding real-time conditions (GPS tracking, audio generation, pace calculation) where performance is non-negotiable.

**Requirements**:
- GPS location processing MUST complete within 200ms of update
- Pace calculations MUST complete within 50ms
- Audio tempo beat timing MUST maintain ±5ms accuracy
- Watch app MUST remain under 50MB resident memory during workouts
- No third-party dependencies that introduce performance overhead without clear justification

**Rationale**: Runners depend on real-time feedback. Laggy pace readings or inconsistent tempo beats destroy the user experience and training effectiveness. Native frameworks are optimized for the platform and provide predictable performance.

### II. Test-Driven Development (NON-NEGOTIABLE)

Every feature MUST follow the Red-Green-Refactor cycle. Tests are written first, reviewed by user (if applicable), verified to fail, then implementation proceeds.

**Requirements**:
- Write tests BEFORE implementation
- Verify tests fail with expected failure message
- Implement minimal code to make tests pass
- Refactor only after tests are green
- All tests MUST pass before code review
- Contract tests MUST be included for all HealthKit, CoreLocation, and WatchConnectivity integrations
- Integration tests MUST cover complete user journeys (start workout → GPS tracking → audio feedback → end workout)

**Rationale**: Real-world testing on Apple Watch during actual runs is expensive and time-consuming. Unit and integration tests catch regressions early. GPS, audio, and HealthKit bugs discovered mid-run are catastrophic to user experience.

### III. User Experience Consistency

Watch interface MUST be operable during vigorous exercise with gloves, rain, and visual impairment from movement. Audio feedback MUST work without requiring visual confirmation.

**Requirements**:
- All interactive elements MUST support 44x44pt minimum touch targets
- Critical actions (start/pause/stop) MUST be accessible within 2 taps
- Audio alerts MUST provide complete status without looking at screen
- Text MUST use San Francisco system font with minimum 17pt for body text
- Visual feedback MUST accompany all state changes (haptics + audio + visual)
- No animations exceeding 300ms that block user interaction
- Dark mode MUST be fully supported (workout happens at dawn/dusk)
- VoiceOver accessibility MUST be tested for all workout screens

**Rationale**: Runners cannot focus on small UI elements while maintaining target pace. The watch is a glance-and-go device. Poor UX during workouts leads to abandoned training runs.

### IV. Battery Life as a Feature

Watch app MUST sustain 6+ hours of continuous GPS + audio operation. Battery life is a functional requirement, not an optimization.

**Requirements**:
- GPS accuracy MUST be tuned for battery efficiency (kCLLocationAccuracyBest only when necessary)
- Display MUST auto-dim after 10 seconds of no interaction
- Audio processing MUST use minimal CPU (no unnecessary DSP)
- Background tasks MUST be profiled with Instruments to verify efficient execution
- Workout sessions MUST release resources promptly on pause/end
- Location updates MUST throttle to 1 Hz when pace is stable
- Memory leaks are BLOCKING bugs

**Rationale**: Marathon training runs last 2-6 hours. Battery anxiety destroys workout focus. If the watch dies mid-run, the workout cannot be completed and real-time pace guidance is lost.

### V. Workout Independence, Cloud-Enabled Analytics

Workout execution MUST operate 100% locally with no cloud dependencies. Historical workout data MAY be synced to cloud services for analytics, training insights, and AI-assisted coaching via tools like Claude Desktop with MCP servers.

**Requirements**:
- **Workout Boundary**: All real-time workout features (GPS tracking, pace calculation, audio feedback, HealthKit recording) MUST function without network connectivity
- **No Blocking**: Cloud sync operations MUST be asynchronous and MUST NOT block workout start, execution, or completion
- **Post-Workout Sync**: Data export to cloud services MUST happen after workout ends, never during active tracking
- **HealthKit as Source of Truth**: Workout data persists to HealthKit first (local), cloud sync is secondary enhancement
- **Graceful Degradation**: If cloud service unavailable, app MUST continue functioning normally with local data
- **Analytics Separation**: Cloud-based analytics, MCP servers, and AI integrations are encouraged but MUST be architecturally separate from workout execution
- **Future-Proof**: Constitution allows for additional cloud-based tools (data aggregation, training plan generation, performance analysis) that consume HealthKit data independently

**Rationale**: Runners cannot depend on network connectivity during training runs (remote trails, tunnels, airplane mode for battery). Workout reliability is paramount. However, post-workout analytics via cloud services (especially AI-powered insights through Claude Desktop MCP servers) provide significant value for training optimization without compromising workout reliability.

## Performance Standards

### GPS & Location Processing

- **Update Rate**: 1 Hz (one location per second)
- **Processing Latency**: <200ms from CLLocation update to UI display
- **Distance Accuracy**: ±2% over full marathon distance (26.2 miles)
- **Smoothing Window**: 10-second rolling average with outlier rejection (>20% deviation)
- **Fallback**: Use watch's built-in pace when GPS accuracy drops below kCLLocationAccuracyNearestTenMeters

### Audio Performance

- **Tempo Beat Jitter**: ±5ms maximum deviation from target BPM
- **Voice Alert Latency**: <500ms from trigger event to audio playback
- **Audio Session**: MUST continue during screen sleep and wrist-down
- **Mixing**: Tempo beats and voice alerts MUST not clip or interrupt each other
- **Volume**: Follow system volume with audio ducking for alerts

### Memory & Battery Benchmarks

- **Resident Memory**: <50MB during active workout
- **Battery Life**: 6+ hours GPS + audio at 180 BPM tempo
- **Startup Time**: <2 seconds from app launch to workout ready
- **Sync Time**: <2 seconds to transfer run configuration from phone to watch

### UI Responsiveness

- **Touch Response**: <100ms from tap to visual feedback
- **State Transitions**: Instant (no loading spinners for local operations); cloud operations MUST show progress indicators with timeout fallbacks
- **Scroll Performance**: 60 fps on list views with 50+ run configurations
- **Animation Budget**: Max 300ms for non-critical animations
- **Network Operations**: Cloud sync status visible but non-intrusive; workout features never wait for network

## Development Workflow

### Code Quality Gates

All code MUST pass these checks before commit:

1. **Swift Linting**: SwiftLint with project configuration (no warnings allowed)
2. **Type Safety**: No force-unwraps (`!`) or force-casts (`as!`) without documented justification
3. **Access Control**: Explicit access modifiers (`private`, `fileprivate`, `internal`, `public`)
4. **Error Handling**: No empty `catch` blocks; all errors logged or surfaced to user
5. **Deprecation**: No use of deprecated APIs without migration plan documented

### Testing Requirements

- **Unit Test Coverage**: All models, services, and business logic MUST have unit tests
- **Contract Tests**: All framework boundaries (HealthKit, CoreLocation, WatchConnectivity, cloud APIs) MUST have contract tests
- **Integration Tests**: Complete user journeys MUST have integration tests
- **Offline Testing**: Workout features MUST be tested with network disabled to verify local operation
- **Real Device Testing**: GPS and audio features MUST be tested on physical Apple Watch before PR approval
- **Performance Testing**: Battery life and memory usage MUST be profiled with Instruments for new features

### Code Review Standards

- All PRs MUST include test verification evidence (screenshots of passing tests)
- GPS/audio changes MUST include real-world testing notes (e.g., "tested on 5K run, pace accuracy within 2%")
- Breaking changes to shared data models MUST include migration strategy
- Performance-sensitive code MUST include Instruments profile showing no regressions
- Accessibility changes MUST include VoiceOver testing notes

### Commit & Branch Hygiene

- Commits MUST be atomic (single logical change)
- Commit messages MUST follow Conventional Commits format (feat:, fix:, refactor:, test:, docs:)
- Feature branches MUST be prefixed with issue number (e.g., `042-gps-smoothing`)
- WIP commits MUST be squashed before merge
- Main branch MUST always build and pass all tests

## Governance

### Amendment Process

1. Propose change as PR to `.specify/memory/constitution.md`
2. Document rationale and impact on existing code/templates
3. Update all dependent templates in `.specify/templates/` to maintain consistency
4. Increment version according to semantic versioning:
   - **MAJOR**: Principle removal or redefinition that invalidates existing code
   - **MINOR**: New principle added or materially expanded guidance
   - **PATCH**: Clarifications, wording improvements, typo fixes
5. Update `LAST_AMENDED_DATE` to amendment merge date
6. Require approval from project maintainer

### Compliance Verification

- All PRs MUST pass constitution check before merge
- `.specify/templates/plan-template.md` contains constitution check gate
- Code reviews MUST explicitly verify compliance with relevant principles
- Constitution violations MUST be justified in `plan.md` Complexity Tracking table
- Annual review on project anniversary to ensure principles remain relevant

### Complexity Justification

If a design violates a principle (e.g., introducing third-party dependency, exceeding memory budget), it MUST be documented in the Implementation Plan's Complexity Tracking table with:

- **Violation**: Which principle is violated
- **Why Needed**: Specific problem that cannot be solved within constraints
- **Simpler Alternative Rejected Because**: Why conforming approach is insufficient

### Version Control

All principle changes are tracked through git history of this file. The Sync Impact Report (HTML comment at top of file) provides human-readable changelog for latest amendment.

**Version**: 1.1.0 | **Ratified**: 2025-11-17 | **Last Amended**: 2025-11-17
