import { test } from "node:test";
import assert from "node:assert/strict";
import { detectWorkoutStructure } from "./structure.js";
import type { IngestSample, IngestSamples } from "./summary.js";

/**
 * Synthetic sample-stream builder. Emits one power + speed + distance +
 * heartRate sample per second over a list of [durationSec, watts] segments,
 * so tests read like a workout profile. Speed and distance are derived from a
 * fixed power→speed map (higher power = faster) purely so the streams are
 * self-consistent; detection keys off power.
 */
function build(segments: Array<[number, number]>): {
  samples: IngestSamples;
  durationSeconds: number;
} {
  const power: IngestSample[] = [];
  const speed: IngestSample[] = [];
  const dist: IngestSample[] = [];
  const hr: IngestSample[] = [];
  const base = Date.parse("2026-07-08T11:00:00Z");
  let t = 0;
  for (const [dur, watts] of segments) {
    for (let i = 0; i < dur; i++) {
      const iso = new Date(base + t * 1000).toISOString();
      const mps = watts < 120 ? 1.0 : 1.0 + (watts - 120) / 120; // walk≈1, 216W≈1.8, 400W≈3.3
      power.push({ start: iso, end: iso, value: watts, unit: "W" });
      speed.push({ start: iso, end: iso, value: mps, unit: "m/s" });
      dist.push({ start: iso, end: iso, value: mps, unit: "m" });
      hr.push({ start: iso, end: iso, value: watts < 120 ? 110 : 135, unit: "count/min" });
      t++;
    }
  }
  return {
    samples: { runningPower: power, runningSpeed: speed, distanceWalkingRunning: dist, heartRate: hr },
    durationSeconds: t,
  };
}

test("detects an easy run with 4 strides at the end", () => {
  // 50 min steady @216W, walk-rest, then 4× (15s @400W, 60s walk-rest).
  const segments: Array<[number, number]> = [[3000, 216], [120, 90]];
  for (let i = 0; i < 4; i++) {
    segments.push([15, 400]);
    segments.push([60, 90]);
  }
  const { samples, durationSeconds } = build(segments);
  const r = detectWorkoutStructure({ samples, durationSeconds });
  assert.ok(r, "structure should be detected");
  assert.equal(r!.has_strides, true);
  const strides = r!.phases.find((p) => p.phase === "strides");
  assert.ok(strides, "a strides phase should exist");
  assert.equal(strides!.reps, 4);
  assert.ok(strides!.peak_stride_power_watts! >= 350);
  // Core ends before the stride block begins (steady was 3000s).
  assert.ok(r!.core_end_seconds <= 3200, `core_end ${r!.core_end_seconds} should precede strides`);
  assert.ok(r!.detection_confidence >= 0.8);
});

test("a plain steady run has no structure", () => {
  const { samples, durationSeconds } = build([[3600, 216]]);
  const r = detectWorkoutStructure({ samples, durationSeconds });
  assert.equal(r, null);
});

test("isolated steady-embedded power blips are not strides", () => {
  // Steady run with a single ~305W blip every ~7 min, embedded in steady
  // running (no walk-rest around them) — the Apple Watch power artifact.
  const segments: Array<[number, number]> = [];
  for (let i = 0; i < 6; i++) {
    segments.push([420, 216]);
    segments.push([8, 305]);
  }
  const { samples, durationSeconds } = build(segments);
  const r = detectWorkoutStructure({ samples, durationSeconds });
  assert.equal(r, null, "blips embedded in steady running must not read as strides");
});

test("a bonked run (long trailing walks, no burst cluster) is not structured", () => {
  // Steady, then it falls apart into long walks — no fast bursts at the end.
  const { samples, durationSeconds } = build([[2400, 200], [1800, 85]]);
  const r = detectWorkoutStructure({ samples, durationSeconds });
  // No stride cluster; a lone trailing walk isn't enough to call it structured
  // unless it lands in the warmup/cooldown band — either way, no strides.
  if (r) assert.equal(r.has_strides, false);
});

test("late run-walk surges during a bonk are not mistaken for strides", () => {
  // 40 min steady @210W, then it falls apart: alternating slow jog surges
  // (90s @ ~250W — only ~1.2× core, and long) and walks near the end. These
  // are NOT strides: too long and not hard enough to clear the stride power bar.
  const segments: Array<[number, number]> = [[2400, 210]];
  for (let i = 0; i < 4; i++) {
    segments.push([90, 250]);
    segments.push([90, 88]);
  }
  const { samples, durationSeconds } = build(segments);
  const r = detectWorkoutStructure({ samples, durationSeconds });
  if (r) assert.equal(r.has_strides, false, "long moderate surges must not read as strides");
});

