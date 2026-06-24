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
}

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

  // Tier 1 derived metrics. All take the same defensive shape: null if
  // we don't have the inputs to compute meaningfully.
  const fullSplits = (args.splits ?? []).filter(isFullSplit);
  const { firstHalf, secondHalf } = computeHalves(fullSplits);
  const drift = computeDrift(fullSplits);
  const variability = computeVariability(fullSplits);
  const hrToPower = (avgHR !== null && avgPower !== null && avgPower > 0)
    ? avgHR / avgPower
    : null;

  // Tier 2 — classification. Prefer user intent (config name) when present;
  // fall back to HR-based heuristics otherwise.
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
      avgHR,
      avgPace: pace,
      hrSamples: s.heartRate,
      baseline: args.baseline ?? null,
    });
    workoutType = fromHeuristic.workoutType;
    confidence = fromHeuristic.confidence;
  }

  return {
    avg_heart_rate_bpm: round(avgHR, 0),
    max_heart_rate_bpm: hr ? Math.round(hr.max) : null,
    min_heart_rate_bpm: hr ? Math.round(hr.min) : null,

    avg_pace_seconds_per_mile: round(pace, 1),

    avg_running_power_watts: round(avgPower, 1),
    max_running_power_watts: power ? Math.round(power.max) : null,

    avg_running_speed_mps: round(avg(speed), 2),
    avg_stride_length_m: round(avg(stride), 2),
    avg_cadence_spm: round(cadence, 1),
    avg_ground_contact_ms: round(avg(gct), 1),
    avg_vertical_oscillation_cm: round(avg(vosc), 2),

    elevation_gain_meters: elevGain !== null ? round(elevGain, 1) : null,
    elevation_loss_meters: elevLoss !== null ? round(elevLoss, 1) : null,

    hr_to_power_ratio: round(hrToPower, 3),
    first_half: firstHalf,
    second_half: secondHalf,
    drift,
    split_variability: variability,

    workout_type: workoutType,
    workout_type_confidence: round(confidence, 2),
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
