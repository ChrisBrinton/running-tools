# PaceRunner — Marathon Pace Training App

Native iOS and watchOS app for maintaining a target pace during marathon
training, with audio tempo beats and real-time pace guidance.

**Status:** Shipped (build 35). This app is implemented and in active use; the
older `docs/pace-runner/` specs are design intent — verify specifics against the
code.

## Overview

- Per-mile (and per-segment) pace targets via named run configurations
- Audio tempo beats matched to target cadence + voice pace alerts
- Real-time GPS pace monitoring with rolling multi-window smoothing
- Independent Apple Watch operation (no phone needed during a run)
- HealthKit workout recording; a Pro tier for advanced configuration
- Post-workout sync to the analytics server (see below)

## Technology

- Swift 5.9+, SwiftUI; iOS 17+ / watchOS 10+
- HealthKit, CoreLocation, WatchConnectivity, AVFoundation

## Project structure

```
pace-runner/
├── PaceRunner/                     # Xcode project
│   └── PaceRunner.xcodeproj
│   ├── PaceRunner/                 # iOS app target
│   ├── PaceRunner Watch App/       # watchOS app target
│   ├── PaceRunnerTests/            # app-target unit tests (@testable PaceRunnerShared)
│   └── …
└── PaceRunnerShared/               # Swift package: shared models/services/protocols
    ├── Sources/PaceRunnerShared/{Models,Services,Protocols,…}
    └── Tests/PaceRunnerSharedTests/
```

## Build & test

Open `PaceRunner/PaceRunner.xcodeproj` in Xcode, or from the CLI:

```bash
cd pace-runner/PaceRunner
xcodebuild -project PaceRunner.xcodeproj -scheme PaceRunner \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -project PaceRunner.xcodeproj -scheme 'PaceRunner Watch App' \
  -destination 'platform=watchOS Simulator,name=Apple Watch SE 3 (44mm),OS=26.5' build
```

Tests run through the app-target `PaceRunnerTests` on the `PaceRunner` scheme.
`swift test` in `PaceRunnerShared` fails on the macOS host (WatchConnectivity
import) — use `xcodebuild test`. See [`../CLAUDE.md`](../CLAUDE.md) for the full
set of build/test gotchas.

## Documentation

Design docs (intent) live in [`../docs/pace-runner/`](../docs/pace-runner/):
ARCHITECTURE, DATA-MODEL, WATCH-APP, PHONE-APP, SYNC-PROTOCOL, AUDIO-ENGINE,
GPS-ALGORITHM, WORKOUT-EXPORT, PRO-TIER-PLAN.

## Privacy

Workouts run 100% offline on the watch/phone. After a run, data is synced
(background/opt-in) to the PaceRunner analytics server
([`../pacerunner-server/`](../pacerunner-server/)) for post-workout insights.
No PII is required — identity is an anonymous install ID mapped to a server
user_id. Required permissions: Location (GPS during workouts), HealthKit
(workout storage), Motion & Fitness (step counting).
