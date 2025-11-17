# Feature Specification: PaceRunner Marathon Training App

**Feature Branch**: `001-pace-runner-mvp`
**Created**: 2025-11-17
**Status**: Draft
**Input**: User description: "Marathon training app with per-mile pace targets, real-time GPS tracking, audio tempo beats, and voice alerts for Apple Watch and iPhone"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Complete Training Run with Pace Guidance (Priority: P1)

A marathon runner wants to complete a training run at their target pace without constantly checking their watch. They configure a run on their iPhone (e.g., "20 miles at 8:00/mile pace"), start the workout on their Apple Watch, and receive audio tempo beats matching their target cadence plus voice alerts when they drift off pace.

**Why this priority**: This is the core value proposition - enabling pace-controlled training without visual distractions. Delivers immediate value for a single workout.

**Independent Test**: Runner can complete one full training run from start to finish with audio guidance keeping them on pace, testable in a single outdoor workout session.

**Acceptance Scenarios**:

1. **Given** a runner has configured a 10-mile run at 8:00/mile pace on iPhone, **When** they start the workout on Apple Watch with GPS lock, **Then** tempo beats play at 180 SPM and current pace displays on watch face
2. **Given** an active workout, **When** runner's pace drifts to 8:15/mile (15s slower than target), **Then** voice alert says "Speed up. Current pace 8:15" within 30 seconds
3. **Given** runner completes mile 1 in 7:55, **When** they cross the mile boundary, **Then** voice alert says "Mile 1 complete" and display shows mile 2 progress
4. **Given** runner completes 10-mile workout, **When** they stop the workout, **Then** summary shows all 10 mile splits with actual vs target paces and workout saves to HealthKit

---

### User Story 2 - Create Run Configuration (Priority: P1)

A runner preparing for marathon training wants to create a workout plan specifying different pace targets for each mile (e.g., progressive run starting at 9:00/mile and ending at 7:30/mile). They use the iPhone app to create, name, and configure the run with per-mile pace targets, then sync it to their Apple Watch.

**Why this priority**: Configuration capability is a prerequisite for story 1 - runners need to set up paces before they can execute workouts. Also independently valuable for planning.

**Independent Test**: Runner can create, edit, and save a run configuration with custom pace targets, verify it syncs to watch, and see it available for selection during workout start.

**Acceptance Scenarios**:

1. **Given** runner opens iPhone app, **When** they tap "New Workout" and enter "Marathon Pace Test, 13 miles, 8:00/mile even pace", **Then** configuration saves with 13 identical mile paces of 8:00
2. **Given** existing configuration, **When** runner edits to progressive pace (mile 1 at 9:00, mile 10 at 7:30 with linear progression), **Then** each mile shows calculated progressive pace and chart visualizes progression
3. **Given** saved configuration on iPhone, **When** Apple Watch is connected and runner taps "Sync to Watch", **Then** configuration appears on watch within 2 seconds
4. **Given** multiple configurations, **When** runner deletes one on iPhone, **Then** it disappears from both iPhone and synced watch within 2 seconds

---

### User Story 3 - View Workout History and Performance (Priority: P2)

After completing several training runs, a runner wants to review their workout history to see how well they maintained target paces, identify trends, and track improvement. They open the iPhone app to see all completed workouts with summaries, drill into individual workouts to see mile-by-mile splits, and identify patterns (e.g., "I consistently slow down in miles 8-10").

**Why this priority**: Historical analysis helps runners adjust future training. Valuable after multiple workouts accumulate, not critical for first workout.

**Independent Test**: Runner with 3+ completed workouts can view workout list, select a workout, see all mile splits with deviations from target, and export workout summary.

**Acceptance Scenarios**:

1. **Given** runner has completed 5 workouts, **When** they open History tab on iPhone, **Then** all 5 workouts display with date, distance, average pace, and on/off pace summary
2. **Given** workout list, **When** runner taps workout from Nov 15, **Then** detail view shows complete summary: total time, distance, average pace, and scrollable list of all mile splits with +/- deviations
3. **Given** workout detail view, **When** runner taps "Share", **Then** workout summary exports as text or image to share via Messages/social media

---

### User Story 4 - Adjust Tempo Cadence and Audio Preferences (Priority: P3)

