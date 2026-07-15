# Running Tools Documentation

This directory contains documentation for all tools in the running-tools repository.

## Documentation Structure

```
docs/
├── pace-runner/              # PaceRunner iOS/watchOS app specs
│   ├── ARCHITECTURE.md
│   ├── DATA-MODEL.md
│   ├── WATCH-APP.md
│   ├── PHONE-APP.md
│   ├── SYNC-PROTOCOL.md
│   ├── AUDIO-ENGINE.md
│   ├── GPS-ALGORITHM.md
│   ├── IMPLEMENTATION-GUIDE.md
│   └── README.md
└── README.md                 # This file
```

## Tools Documentation

### PaceRunner

A native iOS and watchOS application for pace-guided marathon training.

**Status**: Shipped (build 35). The design docs below are reference/intent —
verify specifics against the code, which has moved beyond some of them.

**Documentation**: [pace-runner/](pace-runner/)

**Key Specs**:
- [Architecture Overview](pace-runner/ARCHITECTURE.md) - System design and component interaction
- [Implementation Guide](pace-runner/IMPLEMENTATION-GUIDE.md) - Step-by-step development guide
- [Watch App Spec](pace-runner/WATCH-APP.md) - Primary workout interface
- [Phone App Spec](pace-runner/PHONE-APP.md) - Configuration management
- [GPS Algorithm](pace-runner/GPS-ALGORITHM.md) - Pace calculation and smoothing
- [Audio Engine](pace-runner/AUDIO-ENGINE.md) - Tempo beats and voice alerts
- [Data Model](pace-runner/DATA-MODEL.md) - Data structures and persistence
- [Sync Protocol](pace-runner/SYNC-PROTOCOL.md) - Phone-watch communication

### PaceRunner Server

Always-on multi-user server that ingests workouts, derives analytics
(splits, drift, run_quality, workout structure), decorates with weather, and
serves per-user data over MCP. Live at `pacerunner.brintontech.com`.

**Status**: Shipped / live.

**Documentation**: See [`../pacerunner-server/README.md`](../pacerunner-server/README.md).
(The earlier "Workout Sync Service" plan in `../workout-sync-service/` is
superseded by this server.)

## Development Process

All tools in this repository follow a structured development process defined by the project constitution and SpecKit workflow:

### 1. Specification Phase

Each feature starts with a detailed specification created using `/speckit.specify`:

- **User Scenarios**: Prioritized user stories with acceptance criteria
- **Requirements**: Functional requirements and key entities
- **Success Criteria**: Measurable outcomes

### 2. Planning Phase

Implementation plans are generated using `/speckit.plan`:

- **Technical Context**: Language, dependencies, platform, performance goals
- **Constitution Check**: Verify compliance with project principles
- **Project Structure**: Directory layout and organization
- **Complexity Tracking**: Document any principle violations with justification

### 3. Task Breakdown

Tasks are generated using `/speckit.tasks`:

- **Organized by User Story**: Each story is independently implementable
- **Dependency Ordering**: Clear execution order with parallel opportunities
- **Test Integration**: Optional test tasks if requested

### 4. Implementation

Features are implemented using `/speckit.implement`:

- **TDD Workflow**: Tests first (if included), then implementation
- **Incremental Delivery**: MVP first, then additional stories
- **Constitution Compliance**: All code must pass constitutional checks

## Project Constitution

All tools and features must comply with the running-tools constitution:

**Location**: [`../.specify/memory/constitution.md`](../.specify/memory/constitution.md)

**Core Principles**:

1. **Native Performance First** - Runtime-critical code in Swift with strict targets
2. **Test-Driven Development (NON-NEGOTIABLE)** - Red-Green-Refactor cycle mandatory
3. **User Experience Consistency** - Interfaces work during vigorous exercise
4. **Battery Life as a Feature** - 6+ hour continuous operation required
5. **Workout Independence, Cloud-Enabled Analytics** - Local workouts, optional cloud sync

**Performance Standards**:
- GPS processing: <200ms latency
- Pace calculation: <50ms
- Audio timing: ±5ms
- Memory: <50MB during workouts
- Battery: 6+ hours continuous use

**Development Workflow**:
- SwiftLint (no warnings)
- Type safety (no force-unwraps without justification)
- Error handling (no empty catch blocks)
- Unit + contract + integration tests
- Real device testing required

## Contributing Guidelines

(TBD - will include):
- Code review standards
- Testing requirements
- Documentation standards
- Commit message format
- Branch naming conventions

## License

TBD
