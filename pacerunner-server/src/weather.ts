import type { Store, WeatherRow } from "./db.js";
import { readRouteGPX } from "./storage.js";

/**
 * Weather decoration for outdoor workouts.
 *
 * Source: Open-Meteo. Free, no API key required, returns hourly historical
 * weather + a separate hourly air-quality endpoint. We fetch both keyed
 * by (lat, lon, date) and pick the hour bucket nearest the workout's
 * start time.
 *
 * Indoor workouts (HKMetadataKeyIndoorWorkout=1 in raw_metadata) are
 * skipped — there's no meaningful "weather" for a treadmill run.
 *
 * Triggered asynchronously after `/ingest/workout` returns, so the phone
 * doesn't wait on a third-party API. If the lookup fails, we log and
 * move on — the workout itself is fine, only the decoration is missing.
 */

const WEATHER_URL = "https://api.open-meteo.com/v1/forecast";
const AIR_QUALITY_URL = "https://air-quality-api.open-meteo.com/v1/air-quality";

export interface WorkoutLocationHint {
  workoutID: string;
  userID: number;
  startISO: string;
  rawMetadataJSON: string | null;
}

/** Best-effort weather decoration. Never throws. Logs and returns. */
export async function decorateWorkoutWeather(
  store: Store,
  hint: WorkoutLocationHint
): Promise<void> {
  try {
    if (isIndoor(hint.rawMetadataJSON)) {
      return; // no weather to fetch
    }
    if (store.getWeather(hint.workoutID)) {
      return; // already decorated; idempotent re-ingest
    }

    const coords = await firstCoordFromGPX(store, hint.userID, hint.workoutID);
    if (!coords) {
      console.warn(`[weather] ${hint.workoutID}: no GPS coords, skipping`);
      return;
    }

    const start = new Date(hint.startISO);
    if (Number.isNaN(start.getTime())) {
      console.warn(`[weather] ${hint.workoutID}: bad start time`);
      return;
    }

    const [met, air] = await Promise.allSettled([
      fetchMet(coords, start),
      fetchAir(coords, start),
    ]);

    const metRes = met.status === "fulfilled" ? met.value : null;
    const airRes = air.status === "fulfilled" ? air.value : null;
    if (!metRes && !airRes) {
      console.warn(`[weather] ${hint.workoutID}: both providers failed`);
      return;
    }

    const row: WeatherRow = {
      workout_id: hint.workoutID,
      fetched_at: new Date().toISOString(),
      provider: "open-meteo",
      lat: coords.lat,
      lon: coords.lon,
      observed_at: metRes?.observedAt ?? airRes?.observedAt ?? hint.startISO,
      temp_c: metRes?.temp_c ?? null,
      humidity_pct: metRes?.humidity_pct ?? null,
      precip_mm: metRes?.precip_mm ?? null,
      wind_mps: metRes?.wind_mps ?? null,
      wind_dir_deg: metRes?.wind_dir_deg ?? null,
      cloud_cover_pct: metRes?.cloud_cover_pct ?? null,
      pressure_hpa: metRes?.pressure_hpa ?? null,
      pm25_ug_m3: airRes?.pm25_ug_m3 ?? null,
      pm10_ug_m3: airRes?.pm10_ug_m3 ?? null,
      us_aqi: airRes?.us_aqi ?? null,
      raw_json: JSON.stringify({ met: metRes?.raw, air: airRes?.raw }),
    };
    store.upsertWeather(row);
    console.log(
      `[weather] ${hint.workoutID}: ${coords.lat.toFixed(3)},${coords.lon.toFixed(3)} ` +
      `${row.temp_c?.toFixed(1) ?? "?"}°C ${row.humidity_pct?.toFixed(0) ?? "?"}%H ` +
      `AQI ${row.us_aqi ?? "?"}`
    );
  } catch (e) {
    console.warn(`[weather] ${hint.workoutID} failed:`, e);
  }
}

function isIndoor(rawMetadataJSON: string | null): boolean {
  if (!rawMetadataJSON) return false;
  try {
    const md = JSON.parse(rawMetadataJSON);
    const flag = md.HKIndoorWorkout ?? md.indoorWorkout ?? md.HKWasUserEntered;
    return flag === "1" || flag === 1 || flag === true;
  } catch {
    return false;
  }
}

