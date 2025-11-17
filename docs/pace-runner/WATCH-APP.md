# Apple Watch App Specification

## Overview

The Apple Watch app is the primary user interface during workouts. It must operate completely independently from the iPhone, handling GPS tracking, pace calculation, audio feedback, and tempo beat generation.

## User Interface

### Screen Flow

```
Launch → Config Selection → Pre-Workout → Active Workout → Paused (optional) → Summary
```

### 1. Configuration Selection Screen

**Purpose**: Select which run configuration to use for the workout

**Layout**:
```
┌─────────────────────────┐
│   Select Your Run       │
├─────────────────────────┤
│                         │
│  📋 Marathon - Even     │
│     26.2 mi @ 8:00      │
│                         │
│  📋 10K Tempo           │
│     6.2 mi @ 7:30       │
│                         │
│  📋 Easy Long Run       │
│     15.0 mi @ 9:00      │
│                         │
└─────────────────────────┘
     (scrollable list)
```

**Components**:
- List of available run configurations
- Shows: name, distance, average pace
- Tap to select
- Sync indicator if configs not yet loaded

**Actions**:
- Tap config → Navigate to Pre-Workout screen
- Digital Crown scroll through list

### 2. Pre-Workout Screen

**Purpose**: Confirm settings and start GPS acquisition

**Layout**:
```
┌─────────────────────────┐
│   Marathon - Even       │
├─────────────────────────┤
│                         │
│  Distance: 26.2 mi      │
│  Target: 8:00/mi        │
│  Cadence: 180 SPM       │
│                         │
│  GPS Status: Ready ✓    │
│                         │
│  ┌───────────────────┐ │
│  │   START WORKOUT   │ │
│  └───────────────────┘ │
│                         │
└─────────────────────────┘
```

**Components**:
- Configuration summary
- GPS status indicator (Acquiring... / Ready ✓ / Poor Signal ⚠)
- Start button (disabled until GPS ready)
- Settings button (bottom left) → Settings sheet

**Actions**:
- Start button → Begin workout, navigate to Active Workout screen
- Settings button → Open settings overlay

### 3. Active Workout Screen

**Purpose**: Display current workout progress and metrics

**Layout** (Primary view):
```
┌─────────────────────────┐
│ Mile 3 of 26           │← Top: Progress
├─────────────────────────┤
│                         │
│     7:58               │← Large: Current pace
│    /mile               │
│                         │
│  Target: 8:00          │← Medium: Target
│                         │
│  Distance: 2.85 mi     │← Small: Stats
│  Time: 23:42           │
│                         │
└─────────────────────────┘
```

**Alternative Layouts** (swipe to change):

Layout 2 - Split focused:
```
┌─────────────────────────┐
│ Mile 3 @ 7:58          │
├─────────────────────────┤
│                         │
│  Last Mile: 7:52       │
│  This Mile: 2:15       │
│                         │
│  Target: 8:00          │
│  Deviation: -2s        │
│                         │
│  ♥ 156 bpm            │
│                         │
└─────────────────────────┘
```

Layout 3 - Minimal:
```
┌─────────────────────────┐
│                         │
│                         │
│       7:58             │
│      /mile             │
│                         │
│     (8:00)             │
│                         │
│                         │
└─────────────────────────┘
```

**Components**:
- Current pace (large, color-coded: green=on target, yellow=±5s, red=>5s)
- Target pace for current mile
- Distance progress
- Elapsed time
- Current mile number
- Heart rate (if available)
- Tempo beat indicator (visual pulse)

**Color Coding**:
- Green: Within tolerance (±5s of target)
- Yellow: Slightly off (5-10s from target)
- Red: Significantly off (>10s from target)

**Actions**:
- Tap screen → Pause/Resume controls appear
- Digital Crown → Adjust volume
- Swipe left/right → Change layout
- Press both buttons → Mark lap (optional)

### 4. Pause Controls Overlay

**Purpose**: Pause, resume, or end workout

