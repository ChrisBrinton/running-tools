# PaceRunner MCP Server — Enhancement Spec

**Goal:** Reduce context consumption when analyzing training data with Claude by moving aggregation and derived metrics server-side. Workout-level computations are cheap on the server but expensive in chat context (every sample/split row consumed must travel through context, get parsed, and recomputed each conversation).

**Prioritization principle:** Highest ratio of analytical value to implementation effort first. Tier 1 alone probably eliminates 60%+ of routine context usage; Tiers 2-4 are progressively more nice-to-have.

---

## Tier 1 — Extend the existing `summary` object

Add derived metrics to the existing `summary` object returned by `list_workouts` and `get_workout` (with `fields=["metadata"]`). All fields below are computable from existing samples/splits, no new data inputs.

### Proposed schema additions

```jsonc
"summary": {
  // ... existing fields (avg_heart_rate_bpm, max_heart_rate_bpm, etc.) ...

  // Core derived metric — single most useful number for tracking aerobic fitness
  "hr_to_power_ratio": 0.58,

  // Half-by-half summary — answers "did they negative split?" in one comparison
  "first_half": {
    "avg_hr_bpm": 122,
    "avg_running_power_watts": 218,
    "avg_pace_seconds_per_mile": 631,
    "avg_cadence_spm": 156
  },
  "second_half": {
    "avg_hr_bpm": 128,
    "avg_running_power_watts": 212,
    "avg_pace_seconds_per_mile": 644,
    "avg_cadence_spm": 154
  },

  // Drift metrics — linear regression slope across splits (mile 1 → mile N)
  "drift": {
    "hr_bpm_per_mile": 2.1,
    "pace_sec_per_mile_per_mile": 1.5,
    "power_w_per_mile": -1.3,
    "cadence_spm_per_mile": -0.3
  },

  // Split-level variability — detects unsteady efforts
  "split_variability": {
    "pace_stdev_sec": 12.3,
    "hr_stdev_bpm": 4.1,
    "power_stdev_w": 8.2
  }
}
```

### Implementation notes

- **`hr_to_power_ratio`** = `avg_heart_rate_bpm / avg_running_power_watts`. Skip computation (return null) for workouts with no power data (older devices, indoor treadmill).
- **`first_half` / `second_half`** = compute over splits 1..floor(N/2) and ceil(N/2)+1..N. For runs with odd number of splits, exclude the middle split or split it proportionally. For runs with cool-down splits much shorter than a mile (like the 0.22 mi cooldown on 6/21), exclude splits < 0.5 mile from the half-half calculation — they distort the averages.
- **`drift`** = linear regression slope using split midpoint as x-axis (mile 0.5, 1.5, 2.5, ...) and the metric as y-axis. Again, exclude partial cool-down splits from the regression. Units are "per mile" not "per split" — keeps the metric stable regardless of split unit.
- **`split_variability`** = standard deviation across full-distance splits only. Exclude partial splits.

### Bug fix to include

- `elevation_loss_meters` in `summary` is currently always `null` even when splits have populated loss data. The rollup should sum split-level elevation loss the same way it sums gain.

---

## Tier 2 — Workout auto-classification

Add a `workout_type` field to `summary` (and as a filter parameter to `list_workouts`).

### Proposed schema addition

```jsonc
"summary": {
  // ...
  "workout_type": "easy",     // one of: easy | moderate | long | tempo | recovery | race | walk_jog
  "workout_type_confidence": 0.85   // 0-1, lets clients decide whether to trust the label
}
```

### Classification heuristics (suggested starting point)

These are reasonable defaults to start with; expect to tune over time based on observed misclassifications.