test("a walk-dominant low-power workout is not classified as structured", () => {
  // Mostly walking (~70W) with a little jogging — median power is too low to
  // band reliably, so detection bails rather than calling jogging 'tempo'.
  const { samples, durationSeconds } = build([[1800, 70], [600, 130], [1200, 70]]);
  const r = detectWorkoutStructure({ samples, durationSeconds });
  assert.equal(r, null);
});

/** Build a workout from a list of per-mile split paces (s/mi), with a matching
 *  steady-ish power stream so t0/corePower/duration are valid. Power tracks the
 *  splits loosely (faster split → a bit more power) but stays well under the
 *  stride bar, so only tempo (split-based) detection can fire. */
function buildFromSplitPaces(splitPaces: number[]): {
  samples: IngestSamples;
  durationSeconds: number;
  splits: SplitForSummaryLike[];
} {
  const base = Date.parse("2026-07-08T11:00:00Z");
  const power: IngestSample[] = [];
  const speed: IngestSample[] = [];
  const dist: IngestSample[] = [];
  const hr: IngestSample[] = [];
  const SPLIT = 600;
  const total = splitPaces.length * SPLIT;
  for (let t = 0; t < total; t++) {
    const iso = new Date(base + t * 1000).toISOString();
    const idx = Math.floor(t / SPLIT);
    const watts = 200 + Math.max(0, 640 - splitPaces[idx]) * 0.4;
    power.push({ start: iso, end: iso, value: watts, unit: "W" });
    speed.push({ start: iso, end: iso, value: 2.5, unit: "m/s" });
    dist.push({ start: iso, end: iso, value: 2.5, unit: "m" });
    hr.push({ start: iso, end: iso, value: 140, unit: "count/min" });
  }
  const splits = splitPaces.map((pace, i) => ({
    distance_meters: 1609.344,
    duration_seconds: SPLIT,
    pace_seconds_per_mile: pace,
    avg_heart_rate_bpm: 140,
    avg_running_power_watts: 210,
    elevation_gain_meters: 0,
    elevation_loss_meters: 0,
    start_time: new Date(base + i * SPLIT * 1000).toISOString(),
    end_time: new Date(base + (i + 1) * SPLIT * 1000).toISOString(),
  }));
  return {
    samples: { runningPower: power, runningSpeed: speed, distanceWalkingRunning: dist, heartRate: hr },
    durationSeconds: total,
    splits,
  };
}
type SplitForSummaryLike = NonNullable<Parameters<typeof detectWorkoutStructure>[0]["splits"]>[number];

test("detects a tempo block bracketed by easy running", () => {
  // easy, easy, tempo, tempo, tempo, easy(cooldown)
  const w = buildFromSplitPaces([640, 635, 545, 545, 545, 640]);
  const r = detectWorkoutStructure(w);
  assert.ok(r, "structure should be detected");
  const core = r!.phases[r!.core_phase_index];
  assert.equal(core.phase, "tempo");
  assert.equal(r!.has_strides, false);
});

test("a flat easy run has no tempo structure", () => {
  const w = buildFromSplitPaces([625, 630, 628, 632, 626, 629]);
  assert.equal(detectWorkoutStructure(w), null);
});

test("a run with a walking split is not called tempo (bonk/run-walk)", () => {
  // A fast stretch but a walking split present → detectTempo bails.
  const w = buildFromSplitPaces([640, 545, 545, 900, 640, 640]);
  const r = detectWorkoutStructure(w);
  if (r) assert.notEqual(r.phases[r.core_phase_index].phase, "tempo");
});

test("returns null without a power stream", () => {
  assert.equal(detectWorkoutStructure({ samples: {}, durationSeconds: 1800 }), null);
  assert.equal(detectWorkoutStructure({ samples: undefined, durationSeconds: 1800 }), null);
});

/**
 * Build a workout from realistic per-mile splits: each entry is
 * [paceSecondsPerMile, distanceMiles], so split durations vary the way a real
 * run's do (a trailing partial mile is shorter in both axes). Power tracks pace
 * loosely and stays well under the stride bar so only tempo detection can fire.
 */
