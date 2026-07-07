import { Hono } from "hono";
import type { Store } from "../db.js";
import { writePaceRunnerLog } from "../storage.js";

interface LogPayload {
  pacerunner_workout_id: string;
  hk_workout_id?: string;
  started_at: string;
  /** Optional. End of the PaceRunner workout. When present, correlation to an
   *  HK workout is done by time-interval overlap rather than start proximity,
   *  which handles the common case where the PaceRunner workout is shorter than
   *  the HK workout and the two start in either order. */
  ended_at?: string;
  log: string;
  device?: string;
  /** Optional. Name of the PaceRunner run configuration this workout used
   *  (e.g. "5mi Easy"). Attached to the matched HK workout row. */
  pacerunner_config_name?: string;
}

export function mountPaceRunnerLogIngest(app: Hono, store: Store) {
  app.post("/ingest/pacerunner-log", async (c) => {
    const auth = c.get("auth");
    let payload: LogPayload;
    try {
      payload = await c.req.json();
    } catch {
      return c.json({ error: "Invalid JSON" }, 400);
    }
    if (!payload.pacerunner_workout_id || !payload.log) {
      return c.json({ error: "Missing required fields: pacerunner_workout_id, log" }, 400);
    }

    const fileBase = payload.hk_workout_id ?? payload.pacerunner_workout_id;
    const rel = await writePaceRunnerLog(store, auth.user.id, fileBase, payload.log);
    const configName = sanitizeConfigName(payload.pacerunner_config_name);

    let attachedTo: string | null = null;
    if (payload.hk_workout_id && store.getWorkout(auth.user.id, payload.hk_workout_id)) {
      // Caller already knows which HK workout this belongs to — attach directly.
      store.attachPaceRunnerLogAndConfig(
        auth.user.id, payload.hk_workout_id, rel, payload.pacerunner_workout_id, configName
      );
      attachedTo = payload.hk_workout_id;
    } else if (payload.started_at) {
      const match = findBestOverlap(store, auth.user.id, payload.started_at, payload.ended_at);
      if (match) {
        store.attachPaceRunnerLogAndConfig(
          auth.user.id, match, rel, payload.pacerunner_workout_id, configName
        );
        attachedTo = match;
      }
    }

    return c.json({
      ok: true,
      pacerunner_workout_id: payload.pacerunner_workout_id,
      user_id: auth.user.id,
      stored_path: rel,
      attached_to_workout: attachedTo,
      config_name_attached: configName !== null,
    });
  });
}

/**
 * Find the HK workout whose time interval best overlaps the PaceRunner
 * workout's [started_at, ended_at] interval, returning its id (or null).
 *
 * The PaceRunner workout is usually shorter than the HK workout and the two can
 * start in either order, so a start-time-only window misses valid matches (e.g.
 * a 2-hour HK outing containing a 40-minute PaceRunner segment that began 25
 * minutes in). We widen the candidate query generously, then rank by actual
 * overlap. A small negative tolerance lets near-adjacent intervals (a few
 * minutes' clock skew between watch and phone) still match.
 */
function findBestOverlap(
  store: Store,
  userId: number,
  startedAt: string,
  endedAt?: string
): string | null {
  const startMs = Date.parse(startedAt);
  if (Number.isNaN(startMs)) return null;
  const endMs = endedAt ? Date.parse(endedAt) : startMs;
  const prStart = Math.min(startMs, endMs);
  const prEnd = Math.max(startMs, endMs);

  // Candidate window: any HK workout that could plausibly overlap. The query
  // filters on the HK workout's *start_time*, so pad the lookback generously
  // (6h) to catch a long outing that began well before the PaceRunner segment;
  // an hour of look-ahead is enough since an HK workout starting after the PR
  // segment ends can't overlap it.
  const lo = new Date(prStart - 6 * 60 * 60 * 1000).toISOString();
  const hi = new Date(prEnd + 60 * 60 * 1000).toISOString();
  const candidates = store.listWorkouts(userId, { since: lo, until: hi, limit: 20 });
  if (candidates.length === 0) return null;

  const tolerance = 2 * 60 * 1000; // 2 minutes
  let best: string | null = null;
  let bestOverlap = -Infinity;
  for (const w of candidates) {
    const wStart = Date.parse(w.start_time);
    const wEnd = Date.parse(w.end_time);
    if (Number.isNaN(wStart) || Number.isNaN(wEnd)) continue;
    // Positive = ms of true overlap; negative = gap between intervals.
    const overlap = Math.min(prEnd, wEnd) - Math.max(prStart, wStart);
    if (overlap > bestOverlap) {
      bestOverlap = overlap;
      best = w.id;
    }
  }
  return bestOverlap > -tolerance ? best : null;
}

function sanitizeConfigName(s: unknown): string | null {
  if (typeof s !== "string") return null;
  const t = s.trim();
  if (t.length === 0 || t.length > 120) return null;
  return t;
}
