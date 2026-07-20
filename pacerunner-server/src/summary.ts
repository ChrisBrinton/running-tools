/**
 * Per-workout summary statistics — computed at ingest time from the raw
 * samples payload + HK metadata. Stored as a JSON blob on the workout row
 * so list_workouts and get_workout can serve cross-workout trend questions
 * (HR trending up? mileage week-over-week? power vs last month?) without
 * paginating thousands of sample points per call.
 *
 * The structure is deliberately flat and additive: every field is nullable.
 * A workout that's missing a sample stream (no HR strap, no Stryd) just
 * omits that field rather than failing the whole summary.
 *
 * Inputs come from the ingest payload, not from the DB — we compute once on
 * the write path, not on every read.
 */

import { detectWorkoutStructure, type WorkoutStructure } from "./structure.js";
import {
  pauseIntervalsFromEvents,
  detectPauses,
  totalPauseSeconds,
  movingTimeForSplit,
  type WorkoutEventInput,
  type PauseEvent,
} from "./pauses.js";

const SECONDS_PER_MILE = 1609.344;

export interface IngestSample {
  start: string;
  end: string;
  value: number;
  unit: string;
}

export interface IngestSamples {
  [type: string]: IngestSample[];
}

export interface WorkoutSummary {
  // Heart rate (bpm)
  avg_heart_rate_bpm: number | null;
  max_heart_rate_bpm: number | null;
  min_heart_rate_bpm: number | null;

  // Pace (seconds per mile)
  avg_pace_seconds_per_mile: number | null;

  // Power (W) — only meaningful for runs that recorded it (Stryd, AW 16+)
  avg_running_power_watts: number | null;
  max_running_power_watts: number | null;

  // Form metrics — Apple Watch Series 9+ / Ultra deliver these for outdoor runs
  avg_running_speed_mps: number | null;
  avg_stride_length_m: number | null;
  avg_cadence_spm: number | null;
  avg_ground_contact_ms: number | null;
  avg_vertical_oscillation_cm: number | null;

  // Elevation (m) — from raw HK metadata when present, else null
  elevation_gain_meters: number | null;
  elevation_loss_meters: number | null;

  // -------- Tier 1 derived metrics (Coach context-saver) ------------

  /** Avg HR / avg power. The single best single-number aerobic-fitness
   *  proxy. Null when power isn't available (older devices / treadmill). */
  hr_to_power_ratio: number | null;

  /** Mean metrics over the first half of the workout's full-mile splits
   *  (excludes partial cool-down splits < 0.5 mi). Null on workouts with
   *  fewer than 2 full splits — half-half doesn't mean anything there. */
  first_half: HalfSummary | null;
  second_half: HalfSummary | null;

  /** Per-mile drift slopes via linear regression across full-mile splits.
   *  Positive HR drift + positive pace drift => fading; negative power
   *  drift => effort fading. Null when fewer than 3 splits. */
  drift: DriftSummary | null;

  /** Standard deviation across full-mile splits. Detects unsteady efforts;
   *  a tempo run should have low pace stdev, a fartlek high. Null when
   *  fewer than 3 splits. */
  split_variability: SplitVariability | null;

  // -------- Tier 2 auto-classification ----------------------------------

  /** Heuristic classification based on distance, HR zone distribution,
   *  and pace vs the user's 30-day baselines. May be null if there's not
   *  enough history to baseline. */
  workout_type: WorkoutType | null;
  /** 0–1 score for how confidently the heuristic landed on `workout_type`.
   *  Treat values below ~0.5 as "the coach should probably ignore the label." */
  workout_type_confidence: number | null;

  // -------- Run-quality flag (execution vs. intent) ---------------------

  /** How well the run held together, *independent* of `workout_type` (which
   *  now reflects user intent via the config name and so reads 0.95 even on a
   *  bad day). "degraded" = breakdown signals fired (high pace variability,
   *  second-half fade, power drop); "aborted" = the run fell apart (a stalled
   *  / walked mile, or multiple severe signals); "structured" = the workout had
   *  detected structure (e.g. strides at the end) so whole-workout flags aren't
   *  meaningful — the effort metrics on this summary are computed over the core
   *  phase only, and `run_quality_reasons` carries a `core_*` code for how the
   *  core effort itself executed. Lets weekly trend math put an asterisk on — or
   *  exclude — bad-day runs when averaging HR/power/pace. Null when there aren't
   *  enough full-mile splits to judge (same gate as `drift` /
   *  `split_variability`). */
  run_quality: RunQuality | null;

  /** Machine-readable reasons `run_quality` was not "clean" (e.g.
   *  "pace_stdev_104s", "pace_fade_73s_per_mi", "power_drop_29w"). For
   *  "structured" runs, carries phase-scoped codes ("core_clean",
   *  "strides_4reps"). Empty when clean or unjudgeable. Meant for the coach to
   *  see *why* a run was flagged. */
  run_quality_reasons: string[];

  // -------- Workout structure (strides / warmup / tempo / intervals) -----

  /** Detected phase structure of the workout, or null for a single continuous
   *  effort. When present, all the effort metrics above are computed over the
   *  core phase only (see `workout_structure.core_phase_index`); the
   *  whole-workout values are preserved under `full_workout_summary`. */
  workout_structure: WorkoutStructure | null;