| Label | Criteria |
|---|---|
| `race` | Distance ≥ 13.0 mi AND avg HR ≥ 85% of max HR (or top 1% of avg HR observed in user's history) |
| `long` | Distance ≥ 1.5× the user's median weekly run distance over the last 30 days |
| `tempo` | Avg HR in zone 3-4 (70-85% of max HR) for ≥ 50% of the run, AND not classified as `long` |
| `recovery` | Avg HR < 65% of max HR AND avg pace > 20% slower than user's 30-day median easy pace |
| `walk_jog` | Avg pace > 13:00/mi (configurable threshold) |
| `easy` | Default for runs not matching above and distance < long-run threshold |
| `moderate` | Catch-all for runs that don't fit cleanly (e.g., medium-long, fartlek) |

### Implementation notes

- Max HR estimate needs to come from somewhere. Options: (a) static formula like 220 - age (crude), (b) the user's observed max HR across all workouts (better, self-calibrating), (c) user-configurable in settings. Recommend (b) with optional override in user settings.
- 30-day rolling baselines (median weekly run distance, median easy pace) should be recomputed periodically or on each new workout ingest.
- Allow user-supplied notes/labels (Tier 5 below) to override the auto-classification when present.
- Add `workout_type` as an optional filter on `list_workouts`: `?workout_type=easy` or `?workout_type=long,tempo`.

---

## Tier 3 — Weekly summary endpoint

New tool: `get_weekly_summaries`.

### Signature

```
get_weekly_summaries(since: ISO date, until: ISO date, week_start_day: "monday" | "sunday" = "monday")
```

### Response shape

```jsonc
{
  "count": 9,
  "weeks": [
    {
      "week_start": "2026-05-25",
      "week_end": "2026-05-31",
      "total_miles": 28.7,
      "total_duration_seconds": 17582,
      "run_count": 4,
      "longest_run_miles": 11.2,
      "longest_run_id": "207DF3DA-2C30-4706-B4F2-0BD1090906D9",
      "weekly_avg_pace_seconds_per_mile": 624,
      "weekly_avg_heart_rate_bpm": 130,
      "weekly_avg_hr_to_power_ratio": 0.60,
      "weekly_avg_running_power_watts": 218,
      "total_elevation_gain_meters": 380,
      "avg_temp_f": 67,
      "max_temp_f": 78,
      "min_temp_f": 58,
      "workout_breakdown": {
        "easy": 3,
        "long": 1,
        "tempo": 0,
        "recovery": 0,
        "race": 0
      }
    },
    // ... one entry per week
  ]
}
```

### Implementation notes

- Weighted averages (by distance, not by run count) for pace, HR, power. A 3-mile recovery jog and an 11-mile long run shouldn't be equally weighted in the weekly average pace.
- For weeks with no runs, return the week entry with zeros rather than skipping it. Gaps are informative.
- `weekly_avg_hr_to_power_ratio` should average each run's ratio weighted by distance. This is the primary fitness-trend metric across weeks.
- `workout_breakdown` requires Tier 2 (workout_type) to be implemented. If Tier 2 isn't ready yet, ship Tier 3 without `workout_breakdown` and add it later.

---

## Tier 4 — Trend tools (nice-to-have)

New tool: `get_metric_trend`.

### Signature

```
get_metric_trend(
  metric: string,              // e.g., "hr_to_power_ratio", "weekly_mileage", "easy_pace_avg_hr"
  since: ISO date,
  until: ISO date,
  workout_filter?: { workout_type?: string, min_distance_miles?: number, ... },
  granularity?: "workout" | "weekly" = "weekly"
)
```

### Response shape

```jsonc
{
  "metric": "hr_to_power_ratio",
  "granularity": "weekly",
  "points": [
    { "date": "2026-05-25", "value": 0.60, "n_workouts": 4 },
    { "date": "2026-06-01", "value": 0.61, "n_workouts": 3 },
    { "date": "2026-06-22", "value": 0.63, "n_workouts": 2 }
  ],
  "regression": {
    "slope_per_week": 0.008,
    "r_squared": 0.42,
    "trend_direction": "worsening",
    "interpretation": "HR/power ratio increasing — possible detraining or accumulated fatigue"
  }
}
```

### Implementation notes

- Start with a small fixed list of supported metrics rather than a fully generic query system. Suggested initial set: `hr_to_power_ratio`, `weekly_mileage`, `easy_pace_avg_hr`, `long_run_distance`, `tempo_pace_avg`.
- Regression interpretation is optional and a bit subjective — could be skipped on first pass.
- This tier mostly benefits open-ended "how am I trending" questions. If chat usage is mostly week-over-week comparison rather than long-term trend analysis, this tier may not be worth implementing immediately.

---

## Tier 5 — User-supplied workout context (future)

This requires UI work in the PaceRunner app (or API endpoints for an external client) to let the user attach notes, RPE, and explicit labels to workouts. Not strictly an MCP server change but should be considered as the data path completes the picture.

### Proposed schema

```jsonc
"user_context": {
  "label": "long_run",              // user override of workout_type
  "rpe": 6,                          // 1-10 perceived effort
  "notes": "first run back from vacation, midday heat killed me",
  "tags": ["heat", "post-vacation"],
  "planned_distance_miles": 8,       // for "did I hit the plan" comparison
  "planned_workout_type": "easy"
}
```

### Implementation notes

- Need an `update_workout_context` MCP tool to write back to the server.
- Once present, this overrides Tier 2 auto-classification for `workout_type` in queries.
- Tags would enable powerful filtering ("show me all runs tagged 'heat'").

---

## Implementation order recommendation

1. **Tier 1 + elevation_loss bug fix.** Highest immediate value, smallest scope. Should be doable in one pass — all computations are over data already in samples/splits.
2. **Tier 2 (auto-classification).** Modest scope, unlocks filtered queries and the workout_breakdown field in Tier 3.
3. **Tier 3 (weekly summaries).** Builds on Tier 1/2 outputs.
4. **Tier 5 (user notes/labels).** Requires app-side work; can be in parallel with Tiers 2-3.
5. **Tier 4 (trend tools).** Last because Tiers 1-3 already cover most analytical use cases.

## Out of scope (for now)

- Per-sample altitude in summary (route_gpx already has elevation in waypoint data; can be parsed when needed)
- Forecast weather alongside actuals (would require external data ingestion)
- Multi-user/coach views (single-user system)
- Caching layer for derived metrics — recompute on read is fine until performance becomes a real issue
