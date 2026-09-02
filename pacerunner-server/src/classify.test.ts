import { test } from "node:test";
import assert from "node:assert/strict";
import { computeSummary, parsePlannedMiles } from "./summary.js";
import type { IngestSample, SplitForSummary, UserBaseline } from "./summary.js";

// ---------------------------------------------------------------------------
// Planned distance
// ---------------------------------------------------------------------------

test("planned miles are parsed from a config name", () => {
  assert.equal(parsePlannedMiles("5mi Easy"), 5);
  assert.equal(parsePlannedMiles("13.1mi Easy"), 13.1);
  assert.equal(parsePlannedMiles("6mi Recovery"), 6);
});

test("planned miles sum across a compound config name", () => {
  // The real config behind the Jul 28 / Aug 25 runs.
  assert.equal(parsePlannedMiles("1mi Easy + 4mi Tempo"), 5);
});

test("planned miles are null when the name states no distance", () => {
  assert.equal(parsePlannedMiles("Half Marathon"), null);
  assert.equal(parsePlannedMiles("Tempo Progression"), null);
  assert.equal(parsePlannedMiles(null), null);
});

// ---------------------------------------------------------------------------
// Abandoned sessions
// ---------------------------------------------------------------------------

/** Splits that fire the breakdown signals: a big fade plus high variability. */
function collapsingSplits(): SplitForSummary[] {
  const paces = [545, 560, 900];
  return paces.map((pace, i) => ({
    distance_meters: 1609.344,
    duration_seconds: pace,
    pace_seconds_per_mile: pace,
    avg_heart_rate_bpm: 120,
    avg_running_power_watts: i < 2 ? 222 : 171,
    elevation_gain_meters: 0,
    elevation_loss_meters: 0,
  }));
}

function steadySplits(): SplitForSummary[] {
  return [545, 549, 552, 547].map((pace) => ({
    distance_meters: 1609.344,
    duration_seconds: pace,
    pace_seconds_per_mile: pace,
    avg_heart_rate_bpm: 137,
    avg_running_power_watts: 242,
    elevation_gain_meters: 0,
    elevation_loss_meters: 0,
  }));
}

/**
 * Regression: the Aug 25 run. 2.60 mi of a planned "1mi Easy + 4mi Tempo"
 * (52%), run_quality degraded — yet it was reported as tempo at 0.95 and so
 * polluted tempo pace/HR trends.
 */
test("a session cut far short with a degraded execution is reclassified aborted", () => {
  const summary = computeSummary({
    samples: {},
    rawMetadata: undefined,
    totalDistanceMeters: 4177.25, // 2.596 mi of 5 planned
    durationSeconds: 1638,
    splits: collapsingSplits(),
    paceRunnerConfigName: "1mi Easy + 4mi Tempo",
  });

  assert.equal(summary.workout_type, "aborted");
  assert.equal(summary.planned_workout_type, "tempo", "intent must stay readable");
  assert.ok(
    summary.run_quality_reasons.some((r) => r.startsWith("abandoned_")),
    `expected an abandoned_ reason, got ${JSON.stringify(summary.run_quality_reasons)}`
  );
});

test("a short but cleanly executed run is a cutback, not an abort", () => {
  const summary = computeSummary({
    samples: {},
    rawMetadata: undefined,
    totalDistanceMeters: 4177.25,
    durationSeconds: 1638,
    splits: steadySplits(),
    paceRunnerConfigName: "1mi Easy + 4mi Tempo",
  });

  assert.notEqual(summary.workout_type, "aborted");
  assert.equal(summary.workout_type, "tempo");
});

test("a full-distance degraded run is a bad day, not an abort", () => {
  const summary = computeSummary({
    samples: {},
    rawMetadata: undefined,
    totalDistanceMeters: 5 * 1609.344, // the whole planned distance
    durationSeconds: 3000,
    splits: collapsingSplits(),
    paceRunnerConfigName: "1mi Easy + 4mi Tempo",
  });

  assert.notEqual(summary.workout_type, "aborted");
  assert.equal(summary.workout_type, "tempo");
});

