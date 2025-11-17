# PaceRunner - Marathon Pace Training App

A native iOS and WatchOS application for maintaining target pace during marathon training with audio tempo beats and real-time pace guidance.

## Project Overview

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
PaceRunner/
├── PaceRunner-iOS/           # iPhone app
│   ├── Models/              # Data models
│   ├── Views/               # SwiftUI views
│   ├── ViewModels/          # View models
│   └── Services/            # Business logic
├── PaceRunner-Watch/         # Watch app
│   ├── Models/              # Data models
│   ├── Views/               # SwiftUI views
│   ├── ViewModels/          # View models
│   └── Services/            # Business logic
└── PaceRunner-Shared/        # Shared code
    ├── Models/              # Shared data models
    └── Extensions/          # Shared utilities
```

## Specification Documents

1. **[ARCHITECTURE.md](ARCHITECTURE.md)** - Overall system design and component interaction
2. **[DATA-MODEL.md](DATA-MODEL.md)** - Data structures and persistence
3. **[WATCH-APP.md](WATCH-APP.md)** - Apple Watch app specification
4. **[PHONE-APP.md](PHONE-APP.md)** - iPhone app specification
5. **[SYNC-PROTOCOL.md](SYNC-PROTOCOL.md)** - Phone-Watch communication
6. **[AUDIO-ENGINE.md](AUDIO-ENGINE.md)** - Tempo beat and audio feedback system
7. **[GPS-ALGORITHM.md](GPS-ALGORITHM.md)** - Pace calculation and smoothing

## Development Approach

This project uses spec-driven development:
1. Review and refine specifications
2. Implement each component according to spec
3. Test against specification requirements
4. Iterate based on real-world testing

## Getting Started

1. Review all specification documents
2. Set up Xcode project with iOS and WatchOS targets
3. Implement shared data models first
4. Build watch app (primary user interface)
5. Build phone app (configuration interface)
6. Integrate sync protocol
7. Test on real devices

## Privacy & Permissions

Required permissions:
- Location Services (for GPS tracking)
- HealthKit (for workout data)
- Motion & Fitness (for step counting)

Data stays local on device. No cloud sync, no analytics, no third-party services.

## License

TBD