  /** Convenience flag: the workout ended with a stride block. Mirror of
   *  `workout_structure?.has_strides`. */
  has_strides: boolean;

  /** The workout's intended type, parsed from the PaceRunner config name
   *  ("6mi Easy" → easy). Distinct from `workout_type` (which may be
   *  data-inferred) so planned-vs-actual can be compared. Null when the
   *  workout wasn't run through a named PaceRunner configuration. */
  planned_workout_type: WorkoutType | null;

  /** Whole-workout values for the metrics that were narrowed to the core
   *  phase, kept for total-training-load / weekly-mileage questions that want
   *  the full session. Null when no structure was detected (the top-level
   *  fields already ARE the whole workout in that case). */
  full_workout_summary: FullWorkoutSummary | null;

  // -------- Mid-run pauses (bathroom / water / traffic) ------------------

  /** Detected mid-run pause/resume interruptions. Empty array (never null)
   *  when none. When present, the split-derived pace metrics above
   *  (`split_variability`, `drift`, `first_half`/`second_half`) are computed on
   *  MOVING time so a 5-minute restroom stop doesn't read as pace variability.
   *  HR/power metrics are intentionally left on elapsed samples — HR really did
   *  drop during the stop. See `pacerunner_pause_detection.md`. */
  pause_events: PauseEvent[];

  /** Moving time for the whole workout (paused time excluded). Equal to the
   *  workout's `duration_seconds` (HKWorkout.duration is already moving time).
   *  Null when duration is unknown. */
  total_moving_duration_seconds: number | null;

  /** Wall-clock time out (moving + all pauses) — "how long was I out." Equals
   *  moving time when there were no pauses. Null when duration is unknown. */
  total_elapsed_duration_seconds: number | null;
}

export interface FullWorkoutSummary {
  avg_heart_rate_bpm: number | null;
  avg_pace_seconds_per_mile: number | null;
  avg_running_power_watts: number | null;
  hr_to_power_ratio: number | null;
}

export type RunQuality = "clean" | "degraded" | "aborted" | "structured";

export type WorkoutType =
  | "easy"
  | "moderate"
  | "long"
  | "tempo"
  | "recovery"
  | "race"
  | "walk_jog";

export interface HalfSummary {
  avg_heart_rate_bpm: number | null;
  avg_pace_seconds_per_mile: number | null;
  avg_running_power_watts: number | null;
  avg_cadence_spm: number | null;
}

export interface DriftSummary {
  hr_bpm_per_mile: number | null;
  pace_sec_per_mile_per_mile: number | null;
  power_w_per_mile: number | null;
  cadence_spm_per_mile: number | null;
}

export interface SplitVariability {
  pace_stdev_sec: number | null;
  hr_stdev_bpm: number | null;
  power_stdev_w: number | null;
}

/** Numeric aggregations over a one-dimensional value series. */
interface Aggregate {
  count: number;
  sum: number;
  min: number;
  max: number;
}

function aggregate(samples: IngestSample[] | undefined): Aggregate | null {
  if (!samples || samples.length === 0) return null;
  let count = 0;
  let sum = 0;
  let min = Infinity;
  let max = -Infinity;
  for (const s of samples) {
    if (!Number.isFinite(s.value)) continue;
    count++;
    sum += s.value;
    if (s.value < min) min = s.value;
    if (s.value > max) max = s.value;
  }
  if (count === 0) return null;
  return { count, sum, min, max };
}

function avg(a: Aggregate | null): number | null {
  return a ? a.sum / a.count : null;
}

/** Earliest runningPower sample time (epoch seconds), or null. Structure
 *  detection windows on the same t0, so the two agree. */
function workoutStartEpoch(s: IngestSamples): number | null {
  const arr = s.runningPower;
  if (!arr || arr.length === 0) return null;
  let min = Infinity;
  for (const x of arr) {
    const t = Date.parse(x.start) / 1000;
    if (Number.isFinite(t) && t < min) min = t;
  }
  return Number.isFinite(min) ? min : null;
}

/** Aggregate over samples whose start falls in the elapsed window
 *  [startSec, endSec) relative to `t0`. */
function aggregateIn(
  samples: IngestSample[] | undefined,
  t0: number,
  startSec: number,
  endSec: number
): Aggregate | null {
  if (!samples || samples.length === 0) return null;
  let count = 0, sum = 0, min = Infinity, max = -Infinity;
  for (const sm of samples) {
    if (!Number.isFinite(sm.value)) continue;
    const el = Date.parse(sm.start) / 1000 - t0;
    if (!Number.isFinite(el) || el < startSec || el >= endSec) continue;
    count++;
    sum += sm.value;
    if (sm.value < min) min = sm.value;
    if (sm.value > max) max = sm.value;
  }
  if (count === 0) return null;
  return { count, sum, min, max };
}

/** Sum of incremental sample values (e.g. distanceWalkingRunning meters) in
 *  the elapsed window [startSec, endSec) relative to `t0`. */
function sumIn(
  samples: IngestSample[] | undefined,
  t0: number,
  startSec: number,
  endSec: number
): number {
  if (!samples) return 0;
  let sum = 0;
  for (const sm of samples) {
    if (!Number.isFinite(sm.value)) continue;
    const el = Date.parse(sm.start) / 1000 - t0;
    if (!Number.isFinite(el) || el < startSec || el >= endSec) continue;
    sum += sm.value;
  }
  return sum;
}

