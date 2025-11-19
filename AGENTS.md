# Repository Guidelines

## Project Structure & Module Organization
`pace-runner/PaceRunner` hosts the active Swift targets: Shared logic (`PaceRunner-Shared/`), phone UI (`PaceRunner/`), watch UI (`PaceRunner Watch App/`), and matching `*Tests`/`*UITests`. Project-wide resources such as mile split models, sync protocols, and watch services live in `PaceRunner-Shared/`. Long-form specifications stay in `docs/pace-runner/`, while executable research and planning artifacts live in `specs/001-pace-runner-mvp/` (SpecKit generates plans, tasks, and contracts there). `workout-sync-service/` is currently documentation-only; treat it as a future independent service boundary.

## Build, Test, and Development Commands
- `cd pace-runner/PaceRunner && xed PaceRunner.xcodeproj` — open the unified iOS/watchOS workspace in Xcode.
- `cd pace-runner/PaceRunner && xcodebuild -scheme "PaceRunner" -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build` — simulator build of both apps.
- `xcodebuild test -scheme "PaceRunner-Shared" -destination 'platform=iOS Simulator,name=iPhone 15 Pro'` — run shared model/service tests headlessly.
- `xcodebuild test -scheme "PaceRunner Watch App" -destination 'platform=watchOS Simulator,name=Apple Watch Series 9 (45mm)'` — verify watch targets plus WatchConnectivity contract tests.
- `swiftlint` from repo root — required before every commit; the build script fails the build on lint warnings.

## Coding Style & Naming Conventions
Swift 5.9+, 4-space indentation, and always-on strict linting (no force unwraps or unused code). Protocols end with `Protocol` (see `PaceRunner-Shared/Protocols/`), services stay in `Services/`, data models in `Models/`, and files mirror type names. Favor `struct` + `enum` immutability, dependency injection via protocols, and explicit `private`/`public`. Resource names follow PascalCase (`WorkoutSummary`, `RunConfiguration`), and tests mirror the type under test with `Tests` suffix.

## Testing Guidelines
Constitution mandates TDD: write failing tests first, then code. Maintain exhaustive coverage for shared math/services (`PaceRunner-SharedTests/`), UI logic via ViewModel tests, and end-to-end flows via `PaceRunnerUITests` and `PaceRunner Watch AppUITests`. Contract tests already stub HealthKit, CoreLocation, AVFoundation, and WatchConnectivity—extend them when frameworks change. Before PR, run both simulator destinations plus on-device smoke tests (real iPhone + Apple Watch) and record findings inside the PR description.

## Commit & Pull Request Guidelines
Use Conventional Commits (`feat: watch audio tempo engine`, `fix: healthkit exporter retry`) and keep commits atomic. Branch names follow `<issue#>-short-slug` (e.g., `042-gps-smoothing`). Every PR must include: summary of scope, specification references (`docs/pace-runner/...` or `specs/...`), screenshots or logs of simulator/device runs, `swiftlint` output, and confirmation that watch + phone tests passed offline. Note any constitution trade-offs explicitly; unresolved violations block merges.
