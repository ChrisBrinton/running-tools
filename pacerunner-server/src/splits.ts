/**
 * Per-mile splits derived from the route GPX.
 *
 * Why not use `workout_events` segments? Because for Apple Watch standard
 * Running workouts, segment events are overlapping internal state markers,
 * not mile boundaries (see workout-events docs in mcp/tools.ts). Splits are
 * derived from the GPS trace and cross-referenced with time-aligned samples
 * for HR/power/elevation.
 *
 * Algorithm:
 *   - Parse GPX into chronological trkpts.
 *   - Walk segment-by-segment (between consecutive trkpts). When a segment
 *     would cross one or more mile boundaries, slice it: linearly interpolate
 *     a virtual point at each boundary, attribute distance/elev/time to the
 *     correct split, then advance to the next boundary.
 *   - For each split, time-window the ingest samples to compute mean HR / power.
 */

import type { IngestSample, IngestSamples } from "./summary.js";

const METERS_PER_MILE = 1609.344;
const EARTH_RADIUS_M = 6_371_000;

export interface ComputedSplit {
  split_number: number;
  unit: "mile" | "km";
  cumulative_distance_meters: number;
  distance_meters: number;
  start_time: string;
  end_time: string;
  duration_seconds: number;
  pace_seconds_per_mile: number | null;
  avg_heart_rate_bpm: number | null;
  avg_running_power_watts: number | null;
  elevation_gain_meters: number;
  elevation_loss_meters: number;
}

interface TrkPt {
  lat: number;
  lon: number;
  ele: number | null;
  t: Date;
}

interface SplitAccumulator {
  startTime: Date;
  distance: number;
  gain: number;
  loss: number;
}

const TRKPT_RE_LAT_FIRST = /<trkpt\b[^>]*\blat="([-\d.]+)"[^>]*\blon="([-\d.]+)"[^>]*>([\s\S]*?)<\/trkpt>/g;
const TRKPT_RE_LON_FIRST = /<trkpt\b[^>]*\blon="([-\d.]+)"[^>]*\blat="([-\d.]+)"[^>]*>([\s\S]*?)<\/trkpt>/g;
const ELE_RE = /<ele>\s*([-\d.eE+]+)\s*<\/ele>/;
const TIME_RE = /<time>\s*([^<]+)\s*<\/time>/;

export function parseTrkpts(gpx: string): TrkPt[] {
  const collect = (re: RegExp, latFirst: boolean): TrkPt[] => {
    const out: TrkPt[] = [];
    re.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = re.exec(gpx)) !== null) {
      const lat = parseFloat(latFirst ? m[1] : m[2]);
      const lon = parseFloat(latFirst ? m[2] : m[1]);
      const body = m[3];
      const timeMatch = body.match(TIME_RE);
      if (!timeMatch) continue;
      const t = new Date(timeMatch[1]);
      if (Number.isNaN(t.getTime())) continue;
      const eleMatch = body.match(ELE_RE);
      const ele = eleMatch ? parseFloat(eleMatch[1]) : null;
      if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
      out.push({ lat, lon, ele, t });
    }
    return out;
  };

  const a = collect(TRKPT_RE_LAT_FIRST, true);
  const b = collect(TRKPT_RE_LON_FIRST, false);
  const pts = a.length >= b.length ? a : b;
  pts.sort((x, y) => x.t.getTime() - y.t.getTime());
  return pts;
}

function haversine(a: TrkPt, b: TrkPt): number {
  const phi1 = (a.lat * Math.PI) / 180;
  const phi2 = (b.lat * Math.PI) / 180;
  const dphi = ((b.lat - a.lat) * Math.PI) / 180;
  const dlam = ((b.lon - a.lon) * Math.PI) / 180;
  const x =
    Math.sin(dphi / 2) ** 2 +
    Math.cos(phi1) * Math.cos(phi2) * Math.sin(dlam / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.sqrt(x));
}

function lerp(a: number, b: number, f: number): number {
  return a + (b - a) * f;
}

function meanSampleIn(
  samples: IngestSample[] | undefined,
  from: Date,
  to: Date
): number | null {
  if (!samples || samples.length === 0) return null;
  let sum = 0;
  let n = 0;
  const fromMs = from.getTime();
  const toMs = to.getTime();
  for (const s of samples) {
    const ts = Date.parse(s.start);
    if (Number.isNaN(ts)) continue;
    if (ts < fromMs || ts >= toMs) continue;
    if (!Number.isFinite(s.value)) continue;
    sum += s.value;
    n++;
  }
  return n > 0 ? sum / n : null;
}

