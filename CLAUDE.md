# CLAUDE.md — Running Tools

Session bootstrap for this repo. Read this first; it points to everything else.

## What this is

A **shipping, commercial, multi-user** running-training platform (not a
pre-release spec project — ignore any doc that says "implementation pending").
Three components:

| Dir | What | Stack | Status |
|-----|------|-------|--------|
| `pace-runner/` | iOS + watchOS app: pace-guided training with audio tempo beats, GPS pace guidance, HealthKit workouts | Swift/SwiftUI, HealthKit, CoreLocation, WatchConnectivity, AVFoundation | Shipped (build 35) |
| `pacerunner-server/` | Always-on home server: ingests workouts from phones, decorates with weather/AQI, derives analytics, serves per-user views over MCP to chat/coach sessions | TypeScript, Hono, better-sqlite3, MCP JSON-RPC, Docker | Live at `pacerunner.brintontech.com` |
| `workout-sync-service/` | **Superseded** — old "planned" design doc; the real server is `pacerunner-server/`. Docs only, no code. | — | Dead/historical |

`docs/` = design docs (reference/intent). `specs/` + `.specify/` = SpecKit
artifacts. `.claude/` = Claude Code config.

Data flow: watch/phone record a run → phone pushes to `pacerunner-server` over
HTTPS → server stores (SQLite, per-user), computes a summary blob (splits,
derived metrics, workout structure, run_quality), decorates with weather → a
coach/chat session queries it over MCP.

## Cross-cutting principles

- **Privacy by design**: never require PII. Per-user identity is an install ID
  → server user_id; tokens are per-user, per-scope. Reinstalling yields a new user.
- **Workout independence**: the app works 100% offline during a run; all sync is
  post-workout / background.
- The user (Chris, `cbrinton@mmplatformco.com`) manages release versions
  (`MARKETING_VERSION`) manually.

## Build Number

After every set of changes, increment the build number (`CURRENT_PROJECT_VERSION`) by 1 in `pace-runner/PaceRunner/PaceRunner.xcodeproj/project.pbxproj`. Only increment the iOS app and Watch app targets — the 4 entries currently at the highest build number (Debug+Release for each; **currently 35**). Do NOT change the build numbers for other targets (tests, widget extensions, etc.) that are at 1. The user manages version numbers (`MARKETING_VERSION`) manually — do not change those. Server-only changes do NOT need a build-number bump.

## Working on the iOS/watchOS app (`pace-runner/`)

Xcode project: `pace-runner/PaceRunner/PaceRunner.xcodeproj`. Structure:
- `PaceRunner/PaceRunner/` — iOS app target
- `PaceRunner/PaceRunner Watch App/` — watchOS app target
- `PaceRunnerShared/` — Swift Package with the shared model/service/protocol code (`Sources/PaceRunnerShared/…`, tests in `Tests/PaceRunnerSharedTests/`)

Build (valid simulator names — **use these exact ones**):
```bash
cd pace-runner/PaceRunner
xcodebuild -project PaceRunner.xcodeproj -scheme PaceRunner \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug build
xcodebuild -project PaceRunner.xcodeproj -scheme 'PaceRunner Watch App' \
  -destination 'platform=watchOS Simulator,name=Apple Watch SE 3 (44mm),OS=26.5' -configuration Debug build
```
Pipe carefully — `xcodebuild | tail` masks the real exit code; use `set -o pipefail` or grep the log for `BUILD SUCCEEDED`/`error:`. Don't run the iOS and watch builds concurrently (they contend over DerivedData and give spurious failures).

Testing gotchas (learned the hard way):
- `swift test` in `PaceRunnerShared` **fails on the macOS host** (imports `WatchConnectivity`, unavailable off-device). Use `xcodebuild test` via the app scheme instead.
- The runnable unit tests are the app-target `PaceRunnerTests` (they `@testable import PaceRunnerShared`), via the `PaceRunner` scheme on the iPhone 17 sim.
- SourceKit "No such module 'UIKit' / 'WatchConnectivity' / 'PaceRunnerShared' / 'XCTest'" diagnostics are **stale-indexer noise**, NOT real errors. Only `xcodebuild` errors count.
- Sync behavior (WatchConnectivity acks, HealthKit background delivery, pairing state) can't be exercised in the simulator — flag those for on-device testing.

## Working on the server (`pacerunner-server/`)

```bash
cd pacerunner-server
npm run dev        # local dev on :8080
npm run build      # tsc → dist/
npm run typecheck
npm test           # node --test over src/*.test.ts (structure detection, etc.)
npm run admin -- <cmd>   # create-user/create-token/list-*/recompute-summaries
```

Key source: `src/summary.ts` (the derived-metrics blob), `src/structure.ts`
(workout-structure/stride/tempo detection), `src/splits.ts` (per-mile splits
from GPX), `src/mcp/tools.ts` (MCP tools incl. weekly aggregation),
`src/ingest/` (phone→server), `src/admin.ts` (CLI). The summary is computed on
the write path and stored as a JSON blob on the workout row; both ingest and
`recompute-summaries` funnel through `computeSummary`, so backfilling is a
matter of re-running recompute after a deploy.

Deploy = Docker on the Mac mini (the server host, repo at `~/git_repos/running-tools`):
```bash
cd ~/git_repos/running-tools/pacerunner-server
git pull && docker compose up -d --build
docker compose exec pacerunner-server node dist/admin.js recompute-summaries   # backfill after summary/structure changes
```
Note: the container has the compiled `dist/` + prod deps; run admin via
`node dist/admin.js <cmd>` inside it (NOT host `npm run admin`, which needs devDeps).

To query the live server from a session, POST JSON-RPC to
`https://pacerunner.brintontech.com/mcp` with a `Bearer` MCP token. Tools:
`list_workouts`, `get_workout` (fields: metadata/route_gpx/samples/events/splits/pacerunner_log/weather),
`get_pacerunner_log`, `get_weather`, `get_weekly_summaries`, `list_configurations`,
`get_settings`. `get_workout` `id` must be the FULL HealthKit UUID (not a prefix).

## Git / commits

- Working branch: `001-pace-runner-mvp` (also the effective main here).
- Commit/push only when asked. End commit messages with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

## Where the detail lives

- App design docs: `docs/pace-runner/` (ARCHITECTURE, DATA-MODEL, WATCH-APP,
  PHONE-APP, SYNC-PROTOCOL, AUDIO-ENGINE, GPS-ALGORITHM, WORKOUT-EXPORT, PRO-TIER-PLAN).
  These are design intent; verify against code before relying on specifics.
- Server: `pacerunner-server/README.md` (identity, endpoints, deploy, analytics).
- Product constitution: `.specify/memory/constitution.md`.