/** Pull the first lat/lon out of the stored GPX without DOM parsing. */
async function firstCoordFromGPX(
  store: Store,
  userID: number,
  workoutID: string
): Promise<{ lat: number; lon: number } | null> {
  const gpx = await readRouteGPX(store, userID, workoutID);
  if (!gpx) return null;
  const m = gpx.match(/<trkpt\s+lon="([-\d.]+)"\s+lat="([-\d.]+)"/);
  if (!m) {
    // Try lat-first ordering
    const m2 = gpx.match(/<trkpt\s+lat="([-\d.]+)"\s+lon="([-\d.]+)"/);
    if (!m2) return null;
    return { lat: parseFloat(m2[1]), lon: parseFloat(m2[2]) };
  }
  return { lat: parseFloat(m[2]), lon: parseFloat(m[1]) };
}

// --- Open-Meteo fetchers --------------------------------------------------

interface MetSlice {
  observedAt: string;
  temp_c: number | null;
  humidity_pct: number | null;
  precip_mm: number | null;
  wind_mps: number | null;
  wind_dir_deg: number | null;
  cloud_cover_pct: number | null;
  pressure_hpa: number | null;
  raw: unknown;
}

interface AirSlice {
  observedAt: string;
  pm25_ug_m3: number | null;
  pm10_ug_m3: number | null;
  us_aqi: number | null;
  raw: unknown;
}

async function fetchMet(coords: { lat: number; lon: number }, when: Date): Promise<MetSlice> {
  const date = isoDate(when);
  const url = new URL(WEATHER_URL);
  url.searchParams.set("latitude", coords.lat.toString());
  url.searchParams.set("longitude", coords.lon.toString());
  url.searchParams.set("start_date", date);
  url.searchParams.set("end_date", date);
  url.searchParams.set(
    "hourly",
    "temperature_2m,relative_humidity_2m,precipitation,wind_speed_10m,wind_direction_10m,cloud_cover,surface_pressure"
  );
  url.searchParams.set("wind_speed_unit", "ms");
  url.searchParams.set("timezone", "UTC");
  const json = await getJSON(url.toString());
  const idx = pickHourIndex(json?.hourly?.time, when);
  if (idx < 0) throw new Error("no matching hour in met response");
  return {
    observedAt: json.hourly.time[idx] + "Z",
    temp_c: numAt(json?.hourly?.temperature_2m, idx),
    humidity_pct: numAt(json?.hourly?.relative_humidity_2m, idx),
    precip_mm: numAt(json?.hourly?.precipitation, idx),
    wind_mps: numAt(json?.hourly?.wind_speed_10m, idx),
    wind_dir_deg: numAt(json?.hourly?.wind_direction_10m, idx),
    cloud_cover_pct: numAt(json?.hourly?.cloud_cover, idx),
    pressure_hpa: numAt(json?.hourly?.surface_pressure, idx),
    raw: json,
  };
}

async function fetchAir(coords: { lat: number; lon: number }, when: Date): Promise<AirSlice> {
  const date = isoDate(when);
  const url = new URL(AIR_QUALITY_URL);
  url.searchParams.set("latitude", coords.lat.toString());
  url.searchParams.set("longitude", coords.lon.toString());
  url.searchParams.set("start_date", date);
  url.searchParams.set("end_date", date);
  url.searchParams.set("hourly", "pm10,pm2_5,us_aqi");
  url.searchParams.set("timezone", "UTC");
  const json = await getJSON(url.toString());
  const idx = pickHourIndex(json?.hourly?.time, when);
  if (idx < 0) throw new Error("no matching hour in air response");
  return {
    observedAt: json.hourly.time[idx] + "Z",
    pm25_ug_m3: numAt(json?.hourly?.pm2_5, idx),
    pm10_ug_m3: numAt(json?.hourly?.pm10, idx),
    us_aqi: numAt(json?.hourly?.us_aqi, idx),
    raw: json,
  };
}

async function getJSON(url: string): Promise<any> {
  const resp = await fetch(url, { headers: { "user-agent": "pacerunner-server/0.1" } });
  if (!resp.ok) throw new Error(`${url} → HTTP ${resp.status}`);
  return await resp.json();
}

function isoDate(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function pickHourIndex(times: string[] | undefined, when: Date): number {
  if (!times || times.length === 0) return -1;
  const target = when.getTime();
  let best = -1;
  let bestDiff = Infinity;
  for (let i = 0; i < times.length; i++) {
    const t = Date.parse(times[i] + "Z");
    if (Number.isNaN(t)) continue;
    const diff = Math.abs(t - target);
    if (diff < bestDiff) {
      bestDiff = diff;
      best = i;
    }
  }
  return best;
}

function numAt(arr: unknown, i: number): number | null {
  if (!Array.isArray(arr)) return null;
  const v = arr[i];
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}
