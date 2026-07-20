# PaceRunner MCP Server — Pause Event Detection Spec

**Companion to:** `pacerunner_mcp_enhancements.md`, `pacerunner_workout_structure_detection.md`

## Problem

Mid-run pauses (bathroom stops, water fountain refills, waiting at traffic lights, tying a shoe, etc.) are a normal part of long training runs. Currently these show up as a single split with an anomalously long duration, which pollutes rollup metrics without conveying any useful signal about effort or fitness.

The pause is not an effort signal. It's an interruption. Rollup metrics that treat it as effort — `avg_pace_seconds_per_mile`, `pace_stdev_sec`, `drift.pace_sec_per_mile_per_mile`, and the pace components of `first_half`/`second_half` — measure "did anything unusual happen" instead of "how was the run."

## Real example that motivated this

Sun Jul 19, 2026 workout (12.20 mi long run, `id: 04CAB6AB-8B33-4E91-AFE4-3C02300632CC`). Mile 4 had a ~5 min restroom stop inside it. Split durations:

| Split | Duration | Pace | HR |
|---|---|---|---|
| 1 | 640.8s | 10:41 | 118 |
| 2 | 624.6s | 10:25 | 123 |
| 3 | 627.5s | 10:28 | 129 |
| **4** | **970.0s** | **16:10** | **124** |
| 5 | 640.9s | 10:41 | 124 |
| 6 | 632.4s | 10:32 | 127 |
| ... | ... | ... | ... |
| 12 | 624.1s | 10:24 | 131 |

Currently classified as:

```jsonc
{
  "workout_type": "easy",
  "run_quality": "clean",
  "avg_pace_seconds_per_mile": 632.7,
  "split_variability": { "pace_stdev_sec": 97.84 }
}
```

The `pace_stdev_sec: 97.84` is misleading — it's driven entirely by mile 4's outlier. Strip the pause and pace stdev drops to ~9 sec (metronomic). Every other pace-derived metric on this workout is similarly distorted.

## Detection sources

Try in this order, prefer the more reliable signal:

### 1. HealthKit workout events (preferred)

Apple Watch records pause/resume events in the HKWorkout event stream:

- `HKWorkoutEventTypePause` (raw value 2)
- `HKWorkoutEventTypeResume` (raw value 3)

These fire on both manual pauses (user taps pause) and auto-pauses (workout auto-pause enabled + speed drops below threshold). When available, they're ground truth — no inference needed.

The current ingest already sets `has_events: true` on every workout, and the events endpoint exposes 31 "segments" per workout that we haven't fully characterized (see May 31 workout inspection). Worth checking whether pause/resume events are already coming through in the raw event stream under a different type name and just aren't being surfaced.

### 2. Inferred from samples (fallback)

For older workouts, or workouts where HealthKit events aren't available, infer pauses from the sample stream.

Signal for an inferred pause:

- Continuous stretch of `runningSpeed < 0.5 m/s` for `duration ≥ 60 seconds`
- Not within the first 60 seconds of workout start (that's just workout beginning)
- Not within the last 60 seconds of workout end (that's just workout ending)
- Not inside a detected `strides` or `intervals` phase (those have intentional walking recovery)

Thresholds worth tuning against real data; the values above are reasonable v1 starting points. In particular, the 0.5 m/s threshold (~30 min/mi pace) is aggressive enough to exclude actual slow walking but permissive enough to catch "standing at a water fountain."

## Schema

### Add `pause_events` array to `summary`

```jsonc
"summary": {
  // ... existing fields ...

  "pause_events": [
    {
      "start_seconds": 1965,        // seconds from workout start
      "duration_seconds": 297,
      "affected_split_index": 3,    // zero-indexed; matches splits array position
      "source": "healthkit_event"   // "healthkit_event" | "inferred_from_samples"
    }
  ]
}
```

Return an empty array `[]` (not `null`) when no pauses are detected, so clients don't need null-checks.

### Extend affected splits with `moving_*` fields

For splits that contain a pause, add moving-time equivalents alongside the raw elapsed values. Preserve the raw split unchanged — the elapsed duration is true and useful (a runner glancing at their watch really did see 16:10 for that mile).

```jsonc
{
  "split_number": 4,
  "duration_seconds": 970.0,               // unchanged — raw elapsed
  "pace_seconds_per_mile": 970.0,          // unchanged — raw elapsed pace
  "moving_duration_seconds": 673.0,        // NEW — pause subtracted
  "moving_pace_seconds_per_mile": 673.0,   // NEW — moving-time pace
  "avg_heart_rate_bpm": 124,               // unchanged (samples during pause naturally weight down)
  "avg_running_power_watts": 217,          // unchanged
  ...
}
```

For splits with no pause, `moving_duration_seconds` and `moving_pace_seconds_per_mile` should equal the raw values (or be omitted — either works, be consistent).

## Impact on existing metrics

Once pause detection is populated, existing pace-derived metrics should compute on moving time by default, with pause-affected splits excluded from variability and drift calculations.

### Recompute from moving time

- `avg_pace_seconds_per_mile` — use moving duration, not elapsed
- `first_half.avg_pace_seconds_per_mile`, `second_half.avg_pace_seconds_per_mile` — same
- `drift.pace_sec_per_mile_per_mile` — regression should either exclude pause-affected splits, or use `moving_pace_seconds_per_mile` values
- `split_variability.pace_stdev_sec` — exclude pause-affected splits from the stdev calculation

### Leave alone (already based on samples during motion)

- `avg_heart_rate_bpm`, `first_half.avg_heart_rate_bpm`, `second_half.avg_heart_rate_bpm` — HR samples during a pause naturally weight the average down and reflect what actually happened (HR did drop during those 5 min); recomputing on moving-only samples would be misleading
- `avg_running_power_watts` — same reasoning; power samples during pause are legitimately zero-ish
- `hr_to_power_ratio` — same
- `elevation_gain_meters`, `elevation_loss_meters` — you don't lose elevation by pausing

### Expose whole-workout duration correctly

- Add `total_moving_duration_seconds` to summary alongside the existing `duration_seconds`. Both are useful — one is "how long was I out" and the other is "how long was I moving."

### Impact on `run_quality`

Add a new `run_quality_reasons` code: `pause_events_present`. When a run has one or more pause events but is otherwise a clean effort profile (no fade, no HR drift, no genuine degradation signals), it should still classify as `clean` — with `pause_events_present` listed in reasons for transparency. This separates "one bathroom stop" from actual degradation, which are currently indistinguishable in the `split_variability.pace_stdev_sec` signal.

For the Sunday Jul 19 example, the corrected summary should look like:

```jsonc
{
  "run_quality": "clean",
  "run_quality_reasons": ["pause_events_present"],
  "avg_pace_seconds_per_mile": 631,        // was 632.7 — small change since one split dropped ~5 min
  "split_variability": { "pace_stdev_sec": 9.2 },   // was 97.84 — huge change
  "pause_events": [{
    "start_seconds": 1965,
    "duration_seconds": 297,
    "affected_split_index": 3,
    "source": "healthkit_event"
  }]
}
```

## Interaction with `workout_structure`

Pauses are interruptions, not training phases. Do **not** add a `pause` phase type to `workout_structure.phases`. Structure detection should treat pauses as if they weren't there — skip over them when identifying phase boundaries, and don't include their duration in phase durations.

Specifically, when computing phase boundaries or per-phase metrics inside `workout_structure`, work off a "moving-time timeline" that removes pause spans. The `phase.start_seconds` and `phase.end_seconds` fields should probably still reference elapsed-time (to be consistent with `pause_events[].start_seconds`), but phase durations and per-phase averages should be based on moving-time samples only.

## Edge cases

**Strides and intervals recovery periods.** These have intentional near-zero-speed spans between fast segments. Rule: near-zero-speed spans **inside** a detected `strides` or `intervals` phase are recovery, not pauses. Only classify spans in `steady`, `warmup`, `cooldown`, or `tempo` phases as pause events.

**Very short workouts.** For workouts shorter than ~2 miles or ~15 minutes, pause detection is probably not worth running (few splits, high false-positive risk). Reasonable to skip pause detection below some threshold, or just accept it if the data quality is good.

**Multiple pauses in one workout.** Support N pauses, not just one. Long runs with multiple water/bathroom stops are common.

**Pause spanning a split boundary.** A pause could start in split N and end in split N+1. `affected_split_index` should probably become `affected_split_indices` (array) to handle this — or a rule that a pause is attributed to whichever split it started in. Whichever is simpler; document the choice.

**Pauses inside partial (fractional) final splits.** The last split is often less than 1 mile (0.20 mi in the Sunday example). Pause detection should still work on partial splits. `moving_pace_seconds_per_mile` scales the same way.

## Backfill

Pause detection should apply to historical workouts, not just new ones. Every existing long run in the dataset with mysterious pace stdev spikes is likely an undetected pause. Recommend:

1. Ship detection + schema
2. One-time backfill over all existing workouts to populate `pause_events` and recompute affected summary fields
3. New workouts get pause detection at ingest time

Backfill should be idempotent so it can be re-run after threshold tuning.

## Implementation order recommendation

1. **Investigate HealthKit events first.** Before writing sample-inference code, check whether pause/resume events are already flowing through the ingest and just not being exposed. That could turn v1 into a schema-only change plus a small extraction step.
2. **v1: Detection + `pause_events` array + `run_quality` reason.** Minimum useful step — surfaces the data even before rollup metrics change.
3. **v2: Moving-time recompute of rollup metrics.** Update `avg_pace`, `first_half`/`second_half`, `drift`, `split_variability` to use moving time and exclude pause-affected splits. Add `moving_duration_seconds`, `moving_pace_seconds_per_mile` to splits, and `total_moving_duration_seconds` to summary.
4. **v3: Sample-based inference fallback.** For workouts without HealthKit events (older data, other sources).
5. **Backfill.**

## Out of scope for this spec

- Distinguishing intentional pauses (bathroom, water) from unintentional pauses (waiting at a crosswalk) — the data doesn't support this distinction, and it doesn't matter for effort analysis
- Auto-detecting failed workouts vs paused workouts (bonked runs like Sun Jul 5 have a walk phase, not a pause — that's already handled by `workout_type: walk_jog`)
- Exposing pause events in a route visualization (that's a UI concern)
