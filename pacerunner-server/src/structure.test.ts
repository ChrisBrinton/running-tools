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

test("returns null without a power stream", () => {
  assert.equal(detectWorkoutStructure({ samples: {}, durationSeconds: 1800 }), null);
  assert.equal(detectWorkoutStructure({ samples: undefined, durationSeconds: 1800 }), null);
});