/** True when a split's time window lies within the core-phase window. The
 *  split that straddles the core-end boundary (the one containing the stride
 *  block) is excluded so it doesn't pollute the steady-effort metrics. Splits
 *  without timestamps are kept (we can't place them). Split elapsed is measured
 *  from the SAME power-based `t0` that `coreStart`/`coreEnd` use — split
 *  timestamps (GPX trkpt clock) and sample timestamps share the watch's wall
 *  clock, so subtracting the one `t0` puts both on one axis and avoids a
 *  two-clock mismatch at the boundary. */
function splitInCore(
  sp: SplitForSummary,
  t0: number,
  coreStart: number,
  coreEnd: number
): boolean {
  if (!sp.start_time || !sp.end_time) return true;
  const start = Date.parse(sp.start_time) / 1000 - t0;
  const end = Date.parse(sp.end_time) / 1000 - t0;
  if (!Number.isFinite(start) || !Number.isFinite(end)) return true;
  const TOL = 15;
  return start >= coreStart - TOL && end <= coreEnd + TOL;
}

function round(n: number | null, decimals = 1): number | null {
  if (n === null) return null;
  const f = Math.pow(10, decimals);
  return Math.round(n * f) / f;
}

/** Parses "9118 cm" → 91.18 (meters). Apple sometimes uses raw cm strings
 *  in HK metadata; we normalize to SI here. Returns null on parse failure. */
function parseCmToMeters(raw: unknown): number | null {
  if (typeof raw !== "string") return null;
  const m = raw.match(/^([-\d.]+)\s*cm$/);
  if (m) {
    const n = parseFloat(m[1]);
    return Number.isFinite(n) ? n / 100 : null;
  }
  const n = parseFloat(raw);
  return Number.isFinite(n) ? n : null;
}

/** Per-user baselines used by the workout classifier (Tier 2). Null when
 *  not enough history has been ingested yet; classification falls back to
 *  pure-distance heuristics in that case. */
export interface UserBaseline {
  /** Observed max HR across the user's whole history (bpm). */
  observed_max_hr_bpm: number | null;
  /** Median distance per workout over the last 30 days (mi). */
  median_workout_miles_30d: number | null;
  /** Median pace seconds/mi over the last 30 days, restricted to runs
   *  with HR < ~65% of observed_max — a rough proxy for "easy" runs. */
  median_easy_pace_seconds_per_mile_30d: number | null;
}

/** Minimal shape of a split row that the summary cares about. Mirrors the
 *  splits returned by `computeMileSplits`; we accept either at call time. */
export interface SplitForSummary {
  distance_meters: number;
  duration_seconds: number;
  pace_seconds_per_mile: number | null;
  avg_heart_rate_bpm: number | null;
  avg_running_power_watts: number | null;
  elevation_gain_meters: number;
  elevation_loss_meters: number;
  /** ISO start/end of the split. Present on the ComputedSplit rows we're
   *  handed at runtime; optional here so callers with a leaner shape still
   *  type-check. Used to keep only the core-phase splits when a workout has
   *  detected structure. */
  start_time?: string;
  end_time?: string;
}

/**
 * Compute the summary blob from an ingest payload. `totalDistanceMeters`
 * and `durationSeconds` come from the top-level workout fields, not from
 * samples — they're what's authoritative on the watch.
 *
 * `splits` and `baseline` are optional. When present, the Tier 1 derived
 * metrics (halves, drift, variability, elevation_loss fallback) and the
 * Tier 2 workout_type label get populated. When absent, those fields
 * land as null — never break the summary.
 */
