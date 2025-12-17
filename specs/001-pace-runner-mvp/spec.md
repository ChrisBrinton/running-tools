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

## Critical Issues (Real-World Testing - 2025-11-23)

Issues discovered during first outdoor test run. **Must be fixed before next real-world test.**

### 1. Workout App Conflict (CRITICAL)

**Problem**: Starting a workout in PaceRunner ends the native Workout app's workout and vice versa. PaceRunner is intended to be a **companion/add-on** to the native Workout app, not a replacement. The native Workout app collects extensive health data that PaceRunner should not duplicate.

**Current behavior**: Both apps fight for the HealthKit workout session, causing one to terminate when the other starts.

**Required behavior - Companion Mode**:
- PaceRunner should **not** start its own HealthKit workout session by default
- Add configuration option on iPhone: "Standalone Mode" vs "Companion Mode" (default)
- **Companion Mode**: PaceRunner only provides audio feedback and pace tracking; user starts actual workout via native Workout app
- **Standalone Mode**: PaceRunner manages full workout session (current behavior, for users who want it)
- In Companion Mode, PaceRunner should detect when a workout is started in the native app and begin its session automatically (if possible via HealthKit observer)
- Alternatively: Manual "Start Pacing" button that doesn't touch HealthKit

**Technical investigation needed**: Can we observe when native Workout app starts a workout? Or does user need to manually start PaceRunner after starting native workout?

### 2. Audio Inconsistency on Workout Conflict

**Problem**: When switching to native Workout app and starting a workout there, voice prompts stopped but metronome clicks continued. Inconsistent state.

**Required behavior**: If PaceRunner session is terminated (for any reason), ALL audio must stop - both voice prompts and metronome. Audio state must be consistent with session state.

### 3. Metronome Sound Quality (CRITICAL)

**Problem**: Current metronome sounds like a "galloping horse" - irregular, unpleasant, not useful for pacing.

**Required behavior**:
- Steady, consistent beat that matches target footfall cadence
- Sound should be a **bass drum** or similar low-frequency percussion (not a click or beep)
- Beat frequency should match target cadence from configuration (e.g., 180 SPM = 180 BPM = 3 Hz)
- Tempo should be rock-solid consistent, not varying based on current pace

**Note**: The metronome tempo should NOT change based on current pace. It provides the TARGET rhythm the runner should match. Voice alerts tell them if they're off pace.

### 4. Metronome Behavior - Adaptive Volume (CRITICAL)

**Problem**: Constant metronome is extremely annoying during a run, even when on pace.

**Required behavior**:
- **In target zone**: Metronome is SILENT (or option to have very quiet background beat)
- **Leaving target zone**: Metronome fades in, starting quiet
- **Further from target**: Metronome gets progressively louder
- Volume should be proportional to pace deviation (e.g., 5 sec off = 20% volume, 15 sec off = 60% volume, 30+ sec off = 100% volume)
- Consider: different sound/tone for "too fast" vs "too slow"?

**Configuration options** (on iPhone):
- Enable/disable adaptive metronome
- Target zone tolerance (seconds) before metronome starts
- Maximum volume level

### 5. Workout Sync Not Working

**Problem**: Completed workout on watch (1.1 miles) did not transfer to iPhone when returning to phone proximity.

**Investigation needed**:
- Test in simulator: complete workout without phone app running, then start phone app
- Verify WatchConnectivity transferFile is being called on workout completion
- Verify queued transfers are delivered when connection restored
- Check for errors in transfer completion handler

### 6. What Worked Well

- GPS tracking was accurate and functional
- Voice alerts ("go faster"/"go slower") were audible and clear
- Audio was hearable during run
- No noticeable battery drain
- 1.1 mile workout completed successfully (data-wise)

## Polish (Post-MVP)

Items identified during initial testing that should be addressed before production release.

### Workout Start Grace Period

**Problem**: Audio feedback (tempo beats and voice alerts) starts immediately when workout begins, but runner needs time to actually start moving. Results in premature "speed up" alerts while still standing or walking to starting position.

**Proposed solution**:
1. After workout starts, enter "waiting for movement" state (no audio feedback)
2. Detect movement start via GPS (speed threshold ~0.5 m/s or ~3 min/mile movement)
3. Once movement detected, start grace period timer (configurable, default 10-15 seconds)
4. During grace period: tempo beats may play, but no pace deviation alerts
5. After grace period expires: full audio feedback enabled, pace calculation begins
6. Display should show "Starting..." or "Get ready..." during this phase

**Edge cases**:
- Runner starts moving before pressing Start → grace period begins immediately after Start
- Runner stops during grace period → pause grace period timer, resume when moving again
- Very slow warm-up walk → may need speed threshold tuning or manual "I'm running now" button

### Configuration Editor Improvements

#### Per-Mile Custom Pace Entry
Currently the app supports "even pace" (same for all miles) and "progressive pace" (linear interpolation between start and end pace). Need to add a third mode for fully custom per-mile pacing.

**Use case**: Runner wants a 7-mile run with warm-up, tempo, and cool-down segments:
- Miles 1-2: 10:40 (warm-up)
- Miles 3-6: 9:25 (tempo)
- Mile 7: 10:50 (cool-down)

**Requirements**:
- Add "Custom" option to pace strategy picker
- When custom is selected, show editable list of all miles with individual pace pickers
- Allow copy/paste of pace values between miles
- Consider "apply to range" feature (e.g., set miles 3-6 to same pace)

#### Distance Picker Redesign
Current slider is problematic:
- Too sensitive for precise selection
- Most of the range (marathon+) is rarely used
- Decimal precision (3.45 mi) unnecessary - 0.25 mile granularity sufficient

**Proposed solution**:
- Replace slider with stepper/spinner showing whole miles + quarter increments (0.25, 0.5, 0.75)
- Keep existing preset dropdown (5K, 10K, Half, Marathon, etc.)
- Add text field for direct entry of unusual distances
- Default interaction: tap +/- buttons or use spinner wheel
- Fallback: type exact value for edge cases

#### Compact Pace Picker
Current wheel pickers take significant vertical space even when not being edited.

**Proposed solution**:
- Display pace as tappable text (e.g., "8:30 min/mi") when not editing
- Tap to expand into full wheel picker
- Collapse back to text display after selection
- Reduces form height significantly when multiple paces visible