function round(n: number, decimals = 1): number {
  const f = Math.pow(10, decimals);
  return Math.round(n * f) / f;
}

function roundOrNull(n: number | null, decimals: number): number | null {
  if (n === null) return null;
  const f = Math.pow(10, decimals);
  return Math.round(n * f) / f;
}

/**
 * Compute per-mile splits. Handles long segments that span multiple mile
 * boundaries (rare at 1Hz GPS, but possible for older sparse Apple Watch
 * data) by slicing them and interpolating.
 */
export function computeMileSplits(args: {
  gpx: string;
  samples: IngestSamples | undefined;
}): ComputedSplit[] {
  const pts = parseTrkpts(args.gpx);
  if (pts.length < 2) return [];

  const splits: ComputedSplit[] = [];
  let cumulative = 0;
  let nextBoundary = METERS_PER_MILE;
  let acc: SplitAccumulator = {
    startTime: pts[0].t,
    distance: 0,
    gain: 0,
    loss: 0,
  };

  // Helper to emit the current accumulator as a finished split.
  const emit = (endTime: Date): void => {
    const durSec = (endTime.getTime() - acc.startTime.getTime()) / 1000;
    const pace = acc.distance > 0
      ? durSec / (acc.distance / METERS_PER_MILE)
      : null;
    cumulative += acc.distance;
    splits.push({
      split_number: splits.length + 1,
      unit: "mile",
      cumulative_distance_meters: round(cumulative, 1),
      distance_meters: round(acc.distance, 1),
      start_time: acc.startTime.toISOString(),
      end_time: endTime.toISOString(),
      duration_seconds: round(durSec, 1),
      pace_seconds_per_mile: pace === null ? null : round(pace, 1),
      avg_heart_rate_bpm: roundOrNull(
        meanSampleIn(args.samples?.heartRate, acc.startTime, endTime), 0
      ),
      avg_running_power_watts: roundOrNull(
        meanSampleIn(args.samples?.runningPower, acc.startTime, endTime), 0
      ),
      elevation_gain_meters: round(acc.gain, 1),
      elevation_loss_meters: round(acc.loss, 1),
    });
  };

  let totalSoFar = 0;
  for (let i = 1; i < pts.length; i++) {
    let from = pts[i - 1];
    const to = pts[i];
    let segRemaining = haversine(from, to);
    const segFullDist = segRemaining;
    const segDurMs = to.t.getTime() - from.t.getTime();

    while (totalSoFar + segRemaining >= nextBoundary) {
      // How much of this segment falls inside the current split?
      const distToBoundary = nextBoundary - totalSoFar;
      const fracOfFull = segFullDist > 0
        ? (segFullDist - segRemaining + distToBoundary) / segFullDist
        : 0;

      // Interpolate the virtual point at the boundary
      const baseFracInSegment = segFullDist > 0
        ? distToBoundary / segFullDist
        : 0;
      const virt: TrkPt = {
        lat: lerp(from.lat, to.lat, baseFracInSegment),
        lon: lerp(from.lon, to.lon, baseFracInSegment),
        ele: from.ele !== null && to.ele !== null
          ? lerp(from.ele, to.ele, baseFracInSegment)
          : null,
        t: new Date(from.t.getTime() + segDurMs * fracOfFull),
      };

      // Attribute pre-boundary portion to the current split
      acc.distance += distToBoundary;
      if (from.ele !== null && virt.ele !== null) {
        const d = virt.ele - from.ele;
        if (d > 0) acc.gain += d; else acc.loss += -d;
      }
      totalSoFar = nextBoundary;
      emit(virt.t);

      // Start a new split at the virtual point
      acc = { startTime: virt.t, distance: 0, gain: 0, loss: 0 };
      nextBoundary += METERS_PER_MILE;

      // Continue with the remainder of the segment from the virtual point
      from = virt;
      segRemaining = segFullDist - distToBoundary - (segFullDist - segRemaining);
      // segRemaining = the post-boundary portion of THIS while-iteration's segment
      // For multi-mile-spanning segments, the loop will repeat; for normal 1Hz
      // running data this loop body runs at most once.
    }

    // Whatever's left of the segment belongs to the current split.
    acc.distance += segRemaining;
    if (from.ele !== null && to.ele !== null) {
      const d = to.ele - from.ele;
      if (d > 0) acc.gain += d; else acc.loss += -d;
    }
    totalSoFar += segRemaining;
  }

  // Final partial split (almost always present — runs rarely end on a mile)
  if (acc.distance > 0) {
    emit(pts[pts.length - 1].t);
  }

  return splits;
}