export function computeSummary(args: {
  samples: IngestSamples | undefined;
  rawMetadata: Record<string, unknown> | undefined;
  totalDistanceMeters: number | undefined | null;
  durationSeconds: number;
  splits?: SplitForSummary[];
  baseline?: UserBaseline;
  /** Name of the PaceRunner run configuration this workout used (e.g.
   *  "5mi Easy"). When supplied, the classifier extracts user intent
   *  from the name instead of guessing from HR. */
  paceRunnerConfigName?: string | null;
  /** Workout event stream (HK `pause`/`resume` markers among others). When
   *  present, mid-run pauses are detected and the split-derived pace metrics
   *  are computed on moving time. */
  events?: WorkoutEventInput[];
}): WorkoutSummary {
  const s = args.samples ?? {};

  const hr = aggregate(s.heartRate);
  const power = aggregate(s.runningPower);
  const speed = aggregate(s.runningSpeed);
  const stride = aggregate(s.runningStrideLength);
  const gct = aggregate(s.runningGroundContactTime);
  const vosc = aggregate(s.runningVerticalOscillation);
  const steps = aggregate(s.stepCount);

  // Cadence (steps/min) is derivable from stepCount samples if HK didn't
  // emit it directly. stepCount samples are aggregated by HK over an
  // interval; we sum and divide by total minutes.
  let cadence: number | null = null;
  if (steps && args.durationSeconds > 0) {
    cadence = (steps.sum / args.durationSeconds) * 60;
  }

  // Pace — only when both distance and duration are present.
  let pace: number | null = null;
  if (args.totalDistanceMeters && args.totalDistanceMeters > 0 && args.durationSeconds > 0) {
    const totalMiles = args.totalDistanceMeters / SECONDS_PER_MILE;
    pace = args.durationSeconds / totalMiles;
  }

  const avgHR = avg(hr);
  const avgPower = avg(power);
  const elevGain = parseCmToMeters(args.rawMetadata?.HKElevationAscended);
  const elevLossMeta = parseCmToMeters(args.rawMetadata?.HKElevationDescended);

  // Tier 1 bug fix: HK metadata's HKElevationDescended is often absent
  // (it was reliably null in our backfilled workouts). Fall back to
  // summing per-split elevation_loss_meters whenever splits are present.
  const elevLossFromSplits = args.splits
    ? args.splits.reduce((acc, sp) => acc + (sp.elevation_loss_meters ?? 0), 0)
    : null;
  const elevLoss = elevLossMeta !== null
    ? elevLossMeta
    : elevLossFromSplits !== null && elevLossFromSplits > 0
      ? elevLossFromSplits
      : null;

  // ---- Workout structure -------------------------------------------------
  // Detect strides / warmup / tempo / intervals from the per-sample streams.
  // When present, the effort metrics below are computed over the *core* phase
  // only (so a stride coda doesn't read as a "degraded" easy run); the
  // whole-workout numbers are preserved under `full_workout_summary`.
  const structure = detectWorkoutStructure({
    samples: args.samples,
    durationSeconds: args.durationSeconds,
    splits: args.splits,
  });
  const t0 = workoutStartEpoch(s);
  const coreStart = structure?.core_start_seconds ?? 0;
  const coreEnd = structure?.core_end_seconds ?? Infinity;
  // "Narrowed" = the core window is a strict subset of the whole workout, so
  // the sample-derived means genuinely differ from the whole-workout ones.
  // Compare against the structure's own sample-elapsed span (same clock as
  // core_start/core_end) — NOT args.durationSeconds, which may be moving-time
  // and would misjudge the boundary on a run with pauses.
  const sampleSpan = structure?.total_sample_seconds ?? 0;
  const narrowed =
    structure !== null &&
    t0 !== null &&
    (coreStart > 5 || coreEnd < sampleSpan - 5);

  // Core-phase aggregates — windowed to [coreStart, coreEnd] when narrowed,
  // otherwise identical to the whole-workout aggregates computed above.
  const win = (all: Aggregate | null, key: string): Aggregate | null =>
    narrowed && t0 !== null ? aggregateIn(s[key], t0, coreStart, coreEnd) : all;
  const coreHR = win(hr, "heartRate");
  const corePowerAgg = win(power, "runningPower");
  const coreSpeed = win(speed, "runningSpeed");
  const coreStrideAgg = win(stride, "runningStrideLength");
  const coreGct = win(gct, "runningGroundContactTime");
  const coreVosc = win(vosc, "runningVerticalOscillation");
  const avgCoreHR = avg(coreHR);
  const avgCorePower = avg(corePowerAgg);

  // Core-phase pace + cadence, recomputed from the windowed distance/step sums.
  let corePace = pace;
  let coreCadence = cadence;
  if (narrowed && t0 !== null) {
    const coreDur = Math.max(0, Math.min(coreEnd, args.durationSeconds) - coreStart);
    const coreMeters = sumIn(s.distanceWalkingRunning, t0, coreStart, coreEnd);
    corePace = coreMeters > 0 && coreDur > 0
      ? coreDur / (coreMeters / SECONDS_PER_MILE)
      : null;
    const coreSteps = aggregateIn(s.stepCount, t0, coreStart, coreEnd);
    coreCadence = coreSteps && coreDur > 0 ? (coreSteps.sum / coreDur) * 60 : null;
  }

  // ---- Mid-run pauses ----------------------------------------------------
  // Detect pause/resume interruptions from the HK event stream. The split-
  // derived pace metrics below are then computed on MOVING time (paused span
  // subtracted from each affected split) so a bathroom stop doesn't masquerade
  // as pace variability / a second-half fade / a stalled mile. HR and power are
  // left on elapsed samples — HR really did drop during the stop.
  const allSplits = args.splits ?? [];
  const workoutStartMs =
    allSplits.length > 0 && allSplits[0].start_time
      ? Date.parse(allSplits[0].start_time)
      : null;
  const workoutEndMs =
    allSplits.length > 0 && allSplits[allSplits.length - 1].end_time
      ? Date.parse(allSplits[allSplits.length - 1].end_time!)
      : null;
  const recoveryWindows = (structure?.phases ?? [])
    .filter((p) => p.phase === "strides" || p.phase === "intervals")
    .map((p) => ({ startSeconds: p.start_seconds, endSeconds: p.end_seconds }));
  const { intervals: pauseIntervals, pauseEvents } = detectPauses({
    intervals: pauseIntervalsFromEvents(args.events, workoutEndMs),
    splits: allSplits,
    workoutStartMs,
    recoveryWindows,
  });
  const pausedSeconds = totalPauseSeconds(pauseIntervals);

  // Rewrite a split's pace + duration onto moving time. Identity when there are
  // no pauses, so non-paused workouts are byte-for-byte unchanged.
  const toMoving = (sp: SplitForSummary): SplitForSummary => {
    if (pauseIntervals.length === 0) return sp;
    const m = movingTimeForSplit(sp, pauseIntervals);
    return {
      ...sp,
      duration_seconds: m.moving_duration_seconds,
      pace_seconds_per_mile: m.moving_pace_seconds_per_mile,
    };
  };

  // Tier 1 derived metrics — computed over the core-phase splits, on moving
  // time. When not narrowed, `coreSplits === fullSplits`, preserving prior
  // behavior for pause-free workouts.
  const fullSplits = allSplits.filter(isFullSplit).map(toMoving);
  const coreSplits = narrowed
    ? fullSplits.filter((sp) => splitInCore(sp, t0 ?? 0, coreStart, coreEnd))
    : fullSplits;
  const { firstHalf, secondHalf } = computeHalves(coreSplits);
  const drift = computeDrift(coreSplits);
  const variability = computeVariability(coreSplits);

  const hrToPowerCore = (avgCoreHR !== null && avgCorePower !== null && avgCorePower > 0)
    ? avgCoreHR / avgCorePower
    : null;
  const hrToPowerFull = (avgHR !== null && avgPower !== null && avgPower > 0)
    ? avgHR / avgPower
    : null;

  // Tier 2 — classification. Prefer user intent (config name) when present;
  // fall back to HR-based heuristics (on core-phase HR/pace) otherwise.
  let workoutType: WorkoutType | null = null;
  let confidence: number | null = null;
  const fromConfig = classifyFromConfigName(args.paceRunnerConfigName ?? null);
  if (fromConfig) {
    workoutType = fromConfig.workoutType;
    confidence = fromConfig.confidence;
  } else {
    const fromHeuristic = classifyWorkout({
      distanceMiles: args.totalDistanceMeters ? args.totalDistanceMeters / SECONDS_PER_MILE : null,
      durationSeconds: args.durationSeconds,
      avgHR: avgCoreHR,
      avgPace: corePace,
      hrSamples: s.heartRate,
      baseline: args.baseline ?? null,
    });
    workoutType = fromHeuristic.workoutType;
    confidence = fromHeuristic.confidence;
  }
  // Intended type, always parsed from the config name — distinct from the
  // (possibly data-inferred) workout_type so planned-vs-actual can be compared.
  const plannedType = fromConfig?.workoutType ?? null;

  // Run-quality over the core effort. On a structured workout the whole-workout
  // flags aren't meaningful, so the top-level quality becomes "structured" and
  // the core execution is recorded in the reasons (`core_clean` / `core_degraded`).
  const coreQuality = computeRunQuality({
    workoutType,
    fullSplits: coreSplits,
    variability,
    firstHalf,
    secondHalf,
  });
  let quality: RunQuality | null = coreQuality?.quality ?? null;
  let qualityReasons: string[] = coreQuality?.reasons ?? [];
  if (structure) {
    const stridePhase = structure.phases.find((p) => p.phase === "strides");
    qualityReasons = [
      `core_${coreQuality?.quality ?? "unjudged"}`,
      ...(stridePhase ? [`strides_${stridePhase.reps ?? 0}reps`] : []),
      ...qualityReasons,
    ];
    quality = "structured";
  }

  // A pause is not degradation. Surface it for transparency but leave the
  // quality verdict driven by the (now moving-time) effort signals — a single
  // bathroom stop on an otherwise steady run stays "clean".
  if (pauseEvents.length > 0 && !qualityReasons.includes("pause_events_present")) {
    qualityReasons = [...qualityReasons, "pause_events_present"];
  }

  const movingDuration =
    args.durationSeconds > 0 ? round(args.durationSeconds, 1) : null;
  const elapsedDuration =
    args.durationSeconds > 0 ? round(args.durationSeconds + pausedSeconds, 1) : null;

  return {
    avg_heart_rate_bpm: round(avgCoreHR, 0),
    max_heart_rate_bpm: coreHR ? Math.round(coreHR.max) : null,
    min_heart_rate_bpm: coreHR ? Math.round(coreHR.min) : null,

    avg_pace_seconds_per_mile: round(corePace, 1),

    avg_running_power_watts: round(avgCorePower, 1),
    // Peak power is a whole-workout signal (the stride burst) — keep it.
    max_running_power_watts: power ? Math.round(power.max) : null,

    avg_running_speed_mps: round(avg(coreSpeed), 2),
    avg_stride_length_m: round(avg(coreStrideAgg), 2),
    avg_cadence_spm: round(coreCadence, 1),
    avg_ground_contact_ms: round(avg(coreGct), 1),
    avg_vertical_oscillation_cm: round(avg(coreVosc), 2),

    elevation_gain_meters: elevGain !== null ? round(elevGain, 1) : null,
    elevation_loss_meters: elevLoss !== null ? round(elevLoss, 1) : null,

    hr_to_power_ratio: round(hrToPowerCore, 3),
    first_half: firstHalf,
    second_half: secondHalf,
    drift,
    split_variability: variability,

    workout_type: workoutType,
    workout_type_confidence: round(confidence, 2),

    run_quality: quality,
    run_quality_reasons: qualityReasons,

    workout_structure: structure,
    has_strides: structure?.has_strides ?? false,
    planned_workout_type: plannedType,
    full_workout_summary: structure
      ? {
          avg_heart_rate_bpm: round(avgHR, 0),
          avg_pace_seconds_per_mile: round(pace, 1),
          avg_running_power_watts: round(avgPower, 1),
          hr_to_power_ratio: round(hrToPowerFull, 3),
        }
      : null,

    pause_events: pauseEvents,
    total_moving_duration_seconds: movingDuration,
    total_elapsed_duration_seconds: elapsedDuration,
  };
}

