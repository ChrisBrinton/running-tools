/**
 * Mid-run pause detection.
 *
 * A mid-run pause (bathroom, water fountain, traffic light) is an interruption,
 * not effort. It should not pollute pace-derived rollups. On the Apple Watch it
 * shows up as a `pause`/`resume` event pair in the workout event stream, so no
 * inference is needed when those events are present (see the companion spec,
 * `pacerunner_pause_detection.md`).
 *
 * Clock note (verified against real data): the workout's `duration_seconds`
 * (HKWorkout.duration) ALREADY excludes paused time — it's moving time — so
 * `avg_pace_seconds_per_mile` is already correct. The pollution is in the
 * GPX-derived splits, which are on the ELAPSED clock: the split containing a
 * pause shows an inflated duration/pace (e.g. a mile at 16:10 that was really
 * 10:34 of running plus a 5-minute stop). This module produces the pause
 * intervals so the split-derived metrics (variability / drift / halves) can be
 * recomputed on moving time.
 */

const SECONDS_PER_MILE = 1609.344;

export interface WorkoutEventInput {
  type: string;
  start: string; // ISO 8601
  duration_seconds: number;
}

export interface PauseInterval {
  startMs: number;
  endMs: number;
}

export interface PauseEvent {
  /** Elapsed seconds from workout start to the pause. */
  start_seconds: number;
  duration_seconds: number;
  /** Zero-indexed position in the splits array of the split the pause started
   *  in, or null when it can't be placed (no splits, or pause outside them). */
  affected_split_index: number | null;
  source: "healthkit_event" | "inferred_from_samples";
}

export interface SplitTimeWindow {
  start_time?: string;
  end_time?: string;
}

/** A strides/intervals phase, in elapsed seconds from workout start. Near-zero
 *  speed spans inside these are intentional recovery, not pauses. */
export interface RecoveryWindow {
  startSeconds: number;
  endSeconds: number;
}

function round1(n: number): number {
  return Math.round(n * 10) / 10;
}

/** Pair `pause` → `resume` events into [startMs, endMs) intervals. A pause with
 *  no following resume is closed at `workoutEndMs` (the run ended while paused).
 *  Overlapping/adjacent intervals are merged. */
export function pauseIntervalsFromEvents(
  events: WorkoutEventInput[] | undefined,
  workoutEndMs: number | null
): PauseInterval[] {
  if (!events || events.length === 0) return [];

  const markers = events
    .filter((e) => e.type === "pause" || e.type === "resume")
    .map((e) => ({ type: e.type, ms: Date.parse(e.start) }))
    .filter((e) => Number.isFinite(e.ms))
    .sort((a, b) => a.ms - b.ms);

  const intervals: PauseInterval[] = [];
  let openPause: number | null = null;
  for (const m of markers) {
    if (m.type === "pause") {
      if (openPause === null) openPause = m.ms; // ignore a redundant nested pause
    } else {
      if (openPause !== null) {
        if (m.ms > openPause) intervals.push({ startMs: openPause, endMs: m.ms });
        openPause = null;
      }
    }
  }
  if (openPause !== null && workoutEndMs !== null && workoutEndMs > openPause) {
    intervals.push({ startMs: openPause, endMs: workoutEndMs });
  }

  return mergeIntervals(intervals);
}

function mergeIntervals(intervals: PauseInterval[]): PauseInterval[] {
  if (intervals.length <= 1) return intervals;
  const sorted = [...intervals].sort((a, b) => a.startMs - b.startMs);
  const out: PauseInterval[] = [{ ...sorted[0] }];
  for (let i = 1; i < sorted.length; i++) {
    const last = out[out.length - 1];
    if (sorted[i].startMs <= last.endMs) {
      last.endMs = Math.max(last.endMs, sorted[i].endMs);
    } else {
      out.push({ ...sorted[i] });
    }
  }
  return out;
}

