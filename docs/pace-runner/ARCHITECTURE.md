# Architecture Specification

## System Overview

PaceRunner is a dual-platform application consisting of an iPhone configuration app and an independent Apple Watch workout app. The architecture prioritizes watch independence during workouts while maintaining seamless data synchronization.

## Component Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        iPhone App                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Configuration UI (SwiftUI)               │  │
│  └────────────────────┬─────────────────────────────────┘  │
│                       │                                      │
│  ┌────────────────────▼─────────────────────────────────┐  │
│  │           Run Configuration Manager                   │  │
│  │  - Create/Edit/Delete run profiles                   │  │
│  │  - Validate pace targets                             │  │
│  │  - Persist to UserDefaults                           │  │
│  └────────────────────┬─────────────────────────────────┘  │
│                       │                                      │
│  ┌────────────────────▼─────────────────────────────────┐  │
│  │         WatchConnectivity Manager                     │  │
│  │  - Transfer run configs to watch                     │  │
│  │  - Receive completed workout data                    │  │
│  └────────────────────┬─────────────────────────────────┘  │
└───────────────────────┼──────────────────────────────────────┘
                        │
                WatchConnectivity
                  Framework
                        │
┌───────────────────────▼──────────────────────────────────────┐
│                      Apple Watch App                          │
│  ┌──────────────────────────────────────────────────────┐  │
│  │            Workout UI (SwiftUI)                       │  │
│  │  - Current pace display                              │  │
│  │  - Target pace display                               │  │
│  │  - Mile progress                                     │  │
│  │  - Start/Pause/Resume/Stop controls                  │  │
│  └────────────────────┬─────────────────────────────────┘  │
│                       │                                      │
│  ┌────────────────────▼─────────────────────────────────┐  │
│  │           Workout Session Manager                     │  │
│  │  - HealthKit workout session                         │  │
│  │  - State management (ready/active/paused/ended)      │  │
│  │  - Mile transition detection                         │  │
│  │  - Persist run config locally                        │  │
│  └──┬───────────────────────────────────┬───────────────┘  │
│     │                                   │                   │
│  ┌──▼────────────────┐         ┌───────▼───────────────┐  │
│  │  GPS Manager      │         │  Audio Engine         │  │
│  │  - CoreLocation   │         │  - Tempo beats        │  │
│  │  - Pace calc      │         │  - Voice alerts       │  │
│  │  - Smoothing      │         │  - Audio mixing       │  │
│  └───────────────────┘         └───────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

## Data Flow

### Configuration Phase (Phone)
1. User creates run profile with per-mile pace targets
2. Run profile saved to iPhone UserDefaults
3. WatchConnectivity transfers profile to watch
4. Watch stores profile in local UserDefaults

### Workout Phase (Watch)
1. User selects run profile on watch
2. Workout session starts via HealthKit
3. GPS updates feed into pace calculation
4. Audio engine generates tempo beats based on current target
5. Pace monitoring triggers audio alerts when off-target
6. Mile transitions update target pace and tempo

### Post-Workout Phase
1. Workout data saved to HealthKit
2. Summary stats transferred back to phone
3. Phone displays workout history

## Key Design Decisions

### Watch Independence
**Decision**: Watch must operate completely independently during workouts

**Rationale**: User doesn't carry phone during training runs. All workout logic, GPS tracking, and audio must function on watch alone.

**Implementation**: 
- Pre-sync all run configurations before workout
- Watch stores configs in local UserDefaults
- Watch handles all real-time processing
- Phone only needed for post-workout review

### Audio Architecture
**Decision**: Use AVAudioEngine for tempo beats, AVSpeechSynthesizer for voice alerts

**Rationale**: 
- AVAudioEngine provides precise timing for metronome
- AVSpeechSynthesizer integrates well with system audio
- Both can run in workout background mode