// ---------------------------------------------------------------------------
// Tier 1 helpers
// ---------------------------------------------------------------------------

const FULL_SPLIT_MIN_METERS = 0.5 * SECONDS_PER_MILE; // ≥ 0.5 mi to count

function isFullSplit(sp: SplitForSummary): boolean {
  return sp.distance_meters >= FULL_SPLIT_MIN_METERS;
}

function computeHalves(splits: SplitForSummary[]): {
  firstHalf: HalfSummary | null;
  secondHalf: HalfSummary | null;
} {
  if (splits.length < 2) return { firstHalf: null, secondHalf: null };
  const mid = Math.floor(splits.length / 2);
  const first = splits.slice(0, mid);
  // For odd N, leave the middle split out of both halves — its inclusion
  // would skew the comparison and isn't analytically meaningful.
  const second = splits.length % 2 === 0
    ? splits.slice(mid)
    : splits.slice(mid + 1);
  return {
    firstHalf: summarizeHalf(first),
    secondHalf: summarizeHalf(second),
  };
}

function summarizeHalf(splits: SplitForSummary[]): HalfSummary | null {
  if (splits.length === 0) return null;
  // Distance-weighted means so a partial split (≥0.5 mi but <1.0 mi) doesn't
  // get the same weight as a full mile.
  let totalDist = 0;
  let hrNum = 0, hrW = 0;
  let paceNum = 0, paceW = 0;
  let powerNum = 0, powerW = 0;
  for (const sp of splits) {
    totalDist += sp.distance_meters;
    if (sp.avg_heart_rate_bpm !== null) {
      hrNum += sp.avg_heart_rate_bpm * sp.distance_meters;
      hrW += sp.distance_meters;
    }
    if (sp.pace_seconds_per_mile !== null) {
      paceNum += sp.pace_seconds_per_mile * sp.distance_meters;
      paceW += sp.distance_meters;
    }
    if (sp.avg_running_power_watts !== null) {
      powerNum += sp.avg_running_power_watts * sp.distance_meters;
      powerW += sp.distance_meters;
    }
  }
  return {
    avg_heart_rate_bpm: hrW > 0 ? round(hrNum / hrW, 0) : null,
    avg_pace_seconds_per_mile: paceW > 0 ? round(paceNum / paceW, 1) : null,
    avg_running_power_watts: powerW > 0 ? round(powerNum / powerW, 1) : null,
    // Cadence isn't on the split rows — skipping for now; could derive
    // from stepCount samples bracketed to the split's time window in a
    // future revision.
    avg_cadence_spm: null,
  };
}

