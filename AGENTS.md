# Repository Guidelines

Concise agent guide. For the full session bootstrap (project overview,
per-component commands, gotchas, server access) read [`CLAUDE.md`](CLAUDE.md) first.

## Project structure

- `pace-runner/PaceRunner/PaceRunner.xcodeproj` — the iOS + watchOS app. Targets:
  `PaceRunner/PaceRunner/` (iOS), `PaceRunner/PaceRunner Watch App/` (watchOS).
  Shared model/service/protocol code is the **`PaceRunnerShared`** Swift package
  (`pace-runner/PaceRunnerShared/Sources/PaceRunnerShared/…`).
- `pacerunner-server/` — TypeScript analytics + MCP server (`src/…`), live and
  deployed via Docker.
- `docs/pace-runner/` — design docs (intent; verify against code). `specs/` +
  `.specify/` — SpecKit artifacts. `workout-sync-service/` — superseded doc.

## Build, test, run

App (use these exact simulator names):
- `cd pace-runner/PaceRunner && xcodebuild -project PaceRunner.xcodeproj -scheme PaceRunner -destination 'platform=iOS Simulator,name=iPhone 17' build`
- `xcodebuild -project PaceRunner.xcodeproj -scheme 'PaceRunner Watch App' -destination 'platform=watchOS Simulator,name=Apple Watch SE 3 (44mm),OS=26.5' build`
- Tests run via the app-target `PaceRunnerTests` (they `@testable import PaceRunnerShared`) on the `PaceRunner` scheme. **`swift test` fails on the host** (WatchConnectivity import) — don't use it.
- SourceKit "No such module …" diagnostics are stale-indexer noise, not build errors. Don't run iOS + watch builds concurrently. `xcodebuild | tail` hides the exit code — grep for `BUILD SUCCEEDED`.

Server:
- `cd pacerunner-server && npm run build | npm run typecheck | npm test | npm run dev`.

## Conventions

- Swift 5.9+, protocols suffixed `Protocol`, services in `Services/`, models in
  `Models/`; prefer `struct`/`enum` immutability and protocol-based DI. Match the
  surrounding code's style.
- **Build number:** on any app change bump `CURRENT_PROJECT_VERSION` +1 for the 4
  highest entries (iOS + Watch app, Debug+Release) in `project.pbxproj`; leave the
  8 entries at `1` (tests/widgets); never touch `MARKETING_VERSION`. Server-only
  changes need no bump.
- Sync/WatchConnectivity/HealthKit-background behavior can't be tested in the
  simulator — verify on-device and say so.

## Commits & PRs

- Working branch `001-pace-runner-mvp`. Commit/push only when asked; ask before
  pushing. Keep commits atomic with a clear summary of scope and how it was
  verified (which targets built, tests run, what still needs on-device checks).
- End commit messages with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
