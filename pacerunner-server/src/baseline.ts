import type { Store } from "./db.js";
import type { UserBaseline } from "./summary.js";

/**
 * Per-user baselines used by the workout classifier in summary.ts.
 *
 * Recomputed on every /ingest/workout, EXCLUDING the workout we're about
 * to classify (so a new workout doesn't influence its own baseline). The
 * cost is one aggregate query per ingest — cheap, and avoids a separate
 * scheduled job.
 *
 * All baselines look back 30 days. Anything older is irrelevant for
 * classifying current efforts (training adapts; what was "easy" in March
 * isn't necessarily easy in June).
 */
export function computeUserBaseline(
  store: Store,
  userID: number,
  excludeWorkoutID: string | null
): UserBaseline {
  const since = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();

  // --- observed max HR across ALL history (not just 30d) -----------------
  // Pulled from quantity_samples, joined to workouts so we can scope by user.
  // Lifetime max is the safer choice; a hot summer week shouldn't change the
  // user's classification ceiling.
  const maxHRRow = store.db.prepare(`
    SELECT MAX(qs.value) AS max_hr
    FROM quantity_samples qs
    JOIN workouts w ON w.id = qs.workout_id
    WHERE w.user_id = ?
      AND qs.type = 'heartRate'
      AND (? IS NULL OR w.id != ?)
  `).get(userID, excludeWorkoutID, excludeWorkoutID) as { max_hr: number | null };

  // --- median workout distance (last 30d, this user, exclude current) ----
  const distMilesRows = store.db.prepare(`
    SELECT total_distance_meters
    FROM workouts
    WHERE user_id = ?
      AND start_time >= ?
      AND total_distance_meters IS NOT NULL
      AND (? IS NULL OR id != ?)
    ORDER BY total_distance_meters
  `).all(userID, since, excludeWorkoutID, excludeWorkoutID)
    .map((r) => (r as { total_distance_meters: number }).total_distance_meters / 1609.344);

  const medianMiles = median(distMilesRows);

  // --- median easy pace (last 30d, this user, avg HR < ~65% of max) ------
  // We approximate "easy" without already-classified labels by selecting
  // workouts whose summary_json says avg_heart_rate_bpm is below the
  // threshold. New users without baselines just get null here.
  const maxHR = maxHRRow?.max_hr ?? null;
  let medianEasyPace: number | null = null;
  if (maxHR && maxHR > 0) {
    const hrThreshold = 0.65 * maxHR;
    const rows = store.db.prepare(`
      SELECT total_distance_meters, duration_seconds, summary_json
      FROM workouts
      WHERE user_id = ?
        AND start_time >= ?
        AND total_distance_meters IS NOT NULL
        AND duration_seconds > 0
        AND summary_json IS NOT NULL
        AND (? IS NULL OR id != ?)
    `).all(userID, since, excludeWorkoutID, excludeWorkoutID) as Array<{
      total_distance_meters: number;
      duration_seconds: number;
      summary_json: string;
    }>;

    const easyPaces: number[] = [];
    for (const r of rows) {
      try {
        const s = JSON.parse(r.summary_json);
        const avgHR = typeof s.avg_heart_rate_bpm === "number" ? s.avg_heart_rate_bpm : null;
        if (avgHR === null || avgHR >= hrThreshold) continue;
        const miles = r.total_distance_meters / 1609.344;
        if (miles <= 0) continue;
        easyPaces.push(r.duration_seconds / miles);
      } catch { /* skip malformed summary */ }
    }
    medianEasyPace = median(easyPaces);
  }

  return {
    observed_max_hr_bpm: maxHR !== null ? Math.round(maxHR) : null,
    median_workout_miles_30d: medianMiles !== null ? Math.round(medianMiles * 100) / 100 : null,
    median_easy_pace_seconds_per_mile_30d:
      medianEasyPace !== null ? Math.round(medianEasyPace * 10) / 10 : null,
  };
}

function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? (sorted[mid - 1] + sorted[mid]) / 2
    : sorted[mid];
}