function computeDrift(splits: SplitForSummary[]): DriftSummary | null {
  if (splits.length < 3) return null;
  // x-axis: split midpoint distance (mi). 1st split = 0.5, 2nd = 1.5, etc.
  // y-axis: each metric. Linear-regression slope is the "per-mile" drift.
  const xs: number[] = [];
  let cumDist = 0;
  for (const sp of splits) {
    const xMi = (cumDist + sp.distance_meters / 2) / SECONDS_PER_MILE;
    xs.push(xMi);
    cumDist += sp.distance_meters;
  }
  return {
    hr_bpm_per_mile:
      regressionSlope(xs, splits.map((sp) => sp.avg_heart_rate_bpm)),
    pace_sec_per_mile_per_mile:
      regressionSlope(xs, splits.map((sp) => sp.pace_seconds_per_mile)),
    power_w_per_mile:
      regressionSlope(xs, splits.map((sp) => sp.avg_running_power_watts)),
    cadence_spm_per_mile: null, // see summarizeHalf note
  };
}

function regressionSlope(xs: number[], ys: (number | null)[]): number | null {
  const pairs: Array<[number, number]> = [];
  for (let i = 0; i < xs.length; i++) {
    const y = ys[i];
    if (y === null || !Number.isFinite(y)) continue;
    pairs.push([xs[i], y]);
  }
  if (pairs.length < 3) return null;
  const n = pairs.length;
  const meanX = pairs.reduce((s, [x]) => s + x, 0) / n;
  const meanY = pairs.reduce((s, [, y]) => s + y, 0) / n;
  let num = 0;
  let den = 0;
  for (const [x, y] of pairs) {
    num += (x - meanX) * (y - meanY);
    den += (x - meanX) ** 2;
  }
  if (den === 0) return null;
  return round(num / den, 2);
}

function computeVariability(splits: SplitForSummary[]): SplitVariability | null {
  if (splits.length < 3) return null;
  return {
    pace_stdev_sec:
      stdev(splits.map((sp) => sp.pace_seconds_per_mile)),
    hr_stdev_bpm:
      stdev(splits.map((sp) => sp.avg_heart_rate_bpm)),
    power_stdev_w:
      stdev(splits.map((sp) => sp.avg_running_power_watts)),
  };
}