**Layout**:
```
┌─────────────────────────┐
│   Workout Paused        │
├─────────────────────────┤
│                         │
│  ┌─────────────────┐   │
│  │   RESUME        │   │
│  └─────────────────┘   │
│                         │
│  ┌─────────────────┐   │
│  │   END WORKOUT   │   │
│  └─────────────────┘   │
│                         │
└─────────────────────────┘
```

**Actions**:
- Resume → Return to Active Workout screen
- End → Navigate to Summary screen with confirmation

### 5. Summary Screen

**Purpose**: Show completed workout statistics

**Layout**:
```
┌─────────────────────────┐
│   Great Workout! 🎉     │
├─────────────────────────┤
│                         │
│  Distance: 26.2 mi     │
│  Time: 3:28:15         │
│  Avg Pace: 7:58/mi     │
│                         │
│  Mile Splits:          │
│  1: 7:52 (-8s)         │
│  2: 8:05 (+5s)         │
│  3: 7:58 (±0s)         │
│  ... (scroll)          │
│                         │
│  ┌─────────────────┐   │
│  │     DONE        │   │
│  └─────────────────┘   │
└─────────────────────────┘
```

**Components**:
- Total distance
- Total time
- Average pace
- Scrollable list of mile splits with deviations
- Done button

**Actions**:
- Done → Return to Configuration Selection screen
- Scroll → View all mile splits

### 6. Settings Sheet

**Purpose**: Configure workout preferences

**Layout**:
```
┌─────────────────────────┐
│   Settings              │
├─────────────────────────┤
│                         │
│  Audio Alerts    [ON]   │
│  Tempo Beats     [ON]   │
│  Haptic Feedback [ON]   │
│                         │
│  Volume:         ━━●━   │
│                         │
│  Base Cadence: 180 SPM │
│  Tolerance: 5 sec      │
│                         │
└─────────────────────────┘
```

**Actions**:
- Toggle switches for each setting
- Slider for volume
- Tap to adjust cadence/tolerance

## Workout State Machine

```
┌─────────┐  select   ┌──────────┐  start   ┌────────┐
│ Initial │─────────→ │ Ready    │────────→ │ Active │
└─────────┘           └──────────┘          └────┬───┘
                                                  │
                                             pause│↓↑resume
                                                  │
                                            ┌─────▼───┐
                                            │ Paused  │
                                            └─────┬───┘
                                                  │
                                             end  │
                                                  ↓
                                            ┌─────────┐
                                            │ Ended   │
                                            └─────────┘
```

### State Transitions

**Initial → Ready**
- User selects configuration
- Trigger: GPS acquisition
- Actions: Request location permissions, start GPS

**Ready → Active**
- User presses Start
- Trigger: HealthKit workout session start
- Actions: Begin GPS tracking, start audio engine, initialize pace calculator

**Active → Paused**
- User taps to pause
- Trigger: Pause button press
- Actions: Pause HealthKit session, stop GPS updates, mute audio

**Paused → Active**
- User resumes workout
- Trigger: Resume button press
- Actions: Resume HealthKit session, restart GPS, unmute audio

**Active/Paused → Ended**
- User ends workout
- Trigger: End button press with confirmation
- Actions: End HealthKit session, save workout data, stop all services

**Ended → Initial**
- User dismisses summary
- Trigger: Done button press
- Actions: Clean up session data, return to config selection

## Core Services

### 1. WorkoutManager

**Responsibilities**:
- Manage HealthKit workout session
- Coordinate GPS, audio, and pace services
- Handle state transitions
- Detect mile transitions
- Persist workout data

**Interface**:
```swift
class WorkoutManager: ObservableObject {
    @Published var state: SessionState = .initial
    @Published var currentSession: WorkoutSession?
    @Published var currentPace: Pace?
    @Published var currentDistance: Distance = Distance(miles: 0)
    
    private let gpsManager: GPSManager
    private let audioEngine: AudioEngine
    private let paceCalculator: PaceCalculator
    private var healthStore: HKHealthStore
    private var workoutSession: HKWorkoutSession?
    
    func selectConfiguration(_ config: RunConfiguration)
    func startWorkout()
    func pauseWorkout()
    func resumeWorkout()
    func endWorkout()
    
    // Called by GPS manager on location updates
    func didReceiveLocation(_ location: CLLocation)
    
    // Called when mile threshold crossed
    private func handleMileTransition()
}
```

