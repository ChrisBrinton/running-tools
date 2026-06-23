import { Hono } from "hono";
import { rm } from "node:fs/promises";
import path from "node:path";
import type { Store } from "../db.js";

/**
 * Account deletion endpoint. Lets a user wipe their own data from the
 * server without needing the admin CLI. Designed so the iPhone can offer
 * a "Deregister + delete my data" affordance directly.
 *
 * Privacy posture: we never collect PII (name/email) at registration, so
 * "everything we hold about you" is the workouts you pushed + the App
 * Attest binding (install_id ↔ user_id ↔ ingest token). Wiping the user
 * row cascades through every child table via FK ON DELETE CASCADE, and
 * we explicitly remove the files/<user_id>/ tree afterwards.
 */
export function mountAccountDeletion(app: Hono, store: Store) {
  app.delete("/ingest/device", async (c) => {
    const auth = c.get("auth");
    const userID = auth.user.id;

    // 1) Drop everything in SQLite. FK ON DELETE CASCADE handles all child
    //    tables (workouts, samples, events, weather, splits, configurations,
    //    settings_snapshots, user_tokens, device_registrations, pairing_codes).
    //    oauth_clients have user_id = NULL post-pairing-code refactor so they
    //    aren't tied to any user — but oauth_codes ARE per-user and cascade.
    store.db.prepare("DELETE FROM users WHERE id = ?").run(userID);

    // 2) Wipe per-user files on disk. SQLite knows nothing about these.
    const userFiles = path.join(store.dataDir, "files", String(userID));
    try {
      await rm(userFiles, { recursive: true, force: true });
    } catch (e) {
      // Don't fail the response if the directory is already gone or fs
      // hiccups — the DB is the source of truth and that's done.
      console.warn(`[account] could not remove ${userFiles}: ${(e as Error).message}`);
    }

    console.log(`[account] deleted user_id=${userID} and associated files`);

    return c.json({
      ok: true,
      user_id: userID,
      deleted: true,
    });
  });
}
