# Implementation Guide

## Getting Started

This guide provides step-by-step instructions for implementing PaceRunner using the specifications provided.

## Prerequisites

### Development Environment
- **Xcode**: 15.0 or later
- **macOS**: 14.0 (Sonoma) or later
- **Apple Developer Account**: Required for testing on physical devices
- **Devices**:
  - iPhone running iOS 17.0+
  - Apple Watch running watchOS 10.0+

### Required Knowledge
- Swift programming (intermediate level)
- SwiftUI for UI development
- Basic understanding of:
  - HealthKit framework
  - CoreLocation/GPS
  - AVFoundation for audio
  - WatchConnectivity

## Project Setup

### 1. Create New Xcode Project

```bash
# Project structure
PaceRunner.xcodeproj
├── PaceRunner (iOS app)
├── PaceRunner Watch App
└── PaceRunner Shared
```

**Steps**:
1. Open Xcode
2. File → New → Project
3. Select "iOS App" template
4. Product Name: "PaceRunner"
5. Interface: SwiftUI
6. Language: Swift
7. Check "Include Watch App"

### 2. Configure Targets

#### iOS Target
- Deployment Target: iOS 17.0
- Capabilities:
  - Background Modes: (none needed for phone)
  - HealthKit (optional, for workout export)

#### watchOS Target
- Deployment Target: watchOS 10.0
- Capabilities:
  - Background Modes: Audio, AirPlay, and Picture in Picture
  - HealthKit: Read/Write Workout data
  - Location: While Using

### 3. Create Shared Target

Create a new Swift Package or framework for shared code:

```
PaceRunner-Shared/
├── Models/
│   ├── RunConfiguration.swift
│   ├── Pace.swift
│   ├── Distance.swift
│   ├── WorkoutSession.swift
│   └── WorkoutSummary.swift
├── Extensions/
│   └── Date+Extensions.swift
└── Constants/
    └── UserDefaultsKeys.swift
```

## Implementation Order

Follow this order for efficient development:

### Phase 1: Foundation (Week 1)
1. **Data Models** (DATA-MODEL.md)
   - Implement all models in Shared target
   - Add Codable conformance
   - Write unit tests for models

2. **Persistence Layer**
   - Implement UserDefaultsStore
   - Test saving/loading configurations

### Phase 2: Phone App (Week 2)
3. **Phone UI** (PHONE-APP.md)
   - Configuration list view
   - Configuration editor
   - Mile pace editor
   - Settings view

4. **Phone ViewModels**
   - ConfigurationListViewModel
   - ConfigurationEditorViewModel
   - Connect UI to view models

### Phase 3: Watch App Core (Week 3)
5. **GPS Manager** (GPS-ALGORITHM.md)
   - CoreLocation setup
   - Location processing
   - Distance tracking
   - Test with real device outdoors

6. **Pace Calculator** (GPS-ALGORITHM.md)
   - Implement smoothing algorithm
   - Pace status detection
   - Test with various speeds

### Phase 4: Watch App Audio (Week 4)
7. **Audio Engine** (AUDIO-ENGINE.md)
   - Audio session setup
   - Tempo beat generation
   - Voice alerts
   - Test background audio

### Phase 5: Watch App UI (Week 5)
8. **Watch UI** (WATCH-APP.md)
   - Configuration selection
   - Pre-workout view
   - Active workout view
   - Summary view

9. **Workout Manager**
   - Integrate GPS, pace, and audio
   - HealthKit workout session
   - State management

### Phase 6: Sync (Week 6)
10. **WatchConnectivity** (SYNC-PROTOCOL.md)
    - Setup connectivity sessions
    - Implement message handlers
    - Test bidirectional sync

### Phase 7: Testing & Polish (Week 7-8)
11. **Testing**
    - Unit tests for all components
    - Integration testing
    - Real-world workout testing

12. **Polish**
    - UI refinements
    - Error handling
    - Accessibility
    - Performance optimization

## Detailed Implementation Steps

### Step 1: Data Models

Start with `Pace.swift`:

```swift
// PaceRunner-Shared/Models/Pace.swift

import Foundation

public struct Pace: Codable, Equatable, Comparable {
    public let minutes: Int
    public let seconds: Int
    
    public init(minutes: Int, seconds: Int) {
        let totalSeconds = minutes * 60 + seconds
        self.minutes = totalSeconds / 60
        self.seconds = totalSeconds % 60
    }
    
    public init(totalSeconds: Int) {
        self.minutes = totalSeconds / 60
        self.seconds = totalSeconds % 60
    }
    
    public init(secondsPerMeter: Double) {
        let metersPerMile = 1609.34
        let secondsPerMile = secondsPerMeter * metersPerMile
        self.init(totalSeconds: Int(secondsPerMile))
    }
    
    public var totalSeconds: Int {
        minutes * 60 + seconds
    }
    
    public var secondsPerMeter: Double {
        let metersPerMile = 1609.34
        return Double(totalSeconds) / metersPerMile
    }
    
    public var formatted: String {
        String(format: "%d:%02d", minutes, seconds)
    }
    
    public static func < (lhs: Pace, rhs: Pace) -> Bool {
        lhs.totalSeconds < rhs.totalSeconds
    }
}
```

Continue with other models following DATA-MODEL.md specification.

### Step 2: Phone App - Configuration List

```swift
// PaceRunner/Views/ConfigurationListView.swift

import SwiftUI

struct ConfigurationListView: View {
    @StateObject private var viewModel = ConfigurationListViewModel()
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.configurations) { config in
                    NavigationLink(destination: ConfigurationDetailView(config: config)) {
                        ConfigurationRow(config: config)
                    }
                }
                .onDelete(perform: viewModel.deleteConfigurations)
            }
            .navigationTitle("Workouts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: viewModel.addConfiguration) {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .onAppear {
            viewModel.loadConfigurations()
        }
    }
}
```

### Step 3: Watch App - Workout Manager

```swift
// PaceRunner Watch App/Services/WorkoutManager.swift

import Foundation
import CoreLocation
import HealthKit
import Combine

@MainActor
class WorkoutManager: NSObject, ObservableObject {
    @Published var state: SessionState = .initial
    @Published var currentPace: Pace?
    @Published var currentDistance: Distance = Distance(miles: 0)
    @Published var currentMile: Int = 1
    
    private let gpsManager = GPSManager()
    private let audioEngine = AudioEngine()
    private let paceCalculator = PaceCalculator()
    private var healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    
    private var selectedConfig: RunConfiguration?
    private var workoutData: WorkoutSession?
    
    override init() {
        super.init()
        gpsManager.delegate = self
    }
    
    func selectConfiguration(_ config: RunConfiguration) {
        selectedConfig = config
        state = .ready
    }
    
    func startWorkout() {
        guard let config = selectedConfig else { return }
        
        // Create workout session
        workoutData = WorkoutSession(configuration: config)
        
        // Start HealthKit workout
        startHealthKitWorkout()
        
        // Start services
        gpsManager.startTracking()
        audioEngine.start(bpm: config.baseCadence)
        
        state = .active
    }
    
    func pauseWorkout() {
        // Pause all services
        gpsManager.stopTracking()
        audioEngine.stop()
        workoutSession?.pause()
        
        state = .paused
    }
    
    func resumeWorkout() {
        // Resume all services
        gpsManager.startTracking()
        audioEngine.start(bpm: selectedConfig?.baseCadence ?? 180)
        workoutSession?.resume()
        
        state = .active
    }
    
    func endWorkout() {
        // Stop all services
        gpsManager.stopTracking()
        audioEngine.stop()
        workoutSession?.end()
        
        // Save workout
        saveWorkout()
        
        state = .ended
    }
    
    private func startHealthKitWorkout() {
        // See WATCH-APP.md for full implementation
    }
    
    private func saveWorkout() {
        // See WATCH-APP.md for full implementation
    }
}

extension WorkoutManager: GPSManagerDelegate {
    func gpsManager(_ manager: GPSManager, didUpdateLocation location: CLLocation) {
        // Process location update
        let sample = GPSSample(from: location)
        paceCalculator.addSample(sample)
        currentPace = paceCalculator.getCurrentPace()
        
        // Check for mile transition
        if let newMile = mileTracker.updateDistance(manager.totalDistance) {
            handleMileTransition(to: newMile)
        }
    }
    
    func gpsManager(_ manager: GPSManager, didUpdateDistance distance: Distance) {
        currentDistance = distance
    }
}
```

## Testing Strategy

### Unit Tests

Create test files for each component:

```swift
// PaceRunnerTests/PaceTests.swift

import XCTest
@testable import PaceRunner

class PaceTests: XCTestCase {
    func testPaceInitialization() {
        let pace = Pace(minutes: 7, seconds: 30)
        XCTAssertEqual(pace.minutes, 7)
        XCTAssertEqual(pace.seconds, 30)
    }
    
    func testPaceFormatting() {
        let pace = Pace(minutes: 8, seconds: 5)
        XCTAssertEqual(pace.formatted, "8:05")
    }
    
    func testPaceComparison() {
        let pace1 = Pace(minutes: 7, seconds: 30)
        let pace2 = Pace(minutes: 8, seconds: 0)
        XCTAssertTrue(pace1 < pace2)
    }
}
```

### Integration Tests

Test component interactions:

```swift
class WorkoutIntegrationTests: XCTestCase {
    var workoutManager: WorkoutManager!
    
    func testCompleteWorkoutFlow() async {
        // 1. Select configuration
        let config = createTestConfiguration()
        await workoutManager.selectConfiguration(config)
        
        // 2. Start workout
        await workoutManager.startWorkout()
        XCTAssertEqual(workoutManager.state, .active)
        
        // 3. Simulate GPS updates
        // ...
        
        // 4. End workout
        await workoutManager.endWorkout()
        XCTAssertEqual(workoutManager.state, .ended)
    }
}
```

### Real-World Testing

Test on actual hardware:
1. **Treadmill Test**: Verify pace accuracy at known speed
2. **Track Test**: Run 400m lap, verify distance accuracy
3. **Road Test**: Long run with varying pace
4. **Battery Test**: Monitor battery drain over 2-hour run

## Common Issues & Solutions

### Issue 1: GPS Accuracy Poor
**Symptom**: Erratic pace readings, distance inaccurate  
**Solution**: 
- Ensure watch has clear sky view
- Wait for GPS to fully lock before starting
- Increase smoothing window size
- Check desiredAccuracy settings

### Issue 2: Audio Cuts Out
**Symptom**: Tempo beats stop during workout  
**Solution**:
- Verify Background Modes capability enabled
- Check audio session configuration
- Ensure audio engine doesn't stop on screen sleep

### Issue 3: Watch Sync Fails
**Symptom**: Configurations don't appear on watch  
**Solution**:
- Verify WatchConnectivity session activated
- Check that both apps have session delegate set
- Use transferUserInfo for background transfers
- Implement retry mechanism

### Issue 4: Battery Drains Quickly
**Symptom**: Watch battery depletes in < 4 hours  
**Solution**:
- Reduce GPS update frequency when pace stable
- Lower desiredAccuracy when appropriate
- Minimize audio processing
- Use display sleep timeout

## Performance Benchmarks

Target performance metrics:

- **GPS Latency**: < 200ms from location update to UI
- **Pace Calculation**: < 50ms per update
- **Audio Timing**: ± 5ms tempo beat accuracy
- **Memory Usage**: < 50MB on watch
- **Battery Life**: 6+ hours continuous use
- **Sync Time**: < 2 seconds for configuration transfer

## Deployment Checklist

Before releasing:

- [ ] All unit tests pass
- [ ] Integration tests pass
- [ ] Real-world workout tested (3+ hours)
- [ ] GPS accuracy validated on track
- [ ] Audio works with headphones
- [ ] Sync tested both directions
- [ ] Battery life meets targets
- [ ] Error handling tested
- [ ] Accessibility verified
- [ ] Privacy policy complete
- [ ] App Store screenshots prepared
- [ ] TestFlight beta testing complete

## Next Steps

1. Review all specification documents
2. Set up Xcode project
3. Implement Phase 1 (Foundation)
4. Test thoroughly after each phase
5. Iterate based on real-world testing

## Resources

### Apple Documentation
- [HealthKit Workouts](https://developer.apple.com/documentation/healthkit/workouts_and_activity_rings)
- [CoreLocation Best Practices](https://developer.apple.com/documentation/corelocation)
- [WatchConnectivity Programming Guide](https://developer.apple.com/documentation/watchconnectivity)
- [AVAudioEngine](https://developer.apple.com/documentation/avfoundation/avaudioengine)

### Code Examples
- [Apple Sample: SpeedySloth](https://developer.apple.com/documentation/healthkit/workouts_and_activity_rings/building_a_workout_app_for_apple_watch)
- [Apple Sample: WorkoutKit](https://developer.apple.com/documentation/healthkit/workouts_and_activity_rings)

## Support

For questions during implementation:
- Review specification documents
- Check Apple documentation
- Test on physical devices frequently
- Use Xcode Instruments for profiling

Good luck with your implementation! 🏃‍♂️
