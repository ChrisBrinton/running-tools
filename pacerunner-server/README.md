# pacerunner-server

Always-on home server that ingests PaceRunner workout data from one or more
users' phones, decorates outdoor workouts with weather + air quality, and
exposes per-user views over MCP for chat sessions.

```
iPhone(s) ──HTTPS POST──►  pacerunner-server  ◄──HTTPS MCP──  chat sessions
                           ├─ SQLite (multi-user)
                           ├─ files/<user_id>/gpx/<workout>.gpx
                           ├─ files/<user_id>/logs/<id>.txt
                           └─ async weather decoration (Open-Meteo)
```

## Identity model

There's no shared bearer token. Every user has rows in `users` and one or
more rows in `user_tokens`. A token has a scope:

| scope    | grants                                                 |
| -------- | ------------------------------------------------------ |
| `ingest` | POST to `/ingest/*` for that user's data only          |
| `mcp`    | POST to `/mcp` (read tools), scoped to that user only  |
| `admin`  | Implicit superset of both; intended for the CLI / future admin HTTP |

Users are bootstrapped via a CLI that talks directly to SQLite — no HTTP
auth dance for the first run.

```bash
npm run admin -- create-user --name "Chris" --email chris@example.com
npm run admin -- create-token --user-id 1 --scope ingest --label "iPhone"
npm run admin -- create-token --user-id 1 --scope mcp    --label "claude-code"
npm run admin -- list-users
npm run admin -- list-tokens --user-id 1
npm run admin -- revoke-token --token <full-token>
```

Tokens are 48-hex-char random strings; the value is shown once on creation.

## Endpoints

All endpoints require `Authorization: Bearer <token>`. The server identifies
the user from the token and scopes the request automatically — no `user_id`
in URLs.

### Ingest (phone → server, requires an `ingest` token)
- `POST /ingest/workout` — HK workout: metadata + samples + events + optional `route_gpx`.
- `POST /ingest/pacerunner-log` — verbose GPS debug log, attached by HK UUID or time-window match.
- `POST /ingest/config` and `/ingest/configs` — single or batch run configurations.
- `DELETE /ingest/config/:id` — soft-delete a configuration.
- `POST /ingest/settings` — snapshot of `AppSettings`.

### MCP (chat → server, requires an `mcp` token)
JSON-RPC 2.0 at `POST /mcp`. Tools:
- `list_workouts(since?, until?, activity_type?, limit?)` — directory with has_* flags including `has_weather`; each entry carries the derived `summary` object (see below).
- `get_workout(id, fields?)` — fields ⊆ `metadata, route_gpx, samples, events, splits, pacerunner_log, weather`. `id` is the FULL HealthKit UUID (not a prefix). `metadata.summary` is always present.
- `get_pacerunner_log(workout_id)` — accepts HK or PR UUID.
- `get_weather(workout_id)` — temp, humidity, wind, precipitation, PM2.5/PM10/US AQI.
- `get_weekly_summaries(since?, until?)` — ISO-week rollups: mileage, run count, distance-weighted avg pace/HR/power/hr_to_power, longest run, elevation, weather, a `workout_breakdown` by type, a `run_quality_breakdown` (clean/degraded/aborted/structured), and `clean_only_*` averages that drop degraded/aborted runs (structured runs are kept, since their metrics are core-phase-only) for cleaner week-over-week trends.
- `list_configurations()`
- `get_settings()`

## Derived analytics (the `summary` blob)

Computed on the write path (`src/summary.ts`, with `src/splits.ts` +
`src/structure.ts`) and stored as JSON on the workout row, so cross-workout
trend questions don't paginate raw samples. Every field is nullable. Key pieces:

- **Per-mile splits** (from the GPX trace): pace, mean HR, mean power, elevation.
- **Tier-1 derived metrics:** `first_half`/`second_half`, per-mile `drift`
  (regression slopes), `split_variability` (pace/HR/power stdev),
  `hr_to_power_ratio`.
