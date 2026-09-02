/**
 * Workout structure detection.
 *
 * The summary metrics (first_half, drift, split_variability, run_quality,
 * hr_to_power_ratio) all assume one continuous effort. That breaks for
 * structured sessions — an easy run with strides at the end, a tempo
 * sandwiched in warmup/cooldown, intervals — where the non-core phases
 * pollute every whole-workout average and trip the run_quality signals.
 *
 * This module walks the per-sample power/speed/HR series and segments the
 * workout into phases (warmup, steady, tempo, intervals, strides, cooldown).
 * summary.ts then recomputes the effort metrics over the *core* phase only,
 * and preserves the whole-workout numbers under `full_workout_summary`.
 *
 * Detection order matters (strides first — most distinctive; then
 * tempo/intervals; then warmup/cooldown as bracketing segments; then steady
 * as the remainder). Thresholds were calibrated against real ingested runs:
 *   - easy run + 4 strides (Jul 8): 4 walk-bracketed 380-420 W bursts clustered
 *     in the final ~7 min over a ~216 W steady core → strides detected, core
 *     ends at the walk-rest before the first burst.
 *   - the mislabeled "degraded" easy run (Jul 2): same signature, 4 strides.
 *   - a bonked long run (Jul 5): long walk segments, no end-cluster of bursts →
 *     no structure, stays a single (aborted) effort.
 *   - clean easy/long/recovery runs: isolated ~305 W blips embedded in steady
 *     running (an Apple Watch power artifact, ~1 per 7 min) are NOT strides —
 *     they aren't walk-bracketed and don't cluster near the end.
 */

import type { IngestSample, IngestSamples, SplitForSummary } from "./summary.js";

const METERS_PER_MILE = 1609.344;

export type PhaseType =
  | "warmup"
  | "steady"
  | "tempo"
  | "intervals"
  | "strides"
  | "cooldown";

export interface WorkoutPhase {
  phase: PhaseType;
  start_seconds: number;
  end_seconds: number;
  distance_miles: number | null;
  avg_pace_seconds_per_mile: number | null;
  avg_hr_bpm: number | null;
  avg_running_power_watts: number | null;
  // strides / intervals only
  reps?: number;
  avg_stride_duration_seconds?: number;
  avg_stride_pace_seconds_per_mile?: number | null;
  peak_stride_power_watts?: number | null;
}

export interface WorkoutStructure {
  phases: WorkoutPhase[];
  /** Index into `phases` of the phase that represents the main effort — the
   *  `steady` phase for easy/long/recovery/stride sessions, the `tempo` /
   *  `intervals` phase for quality sessions. Existing summary metrics are
   *  recomputed over this phase's time window. */
  core_phase_index: number;
  /** 0–1 confidence that the detected structure is real (vs. a single
   *  continuous effort mis-segmented by noise). */
  detection_confidence: number;

  // -------- convenience mirrors of the core phase boundaries -------------
  /** True when a trailing stride block was detected. */
  has_strides: boolean;
  /** Elapsed seconds at which the core effort starts (end of any warmup). */
  core_start_seconds: number;
  /** Elapsed seconds at which the core effort ends (start of trailing
   *  strides/cooldown). Equal to the total sample span when nothing trails. */
  core_end_seconds: number;
  /** Total sample-elapsed span (seconds from the power t0 to the last sample).
   *  The reference clock for `core_start_seconds` / `core_end_seconds`; callers
   *  should compare against this, not the workout's (possibly moving-time)
   *  duration, to decide whether the core is a strict subset. */
  total_sample_seconds: number;
}

// ---------------------------------------------------------------------------
// Sample timeline
// ---------------------------------------------------------------------------

interface Pt {
  t: number; // elapsed seconds from workout start
  v: number;
}

/** Parse an ISO timestamp to epoch seconds; NaN on failure. */
function epoch(iso: string): number {
  return Date.parse(iso) / 1000;
}

function toSeries(samples: IngestSample[] | undefined, t0: number): Pt[] {
  if (!samples) return [];
  const out: Pt[] = [];
  for (const s of samples) {
    const t = epoch(s.start);
    if (!Number.isFinite(t) || !Number.isFinite(s.value)) continue;
    out.push({ t: t - t0, v: s.value });
  }
  out.sort((a, b) => a.t - b.t);
  return out;
}