function stdev(values: (number | null)[]): number | null {
  const xs = values.filter((v): v is number => v !== null && Number.isFinite(v));
  if (xs.length < 3) return null;
  const mean = xs.reduce((s, v) => s + v, 0) / xs.length;
  const variance =
    xs.reduce((s, v) => s + (v - mean) ** 2, 0) / (xs.length - 1);
  return round(Math.sqrt(variance), 2);
}

function median(xs: number[]): number {
  const sorted = [...xs].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

// ---------------------------------------------------------------------------
// Run-quality flag
// ---------------------------------------------------------------------------

/**
 * Thresholds calibrated against real ingested runs. Clean steady runs sit at
 * pace stdev ≤ ~27 s, second-half deltas within ±30 s/mi and ±10 W; the flagged
 * bad-day run was 104 s stdev / +73 s/mi / −29 W, and a run that fell apart hit
 * 232 s stdev / +360 s/mi. Degraded thresholds sit well above the clean band;
 * "severe" thresholds mark the fell-apart territory.
 */
const RQ = {
  PACE_STDEV_DEGRADED: 45,   // sec — steady runs stay under ~30
  PACE_STDEV_SEVERE: 150,
  PACE_FADE_DEGRADED: 40,    // sec/mi slower, second half vs first
  PACE_FADE_SEVERE: 150,
  POWER_FADE_DEGRADED: -20,  // W drop, second half vs first
  STALL_FACTOR: 2.0,         // a full mile slower than 2× the run's median
} as const;

/**
 * Classify how well the run's execution matched a steady effort. Returns null
 * when there aren't enough full-mile splits to judge (same gate as drift /
 * variability). Each firing signal adds a machine-readable reason string.
 *
 * clean    — no signals (or a single mild one).
 * degraded — real breakdown: 2+ signals, or one severe (e.g. a stalled mile).
 * aborted  — the run fell apart: 2+ severe signals.
 */
function computeRunQuality(args: {
  workoutType: WorkoutType | null;
  fullSplits: SplitForSummary[];
  variability: SplitVariability | null;
  firstHalf: HalfSummary | null;
  secondHalf: HalfSummary | null;
}): { quality: RunQuality; reasons: string[] } | null {
  const { workoutType, fullSplits, variability, firstHalf, secondHalf } = args;
  if (fullSplits.length < 3) return null;

  const reasons: string[] = [];
  let severeCount = 0;

  // Pace variability — but walk/jog runs are intentionally intermittent, so a
  // high stdev there is by design, not a defect.
  const paceStdev = variability?.pace_stdev_sec ?? null;
  if (workoutType !== "walk_jog" && paceStdev !== null) {
    if (paceStdev > RQ.PACE_STDEV_SEVERE) {
      reasons.push(`pace_stdev_${Math.round(paceStdev)}s_severe`);
      severeCount++;
    } else if (paceStdev > RQ.PACE_STDEV_DEGRADED) {
      reasons.push(`pace_stdev_${Math.round(paceStdev)}s`);
    }
  }

  // Second-half fade (positive = slower in the back half).
  const firstPace = firstHalf?.avg_pace_seconds_per_mile ?? null;
  const secondPace = secondHalf?.avg_pace_seconds_per_mile ?? null;
  if (firstPace !== null && secondPace !== null) {
    const fade = secondPace - firstPace;
    if (fade > RQ.PACE_FADE_SEVERE) {
      reasons.push(`pace_fade_${Math.round(fade)}s_per_mi_severe`);
      severeCount++;
    } else if (fade > RQ.PACE_FADE_DEGRADED) {
      reasons.push(`pace_fade_${Math.round(fade)}s_per_mi`);
    }
  }

  // Power drop across halves — effort fading.
  const firstPower = firstHalf?.avg_running_power_watts ?? null;
  const secondPower = secondHalf?.avg_running_power_watts ?? null;
  if (firstPower !== null && secondPower !== null) {
    const drop = secondPower - firstPower;
    if (drop < RQ.POWER_FADE_DEGRADED) {
      reasons.push(`power_drop_${Math.round(Math.abs(drop))}w`);
    }
  }

  // Stall — a full mile far slower than the run's median points at a walk or
  // stop mid-run. A strong, on its own sufficient, signal.
  const paces = fullSplits
    .map((sp) => sp.pace_seconds_per_mile)
    .filter((p): p is number => p !== null && Number.isFinite(p));
  if (paces.length >= 3) {
    const med = median(paces);
    const slowest = Math.max(...paces);
    if (med > 0 && slowest > RQ.STALL_FACTOR * med) {
      reasons.push(`stall_split_${Math.round(slowest)}s_vs_median_${Math.round(med)}s`);
      severeCount++;
    }
  }

  if (reasons.length === 0) return { quality: "clean", reasons };
  if (severeCount >= 2) return { quality: "aborted", reasons };
  if (reasons.length >= 2 || severeCount >= 1) return { quality: "degraded", reasons };
  // A single mild signal isn't enough to asterisk the run.
  return { quality: "clean", reasons: [] };
}

// ---------------------------------------------------------------------------
// Tier 2 — heuristic workout classifier
// ---------------------------------------------------------------------------

/** Returns the share of HR samples whose value falls in [lo, hi). */
function fractionInZone(
  samples: IngestSample[] | undefined,
  lo: number,
  hi: number
): number {
  if (!samples || samples.length === 0) return 0;
  let count = 0;
  let inZone = 0;
  for (const s of samples) {
    if (!Number.isFinite(s.value)) continue;
    count++;
    if (s.value >= lo && s.value < hi) inZone++;
  }
  return count > 0 ? inZone / count : 0;
}

/** Extract workout_type from a PaceRunner config name like "5mi Easy" or
 *  "Tempo Progression". Returns null when no keyword matches — caller
 *  falls back to the HR heuristic in that case.
 *
 *  Why 0.95 confidence: the user typed this name themselves to describe
 *  the workout's intent. It's the cleanest signal we'll ever have. We
 *  don't go to 1.0 because the config name could be aspirational (the
 *  user intended a tempo but actually ran easy) — the coach should still
 *  be able to cross-check against the actual HR/pace data. */
function classifyFromConfigName(
  name: string | null
): { workoutType: WorkoutType; confidence: number } | null {
  if (!name) return null;
  const lower = name.toLowerCase();
  // Order matters — more specific keywords first.
  if (/\brace\b|\bmarathon\b|\bhalf marathon\b|\b10k\b|\b5k\b/.test(lower)) {
    return { workoutType: "race", confidence: 0.95 };
  }
  if (/\btempo\b|\bthreshold\b|\blactate\b/.test(lower)) {
    return { workoutType: "tempo", confidence: 0.95 };
  }
  if (/\blong\b|\blsd\b/.test(lower)) {
    return { workoutType: "long", confidence: 0.95 };
  }
  if (/\brecovery\b|\bshakeout\b/.test(lower)) {
    return { workoutType: "recovery", confidence: 0.95 };
  }
  if (/\beasy\b|\bbase\b|\bz1\b|\bz2\b|\bzone 1\b|\bzone 2\b/.test(lower)) {
    return { workoutType: "easy", confidence: 0.95 };
  }
  if (/\bwalk\b|\bjog\b/.test(lower)) {
    return { workoutType: "walk_jog", confidence: 0.95 };
  }
  if (/\bmod(erate)?\b|\bsteady\b|\bmedium\b/.test(lower)) {
    return { workoutType: "moderate", confidence: 0.95 };
  }
  return null;
}

function classifyWorkout(args: {
  distanceMiles: number | null;
  durationSeconds: number;
  avgHR: number | null;
  avgPace: number | null;
  hrSamples: IngestSample[] | undefined;
  baseline: UserBaseline | null;
}): { workoutType: WorkoutType | null; confidence: number | null } {
  const { distanceMiles, avgHR, avgPace, hrSamples, baseline } = args;

  // Without distance there's nothing to classify on — bail.
  if (distanceMiles === null || distanceMiles <= 0) {
    return { workoutType: null, confidence: null };
  }

  // ----- Walk / jog detector — pure pace test, runs first because nothing
  // else should call a walk anything else.
  if (avgPace !== null && avgPace > 13 * 60) {
    return { workoutType: "walk_jog", confidence: 0.9 };
  }

  // Use observed max HR when we have it; otherwise fall back to a generic
  // 190 bpm (rough adult athlete max). Mark lower confidence in that case.
  const maxHR = baseline?.observed_max_hr_bpm ?? 190;
  const baselineKnown = baseline?.observed_max_hr_bpm != null;
  const confidenceFloor = baselineKnown ? 0.5 : 0.3;

  // ----- Race detector — long distance + sustained high HR.
  if (distanceMiles >= 13 && avgHR !== null && avgHR >= 0.85 * maxHR) {
    return { workoutType: "race", confidence: Math.max(confidenceFloor, 0.85) };
  }

  // ----- Long run — distance ≥ 1.5× user's median workout, when we have one.
  if (baseline?.median_workout_miles_30d != null
    && distanceMiles >= 1.5 * baseline.median_workout_miles_30d
    && distanceMiles >= 6) {
    return { workoutType: "long", confidence: 0.85 };
  }
  // Without baseline: anything ≥ 10 mi gets labeled long with lower confidence.
  if (!baselineKnown && distanceMiles >= 10) {
    return { workoutType: "long", confidence: 0.6 };
  }

  // ----- Tempo — substantial time in HR zone 3-4.
  if (hrSamples && avgHR !== null) {
    const tempoZoneFraction = fractionInZone(
      hrSamples,
      0.7 * maxHR,
      0.85 * maxHR
    );
    if (tempoZoneFraction >= 0.5 && avgHR >= 0.7 * maxHR) {
      return {
        workoutType: "tempo",
        confidence: Math.max(confidenceFloor, Math.min(0.9, tempoZoneFraction)),
      };
    }
  }

  // ----- Recovery — low HR AND noticeably slower than user's easy pace.
  if (avgHR !== null && avgHR < 0.65 * maxHR) {
    if (baseline?.median_easy_pace_seconds_per_mile_30d != null
      && avgPace !== null
      && avgPace > 1.2 * baseline.median_easy_pace_seconds_per_mile_30d) {
      return { workoutType: "recovery", confidence: 0.75 };
    }
  }

  // ----- Easy — default for moderate distance, moderate effort.
  if (avgHR !== null && avgHR < 0.75 * maxHR) {
    return {
      workoutType: "easy",
      confidence: baselineKnown ? 0.7 : 0.5,
    };
  }

  // ----- Moderate — catch-all for runs that didn't match anything cleanly.
  return { workoutType: "moderate", confidence: 0.4 };
}