- **`workout_type`** — intent from the PaceRunner config name when present,
  else an HR/pace/distance heuristic — plus `planned_workout_type` (always from
  the config name, for planned-vs-actual). Two cases override intent:
  - **Abandoned sessions.** A run under 60% of its planned distance whose
    execution also degraded is reported as `aborted` rather than as its intended
    type, so it drops out of that type's trend queries; the intent stays on
    `planned_workout_type`, and `run_quality_reasons` carries an `abandoned_…`
    code with the actual percentage. Both conditions are required — a short but
    clean run is a cutback, a full-distance degraded run is a bad day.
  - **Indoor runs.** No GPS pace and usually no power, so classification is HR
    and duration only, at capped confidence. The reference is the runner's own
    `median_run_hr_bpm_30d`, not a fraction of observed max — an observed max is
    only ever the hardest effort actually recorded, which for a runner who never
    goes all-out sits barely above their easy HR and drags every zone down with
    it.
- **`run_quality`** — how the *execution* held together, independent of intent:
  `clean` / `degraded` / `aborted`, or **`structured`** when the run has detected
  structure (strides/tempo/intervals) so whole-workout flags aren't meaningful.
- **`workout_structure`** — detected phases (warmup / steady / tempo / intervals
  / strides / cooldown) with a `core_phase_index`. When present, the effort
  metrics above are recomputed over the **core phase only** (e.g. an easy run
  with strides reports the steady portion; a tempo session reports the tempo
  block), and the whole-session numbers are preserved under `full_workout_summary`.

After changing summary/structure logic and deploying, run
`node dist/admin.js recompute-summaries` (in the container) to backfill all
historical workouts — it's idempotent, so re-run freely after threshold tuning.

## Weather decoration

After every `/ingest/workout` for an outdoor workout that includes a route,
the server fires a background task to fetch:

- **Open-Meteo weather** — temperature (°C), relative humidity (%),
  precipitation (mm), wind speed (m/s) + direction (°), cloud cover (%),
  surface pressure (hPa).
- **Open-Meteo air quality** — PM2.5, PM10, US AQI.

Both endpoints are free, no API key. The lookup picks the hour bucket
closest to the workout start time, anchored at the workout's first GPS
point. Indoor workouts (HKMetadataKeyIndoorWorkout=1) are skipped.

The fetch runs in a `queueMicrotask`, so the ingest response doesn't wait
on Open-Meteo. If the lookup fails (offline, transient API error), the
workout itself is unaffected — only the weather row is missing, and a
re-ingest will retry.

## Local dev

```bash
cp .env.example .env
npm install
npm run admin -- create-user --name "Dev"
npm run admin -- create-token --user-id 1 --scope ingest --label "dev-ingest"
npm run admin -- create-token --user-id 1 --scope mcp    --label "dev-mcp"
npm run dev
```

The server boots on `:8080`. Hit `http://localhost:8080/health`. Use the
tokens with curl:

```bash
curl -X POST http://localhost:8080/mcp \
  -H "Authorization: Bearer <mcp-token>" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## Production (Mac mini)

1. DNS A record for `pacerunner.brintontech.com` pointed at your public IP.
2. Ports 80 + 443 forwarded → mini.
3. Docker installed.

```bash
git clone <repo> && cd pacerunner-server
docker compose up -d --build
docker compose exec pacerunner-server node dist/admin.js create-user --name "Chris"
docker compose exec pacerunner-server node dist/admin.js create-token --user-id 1 --scope ingest --label "iPhone"
docker compose exec pacerunner-server node dist/admin.js create-token --user-id 1 --scope mcp    --label "coach"
```

Caddy auto-provisions Let's Encrypt on first HTTPS request. Edit `Caddyfile`
to match your domain if it isn't `pacerunner.brintontech.com`.

### Smoke test

```bash
curl https://pacerunner.brintontech.com/health
curl -X POST https://pacerunner.brintontech.com/mcp \
  -H "Authorization: Bearer $MCP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## Operational notes

- `data/` (mounted as `/data` in the container) holds the SQLite DB plus
  per-user `files/<user_id>/{gpx,logs}/`. Backups are a `tar -czf` of `data/`.
- SQLite is in WAL mode; safe to back up while the server is running.
- Rotating a token: `revoke-token` then `create-token` with a new label.
- Per-user data wipe: `npm run admin -- delete-user --id N` (cascades) plus
  `rm -rf data/files/N`.