function median(xs: number[]): number {
  if (xs.length === 0) return NaN;
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

function meanIn(series: Pt[], startSec: number, endSec: number): number | null {
  let sum = 0;
  let n = 0;
  for (const p of series) {
    if (p.t < startSec || p.t >= endSec) continue;
    sum += p.v;
    n++;
  }
  return n > 0 ? sum / n : null;
}

/** Sum of incremental distance samples (meters) inside [startSec, endSec). */
function sumIn(series: Pt[], startSec: number, endSec: number): number {
  let sum = 0;
  for (const p of series) {
    if (p.t < startSec || p.t >= endSec) continue;
    sum += p.v;
  }
  return sum;
}

// ---------------------------------------------------------------------------
// Effort-band segmentation
// ---------------------------------------------------------------------------

type Band = "fast" | "steady" | "walk";

interface Segment {
  band: Band;
  start: number; // elapsed seconds
  end: number;
  medPower: number;
}

/** Thresholds, all relative to the run's median (core) power. Calibrated so
 *  true strides (>1.6× core) clear the fast bar and walk-rest (<0.6× core)
 *  clears the walk bar, while steady-embedded power blips (~1.4× core) do not
 *  register as bursts on their own. */
const BAND = {
  FAST_FACTOR: 1.5,
  WALK_FACTOR: 0.6,
} as const;

const STRIDE = {
  MIN_BURST_SEC: 8,
  MAX_BURST_SEC: 45, // strides are short accelerations (spec: 10-45s)
  MIN_POWER_FACTOR: 1.55, // burst median power must clear this × core power
  BRACKET_WALK_GAP_SEC: 90, // a walk within this many sec brackets a burst
  CLUSTER_GAP_SEC: 160, // consecutive bursts within this gap join a cluster
  MIN_REPS: 3,
  MIN_CENTER_FRACTION: 0.6, // cluster center must sit in the final 40%
  LEAD_WALK_LOOKBACK_SEC: 180,
} as const;

const BRACKET = {
  // warmup / cooldown: slower-than-core bracketing segments
  MIN_SEC: 180,
  MAX_SEC: 900,
} as const;

function segment(power: Pt[], corePower: number): Segment[] {
  const fast = BAND.FAST_FACTOR * corePower;
  const walk = BAND.WALK_FACTOR * corePower;
  const segs: Segment[] = [];
  let band: Band | null = null;
  let start = 0;
  let vals: number[] = [];
  const flush = (end: number) => {
    if (band && vals.length) {
      segs.push({ band, start, end, medPower: median(vals) });
    }
    vals = [];
  };
  for (const p of power) {
    const b: Band = p.v > fast ? "fast" : p.v < walk ? "walk" : "steady";
    if (b !== band) {
      flush(p.t);
      band = b;
      start = p.t;
    }
    vals.push(p.v);
  }
  flush(power.length ? power[power.length - 1].t : 0);
  return segs;
}

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------

/**
 * Detect the structure of a workout from its sample streams. Returns null when
 * there isn't enough signal (no power/speed series) or when the workout is a
 * single continuous effort with no detectable phases — in both cases the
 * caller keeps the existing whole-workout metrics unchanged.
 */
export function detectWorkoutStructure(args: {
  samples: IngestSamples | undefined;
  durationSeconds: number;
  /** Per-mile splits (with start_time/end_time/pace). Used for tempo/interval
   *  detection, which is a mile-scale, faster-than-easy shift rather than the
   *  sub-minute power bursts that define strides. */
  splits?: SplitForSummary[];
}): WorkoutStructure | null {
  const s = args.samples ?? {};
  const powerRaw = s.runningPower;
  if (!powerRaw || powerRaw.length < 10) return null;

  const t0 = Math.min(
    ...powerRaw.map((x) => epoch(x.start)).filter(Number.isFinite)
  );
  if (!Number.isFinite(t0)) return null;

  const power = toSeries(powerRaw, t0);
  const speed = toSeries(s.runningSpeed, t0);
  const hr = toSeries(s.heartRate, t0);
  const dist = toSeries(s.distanceWalkingRunning, t0);
  if (power.length < 10) return null;

  // Everything here works in sample-elapsed time (seconds from the power t0).
  // `durationSeconds` is deliberately NOT mixed in: it may be moving-time
  // (paused time excluded, see the pace-average change) which is a different
  // clock, and the stride-cluster "final 40%" test must be measured on the
  // same timeline as the sample timestamps it compares.
  const T = Math.max(
    power[power.length - 1].t,
    speed.length ? speed[speed.length - 1].t : 0
  );
  const corePower = median(power.map((p) => p.v));
  // Need a plausible running-power core to band against. A walk-dominant or
  // sensor-glitched workout with a very low median can't be banded reliably
  // (a ~40 W core would make ordinary jogging read as a continuous fast band).
  if (!Number.isFinite(corePower) || corePower < 100) return null;

  const segs = segment(power, corePower);

  // ---- Strides: a tight end-cluster of walk-bracketed fast bursts ----------
  const walkSegs = segs.filter((g) => g.band === "walk");
  const isBracketed = (g: Segment): boolean =>
    walkSegs.some(
      (w) =>
        (w.start >= g.end && w.start - g.end <= STRIDE.BRACKET_WALK_GAP_SEC) ||
        (w.end <= g.start && g.start - w.end <= STRIDE.BRACKET_WALK_GAP_SEC)
    );
  // A stride burst is short, clearly harder than the steady core (a higher bar
  // than the segmentation FAST band, so run-walk jog-surges during a bonk —
  // which sit only slightly above core — don't qualify), and walk-bracketed.
  const strideFast = STRIDE.MIN_POWER_FACTOR * corePower;
  const bursts = segs.filter(
    (g) =>
      g.band === "fast" &&
      g.medPower >= strideFast &&
      g.end - g.start >= STRIDE.MIN_BURST_SEC &&
      g.end - g.start <= STRIDE.MAX_BURST_SEC &&
      isBracketed(g)
  );

  // Cluster consecutive bursts.
  const clusters: Segment[][] = [];
  for (const b of bursts) {
    const last = clusters[clusters.length - 1];
    if (last && b.start - last[last.length - 1].end <= STRIDE.CLUSTER_GAP_SEC) {
      last.push(b);
    } else {
      clusters.push([b]);
    }
  }
  let strideCluster: Segment[] | null = null;
  for (const cl of clusters) {
    if (cl.length < STRIDE.MIN_REPS) continue;
    const center = (cl[0].start + cl[cl.length - 1].end) / 2;
    if (center >= STRIDE.MIN_CENTER_FRACTION * T) {
      strideCluster = cl;
      break;
    }
  }

  // Core effort ends where the run transitions into the stride block: the
  // start of the walk-rest that leads into the first burst (or the first
  // burst itself if it wasn't preceded by a walk).
  let coreEnd = T;
  let strides: WorkoutPhase | null = null;
  if (strideCluster) {
    const first = strideCluster[0];
    const last = strideCluster[strideCluster.length - 1];
    let leadStart = first.start;
    for (const w of walkSegs) {
      if (
        w.end <= first.start + 5 &&
        first.start - w.end <= STRIDE.LEAD_WALK_LOOKBACK_SEC
      ) {
        leadStart = Math.min(leadStart, w.start);
      }
    }
    coreEnd = leadStart;
    const durs = strideCluster.map((b) => b.end - b.start);
    // Stride pace = the fast portion only. The phase's `avg_pace_seconds_per_mile`
    // spans the walking recovery between reps, so it reads far slower than any
    // stride was actually run (~13:00/mi on a real 4-stride block) and is
    // misleading if read as "stride pace".
    let burstMeters = 0;
    let burstSeconds = 0;
    for (const b of strideCluster) {
      burstMeters += sumIn(dist, b.start, b.end);
      burstSeconds += b.end - b.start;
    }
    const stridePace =
      burstMeters > 0 && burstSeconds > 0
        ? round(burstSeconds / (burstMeters / METERS_PER_MILE), 1)
        : null;
    // True peak = the single hardest power sample inside any burst window
    // (not the max of per-burst medians).
    let peakPower = -Infinity;
    for (const b of strideCluster) {
      for (const p of power) {
        if (p.t >= b.start && p.t <= b.end && p.v > peakPower) peakPower = p.v;
      }
    }
    strides = {
      phase: "strides",
      start_seconds: Math.round(leadStart),
      end_seconds: Math.round(last.end),
      distance_miles: round(sumIn(dist, leadStart, last.end) / METERS_PER_MILE, 2),
      avg_pace_seconds_per_mile: pace(dist, leadStart, last.end),
      avg_hr_bpm: roundOrNull(meanIn(hr, leadStart, last.end), 0),
      avg_running_power_watts: roundOrNull(meanIn(power, leadStart, last.end), 0),
      reps: strideCluster.length,
      avg_stride_duration_seconds: Math.round(mean(durs)),
      avg_stride_pace_seconds_per_mile: stridePace,
      peak_stride_power_watts: Number.isFinite(peakPower) ? Math.round(peakPower) : null,
    };
  }

  // ---- Tempo / intervals: a faster-than-easy block across the splits -------
  // Tempo effort sits only ~1.1× the easy power, invisible to the stride-style
  // power band, but shows up clearly as a run of per-mile splits well faster
  // than the easy baseline. Only meaningful on a non-stride run, and only over
  // the pre-stride region. See detectTempo for the calibrated rules.
  const tempo = strides ? null : detectTempo(args.splits, t0, coreEnd, dist, hr, power);

  // ---- Warmup / cooldown: slower-than-core (walking) bracketing segments ---
  const warmupWalk = detectBracket(segs, dist, hr, power, "warmup", coreEnd);
  const cooldownWalk = detectBracket(segs, dist, hr, power, "cooldown", coreEnd);

  // ---- Assemble phases -----------------------------------------------------
  const phases: WorkoutPhase[] = [];
  let coreStart = warmupWalk ? warmupWalk.end_seconds : 0;
  let coreEndAdj = cooldownWalk ? Math.min(coreEnd, cooldownWalk.start_seconds) : coreEnd;
  let corePhaseKind: PhaseType = "steady";
  let intervalReps: number | undefined;

  if (tempo) {
    // The tempo/interval block IS the core; the easy running before and after
    // becomes the warmup / cooldown brackets.
    coreStart = tempo.start_seconds;
    coreEndAdj = tempo.end_seconds;
    corePhaseKind = tempo.kind;
    intervalReps = tempo.reps;
    if (tempo.start_seconds > 60) {
      phases.push(bracketPhase("warmup", 0, tempo.start_seconds, dist, hr, power));
    }
  } else if (warmupWalk) {
    phases.push(warmupWalk);
  }

  const corePhase: WorkoutPhase = {
    phase: corePhaseKind,
    start_seconds: Math.round(coreStart),
    end_seconds: Math.round(coreEndAdj),
    distance_miles: round(sumIn(dist, coreStart, coreEndAdj) / METERS_PER_MILE, 2),
    avg_pace_seconds_per_mile: pace(dist, coreStart, coreEndAdj),
    avg_hr_bpm: roundOrNull(meanIn(hr, coreStart, coreEndAdj), 0),
    avg_running_power_watts: roundOrNull(meanIn(power, coreStart, coreEndAdj), 0),
  };
  if (intervalReps) corePhase.reps = intervalReps;
  const coreIndex = phases.push(corePhase) - 1;

  if (tempo) {
    if (coreEndAdj < T - 60) {
      phases.push(bracketPhase("cooldown", coreEndAdj, T, dist, hr, power));
    }
  } else if (cooldownWalk) {
    phases.push(cooldownWalk);
  }
  if (strides) phases.push(strides);

  // A workout with only a steady core and nothing else isn't "structured" —
  // return null so the caller keeps the plain whole-workout path.
  const hasStructure =
    strides !== null || tempo !== null || warmupWalk !== null || cooldownWalk !== null;
  if (!hasStructure) return null;

  // Confidence: strides clusters are the cleanest signal; tempo/interval and
  // walk brackets are softer.
  let confidence = 0.5;
  if (strides) confidence = 0.85;
  else if (tempo) confidence = tempo.kind === "tempo" ? 0.75 : 0.7;
  else if (warmupWalk || cooldownWalk) confidence = 0.55;

  return {
    phases,
    core_phase_index: coreIndex,
    detection_confidence: round(confidence, 2) ?? confidence,
    has_strides: strides !== null,
    core_start_seconds: Math.round(coreStart),
    core_end_seconds: Math.round(coreEndAdj),
    total_sample_seconds: Math.round(T),
  };
}

const TEMPO = {
  MIN_SPLITS: 4, // need room for easy + tempo + easy
  WALK_PACE: 780, // s/mi; a split slower than this is walking, not easy running
  EASY_SLOWEST_FRACTION: 0.4, // baseline = median of the slowest this-fraction
  PACE_DELTA: 30, // s/mi faster than easy to count a split as tempo
  /** A leading split at least this much slower than the rest of its block is a
   *  warmup that got swallowed, not part of the effort. */
  WARMUP_PACE_RATIO: 1.08,
  WARMUP_MIN_SEC: 3 * 60,
  WARMUP_MAX_SEC: 15 * 60,
} as const;

interface TempoResult {
  start_seconds: number;
  end_seconds: number;
  kind: "tempo" | "intervals";
  reps?: number;
}

/**
 * Detect a tempo (one sustained faster block) or intervals (≥2 faster blocks
 * separated by recovery) from the per-mile splits.
 *
 * Method (calibrated against a real 2 mi easy + 3 mi tempo run, where tempo
 * power was only ~1.1× easy — far too subtle for a power-band test, but a clear
 * ~40 s/mi pace shift at the split level):
 *   - Consider full-mile splits in the pre-stride region only.
 *   - If any split is walking pace, this is a bonk / run-walk, not a clean
 *     tempo — bail (run_quality already handles those as degraded/aborted).
 *   - Easy baseline = median pace of the slowest ~40% of splits (robust even
 *     when the tempo block dominates the run).
 *   - A tempo split is ≥ PACE_DELTA faster than that baseline; a block is ≥2
 *     contiguous tempo splits. One block → tempo; ≥2 → intervals. A block
 *     spanning every split (no easy bracket at all) is just a fast run, not a
 *     tempo — rejected.
 *
 * Interval detection is uncalibrated (no real interval data yet); the ≥2-block
 * rule is a placeholder that won't fire on steady/tempo runs.
 */
function detectTempo(
  splits: SplitForSummary[] | undefined,
  t0: number | null,
  coreEnd: number,
  dist: Pt[],
  hr: Pt[],
  power: Pt[]
): TempoResult | null {
  if (!splits || t0 === null) return null;
  const elapsed = splits
    .filter(
      (s) =>
        (s.distance_meters ?? 0) >= 0.5 * METERS_PER_MILE &&
        s.pace_seconds_per_mile != null &&
        s.start_time != null &&
        s.end_time != null
    )
    .map((s) => ({
      startSec: Date.parse(s.start_time!) / 1000 - t0,
      endSec: Date.parse(s.end_time!) / 1000 - t0,
      pace: s.pace_seconds_per_mile as number,
    }))
    .filter((s) => Number.isFinite(s.startSec) && s.endSec <= coreEnd + 15);
  if (elapsed.length < TEMPO.MIN_SPLITS) return null;

  const paces = elapsed.map((s) => s.pace);
  if (paces.some((p) => p > TEMPO.WALK_PACE)) return null; // bonk / run-walk

  const slowestFirst = [...paces].sort((a, b) => b - a);
  const k = Math.max(2, Math.round(paces.length * TEMPO.EASY_SLOWEST_FRACTION));
  const easy = median(slowestFirst.slice(0, k));
  const threshold = easy - TEMPO.PACE_DELTA;

  const mask = paces.map((p) => p <= threshold);
  const blocks: Array<[number, number]> = [];
  let i = 0;
  while (i < mask.length) {
    if (mask[i]) {
      let j = i;
      while (j < mask.length && mask[j]) j++;
      if (j - i >= 2) blocks.push([i, j]);
      i = j;
    } else {
      i++;
    }
  }
  if (blocks.length === 0) return null;
  // A single block that spans every split is just a fast run, not a tempo
  // bracketed by easy running.
  if (blocks.length === 1 && blocks[0][1] - blocks[0][0] >= mask.length) return null;

  // A leading warmup swallowed into the block. The easy baseline is the median
  // of the slowest ~40% of splits, so on a "1mi easy + 4mi tempo" session the
  // single easy mile is half that sample and drags the baseline down until the
  // warmup itself clears the threshold. Re-check the block's own first split
  // against the effort it supposedly belongs to.
  const firstBlock = blocks[0];
  if (firstBlock[0] === 0 && firstBlock[1] - firstBlock[0] >= 3) {
    const blockPaces = paces.slice(firstBlock[0], firstBlock[1]);
    const restMedian = median(blockPaces.slice(1));
    const lead = elapsed[0];
    const leadDuration = lead.endSec - lead.startSec;
    const isSlowerThanEffort = lead.pace >= TEMPO.WARMUP_PACE_RATIO * restMedian;
    const isWarmupLength =
      leadDuration >= TEMPO.WARMUP_MIN_SEC && leadDuration <= TEMPO.WARMUP_MAX_SEC;
    if (isSlowerThanEffort && isWarmupLength) {
      firstBlock[0] = 1;
    }
  }

  const first = elapsed[firstBlock[0]];
  const last = elapsed[blocks[blocks.length - 1][1] - 1];
  // Clamp to 0: a split's start_time can precede the power-sample t0 by a
  // second or two, which previously surfaced as `start_seconds: -1`.
  return {
    start_seconds: Math.max(0, Math.round(first.startSec)),
    end_seconds: Math.max(0, Math.round(last.endSec)),
    kind: blocks.length >= 2 ? "intervals" : "tempo",
    reps: blocks.length >= 2 ? blocks.length : undefined,
  };
}

/** Build a warmup/cooldown phase over an elapsed window from the sample series. */
function bracketPhase(
  kind: "warmup" | "cooldown",
  startSec: number,
  endSec: number,
  dist: Pt[],
  hr: Pt[],
  power: Pt[]
): WorkoutPhase {
  return {
    phase: kind,
    start_seconds: Math.round(startSec),
    end_seconds: Math.round(endSec),
    distance_miles: round(sumIn(dist, startSec, endSec) / METERS_PER_MILE, 2),
    avg_pace_seconds_per_mile: pace(dist, startSec, endSec),
    avg_hr_bpm: roundOrNull(meanIn(hr, startSec, endSec), 0),
    avg_running_power_watts: roundOrNull(meanIn(power, startSec, endSec), 0),
  };
}

/**
 * Detect a leading (warmup) or trailing (cooldown) slower-than-core segment.
 * Uses the walk/steady band segments: a warmup/cooldown shows up as a slow
 * (walk-band or notably below-core) stretch of 3–15 min at the appropriate
 * end of the core region. Returns null when absent (the common case for the
 * user's easy runs, which start and end running).
 */
function detectBracket(
  segs: Segment[],
  dist: Pt[],
  hr: Pt[],
  power: Pt[],
  which: "warmup" | "cooldown",
  coreEnd: number
): WorkoutPhase | null {
  const candidates = segs.filter(
    (g) =>
      g.band === "walk" &&
      g.end - g.start >= BRACKET.MIN_SEC &&
      g.end - g.start <= BRACKET.MAX_SEC
  );
  if (candidates.length === 0) return null;
  const seg =
    which === "warmup"
      ? candidates.find((g) => g.start <= 60) // must sit at the very start
      : candidates
          .slice()
          .reverse()
          .find((g) => g.end >= coreEnd - 60 && g.start < coreEnd); // trailing, pre-stride
  if (!seg) return null;
  return {
    phase: which,
    start_seconds: Math.round(seg.start),
    end_seconds: Math.round(seg.end),
    distance_miles: round(sumIn(dist, seg.start, seg.end) / METERS_PER_MILE, 2),
    avg_pace_seconds_per_mile: pace(dist, seg.start, seg.end),
    avg_hr_bpm: roundOrNull(meanIn(hr, seg.start, seg.end), 0),
    avg_running_power_watts: roundOrNull(meanIn(power, seg.start, seg.end), 0),
  };
}

// ---------------------------------------------------------------------------
// small numeric helpers (kept local so this module has no import cycle)
// ---------------------------------------------------------------------------

function mean(xs: number[]): number {
  return xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0;
}

function round(n: number | null, decimals = 1): number | null {
  if (n === null || !Number.isFinite(n)) return null;
  const f = Math.pow(10, decimals);
  return Math.round(n * f) / f;
}

function roundOrNull(n: number | null, decimals: number): number | null {
  return round(n, decimals);
}

/** Pace (sec/mi) over a window, from summed incremental distance samples. */
function pace(dist: Pt[], startSec: number, endSec: number): number | null {
  const meters = sumIn(dist, startSec, endSec);
  const dur = endSec - startSec;
  if (meters <= 0 || dur <= 0) return null;
  return round(dur / (meters / METERS_PER_MILE), 1);
}
