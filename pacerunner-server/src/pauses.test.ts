import { test } from "node:test";
import assert from "node:assert/strict";
import {
  pauseIntervalsFromEvents,
  movingTimeForSplit,
  detectPauses,
} from "./pauses.js";
import { computeSummary, type SplitForSummary } from "./summary.js";

const MILE = 1609.344;

test("pauseIntervalsFromEvents pairs pause -> resume", () => {
  const ivs = pauseIntervalsFromEvents(
    [
      { type: "segment", start: "2026-07-19T11:20:00Z", duration_seconds: 100 },
      { type: "pause", start: "2026-07-19T11:50:17Z", duration_seconds: 0 },
      { type: "resume", start: "2026-07-19T11:55:53Z", duration_seconds: 0 },
    ],
    null
  );
  assert.equal(ivs.length, 1);
  assert.equal((ivs[0].endMs - ivs[0].startMs) / 1000, 336);
});

test("an unpaired pause is closed at workout end", () => {
  const end = Date.parse("2026-07-19T12:00:00Z");
  const ivs = pauseIntervalsFromEvents(
    [{ type: "pause", start: "2026-07-19T11:58:00Z", duration_seconds: 0 }],
    end
  );
  assert.equal(ivs.length, 1);
  assert.equal((ivs[0].endMs - ivs[0].startMs) / 1000, 120);
});

test("two separate pauses yield two intervals", () => {
  const ivs = pauseIntervalsFromEvents(
    [
      { type: "pause", start: "2026-07-19T11:30:00Z", duration_seconds: 0 },
      { type: "resume", start: "2026-07-19T11:31:00Z", duration_seconds: 0 },
      { type: "pause", start: "2026-07-19T11:50:00Z", duration_seconds: 0 },
      { type: "resume", start: "2026-07-19T11:55:00Z", duration_seconds: 0 },
    ],
    null
  );
  assert.equal(ivs.length, 2);
  assert.equal((ivs[0].endMs - ivs[0].startMs) / 1000, 60);
  assert.equal((ivs[1].endMs - ivs[1].startMs) / 1000, 300);
});

test("adjacent pause pairs merge into one interval", () => {
  const ivs = pauseIntervalsFromEvents(
    [
      { type: "pause", start: "2026-07-19T11:50:00Z", duration_seconds: 0 },
      { type: "resume", start: "2026-07-19T11:52:00Z", duration_seconds: 0 },
      { type: "pause", start: "2026-07-19T11:52:00Z", duration_seconds: 0 },
      { type: "resume", start: "2026-07-19T11:53:00Z", duration_seconds: 0 },
    ],
    null
  );
  assert.equal(ivs.length, 1);
  assert.equal((ivs[0].endMs - ivs[0].startMs) / 1000, 180);
});

test("movingTimeForSplit subtracts the overlapping pause", () => {
  const split = {
    start_time: "2026-07-19T11:46:10Z",
    end_time: "2026-07-19T12:02:20Z", // 970s elapsed
    duration_seconds: 970,
    distance_meters: 1609.3,
  };
  const iv = pauseIntervalsFromEvents(
    [
      { type: "pause", start: "2026-07-19T11:50:17Z", duration_seconds: 0 },
      { type: "resume", start: "2026-07-19T11:55:53Z", duration_seconds: 0 },
    ],
    null
  );
  const m = movingTimeForSplit(split, iv);
  assert.equal(Math.round(m.moving_duration_seconds), 634);
  assert.ok(Math.abs((m.moving_pace_seconds_per_mile ?? 0) - 634) < 2);
});

test("a pause inside a strides recovery window is not counted", () => {
  const iv = pauseIntervalsFromEvents(
    [
      { type: "pause", start: "2026-07-19T11:10:30Z", duration_seconds: 0 },
      { type: "resume", start: "2026-07-19T11:11:40Z", duration_seconds: 0 },
    ],
    null
  );
  const { pauseEvents, intervals } = detectPauses({
    intervals: iv,
    splits: [{ start_time: "2026-07-19T11:00:00Z", end_time: "2026-07-19T11:30:00Z" }],
    workoutStartMs: Date.parse("2026-07-19T11:00:00Z"),
    recoveryWindows: [{ startSeconds: 600, endSeconds: 900 }], // 10–15 min = strides
  });
  assert.equal(pauseEvents.length, 0);
  assert.equal(intervals.length, 0);
});

