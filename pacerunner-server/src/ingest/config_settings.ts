import { Hono } from "hono";
import type { Store } from "../db.js";

interface ConfigPayload { id: string; name: string; data: unknown }
interface ConfigBatchPayload { configurations: ConfigPayload[] }
interface SettingsPayload { data: unknown }

export function mountConfigIngest(app: Hono, store: Store) {
  app.post("/ingest/config", async (c) => {
    const auth = c.get("auth");
    let payload: ConfigPayload;
    try { payload = await c.req.json(); } catch { return c.json({ error: "Invalid JSON" }, 400); }
    if (!payload.id || !payload.name) {
      return c.json({ error: "Missing required fields: id, name" }, 400);
    }
    store.upsertConfiguration(auth.user.id, payload.id, payload.name, payload.data);
    return c.json({ ok: true, id: payload.id, user_id: auth.user.id });
  });

  app.post("/ingest/configs", async (c) => {
    const auth = c.get("auth");
    let payload: ConfigBatchPayload;
    try { payload = await c.req.json(); } catch { return c.json({ error: "Invalid JSON" }, 400); }
    if (!Array.isArray(payload.configurations)) {
      return c.json({ error: "Expected { configurations: [...] }" }, 400);
    }
    for (const cfg of payload.configurations) {
      if (cfg.id && cfg.name) {
        store.upsertConfiguration(auth.user.id, cfg.id, cfg.name, cfg.data);
      }
    }
    return c.json({ ok: true, count: payload.configurations.length, user_id: auth.user.id });
  });

  app.delete("/ingest/config/:id", async (c) => {
    const auth = c.get("auth");
    const id = c.req.param("id");
    store.deleteConfiguration(auth.user.id, id);
    return c.json({ ok: true, id, user_id: auth.user.id });
  });
}

export function mountSettingsIngest(app: Hono, store: Store) {
  app.post("/ingest/settings", async (c) => {
    const auth = c.get("auth");
    let payload: SettingsPayload;
    try { payload = await c.req.json(); } catch { return c.json({ error: "Invalid JSON" }, 400); }
    store.insertSettingsSnapshot(auth.user.id, payload.data);
    return c.json({ ok: true, user_id: auth.user.id });
  });
}