### 2. GPSManager

**Responsibilities**:
- Manage CoreLocation updates
- Provide raw GPS samples
- Track total distance
- Report GPS accuracy

**Interface**:
```swift
class GPSManager: NSObject, CLLocationManagerDelegate {
    private let locationManager: CLLocationManager
    private var delegate: GPSManagerDelegate?
    
    var currentLocation: CLLocation?
    var totalDistance: Distance = Distance(miles: 0)
    var accuracy: CLLocationAccuracy = 0
    
    func startTracking()
    func stopTracking()
    func requestPermissions()
    
    // CLLocationManagerDelegate
    func locationManager(_ manager: CLLocationManager, 
                        didUpdateLocations locations: [CLLocation])
    func locationManager(_ manager: CLLocationManager, 
                        didFailWithError error: Error)
}

protocol GPSManagerDelegate: AnyObject {
    func gpsManager(_ manager: GPSManager, 
                   didUpdateLocation location: CLLocation)
    func gpsManager(_ manager: GPSManager, 
                   didUpdateDistance distance: Distance)
    func gpsManager(_ manager: GPSManager, 
                   didEncounterError error: Error)
}
```

### 3. PaceCalculator

**Responsibilities**:
- Smooth GPS pace data
- Calculate current pace
- Determine if on/off target
- Maintain rolling window of samples

**Interface**:
```swift
class PaceCalculator {
    private var samples: [GPSSample] = []
    private let windowSize: TimeInterval = 10.0  // 10 second window
    private let outlierThreshold: Double = 0.20   // 20% deviation
    
    func addSample(_ sample: GPSSample)
    func getCurrentPace() -> Pace?
    func isOnTarget(targetPace: Pace, tolerance: Int) -> PaceStatus
    func reset()
    
    private func removeOutliers() -> [GPSSample]
    private func calculateSmoothedPace() -> Pace?
}

enum PaceStatus {
    case tooSlow
    case onTarget
    case tooFast
    
    var needsAlert: Bool {
        self != .onTarget
    }
}
```

### 4. AudioEngine

**Responsibilities**:
- Generate tempo beats
- Play voice alerts
- Mix audio with music
- Manage audio session

**Interface**:
```swift
class AudioEngine {
    private var audioEngine: AVAudioEngine
    private var tempoPlayer: AVAudioPlayerNode
    private var speechSynthesizer: AVSpeechSynthesizer
    
    private var isTempoPlaying: Bool = false
    private var currentBPM: Int = 0
    
    func start()
    func stop()
    func setTempoBPM(_ bpm: Int)
    func playVoiceAlert(_ message: String)
    func setVolume(_ volume: Float)
    
    private func generateTempoBeat() -> AVAudioPCMBuffer
    private func configureAudioSession()
}
```

## Workout Logic

### Mile Transition Detection