function buildFromRealSplits(spec: Array<[number, number]>): {
  samples: IngestSamples;
  durationSeconds: number;
  splits: SplitForSummaryLike[];
} {
  const base = Date.parse("2026-07-28T10:46:53.000Z");
  const power: IngestSample[] = [];
  const speed: IngestSample[] = [];
  const dist: IngestSample[] = [];
  const hr: IngestSample[] = [];
  const splits: SplitForSummaryLike[] = [];

  let elapsed = 0;
  for (const [pace, miles] of spec) {
    const dur = Math.round(pace * miles);
    const meters = miles * 1609.344;
    const mps = meters / dur;
    const watts = 200 + Math.max(0, 640 - pace) * 0.4;
    splits.push({
      distance_meters: meters,
      duration_seconds: dur,
      pace_seconds_per_mile: pace,
      avg_heart_rate_bpm: 140,
      avg_running_power_watts: Math.round(watts),
      elevation_gain_meters: 0,
      elevation_loss_meters: 0,
      start_time: new Date(base + elapsed * 1000).toISOString(),
      end_time: new Date(base + (elapsed + dur) * 1000).toISOString(),
    });
    for (let i = 0; i < dur; i++) {
      // Power samples start 1s after the workout, reproducing the real t0 skew
      // that used to surface as a negative start_seconds.
      const iso = new Date(base + (elapsed + i + 1) * 1000).toISOString();
      power.push({ start: iso, end: iso, value: watts, unit: "W" });
      speed.push({ start: iso, end: iso, value: mps, unit: "m/s" });
      dist.push({ start: iso, end: iso, value: mps, unit: "m" });
      hr.push({ start: iso, end: iso, value: 140, unit: "count/min" });
    }
    elapsed += dur;
  }

  return {
    samples: { runningPower: power, runningSpeed: speed, distanceWalkingRunning: dist, heartRate: hr },
    durationSeconds: elapsed,
    splits,
  };
}

/**
 * Regression: the Jul 28 "1mi Easy + 4mi Tempo" run. Real split paces. The
 * trailing 0.51 mi cooldown at 774 s/mi is the slowest split, so it drags the
 * easy baseline (median of the slowest 40%) up to ~696 — high enough that the
 * 618 s/mi warmup mile cleared the 666 threshold and got swallowed into the
 * tempo block, which then reported the whole 5 miles as tempo.
 */
test("a leading warmup mile is not swallowed into the tempo block", () => {
  const w = buildFromRealSplits([
    [618, 1.0],    // warmup
    [547.1, 1.0],  // tempo
    [561.5, 1.0],
    [552, 1.0],
    [549.5, 1.0],
    [774.2, 0.5126], // cooldown
  ]);
  const r = detectWorkoutStructure(w);
  assert.ok(r, "structure should be detected");

  const warmup = r!.phases.find((p) => p.phase === "warmup");
  assert.ok(warmup, "the easy first mile should be its own warmup phase");

  const core = r!.phases[r!.core_phase_index];
  assert.equal(core.phase, "tempo");
  assert.ok(
    core.start_seconds >= 600,
    `tempo should start after the warmup mile, got ${core.start_seconds}`
  );
  assert.ok(
    core.distance_miles !== null && core.distance_miles < 4.6,
    `tempo should cover ~4 mi, not the whole run (got ${core.distance_miles})`
  );
});

test("phase clocks are never negative", () => {
  const w = buildFromRealSplits([
    [618, 1.0],
    [547.1, 1.0],
    [561.5, 1.0],
    [552, 1.0],
    [549.5, 1.0],
    [774.2, 0.5126],
  ]);
  const r = detectWorkoutStructure(w);
  assert.ok(r);
  assert.ok(r!.core_start_seconds >= 0, `core_start_seconds ${r!.core_start_seconds}`);
  for (const p of r!.phases) {
    assert.ok(p.start_seconds >= 0, `${p.phase} start_seconds ${p.start_seconds}`);
    assert.ok(p.end_seconds >= 0, `${p.phase} end_seconds ${p.end_seconds}`);
  }
});

test("a genuinely fast opening mile is still part of the tempo block", () => {
  // No slow warmup — the run opens at effort. The trim must not fire.
  const w = buildFromRealSplits([
    [548, 1.0],
    [547, 1.0],
    [561, 1.0],
    [552, 1.0],
    [549, 1.0],
    [774, 0.5126],
  ]);
  const r = detectWorkoutStructure(w);
  assert.ok(r);
  const core = r!.phases[r!.core_phase_index];
  assert.equal(core.phase, "tempo");
  assert.ok(
    core.start_seconds < 300,
    `tempo should start at the gun, got ${core.start_seconds}`
  );
});

test("stride pace measures the bursts, not the walking recovery", () => {
  const segments: Array<[number, number]> = [[3000, 216], [120, 90]];
  for (let i = 0; i < 4; i++) {
    segments.push([15, 400]);
    segments.push([60, 90]);
  }
  const { samples, durationSeconds } = build(segments);
  const r = detectWorkoutStructure({ samples, durationSeconds });
  assert.ok(r);
  const strides = r!.phases.find((p) => p.phase === "strides");
  assert.ok(strides);

  const stridePace = strides!.avg_stride_pace_seconds_per_mile;
  assert.ok(stridePace != null, "stride pace should be populated, not null");
  // The phase average spans the walk rests and so reads far slower; the stride
  // pace must reflect the fast portion only.
  assert.ok(
    stridePace! < strides!.avg_pace_seconds_per_mile!,
    `stride pace ${stridePace} should be faster than the phase average ${strides!.avg_pace_seconds_per_mile}`
  );
});
