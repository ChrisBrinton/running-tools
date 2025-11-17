# PaceRunner MVP - Developer Quickstart

**Branch**: `001-pace-runner-mvp`
**Date**: 2025-11-17

## Prerequisites

### Required Software
- **macOS**: 14.0+ (Sonoma)
- **Xcode**: 15.0+
- **Command Line Tools**: `xcode-select --install`

### Required Hardware (for testing)
- **iPhone**: Running iOS 17.0+ (for configuration UI)
- **Apple Watch**: Series 6+ running watchOS 10.0+ (for workout execution)
- **Apple Developer Account**: Required for device testing (GPS and HealthKit unavailable in Simulator)

### Recommended Tools
- **Instruments**: For performance profiling (included with Xcode)
- **SwiftLint**: `brew install swiftlint` (constitution requirement: no warnings)
- **SF Symbols App**: For icon design

---

## Project Setup

### 1. Create Xcode Project

```bash
cd /Users/christopherbrinton/Dev/git_repos/running-tools/pace-runner

# Open Xcode and create new project:
# - Template: "watchOS App"
# - Product Name: "PaceRunner"
# - Organization: [Your Organization]
# - Bundle ID: com.[yourorg].pacerunner
# - Include: Notification Scene (No), Complications (No)
```

This creates:
- `PaceRunner Watch App` target (watchOS app)
- `PaceRunner` target (iPhone companion app - create manually)
- `PaceRunner-Shared` framework (create manually for shared models)

### 2. Add iOS Target

1. **File → New → Target**
2. Select **iOS → App**
3. Name: `PaceRunner-iOS`
4. Ensure same bundle ID prefix

### 3. Add Shared Framework

1. **File → New → Target**
2. Select **Framework** (iOS + watchOS multi-platform)
3. Name: `PaceRunner-Shared`
4. Add to both iOS and Watch targets

### 4. Configure Capabilities

**Watch App Target**:
- **Signing & Capabilities → + Capability**
- Add: `HealthKit`, `Location`, `Background Modes`
- Background Modes: Check "Audio, AirPlay, and Picture in Picture"

**iOS App Target**:
- Add: `HealthKit` (optional - for viewing workouts)

### 5. Project Structure

Create directory structure per plan.md:

```bash
# Shared models
mkdir -p PaceRunner-Shared/Models
mkdir -p PaceRunner-Shared/Extensions
mkdir -p PaceRunner-Shared/Protocols

# iOS app
mkdir -p PaceRunner-iOS/Views/Configuration
mkdir -p PaceRunner-iOS/Views/History
mkdir -p PaceRunner-iOS/Views/Settings
mkdir -p PaceRunner-iOS/ViewModels
mkdir -p PaceRunner-iOS/Services

# Watch app
mkdir -p PaceRunner-Watch/Views
mkdir -p PaceRunner-Watch/ViewModels
mkdir -p PaceRunner-Watch/Services

# Tests
mkdir -p PaceRunner-Tests/Unit/{Models,Services,ViewModels}
mkdir -p PaceRunner-Tests/Contract
mkdir -p PaceRunner-Tests/Integration
```

---

## Development Workflow (TDD)

### Constitution Requirement: Red-Green-Refactor

**Step 1: Write Test (RED)**
```swift
// PaceRunner-Tests/Unit/Models/PaceTests.swift
import XCTest
@testable import PaceRunner_Shared

class PaceTests: XCTestCase {
    func testPaceInitialization() {
        let pace = Pace(minutes: 8, seconds: 30)
        XCTAssertEqual(pace.totalSeconds, 510) // Will fail - not implemented yet
    }
}
```

Run test: **⌘U** → Verify it FAILS with expected message

**Step 2: Implement (GREEN)**
```swift
// PaceRunner-Shared/Models/Pace.swift
struct Pace: Codable {
    let minutes: Int
    let seconds: Int

    var totalSeconds: Int {
        minutes * 60 + seconds  // Minimal implementation
    }
}
```

Run test: **⌘U** → Verify it PASSES

**Step 3: Refactor (REFACTOR)**
```swift
// Add validation, computed properties, etc.
struct Pace: Codable, Equatable, Comparable {
    let minutes: Int
    let seconds: Int

    var totalSeconds: Int {
        minutes * 60 + seconds
    }

    init(minutes: Int, seconds: Int) {
        precondition(240...1200 ~= minutes * 60 + seconds)
        precondition(0...59 ~= seconds)
        self.minutes = minutes
        self.seconds = seconds
    }
}
```

Run tests: **⌘U** → All GREEN

---

## Building and Running

### Run on Simulator (Limited)
```bash
# iPhone Simulator
⌘R (Select PaceRunner-iOS scheme + iPhone simulator)

# Watch Simulator
⌘R (Select PaceRunner Watch App scheme + Apple Watch simulator)
```

**Limitations**: GPS and HealthKit unavailable in Simulator. Use for UI testing only.

### Run on Real Devices (Required)

**Setup**:
1. Connect iPhone to Mac via USB
2. Pair Apple Watch with iPhone
3. **Xcode → Window → Devices and Simulators**
4. Select iPhone, enable "Developer Mode"
5. Select Watch, enable "Developer Mode"

**Run Workout on Watch**:
1. Select **PaceRunner Watch App** scheme
2. Select **Your Apple Watch** as destination
3. **⌘R** to build and run
4. Grant permissions when prompted (Location, HealthKit)
5. Go outdoors for GPS lock
6. Start workout to test

