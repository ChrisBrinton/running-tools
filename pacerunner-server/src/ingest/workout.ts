import { Hono } from "hono";
import type { Store } from "../db.js";
import { writeRouteGPX } from "../storage.js";
import { decorateWorkoutWeather } from "../weather.js";
import { computeSummary } from "../summary.js";
import { computeMileSplits } from "../splits.js";
import { computeUserBaseline } from "../baseline.js";

interface WorkoutPayload {
  id: string;
  activity_type: string;
  activity_type_raw?: number;
  start: string;
  end: string;
  duration_seconds: number;
  total_distance_meters?: number;
  total_energy_kcal?: number;
  source_name?: string;
  source_bundle_id?: string;
  raw_metadata?: Record<string, unknown>;
  route_gpx?: string;
  samples?: Record<string, Array<{
    start: string; end: string; value: number; unit: string;
  }>>;
  events?: Array<{ type: string; start: string; duration_seconds: number }>;
  device?: string;
  /** Optional. Name of the PaceRunner run configuration this workout used
   *  (e.g. "5mi Easy"). Tracked separately from activity_type so the
   *  classifier can prefer user-intent over heuristic labels. */
  pacerunner_config_name?: string;
}

export function mountWorkoutIngest(app: Hono, store: Store) {
  app.post("/ingest/workout", async (c) => {
    const auth = c.get("auth");
    let payload: WorkoutPayload;
    try {
      payload = await c.req.json();
    } catch {
      return c.json({ error: "Invalid JSON" }, 400);
    }
    if (!payload.id || !payload.start || !payload.end) {
      return c.json({ error: "Missing required fields: id, start, end" }, 400);
    }

    let routeRelPath: string | null = null;
    if (payload.route_gpx && payload.route_gpx.length > 0) {
      routeRelPath = await writeRouteGPX(store, auth.user.id, payload.id, payload.route_gpx);
    }

    const hasSamples = payload.samples && Object.keys(payload.samples).length > 0;
    const hasEvents = (payload.events?.length ?? 0) > 0;
    const rawMetaJSON = payload.raw_metadata ? JSON.stringify(payload.raw_metadata) : null;
    const isIndoor = detectIndoor(payload.raw_metadata);

    // Compute splits up-front so the summary can fold in derived
    // first-half / second-half / drift / variability + the elev_loss
    // fallback that sums per-split losses when HK metadata is missing.
    let computedSplits: ReturnType<typeof computeMileSplits> = [];
    if (!isIndoor && payload.route_gpx && payload.route_gpx.length > 0) {
      try {
        computedSplits = computeMileSplits({
          gpx: payload.route_gpx,
          samples: payload.samples,
        });
      } catch (e) {
        console.warn(`[splits] ${payload.id}: ${e instanceof Error ? e.message : e}`);
      }
    }

    // Recompute per-user baseline EXCLUDING this workout so it can't
    // influence its own classification. Cheap aggregate query against
    // the user's existing history.
    const baseline = computeUserBaseline(store, auth.user.id, payload.id);

    // Compute the summary blob with splits + baseline folded in.
    const summary = computeSummary({
      samples: payload.samples,
      rawMetadata: payload.raw_metadata,
      totalDistanceMeters: payload.total_distance_meters,
      durationSeconds: payload.duration_seconds,
      splits: computedSplits,
      baseline,
      paceRunnerConfigName: sanitizeConfigName(payload.pacerunner_config_name),
    });

    store.upsertWorkout({
      id: payload.id,
      user_id: auth.user.id,
      activity_type: payload.activity_type,
      activity_type_raw: payload.activity_type_raw ?? null,
      start_time: payload.start,
      end_time: payload.end,
      duration_seconds: payload.duration_seconds,
      total_distance_meters: payload.total_distance_meters ?? null,
      total_energy_kcal: payload.total_energy_kcal ?? null,
      source_name: payload.source_name ?? null,
      source_bundle_id: payload.source_bundle_id ?? null,
      raw_metadata: rawMetaJSON,
      has_route: routeRelPath ? 1 : 0,
      has_samples: hasSamples ? 1 : 0,
      has_events: hasEvents ? 1 : 0,
      is_indoor: isIndoor ? 1 : 0,
      pacerunner_log_path: null,
      pacerunner_workout_id: null,
      pacerunner_config_name: sanitizeConfigName(payload.pacerunner_config_name),
      ingested_by_device: payload.device ?? null,
      summary_json: JSON.stringify(summary),
    });

    if (payload.samples) {
      const rows = [];
      for (const [type, samples] of Object.entries(payload.samples)) {
        for (const s of samples) {
          rows.push({
            workout_id: payload.id,
            type,
            start_time: s.start,
            end_time: s.end,
            value: s.value,
            unit: s.unit,
          });
        }
      }
      if (rows.length > 0) store.replaceQuantitySamples(payload.id, rows);
    }

    if (payload.events && payload.events.length > 0) {
      store.replaceEvents(
        payload.id,
        payload.events.map((e) => ({
          workout_id: payload.id,
          type: e.type,
          start_time: e.start,
          duration_seconds: e.duration_seconds,
        }))
      );
    }

    // Persist the splits we computed earlier (before the summary pass).
    // Splits are a derived view — never block ingest on a parse failure.
    let splitCount = 0;
    if (computedSplits.length > 0) {
      store.replaceSplits(
        payload.id,
        computedSplits.map((s) => ({
          workout_id: payload.id,
          split_number: s.split_number,
          unit: s.unit,
          cumulative_distance_meters: s.cumulative_distance_meters,
          distance_meters: s.distance_meters,
          start_time: s.start_time,
          end_time: s.end_time,
          duration_seconds: s.duration_seconds,
          pace_seconds_per_mile: s.pace_seconds_per_mile,
          avg_heart_rate_bpm: s.avg_heart_rate_bpm,
          avg_running_power_watts: s.avg_running_power_watts,
          elevation_gain_meters: s.elevation_gain_meters,
          elevation_loss_meters: s.elevation_loss_meters,
        }))
      );
      splitCount = computedSplits.length;
    }

    // Kick off weather decoration in the background. Response goes out
    // immediately; the row gets a weather child later. Errors are caught
    // and logged inside decorateWorkoutWeather — they never escape here.
    if (!isIndoor && routeRelPath) {
      queueMicrotask(() => {
        void decorateWorkoutWeather(store, {
          workoutID: payload.id,
          userID: auth.user.id,
          startISO: payload.start,
          rawMetadataJSON: rawMetaJSON,
        });
      });
    }

    return c.json({
      ok: true,
      id: payload.id,
      user_id: auth.user.id,
      route_stored: routeRelPath !== null,
      sample_count: payload.samples
        ? Object.values(payload.samples).reduce((acc, arr) => acc + arr.length, 0)
        : 0,
      event_count: payload.events?.length ?? 0,
      split_count: splitCount,
      is_indoor: isIndoor,
      weather_queued: !isIndoor && routeRelPath !== null,
    });
  });
}

function detectIndoor(rawMetadata?: Record<string, unknown>): boolean {
  if (!rawMetadata) return false;
  const flag = rawMetadata.HKIndoorWorkout ?? rawMetadata.indoorWorkout;
  return flag === "1" || flag === 1 || flag === true;
}

function sanitizeConfigName(s: unknown): string | null {
  if (typeof s !== "string") return null;
  const t = s.trim();
  if (t.length === 0 || t.length > 120) return null;
  return t;
}
