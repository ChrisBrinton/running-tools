# Running Tools

A collection of tools for runners to train smarter, track performance, and analyze running data with AI assistance.

## Project Structure

```
running-tools/
├── pace-runner/              # iOS/watchOS app for pace-guided marathon training
├── workout-sync-service/     # Cloud service + MCP server for workout analytics (future)
├── docs/                     # Documentation for all tools
├── .specify/                 # SpecKit configuration and templates
└── .claude/                  # Claude Code configuration
```

## Tools

### PaceRunner (iOS/watchOS App)

A native iOS and watchOS application for maintaining target pace during marathon training with audio tempo beats and real-time pace guidance.

**Status**: Specification complete, implementation pending

**Key Features**:
- Per-mile pace target configuration
- Audio tempo beats matching target cadence
- Real-time GPS pace monitoring with audio alerts
- Independent Apple Watch operation (no phone needed during runs)
- 100% local operation during workouts (no cloud dependencies)

**Documentation**: [docs/pace-runner/](docs/pace-runner/)

**Technology**: Swift, SwiftUI, HealthKit, CoreLocation, WatchConnectivity

### Workout Sync Service (Future)

A cloud service that aggregates workout data from iOS HealthKit and exposes it via an MCP server for AI-powered analysis through Claude Desktop.

**Status**: Planned

**Planned Features**:
- HealthKit data ingestion from iOS devices
- Cloud storage for historical workout data
- MCP server exposing workout statistics and trends
- Claude Desktop integration for natural language queries
- Training insights and performance analytics

**Architecture**:
- Separate from PaceRunner app (no direct coupling)
- Consumes HealthKit data independently
- Post-workout analytics only (never during active workouts)

## Constitution

This project follows a constitution defining core principles for code quality, testing standards, user experience consistency, and performance requirements.

See [`.specify/memory/constitution.md`](.specify/memory/constitution.md) for details.

**Key Principles**:
1. **Native Performance First** - Runtime-critical code uses Swift/native frameworks with strict performance targets
2. **Test-Driven Development** - Red-Green-Refactor cycle mandatory for all features
3. **User Experience Consistency** - Interfaces must work during vigorous exercise (gloves, rain, movement)
4. **Battery Life as a Feature** - 6+ hour continuous operation required
5. **Workout Independence, Cloud-Enabled Analytics** - Workouts must work 100% offline; cloud sync is post-workout only

## Development

### Prerequisites

- **macOS**: 14.0+ (Sonoma)
- **Xcode**: 15.0+
- **Apple Developer Account**: Required for device testing
- **Devices** (for testing):
  - iPhone running iOS 17.0+
  - Apple Watch running watchOS 10.0+

### Getting Started

1. Review the constitution and core principles
2. Read tool-specific documentation in `docs/`
3. Follow implementation guides for each tool

### SpecKit Workflow

This repo uses SpecKit for structured feature development:

- `/speckit.specify` - Create feature specifications
- `/speckit.plan` - Generate implementation plans
- `/speckit.tasks` - Break down into actionable tasks
- `/speckit.implement` - Execute implementation

See `.specify/templates/` for templates and slash command definitions.

## Privacy & Data

- **PaceRunner App**: All data stored locally on device. No cloud sync, no analytics, no third-party services.
- **Workout Sync Service** (future): Optional cloud service for users who want AI-powered insights. Users control sync and can delete data at any time.

## License

TBD

## Contributing

TBD