/**
 * Integration: reproduce the real Jul 19 2026 long run (id 04CAB6AB…). Mile 4
 * elapsed = 970s because it contains a ~336s restroom stop. Before the fix,
 * pace stdev across full splits is ~98s (driven entirely by mile 4). After,
 * split pace metrics run on moving time and the stdev collapses to single digits.
 */
test("real pause workout: stdev collapses, pause surfaced, quality stays clean", () => {
  const start = Date.parse("2026-07-19T11:14:36Z");
  // Elapsed split durations from the live workout; mile 4 includes the pause.
  const durations = [641, 625, 628, 970, 641, 632, 636, 637, 631, 644, 617, 624, 128];
  const distances = durations.map((_, i) => (i === durations.length - 1 ? 324 : 1609.3));

  const splits: SplitForSummary[] = [];
  let t = start;
  durations.forEach((dur, i) => {
    const s = new Date(t).toISOString();
    const e = new Date(t + dur * 1000).toISOString();
    splits.push({
      distance_meters: distances[i],
      duration_seconds: dur,
      pace_seconds_per_mile: dur / (distances[i] / MILE),
      avg_heart_rate_bpm: 124,
      avg_running_power_watts: 217,
      elevation_gain_meters: 0,
      elevation_loss_meters: 0,
      start_time: s,
      end_time: e,
    });
    t += dur * 1000;
  });

  // Pause fully inside split index 3 (mile 4): starts 247s in, lasts 336s.
  const pauseStart = new Date(Date.parse(splits[3].start_time!) + 247_000).toISOString();
  const resume = new Date(Date.parse(pauseStart) + 336_000).toISOString();
  const movingDuration = durations.reduce((a, b) => a + b, 0) - 336;

  const summary = computeSummary({
    samples: undefined,
    rawMetadata: undefined,
    totalDistanceMeters: distances.reduce((a, b) => a + b, 0),
    durationSeconds: movingDuration,
    splits,
    events: [
      { type: "pause", start: pauseStart, duration_seconds: 0 },
      { type: "resume", start: resume, duration_seconds: 0 },
    ],
  });

  // Pause surfaced, attributed to mile 4 (index 3).
  assert.equal(summary.pause_events.length, 1);
  assert.equal(summary.pause_events[0].affected_split_index, 3);
  assert.equal(Math.round(summary.pause_events[0].duration_seconds), 336);
  assert.equal(summary.pause_events[0].source, "healthkit_event");

  // The whole point: variability is now single-digit, not ~98.
  assert.ok(
    (summary.split_variability?.pace_stdev_sec ?? 999) < 20,
    `expected moving-time stdev < 20, got ${summary.split_variability?.pace_stdev_sec}`
  );

  // Durations expose both clocks and differ by the pause.
  assert.equal(summary.total_moving_duration_seconds, movingDuration);
  assert.ok(
    Math.abs((summary.total_elapsed_duration_seconds ?? 0) - (movingDuration + 336)) < 1
  );

  // A single bathroom stop isn't degradation.
  assert.equal(summary.run_quality, "clean");
  assert.ok(summary.run_quality_reasons.includes("pause_events_present"));
});

test("no events => byte-for-byte identical split metrics (no regression)", () => {
  const start = Date.parse("2026-07-19T11:14:36Z");
  const durations = [640, 625, 630, 635, 628, 631];
  const splits: SplitForSummary[] = [];
  let t = start;
  for (const dur of durations) {
    const s = new Date(t).toISOString();
    const e = new Date(t + dur * 1000).toISOString();
    splits.push({
      distance_meters: 1609.3,
      duration_seconds: dur,
      pace_seconds_per_mile: dur / (1609.3 / MILE),
      avg_heart_rate_bpm: 130,
      avg_running_power_watts: 220,
      elevation_gain_meters: 0,
      elevation_loss_meters: 0,
      start_time: s,
      end_time: e,
    });
    t += dur * 1000;
  }
  const summary = computeSummary({
    samples: undefined,
    rawMetadata: undefined,
    totalDistanceMeters: 1609.3 * durations.length,
    durationSeconds: durations.reduce((a, b) => a + b, 0),
    splits,
  });
  assert.deepEqual(summary.pause_events, []);
  assert.equal(
    summary.total_moving_duration_seconds,
    summary.total_elapsed_duration_seconds
  );
});