A runner with shorter or longer stride wants to customize the tempo beat cadence from the default 180 SPM to match their natural cadence (e.g., 170 or 190 SPM). They also want control over audio volume and the ability to disable voice alerts while keeping tempo beats.

**Why this priority**: Personalization improves experience but not required for core functionality. Most runners can use 180 SPM default initially.

**Independent Test**: Runner can adjust cadence setting, verify tempo beat frequency changes during workout, and toggle voice alerts on/off without affecting tempo beats.

**Acceptance Scenarios**:

1. **Given** runner in workout settings on iPhone, **When** they change base cadence from 180 to 170 SPM, **Then** setting syncs to watch and next workout plays tempo at 170 SPM
2. **Given** active workout, **When** runner uses digital crown to adjust volume, **Then** tempo beat and voice alert volume change in real-time
3. **Given** workout settings, **When** runner disables voice alerts but keeps tempo beats enabled, **Then** next workout plays only tempo beats with no voice announcements

---

### Edge Cases

- **GPS Signal Loss**: What happens when runner enters tunnel or urban canyon and loses GPS signal mid-workout? System should continue workout using last known pace, display warning on watch face, and resume GPS tracking when signal returns.

- **Battery Critical During Workout**: If Apple Watch battery drops to critical level during workout, system should prompt runner to end workout early and save progress to avoid data loss.

- **Extremely Fast/Slow Paces**: How does system handle outlier paces? Runner sprinting at 4:30/mile or walking at 18:00/mile should see appropriate alerts without audio spam.

- **Mid-Workout App Crash**: If watch app crashes during workout, HealthKit workout session should preserve data and allow resume when app restarts.

- **Phone Not Available**: Runner starts workout on watch when iPhone is not connected or nearby. All workout execution must succeed without phone dependency.

- **Conflicting Audio**: Runner listens to music or podcast during workout. Tempo beats and voice alerts should mix with media without stopping playback (audio ducking).

## Requirements *(mandatory)*

### Functional Requirements

#### Configuration Management
- **FR-001**: Users MUST be able to create run configurations specifying total distance (0.1 to 50 miles) and per-mile pace targets (4:00 to 20:00 per mile)
- **FR-002**: Users MUST be able to name run configurations (1-50 characters)
- **FR-003**: Users MUST be able to apply pace strategies: even pace (all miles same), progressive (gradual speed increase), or custom (manually set each mile)
- **FR-004**: System MUST persist run configurations locally on iPhone
- **FR-005**: Users MUST be able to edit existing run configurations
- **FR-006**: Users MUST be able to delete run configurations with confirmation
- **FR-007**: System MUST sync run configurations from iPhone to Apple Watch within 2 seconds when devices connected

#### Workout Execution (Watch)
- **FR-008**: Users MUST be able to select a run configuration on Apple Watch to start workout
- **FR-009**: System MUST acquire GPS lock before allowing workout start, displaying GPS status (Acquiring/Ready/Poor Signal)
- **FR-010**: System MUST track workout using Apple Watch GPS with location updates every 1 second
- **FR-011**: System MUST calculate current pace from GPS data with smoothing to handle noise
- **FR-012**: System MUST display current pace, target pace, distance, elapsed time, and current mile number on watch face during workout
- **FR-013**: System MUST detect mile boundary crossings and announce mile completion via voice alert
- **FR-014**: Users MUST be able to pause, resume, and end workout via watch controls
- **FR-015**: System MUST save completed workouts to Apple Watch HealthKit with full distance, duration, and splits data
- **FR-016**: System MUST operate entirely on Apple Watch without requiring iPhone during workout

#### Audio Feedback
- **FR-017**: System MUST generate audio tempo beats at configured BPM (default 180 SPM, adjustable 160-200 SPM)
- **FR-018**: System MUST play tempo beats continuously during active workout
- **FR-019**: System MUST provide voice alerts when runner's pace deviates from target by more than 5 seconds (configurable tolerance)
- **FR-020**: System MUST throttle voice alerts to maximum once per 30 seconds to prevent spam
- **FR-021**: System MUST announce mile completion with mile number
- **FR-022**: System MUST mix tempo beats and voice alerts with other audio (music/podcasts) without stopping playback
- **FR-023**: Users MUST be able to adjust audio volume via digital crown during workout
- **FR-024**: System MUST continue audio playback when watch screen turns off

