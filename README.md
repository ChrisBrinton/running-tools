# Running Tools

A running-training platform: a native iOS/watchOS pace-guidance app plus an
always-on analytics server that turns recorded runs into coach-ready insights.

> **Status note:** This is shipping software, not a spec-stage project. Some
> older docs under `docs/` and `specs/` describe a pre-implementation or
> "cloud-optional/planned" state — treat those as historical design intent.
> `CLAUDE.md` and this README reflect current reality.

## Repository structure

```
running-tools/
├── pace-runner/            # iOS + watchOS app (Swift/SwiftUI) — SHIPPED (build 35)
├── pacerunner-server/      # TypeScript analytics server (Hono + SQLite + MCP) — LIVE
├── workout-sync-service/   # SUPERSEDED design doc — replaced by pacerunner-server
├── docs/                   # Design docs (reference/intent)
├── specs/ + .specify/      # SpecKit specs and templates
└── .claude/                # Claude Code configuration
```

See [`CLAUDE.md`](CLAUDE.md) for the fast per-component build/test/deploy guide.

## Components

### PaceRunner — iOS/watchOS app (`pace-runner/`)

Native app for maintaining a target pace during training and races.

- Per-mile (and per-segment) pace targets via named run configurations
- Audio tempo beats matched to target cadence + voice pace alerts
- Real-time GPS pace guidance with rolling multi-window smoothing
- Independent Apple Watch operation — **runs 100% offline**, no phone or network needed
- HealthKit workout recording; a Pro tier for advanced configuration
- Post-workout, pushes data to the analytics server (background/opt-in)

**Tech:** Swift/SwiftUI, HealthKit, CoreLocation, WatchConnectivity, AVFoundation.
Shared logic lives in the `PaceRunnerShared` Swift package.
**Docs:** [`docs/pace-runner/`](docs/pace-runner/).

### PaceRunner Server (`pacerunner-server/`)

Always-on, multi-user home server (`pacerunner.brintontech.com`) that:

- Ingests workouts, run configs, and settings from users' phones over HTTPS
- Decorates outdoor runs with weather + air quality (Open-Meteo)
- Derives per-workout analytics: mile splits, pace/HR/power drift, split
  variability, `hr_to_power_ratio`, `workout_type`, **`run_quality`**
  (clean/degraded/aborted/structured), and **workout-structure detection**
  (warmup / steady / tempo / intervals / strides / cooldown)
- Serves per-user, per-scope views over an **MCP** server so a runner or their
  coach can query training data in a chat session

**Tech:** TypeScript, Hono, better-sqlite3, MCP JSON-RPC, Docker/Caddy.
**Docs:** [`pacerunner-server/README.md`](pacerunner-server/README.md).

### Workout Sync Service (`workout-sync-service/`) — superseded

An earlier "planned cloud service" design. Its role is fully served by
`pacerunner-server/`; the directory is kept for historical context only.

## Design principles

- **Workout independence:** runs work 100% offline; all sync is post-workout / background.
- **Privacy by design:** no PII required. Identity is an anonymous install ID →
  server user_id, with per-user, per-scope tokens. Users control and can delete
  their data.
- **Native performance & battery:** runtime-critical paths in Swift; 6+ hour
  continuous operation target.

Full principles: [`.specify/memory/constitution.md`](.specify/memory/constitution.md).

## Getting started

- **App:** open `pace-runner/PaceRunner/PaceRunner.xcodeproj` in Xcode; build the
  `PaceRunner` (iOS) and `PaceRunner Watch App` schemes. See `CLAUDE.md` for the
  exact simulator names and test caveats.
- **Server:** `cd pacerunner-server && npm install && npm run dev`. See its README
  for the identity model, endpoints, and deploy.