**Debug on Device**:
- **⌘Y**: Enable/disable breakpoints
- **⌘\\**: Toggle breakpoint at current line
- View logs: **⌘⇧C** (Console)

---

## Testing Strategy

### Unit Tests (Models, Services)
```bash
# Run all unit tests
⌘U

# Run specific test class
⌘U (with cursor in test file)

# Run single test method
Click diamond icon in gutter next to test method
```

### Contract Tests (Framework Integration)
```bash
# Run contract tests on real device
# Select test target + physical Apple Watch
⌘U

# Note: Some contract tests require GPS, run outdoors
```

### Integration Tests
```bash
# Test complete user journeys
# Example: Create config on iPhone → appears on Watch
⌘U (with both devices connected)
```

---

## Performance Profiling

### Battery Life Validation
1. **Xcode → Product → Profile** (⌘I)
2. Select **Energy Log** instrument
3. Run 1-hour workout on watch
4. Monitor GPU, CPU, Network, Location usage
5. Verify battery drain <15% per hour

### GPS Latency Validation
1. **Product → Profile** (⌘I)
2. Select **Time Profiler**
3. Record during active workout
4. Find `didUpdateLocations` callback
5. Measure time to UI update
6. Verify <200ms total (constitution requirement)

### Memory Leaks
1. **Product → Profile** (⌘I)
2. Select **Leaks** instrument
3. Run 26-mile simulated workout
4. Check for leaked objects
5. Fix any memory leaks (constitution: leaks are BLOCKING)

---

## Code Quality Gates

### SwiftLint (Required)

**Setup**:
```bash
brew install swiftlint

# Add run script to Xcode build phases
# Build Phases → + → New Run Script Phase
# Script:
if which swiftlint >/dev/null; then
    swiftlint
else
    echo "warning: SwiftLint not installed"
fi
```

**Constitution**: No warnings allowed. Fix all SwiftLint issues before commit.

### Pre-Commit Checklist
- [ ] All unit tests pass (**⌘U**)
- [ ] SwiftLint returns 0 warnings
- [ ] No force-unwraps (`!`) without documentation
- [ ] All `catch` blocks handle errors (no empty blocks)
- [ ] Real device testing completed for GPS/audio features

---

## Common Debugging Scenarios

### GPS Not Working
- **Check**: Location permission granted?
- **Check**: Running on real device outdoors?
- **Check**: `allowsBackgroundLocationUpdates` = true?
- **Check**: Info.plist has location usage descriptions?

### Audio Not Playing
- **Check**: AVAudioSession activated?
- **Check**: Background Modes capability enabled?
- **Check**: Volume not muted on watch?
- **Check**: Watch speaker working (test with Music app)?

### WatchConnectivity Not Syncing
- **Check**: Both devices activated session?
- **Check**: Devices paired and in range?
- **Check**: Watch app installed?
- **Check**: `isReachable` = true for immediate sync?

### HealthKit Permission Denied
- **Check**: Capability added to target?
- **Check**: Usage description in Info.plist?
- **Check**: User granted permission in Settings?

---

## Useful Xcode Shortcuts

| Shortcut | Action |
|----------|--------|
| **⌘R** | Build and run |
| **⌘.** | Stop running |
| **⌘U** | Run tests |
| **⌘B** | Build |
| **⌘⇧K** | Clean build folder |
| **⌘⇧O** | Open quickly (find file) |
| **⌘⇧F** | Find in project |
| **⌘⌥[** / **⌘⌥]** | Move line up/down |
| **⌘/** | Toggle comment |
| **^I** | Re-indent |

---

## Documentation

- **Spec**: `specs/001-pace-runner-mvp/spec.md`
- **Plan**: `specs/001-pace-runner-mvp/plan.md`
- **Research**: `specs/001-pace-runner-mvp/research.md`
- **Data Model**: `specs/001-pace-runner-mvp/data-model.md`
- **Contracts**: `specs/001-pace-runner-mvp/contracts/*.md`
- **Apple Docs**: [https://developer.apple.com/documentation/](https://developer.apple.com/documentation/)

---

## Next Steps

1. **Read all spec documents** to understand feature requirements
2. **Review constitution** (`.specify/memory/constitution.md`) for compliance rules
3. **Start with Shared models** (Pace, Distance per data-model.md)
4. **Write tests first** (TDD non-negotiable per constitution)
5. **Build watch app** (primary user interface per spec priority)
6. **Validate on real device** outdoors with GPS

---

## Support

- **Constitution**: `.specify/memory/constitution.md`
- **Implementation Guide**: `docs/pace-runner/IMPLEMENTATION-GUIDE.md`
- **Architecture Overview**: `docs/pace-runner/ARCHITECTURE.md`
- **GPS Algorithm**: `docs/pace-runner/GPS-ALGORITHM.md`
- **Audio Engine**: `docs/pace-runner/AUDIO-ENGINE.md`

---

## Constitution Reminders

✅ **TDD is NON-NEGOTIABLE**: Write tests first, verify fail, then implement
✅ **Performance Targets**: GPS <200ms, Pace <50ms, Audio ±5ms
✅ **Battery Life**: 6+ hours continuous operation required
✅ **Memory**: <50MB during workout
✅ **No force-unwraps without justification**
✅ **Real device testing required for GPS/audio**
