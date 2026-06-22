import { Hono } from "hono";
import type { Store } from "../db.js";
import { writePaceRunnerLog } from "../storage.js";

interface LogPayload {
  pacerunner_workout_id: string;
  hk_workout_id?: string;
  started_at: string;
  log: string;
  device?: string;
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

    let attachedTo: string | null = null;
    if (payload.hk_workout_id && store.getWorkout(auth.user.id, payload.hk_workout_id)) {
      store.attachPaceRunnerLog(auth.user.id, payload.hk_workout_id, rel, payload.pacerunner_workout_id);
      attachedTo = payload.hk_workout_id;
    } else if (payload.started_at) {
      const startMs = Date.parse(payload.started_at);
      if (!Number.isNaN(startMs)) {
        const lo = new Date(startMs - 10 * 60 * 1000).toISOString();
        const hi = new Date(startMs + 10 * 60 * 1000).toISOString();
        const candidates = store.listWorkouts(auth.user.id, { since: lo, until: hi, limit: 5 });
        if (candidates.length > 0) {
          store.attachPaceRunnerLog(
            auth.user.id, candidates[0].id, rel, payload.pacerunner_workout_id
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
    });
  });
}
