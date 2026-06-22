import type { Store } from "../db.js";
import { readRouteGPX, readPaceRunnerLog, fileSize } from "../storage.js";
import { parseTrkpts } from "../splits.js";

export interface ToolDescriptor {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

export const TOOL_DESCRIPTORS: ToolDescriptor[] = [
  {
    name: "list_workouts",
    description:
      "Lists ingested workouts for the authenticated user, newest first. Each entry " +
      "includes a `summary` object (avg/min/max HR, pace, power, stride, cadence, " +
      "elevation gain/loss) so cross-workout trend questions can be answered without " +
      "paginating raw samples. The per-entry `has_*` flags advertise which fields " +
      "would return content on get_workout: route_gpx, samples, events, pacerunner_log, " +
      "weather, splits.",
    inputSchema: {
      type: "object",
      properties: {
        since: { type: "string", description: "ISO-8601 lower bound (inclusive). Default 30 days ago." },
        until: { type: "string", description: "ISO-8601 upper bound (exclusive). Default now." },
        activity_type: { type: "string", description: "Optional filter: 'running','walking', etc." },
        limit: { type: "integer", description: "Max rows. Default 50." },
      },
    },
  },
  {
    name: "get_workout",
    description:
      "Returns selected slices for a workout. `fields` is any subset of " +
      "['metadata','route_gpx','samples','events','splits','pacerunner_log','weather']. " +
      "Default ['metadata']. Notes:\n" +
      "  • `metadata.summary` is always present when 'metadata' is requested.\n" +
      "  • `samples` is keyed by HK quantity type (heartRate, runningPower, " +
      "runningSpeed, runningStrideLength, runningGroundContactTime, " +
      "runningVerticalOscillation, stepCount, activeEnergyBurned, basalEnergyBurned, " +
      "vo2Max). Per-sample `altitude` (meters) is synthesized from the GPX trkpts " +
      "and included whenever 'samples' is requested AND the workout has a route.\n" +
      "  • `events` carries Apple Watch's internal workout-state markers. For " +
      "standard Running workouts these are typically `segment` entries that " +
      "represent Apple's internal workout subdivisions (NOT mile boundaries — " +
      "use the `splits` field for that). Documented event `type` values: " +
      "pause, resume, lap, marker, motionPaused, motionResumed, segment, " +
      "pauseOrResumeRequest. Apple's documentation on `segment` semantics is " +
      "thin; treat them as opaque and prefer `splits` for analysis.\n" +
      "  • `splits` is per-mile, derived from the GPS trace via interpolation " +
      "(not from Watch lap-button presses). Each split carries distance, " +
      "duration, pace (sec/mi), mean HR, mean power, elevation gain/loss.",
    inputSchema: {
      type: "object",
      required: ["id"],
      properties: {
        id: { type: "string", description: "HealthKit workout UUID." },
        fields: { type: "array", items: { type: "string" } },
      },
    },
  },
  {
    name: "get_pacerunner_log",
    description:
      "Returns the verbose PaceRunner GPS debug log for a workout. The 'workout_id' can be " +
      "a HealthKit UUID or a PaceRunner WorkoutSummary UUID.",
    inputSchema: {
      type: "object",
      required: ["workout_id"],
      properties: { workout_id: { type: "string" } },
    },
  },
  {
    name: "get_weather",
    description:
      "Returns ingested weather observations for a workout (temp, humidity, wind, precipitation, " +
      "and air quality PM2.5/PM10/US AQI). Indoor workouts have no weather row.",
    inputSchema: {
      type: "object",
      required: ["workout_id"],
      properties: { workout_id: { type: "string", description: "HealthKit workout UUID." } },
    },
  },
  {
    name: "list_configurations",
    description: "Returns the user's saved PaceRunner run configurations.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "get_settings",
    description: "Returns the most recent snapshot of the user's PaceRunner app settings.",
    inputSchema: { type: "object", properties: {} },
  },
];

export async function callTool(
  store: Store,
  userID: number,
  name: string,
  args: Record<string, unknown>
): Promise<unknown> {
  switch (name) {
    case "list_workouts":         return await listWorkouts(store, userID, args);
    case "get_workout":           return await getWorkout(store, userID, args);
    case "get_pacerunner_log":    return await getPaceRunnerLog(store, userID, args);
    case "get_weather":           return await getWeatherTool(store, userID, args);
    case "list_configurations":   return { configurations: store.listConfigurations(userID) };
    case "get_settings":          return store.latestSettings(userID) ?? null;
    default: throw new Error(`Unknown tool: ${name}`);
  }
}

async function listWorkouts(
  store: Store, userID: number, args: Record<string, unknown>
): Promise<unknown> {
  const since = (args.since as string | undefined) ?? defaultSince();
  const until = (args.until as string | undefined) ?? new Date().toISOString();
  const activity = args.activity_type as string | undefined;
  const limit = Math.min(Math.max(Number(args.limit ?? 50), 1), 500);

  const rows = store.listWorkouts(userID, { since, until, activityType: activity, limit });

  const workouts = rows.map((r) => {
    const hasWeather = store.getWeather(r.id) !== undefined;
    const hasSplits = store.getSplits(r.id).length > 0;
    return {
      id: r.id,
      activity_type: r.activity_type,
      start: r.start_time,
      end: r.end_time,
      duration_seconds: r.duration_seconds,
      distance_meters: r.total_distance_meters,
      distance_miles:
        r.total_distance_meters !== null ? r.total_distance_meters / 1609.344 : null,
      energy_kcal: r.total_energy_kcal,
      source: r.source_name,
      is_indoor: r.is_indoor === 1,
      has_route: r.has_route === 1,
      has_samples: r.has_samples === 1,
      has_events: r.has_events === 1,
      has_pacerunner_log: r.pacerunner_log_path !== null,
      has_weather: hasWeather,
      has_splits: hasSplits,
      summary: r.summary_json ? JSON.parse(r.summary_json) : null,
    };
  });

  return { count: workouts.length, since, until, workouts };
}

async function getWorkout(
  store: Store, userID: number, args: Record<string, unknown>
): Promise<unknown> {
  const id = args.id as string | undefined;
  if (!id) throw new Error("Missing 'id'");
  const fieldsArr = (args.fields as string[] | undefined) ?? ["metadata"];
  const fields = new Set(fieldsArr);
  const w = store.getWorkout(userID, id);
  if (!w) throw new Error(`Workout not found: ${id}`);

  const out: Record<string, unknown> = { id };

  if (fields.has("metadata")) {
    out.metadata = {
      activity_type: w.activity_type,
      activity_type_raw: w.activity_type_raw,
      uuid: w.id,
      start: w.start_time,
      end: w.end_time,
      duration_seconds: w.duration_seconds,
      total_distance_meters: w.total_distance_meters,
      total_distance_miles:
        w.total_distance_meters !== null ? w.total_distance_meters / 1609.344 : null,
      total_energy_kcal: w.total_energy_kcal,
      source_name: w.source_name,
      source_bundle_id: w.source_bundle_id,
      raw_metadata: w.raw_metadata ? JSON.parse(w.raw_metadata) : null,
      is_indoor: w.is_indoor === 1,
      summary: w.summary_json ? JSON.parse(w.summary_json) : null,
      ingested_at: w.ingested_at,
      ingested_by_device: w.ingested_by_device,
    };
  }

  if (fields.has("route_gpx")) {
    const gpx = await readRouteGPX(store, userID, w.id);
    out.route_gpx = gpx;
    if (gpx) out.route_byte_count = gpx.length;
  }

  if (fields.has("samples")) {
    const rows = store.getQuantitySamples(w.id);
    const grouped: Record<string, Array<Record<string, unknown>>> = {};
    for (const r of rows) {
      (grouped[r.type] ??= []).push({
        start: r.start_time, end: r.end_time, value: r.value, unit: r.unit,
      });
    }
    // P3 — synthesize a per-sample `altitude` series from the GPX trkpts so
    // the coach can correlate elevation with HR/power on the same time axis.
    // The trkpts contain <ele> tags; we just expose them as a parallel series.
    if (w.has_route === 1) {
      const gpx = await readRouteGPX(store, userID, w.id);
      if (gpx) {
        const trkpts = parseTrkpts(gpx);
        const altSamples = trkpts
          .filter((p) => p.ele !== null)
          .map((p) => ({
            start: p.t.toISOString(),
            end: p.t.toISOString(),
            value: p.ele as number,
            unit: "m",
          }));
        if (altSamples.length > 0) {
          grouped.altitude = altSamples;
        }
      }
    }
    out.samples = grouped;
  }

  if (fields.has("events")) {
    out.events = store.getEvents(w.id).map((r) => ({
      type: r.type, start: r.start_time, duration_seconds: r.duration_seconds,
    }));
  }

  if (fields.has("splits")) {
    const splits = store.getSplits(w.id);
    out.splits = splits.map((s) => ({
      split_number: s.split_number,
      unit: s.unit,
      cumulative_distance_meters: s.cumulative_distance_meters,
      cumulative_distance_miles: s.cumulative_distance_meters / 1609.344,
      distance_meters: s.distance_meters,
      distance_miles: s.distance_meters / 1609.344,
      start_time: s.start_time,
      end_time: s.end_time,
      duration_seconds: s.duration_seconds,
      pace_seconds_per_mile: s.pace_seconds_per_mile,
      avg_heart_rate_bpm: s.avg_heart_rate_bpm,
      avg_running_power_watts: s.avg_running_power_watts,
      elevation_gain_meters: s.elevation_gain_meters,
      elevation_loss_meters: s.elevation_loss_meters,
    }));
  }

  if (fields.has("pacerunner_log")) {
    if (w.pacerunner_log_path) {
      out.pacerunner_log = await readPaceRunnerLog(store, w.pacerunner_log_path);
      out.pacerunner_workout_id = w.pacerunner_workout_id;
      out.pacerunner_log_byte_count = await fileSize(store, w.pacerunner_log_path);
    } else {
      out.pacerunner_log = null;
    }
  }

  if (fields.has("weather")) {
    out.weather = projectWeather(store.getWeather(w.id));
  }

  return out;
}

async function getPaceRunnerLog(
  store: Store, userID: number, args: Record<string, unknown>
): Promise<unknown> {
  const id = args.workout_id as string | undefined;
  if (!id) throw new Error("Missing 'workout_id'");
  let w = store.getWorkout(userID, id);
  if (!w) w = store.getWorkoutByPaceRunnerID(userID, id);
  if (!w || !w.pacerunner_log_path) return { workout_id: id, log: null };
  return {
    workout_id: id,
    healthkit_workout_id: w.id,
    pacerunner_workout_id: w.pacerunner_workout_id,
    log: await readPaceRunnerLog(store, w.pacerunner_log_path),
  };
}

async function getWeatherTool(
  store: Store, userID: number, args: Record<string, unknown>
): Promise<unknown> {
  const id = args.workout_id as string | undefined;
  if (!id) throw new Error("Missing 'workout_id'");
  // Scope check: confirm the workout belongs to this user before exposing weather.
  const w = store.getWorkout(userID, id);
  if (!w) throw new Error(`Workout not found: ${id}`);
  return projectWeather(store.getWeather(w.id));
}

function projectWeather(row: ReturnType<Store["getWeather"]>): unknown {
  if (!row) return null;
  return {
    provider: row.provider,
    fetched_at: row.fetched_at,
    observed_at: row.observed_at,
    location: { lat: row.lat, lon: row.lon },
    temperature_c: row.temp_c,
    humidity_percent: row.humidity_pct,
    precipitation_mm: row.precip_mm,
    wind_speed_mps: row.wind_mps,
    wind_direction_deg: row.wind_dir_deg,
    cloud_cover_percent: row.cloud_cover_pct,
    pressure_hpa: row.pressure_hpa,
    air_quality: {
      pm25_ug_m3: row.pm25_ug_m3,
      pm10_ug_m3: row.pm10_ug_m3,
      us_aqi: row.us_aqi,
    },
  };
}

function defaultSince(): string {
  return new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
}