**Implementation**:
- Audio session configured for playback during workouts
- Tempo beat generator runs on timer
- Voice alerts queue without interrupting beats

### GPS Smoothing
**Decision**: Use rolling average with outlier rejection

**Rationale**: Raw GPS data is noisy, especially in urban areas or under tree cover. Need smooth pace readings to avoid alert fatigue.

**Implementation**:
- 10-second rolling window
- Reject samples >20% deviation from window average
- Fall back to watch's built-in pace if GPS unavailable

### Pace-to-Cadence Conversion
**Decision**: Use standard cadence range of 170-180 SPM with user adjustment

**Rationale**: Most efficient running cadence is 170-180 steps per minute. Tempo beat helps maintain this cadence at target pace.

**Implementation**:
- Base cadence: 180 SPM (configurable by user)
- Tempo frequency = cadence / 60 Hz
- Adjust beat volume/pattern to match effort level

## Technology Choices

### Swift & SwiftUI
- Native performance critical for GPS and audio
- SwiftUI provides reactive UI updates
- Combine framework for data flow

### HealthKit
- Standard iOS workout framework
- Provides GPS, heart rate, and workout metrics
- Integrates with Apple Health app
- Enables background execution

### CoreLocation
- Direct GPS access for custom pace calculations
- More control than HealthKit's derived pace
- Allows custom smoothing algorithms

### WatchConnectivity
- Reliable data transfer between phone and watch
- Supports both immediate and background transfers
- Built-in session management

### UserDefaults
- Simple key-value storage for configurations
- Fast read/write for frequently accessed data
- Automatic sync via WatchConnectivity

## State Management

### Phone App States
- **Idle**: No active workout, can create/edit configs
- **Connected**: Watch connection active, can transfer data
- **Syncing**: Transferring run configuration to watch

### Watch App States
- **Ready**: Config loaded, ready to start workout
- **Active**: Workout in progress, GPS tracking, audio playing
- **Paused**: Workout paused, GPS stopped, audio muted
- **Ended**: Workout complete, showing summary

## Error Handling

### GPS Issues
- No GPS signal: Display warning, use watch's pace estimate
- Poor accuracy: Show accuracy indicator, warn user
- GPS lost mid-workout: Continue with last known pace, alert user

### Audio Issues
- Headphones disconnected: Pause audio, show alert
- Audio session interrupted: Resume when session reactivates
- Volume too low: One-time prompt to increase volume

### Sync Issues
- Watch not connected: Show sync status, retry mechanism
- Transfer fails: Queue for retry, show pending indicator
- Config out of date: Prompt user to re-sync

## Performance Requirements

### GPS Update Rate
- Location updates: 1 Hz (every second)
- Pace calculation: Real-time with <200ms latency
- Distance accuracy: ±2% over full run

### Audio Timing
- Tempo beat accuracy: ±5ms jitter
- Voice alert latency: <500ms from trigger
- No audio dropouts during workout

### Battery Life
- Target: 6 hours continuous use on watch
- GPS optimization: Use lower accuracy when pace stable
- Display: Auto-dim when not actively viewing

### Memory Usage
- Watch app: <50MB resident memory
- Efficient data structures for GPS history
- Clear old workout data when storage low

## Security & Privacy

### Data Storage
- All data stored locally on device
- No cloud sync, no external servers
- No user accounts or authentication

### Permissions
- Location: Only while using app (watch workout)
- HealthKit: Write workout data, read heart rate
- Motion: Access pedometer data for cadence

### Privacy
- No analytics or telemetry
- No personally identifiable information collected
- User controls all data through iOS Settings

## Future Extensibility

### Planned Enhancements
1. Heart rate zone monitoring
2. Interval training support (alternating paces)
3. Race day strategy mode (negative splits)
4. Audio coaching phrases
5. Integration with training plans

### Architecture Considerations
- Plugin system for audio feedback styles
- Extensible pace calculation algorithms
- Modular UI components for easy customization
