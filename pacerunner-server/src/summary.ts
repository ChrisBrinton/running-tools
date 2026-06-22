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

/**
 * Compute the summary blob from an ingest payload. `totalDistanceMeters`
 * and `durationSeconds` come from the top-level workout fields, not from
 * samples — they're what's authoritative on the watch.
 */
export function computeSummary(args: {
  samples: IngestSamples | undefined;
  rawMetadata: Record<string, unknown> | undefined;
  totalDistanceMeters: number | undefined | null;
  durationSeconds: number;
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

  const elevGain = parseCmToMeters(args.rawMetadata?.HKElevationAscended);
  const elevLoss = parseCmToMeters(args.rawMetadata?.HKElevationDescended);

  return {
    avg_heart_rate_bpm: round(avg(hr), 0),
    max_heart_rate_bpm: hr ? Math.round(hr.max) : null,
    min_heart_rate_bpm: hr ? Math.round(hr.min) : null,

    avg_pace_seconds_per_mile: round(pace, 1),

    avg_running_power_watts: round(avg(power), 1),
    max_running_power_watts: power ? Math.round(power.max) : null,

    avg_running_speed_mps: round(avg(speed), 2),
    avg_stride_length_m: round(avg(stride), 2),
    avg_cadence_spm: round(cadence, 1),
    avg_ground_contact_ms: round(avg(gct), 1),
    avg_vertical_oscillation_cm: round(avg(vosc), 2),

    elevation_gain_meters: elevGain !== null ? round(elevGain, 1) : null,
    elevation_loss_meters: elevLoss !== null ? round(elevLoss, 1) : null,
  };
}