test("without a planned distance the abandoned check cannot fire", () => {
  const summary = computeSummary({
    samples: {},
    rawMetadata: undefined,
    totalDistanceMeters: 1000,
    durationSeconds: 1638,
    splits: collapsingSplits(),
    paceRunnerConfigName: "Tempo Progression",
  });

  assert.notEqual(summary.workout_type, "aborted");
});

// ---------------------------------------------------------------------------
// Indoor classification
// ---------------------------------------------------------------------------

function hrSamples(bpm: number, count: number): IngestSample[] {
  const base = Date.parse("2026-08-21T11:11:25Z");
  return Array.from({ length: count }, (_, i) => ({
    start: new Date(base + i * 1000).toISOString(),
    end: new Date(base + i * 1000).toISOString(),
    value: bpm,
    unit: "count/min",
  }));
}

/** This runner's real profile: recent runs average 121–137 bpm, and their
 *  observed max (153) is just their hardest easy run, not a true max. */
const baseline: UserBaseline = {
  observed_max_hr_bpm: 153,
  median_workout_miles_30d: 6.1,
  median_easy_pace_seconds_per_mile_30d: 645,
  median_run_hr_bpm_30d: 129,
};

/**
 * Regression: the Aug 21 indoor run. 121 bpm — below this runner's own
 * recovery-run HR — was labeled tempo at 0.90, because 0.7 x observed max
 * (153) puts the zone-3 floor at ~107 and the whole run sat above it.
 */
test("an easy-HR indoor run is not called tempo", () => {
  const summary = computeSummary({
    samples: { heartRate: hrSamples(121, 600) },
    rawMetadata: undefined,
    totalDistanceMeters: 9865,
    durationSeconds: 3959,
    baseline,
    isIndoor: true,
  });

  assert.notEqual(summary.workout_type, "tempo");
  assert.equal(summary.workout_type, "easy");
});

test("indoor confidence is capped — pace and power are missing", () => {
  const summary = computeSummary({
    samples: { heartRate: hrSamples(121, 600) },
    rawMetadata: undefined,
    totalDistanceMeters: 9865,
    durationSeconds: 3959,
    baseline,
    isIndoor: true,
  });

  assert.ok(
    summary.workout_type_confidence !== null && summary.workout_type_confidence <= 0.65,
    `indoor confidence should be capped, got ${summary.workout_type_confidence}`
  );
});

test("a genuinely hard indoor run is still called tempo", () => {
  const summary = computeSummary({
    samples: { heartRate: hrSamples(147, 600) }, // 1.14x habitual
    rawMetadata: undefined,
    totalDistanceMeters: 9865,
    durationSeconds: 3000,
    baseline,
    isIndoor: true,
  });

  assert.equal(summary.workout_type, "tempo");
});

test("an indoor run below habitual HR is a recovery run", () => {
  const summary = computeSummary({
    samples: { heartRate: hrSamples(110, 600) }, // 0.85x habitual
    rawMetadata: undefined,
    totalDistanceMeters: 5000,
    durationSeconds: 2000,
    baseline,
    isIndoor: true,
  });

  assert.equal(summary.workout_type, "recovery");
});

test("the same HR outdoors still uses the pace-aware classifier", () => {
  // Guards against the indoor branch leaking into outdoor runs.
  const summary = computeSummary({
    samples: { heartRate: hrSamples(121, 600) },
    rawMetadata: undefined,
    totalDistanceMeters: 9865,
    durationSeconds: 3959,
    baseline,
    isIndoor: false,
  });

  assert.ok(
    summary.workout_type_confidence === null || summary.workout_type_confidence > 0.65,
    "outdoor runs are not subject to the indoor confidence cap"
  );
});

test("indoor classification without HR history does not guess tempo", () => {
  const summary = computeSummary({
    samples: { heartRate: hrSamples(121, 600) },
    rawMetadata: undefined,
    totalDistanceMeters: 9865,
    durationSeconds: 3959,
    baseline: {
      observed_max_hr_bpm: 153,
      median_workout_miles_30d: null,
      median_easy_pace_seconds_per_mile_30d: null,
      median_run_hr_bpm_30d: null,
    },
    isIndoor: true,
  });

  assert.notEqual(summary.workout_type, "tempo");
});
