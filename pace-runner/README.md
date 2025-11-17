# PaceRunner - Marathon Pace Training App

A native iOS and WatchOS application for maintaining target pace during marathon training with audio tempo beats and real-time pace guidance.

## Overview

PaceRunner helps runners maintain their target pace during training runs and races by providing:
- Per-mile pace target configuration
- Audio tempo beats matching target cadence
- Real-time pace monitoring with audio alerts
- Independent Apple Watch operation (no phone needed during runs)

## Target User

Marathon runners who want precise pace control without constantly checking their watch, with audio feedback to maintain rhythm and speed.

## Technology Stack

- **Language**: Swift 5.9+
- **iOS**: iOS 17.0+
- **WatchOS**: WatchOS 10.0+
- **Frameworks**:
  - SwiftUI (UI)
  - HealthKit (workout tracking)
  - CoreLocation (GPS)
  - WatchConnectivity (data sync)
  - AVFoundation (audio/tempo beats)

## Project Structure

```
pace-runner/
├── PaceRunner-iOS/           # iPhone app (configuration interface)
│   ├── Models/              # Data models
│   ├── Views/               # SwiftUI views
│   ├── ViewModels/          # View models
│   └── Services/            # Business logic
├── PaceRunner-Watch/         # Apple Watch app (workout interface)
│   ├── Models/              # Data models
│   ├── Views/               # SwiftUI views
│   ├── ViewModels/          # View models
│   └── Services/            # Business logic
└── PaceRunner-Shared/        # Shared code between iOS and watchOS
    ├── Models/              # Shared data models
    └── Extensions/          # Shared utilities
```

## Documentation

Comprehensive specifications are available in [`/docs/pace-runner/`](../docs/pace-runner/):

1. **[ARCHITECTURE.md](../docs/pace-runner/ARCHITECTURE.md)** - Overall system design and component interaction
2. **[DATA-MODEL.md](../docs/pace-runner/DATA-MODEL.md)** - Data structures and persistence
3. **[WATCH-APP.md](../docs/pace-runner/WATCH-APP.md)** - Apple Watch app specification
4. **[PHONE-APP.md](../docs/pace-runner/PHONE-APP.md)** - iPhone app specification
5. **[SYNC-PROTOCOL.md](../docs/pace-runner/SYNC-PROTOCOL.md)** - Phone-Watch communication
6. **[AUDIO-ENGINE.md](../docs/pace-runner/AUDIO-ENGINE.md)** - Tempo beat and audio feedback system
7. **[GPS-ALGORITHM.md](../docs/pace-runner/GPS-ALGORITHM.md)** - Pace calculation and smoothing
8. **[IMPLEMENTATION-GUIDE.md](../docs/pace-runner/IMPLEMENTATION-GUIDE.md)** - Step-by-step development guide

## Development Approach

This project uses spec-driven development:
1. Review and refine specifications
2. Implement each component according to spec
3. Test against specification requirements
4. Iterate based on real-world testing

## Implementation Status

**Current Status**: Specification complete, implementation pending

**Implementation Order** (from IMPLEMENTATION-GUIDE.md):

### Phase 1: Foundation (Week 1)
- [ ] Data models in Shared target
- [ ] Persistence layer

### Phase 2: Phone App (Week 2)
- [ ] Configuration UI
- [ ] Phone ViewModels

### Phase 3: Watch App Core (Week 3)
- [ ] GPS Manager
- [ ] Pace Calculator

### Phase 4: Watch App Audio (Week 4)
- [ ] Audio Engine
- [ ] Tempo beat generation

### Phase 5: Watch App UI (Week 5)
- [ ] Watch UI screens
- [ ] Workout Manager

### Phase 6: Sync (Week 6)
- [ ] WatchConnectivity implementation
- [ ] Bidirectional sync

### Phase 7: Testing & Polish (Week 7-8)
- [ ] Unit tests
- [ ] Integration tests
- [ ] Real-world workout testing
- [ ] UI refinements
- [ ] Performance optimization

## Getting Started

1. Review all specification documents in `/docs/pace-runner/`
2. Set up Xcode project with iOS and WatchOS targets
3. Implement shared data models first
4. Build watch app (primary user interface)
5. Build phone app (configuration interface)
6. Integrate sync protocol
7. Test on real devices

## Privacy & Permissions

Required permissions:
- Location Services (for GPS tracking during workouts)
- HealthKit (for workout data storage)
- Motion & Fitness (for step counting)

**Privacy Commitment**: Data stays local on device. No cloud sync, no analytics, no third-party services.

## Constitution Compliance

PaceRunner adheres to the running-tools constitution:
- Native Performance First: All runtime code in Swift with strict performance targets
- Test-Driven Development: Red-Green-Refactor cycle for all features
- User Experience Consistency: Operable during vigorous exercise
- Battery Life as a Feature: 6+ hour continuous operation
- Workout Independence: 100% local operation during workouts

See [`../.specify/memory/constitution.md`](../.specify/memory/constitution.md) for full details.

## Performance Requirements

- GPS processing: <200ms latency
- Pace calculation: <50ms per update
- Audio tempo beats: ±5ms accuracy
- Memory usage: <50MB during workouts
- Battery life: 6+ hours GPS + audio

## License

TBD