#### Workout History (Phone)
- **FR-025**: System MUST transfer completed workout summaries from watch to iPhone
- **FR-026**: Users MUST be able to view list of completed workouts showing date, distance, duration, and average pace
- **FR-027**: Users MUST be able to view detailed workout summary with mile-by-mile splits and deviations from target
- **FR-028**: System MUST calculate and display pace deviation for each mile (+/- seconds from target)
- **FR-029**: Users MUST be able to delete workouts from history with confirmation

#### Data Sync
- **FR-030**: System MUST detect when iPhone and Apple Watch are connected
- **FR-031**: System MUST support manual "Sync Now" trigger on iPhone
- **FR-032**: System MUST queue sync operations when watch not reachable and retry when connection restored
- **FR-033**: System MUST show sync status indicators (Synced/Pending/Failed) on iPhone for each configuration

### Key Entities

- **Run Configuration**: A workout plan specifying total distance, per-mile pace targets, base cadence (SPM), pace tolerance (seconds), name, and timestamps. Each configuration has unique ID and contains ordered list of mile paces.

- **Workout Session**: An active workout with configuration ID, start time, end time, state (active/paused/ended), current mile number, recorded mile splits, total distance, and average pace. Represents real-time workout execution state.

- **Mile Split**: Completed mile statistics including mile number, start time, end time, actual distance covered, average pace, target pace, and deviation from target. Captures performance for one mile segment.

- **GPS Sample**: Individual location reading with timestamp, coordinates, speed, horizontal accuracy, and altitude. Used for pace calculation and distance tracking during active workouts.

- **Workout Summary**: Post-workout data transferred to iPhone containing workout ID, configuration name, start/end times, total distance, average pace, and all mile splits. Represents historical workout record.

- **Pace**: Running pace expressed as minutes and seconds per mile (e.g., 8:00/mile). Can be compared, validated (4:00-20:00 range), and converted between formats (total seconds, seconds per meter).

- **Distance**: Distance measurement in miles with support for fractional values. Can be converted to/from meters and kilometers.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Runner can configure a new workout on iPhone and see it available on Apple Watch within 2 seconds of sync completion
- **SC-002**: Runner can complete a 10-mile training run using Apple Watch without carrying iPhone, maintaining target pace within ±5 seconds for 80% of miles
- **SC-003**: Apple Watch battery sustains 6+ hours of continuous GPS tracking and audio playback during workout
- **SC-004**: GPS pace calculations refresh at least once per second with <200ms latency from GPS update to display
- **SC-005**: Audio tempo beats maintain ±5ms timing accuracy throughout workout
- **SC-006**: Voice alerts trigger within 30 seconds when runner drifts >5 seconds off target pace
- **SC-007**: Runner can review workout history showing last 50 workouts with complete mile-by-mile split data
- **SC-008**: System operates through complete marathon distance (26.2 miles) without crashes, freezes, or data loss
- **SC-009**: 95% of workouts successfully sync from watch to phone within 1 minute of workout completion
- **SC-010**: Watch interface remains usable during vigorous exercise with 44pt minimum touch targets and audio-only operation capability

## Assumptions

- Users own both iPhone (iOS 17.0+) and Apple Watch (watchOS 10.0+)
- Users grant necessary permissions (Location, HealthKit, Motion & Fitness)
- Users train in areas with GPS coverage (outdoor running, not indoor treadmill)
- Users have basic familiarity with Apple Watch workout apps
- Configuration is done on iPhone with larger screen; watch is workout-only interface
- Data remains local on device per constitution (no cloud sync in MVP)
- Watch can be worn throughout workout (not overheating, comfortable fit)
- Audio output via watch speaker or connected Bluetooth headphones

## Out of Scope

- Indoor treadmill workouts (requires different distance tracking approach)
- Cycling, swimming, or other non-running activities
- Social features (sharing workouts, challenges, leaderboards)
- Training plan generation or AI coaching
- Integration with third-party platforms (Strava, Garmin, etc.)
- Heart rate zone training (focus is pace-based only)
- Interval training with alternating paces within single mile
- GPS track recording for route mapping
- Elevation/terrain analysis
- Weather integration
- Cloud backup or multi-device sync beyond iPhone-Watch pair
