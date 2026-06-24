import { Hono } from "hono";
import type { Store } from "../db.js";
import { writePaceRunnerLog } from "../storage.js";

interface LogPayload {
  pacerunner_workout_id: string;
  hk_workout_id?: string;
  started_at: string;
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
      store.attachPaceRunnerLogAndConfig(
        auth.user.id, payload.hk_workout_id, rel, payload.pacerunner_workout_id, configName
      );
      attachedTo = payload.hk_workout_id;
    } else if (payload.started_at) {
      const startMs = Date.parse(payload.started_at);
      if (!Number.isNaN(startMs)) {
        const lo = new Date(startMs - 10 * 60 * 1000).toISOString();
        const hi = new Date(startMs + 10 * 60 * 1000).toISOString();
        const candidates = store.listWorkouts(auth.user.id, { since: lo, until: hi, limit: 5 });
        if (candidates.length > 0) {
          store.attachPaceRunnerLogAndConfig(
            auth.user.id, candidates[0].id, rel, payload.pacerunner_workout_id, configName
          );
          attachedTo = candidates[0].id;
        }
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

function sanitizeConfigName(s: unknown): string | null {
  if (typeof s !== "string") return null;
  const t = s.trim();
  if (t.length === 0 || t.length > 120) return null;
  return t;
}
