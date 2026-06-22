import { Hono } from "hono";
import type { Store } from "../db.js";
import { writeRouteGPX } from "../storage.js";
import { decorateWorkoutWeather } from "../weather.js";

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
      ingested_by_device: payload.device ?? null,
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