/** Seconds of overlap between [aStartMs, aEndMs) and [bStartMs, bEndMs). */
export function overlapSeconds(
  aStartMs: number,
  aEndMs: number,
  bStartMs: number,
  bEndMs: number
): number {
  const start = Math.max(aStartMs, bStartMs);
  const end = Math.min(aEndMs, bEndMs);
  return end > start ? (end - start) / 1000 : 0;
}

/**
 * Turn pause intervals into structured `pause_events`, dropping any that begin
 * inside a strides/intervals recovery window (those spans are effort, not
 * interruptions). Returns the kept events AND the kept intervals so callers use
 * the SAME filtered set for both the event list and moving-time subtraction.
 */
export function detectPauses(args: {
  intervals: PauseInterval[];
  splits: SplitTimeWindow[];
  workoutStartMs: number | null;
  recoveryWindows?: RecoveryWindow[];
  source?: "healthkit_event" | "inferred_from_samples";
}): { intervals: PauseInterval[]; pauseEvents: PauseEvent[] } {
  const { intervals, splits, workoutStartMs } = args;
  const source = args.source ?? "healthkit_event";
  const recovery = args.recoveryWindows ?? [];

  const keptIntervals: PauseInterval[] = [];
  const pauseEvents: PauseEvent[] = [];

  for (const iv of intervals) {
    const startSeconds =
      workoutStartMs !== null ? (iv.startMs - workoutStartMs) / 1000 : 0;

    const inRecovery = recovery.some(
      (w) => startSeconds >= w.startSeconds - 5 && startSeconds <= w.endSeconds + 5
    );
    if (inRecovery) continue;

    keptIntervals.push(iv);
    pauseEvents.push({
      start_seconds: round1(Math.max(0, startSeconds)),
      duration_seconds: round1((iv.endMs - iv.startMs) / 1000),
      affected_split_index: splitIndexAt(iv.startMs, splits),
      source,
    });
  }

  return { intervals: keptIntervals, pauseEvents };
}

function splitIndexAt(ms: number, splits: SplitTimeWindow[]): number | null {
  for (let i = 0; i < splits.length; i++) {
    const s = splits[i].start_time ? Date.parse(splits[i].start_time!) : NaN;
    const e = splits[i].end_time ? Date.parse(splits[i].end_time!) : NaN;
    if (Number.isFinite(s) && Number.isFinite(e) && ms >= s && ms < e) return i;
  }
  return null;
}

/** Total paused seconds across all intervals. */
export function totalPauseSeconds(intervals: PauseInterval[]): number {
  return intervals.reduce((acc, iv) => acc + (iv.endMs - iv.startMs) / 1000, 0);
}

export interface MovingSplitTimes {
  moving_duration_seconds: number;
  moving_pace_seconds_per_mile: number | null;
}

/**
 * Moving-time equivalents for a single split: subtract the pause time that
 * overlaps the split's [start, end) window. When the split has no timestamps or
 * no pause overlaps it, the moving values equal the raw ones.
 */
export function movingTimeForSplit(
  split: {
    start_time?: string;
    end_time?: string;
    duration_seconds: number;
    distance_meters: number;
  },
  intervals: PauseInterval[]
): MovingSplitTimes {
  const raw = split.duration_seconds;
  if (!split.start_time || !split.end_time || intervals.length === 0) {
    return {
      moving_duration_seconds: raw,
      moving_pace_seconds_per_mile:
        split.distance_meters > 0 ? raw / (split.distance_meters / SECONDS_PER_MILE) : null,
    };
  }
  const s = Date.parse(split.start_time);
  const e = Date.parse(split.end_time);
  let paused = 0;
  if (Number.isFinite(s) && Number.isFinite(e)) {
    for (const iv of intervals) paused += overlapSeconds(s, e, iv.startMs, iv.endMs);
  }
  const moving = Math.max(0, raw - paused);
  return {
    moving_duration_seconds: moving,
    moving_pace_seconds_per_mile:
      split.distance_meters > 0 ? moving / (split.distance_meters / SECONDS_PER_MILE) : null,
  };
}