```swift
// In WorkoutManager.didReceiveLocation()
func didReceiveLocation(_ location: CLLocation) {
    let newDistance = currentDistance.miles + /* calculate from last location */
    currentDistance = Distance(miles: newDistance)
    
    // Check for mile transition
    let currentMile = Int(currentDistance.miles.rounded(.down)) + 1
    if currentMile > currentSession?.currentMile ?? 0 {
        handleMileTransition(to: currentMile)
    }
    
    // Update pace
    let sample = GPSSample(from: location)
    paceCalculator.addSample(sample)
    currentPace = paceCalculator.getCurrentPace()
    
    // Check pace status
    if let targetPace = currentSession?.currentTargetPace(from: config),
       let pace = currentPace {
        let status = paceCalculator.isOnTarget(
            targetPace: targetPace,
            tolerance: config.paceToleranceSeconds
        )
        handlePaceStatus(status, current: pace, target: targetPace)
    }
}

private func handleMileTransition(to mile: Int) {
    // Save previous mile split
    if let split = calculateMileSplit(for: mile - 1) {
        currentSession?.mileSplits.append(split)
    }
    
    // Update current mile
    currentSession?.currentMile = mile
    
    // Update tempo for new target pace
    if let newTargetPace = currentSession?.currentTargetPace(from: config) {
        updateTempoForPace(newTargetPace)
    }
    
    // Play mile completion alert
    audioEngine.playVoiceAlert("Mile \(mile - 1) complete")
}

private func handlePaceStatus(_ status: PaceStatus, 
                            current: Pace, 
                            target: Pace) {
    guard status.needsAlert else { return }
    
    // Throttle alerts (max once per 30 seconds)
    guard shouldPlayAlert() else { return }
    
    let message = status == .tooSlow ? 
        "Speed up. Current pace \(current.formatted)" :
        "Slow down. Current pace \(current.formatted)"
    
    audioEngine.playVoiceAlert(message)
}
```

### Tempo Beat Calculation

```swift
func updateTempoForPace(_ pace: Pace) {
    // Convert pace to cadence
    // Standard: 180 SPM for most paces, adjust for very fast/slow
    let baseCadence = config.baseCadence
    
    // Calculate beats per second (for tempo)
    let bpm = baseCadence * 2  // Double since tempo beat is per footstrike
    
    audioEngine.setTempoBPM(bpm)
}
```

## Performance Optimizations

### Battery Conservation
- Use significant location changes when pace stable
- Reduce GPS accuracy when not actively changing pace
- Dim screen after 5 seconds of no interaction
- Stop tempo beats when paused

### Memory Management
- Limit GPS sample history to 60 seconds
- Clear old mile splits from memory (keep in HealthKit)
- Release audio buffers when not in use

### GPS Optimization
```swift
// Configure location manager for running
locationManager.desiredAccuracy = kCLLocationAccuracyBest
locationManager.distanceFilter = 5.0  // Update every 5 meters
locationManager.allowsBackgroundLocationUpdates = true
locationManager.activityType = .fitness
```

## Error Handling

### GPS Errors
```swift
func locationManager(_ manager: CLLocationManager, 
                    didFailWithError error: Error) {
    switch error {
    case CLError.denied:
        // Show permission denied alert
        showAlert("GPS access denied. Enable in Settings.")
    case CLError.locationUnknown:
        // Try to continue with last known location
        fallBackToLastLocation()
    default:
        // Log error, continue workout
        logError(error)
    }
}
```

### Audio Errors
- If headphones disconnect: Pause tempo, show alert
- If audio session interrupted: Pause, resume when available
- If speech synthesis fails: Skip alert, continue workout

### HealthKit Errors
- If workout save fails: Retry 3 times, then log locally
- If session fails to start: Show error, return to config selection

## Testing Scenarios

### Happy Path
1. Select configuration
2. Wait for GPS ready
3. Start workout
4. Run 3 miles with varying paces
5. Pause at mile 3
6. Resume and run 2 more miles
7. End workout
8. Verify summary shows correct splits

### Edge Cases
1. **GPS Loss**: Lose GPS mid-workout, verify fallback behavior
2. **Audio Interruption**: Phone call during workout, verify audio resumes
3. **Battery Critical**: Verify graceful degradation
4. **Very Fast Pace**: Run 5:00/mile, verify tempo and alerts
5. **Very Slow Pace**: Run 12:00/mile, verify tempo and alerts
6. **Mile Boundary**: Verify clean transition at exactly 1.00 miles
7. **Config Change**: Load different config mid-workout (should prevent this)

## Accessibility

- VoiceOver support for all controls
- Large touch targets (minimum 44x44 pt)
- High contrast mode for pace display
- Audio-only mode for visually impaired
- Haptic feedback for all state changes
