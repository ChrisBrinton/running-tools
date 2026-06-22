import { Hono } from "hono";
import { serve } from "@hono/node-server";
import { Store } from "./db.js";
import { requireScope } from "./auth.js";
import { mountWorkoutIngest } from "./ingest/workout.js";
import { mountPaceRunnerLogIngest } from "./ingest/pacerunner.js";
import { mountConfigIngest, mountSettingsIngest } from "./ingest/config_settings.js";
import { mountMCP } from "./mcp/transport.js";
import { mountOAuth } from "./oauth.js";

const DATA_DIR = process.env.PACERUNNER_DATA_DIR ?? "./data";
const PORT = Number(process.env.PORT ?? 8080);

const store = new Store(DATA_DIR);

const app = new Hono();

app.get("/", (c) => c.json({ ok: true, service: "pacerunner-server", version: "0.2" }));
app.get("/health", (c) => c.json({ ok: true }));

// Per-route auth, scoped by token type. `requireScope` looks the token up
// in `user_tokens`, identifies the user, and attaches `{user, scope}` to
// the Hono context. Admin tokens implicitly satisfy any narrower scope.
app.use("/ingest/*", requireScope(store, "ingest"));
app.use("/mcp", requireScope(store, "mcp"));

mountOAuth(app, store);
mountWorkoutIngest(app, store);
mountPaceRunnerLogIngest(app, store);
mountConfigIngest(app, store);
mountSettingsIngest(app, store);
mountMCP(app, store);

const userCount = store.listUsers().length;
console.log(`pacerunner-server listening on :${PORT}`);
console.log(`  data dir: ${DATA_DIR}`);
console.log(`  users:    ${userCount}`);
if (userCount === 0) {
  console.log("  (no users yet — run `npm run admin -- create-user --name <name>` to bootstrap)");
}

serve({ fetch: app.fetch, port: PORT });
