import { randomBytes } from "node:crypto";
import { Store, type TokenScope } from "./db.js";
import { hashOAuthSecret } from "./oauth.js";
import { computeSummary } from "./summary.js";
import { computeUserBaseline } from "./baseline.js";

/**
 * Admin CLI. Run via `npm run admin -- <command> [...flags]`.
 *
 * The CLI talks directly to SQLite — no HTTP, no auth dance — so this is
 * how you bootstrap the first user before the server has anyone to
 * authorize.
 */

const DATA_DIR = process.env.PACERUNNER_DATA_DIR ?? "./data";

function usage(): never {
  console.log(`
Usage:
  npm run admin -- create-user --name <name> [--email <email>] [--notes <notes>]
  npm run admin -- list-users
  npm run admin -- delete-user --id <id>

  npm run admin -- create-token --user-id <id> --scope ingest|mcp|admin [--label <label>]
  npm run admin -- list-tokens [--user-id <id>]
  npm run admin -- revoke-token --token <token>

  npm run admin -- create-oauth-client --user-id <id> --label <label>
  npm run admin -- list-oauth-clients [--user-id <id>]
  npm run admin -- delete-oauth-client --client-id <id>

  npm run admin -- recompute-summaries [--user-id <id>]
    Re-derives Tier 1 + Tier 2 fields (hr_to_power_ratio, drift, halves,
    workout_type, etc.) for already-ingested workouts. Safe to run any
    time; touches only summary_json.

The token/secret value is shown ONCE on creation — copy it immediately.
`);
  process.exit(1);
}

function arg(name: string, args: string[], required = true): string | undefined {
  const i = args.indexOf(`--${name}`);
  if (i < 0) {
    if (required) {
      console.error(`Missing --${name}`);
      usage();
    }
    return undefined;
  }
  const v = args[i + 1];
  if (!v || v.startsWith("--")) {
    console.error(`--${name} requires a value`);
    usage();
  }
  return v;
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  if (!cmd) usage();

  const store = new Store(DATA_DIR);

  switch (cmd) {
    case "create-user": {
      const name = arg("name", rest)!;
      const email = arg("email", rest, false);
      const notes = arg("notes", rest, false);
      const u = store.createUser(name, email, notes);
      console.log(`Created user #${u.id}: ${u.name}${u.email ? " <" + u.email + ">" : ""}`);
      return;
    }
    case "list-users": {
      const users = store.listUsers();
      if (users.length === 0) { console.log("(no users)"); return; }
      for (const u of users) {
        console.log(`#${u.id}\t${u.name}\t${u.email ?? "-"}\t${u.created_at}`);
      }
      return;
    }
    case "delete-user": {
      const id = Number(arg("id", rest)!);
      store.db.prepare("DELETE FROM users WHERE id = ?").run(id);
      console.log(`Deleted user #${id} (and cascaded data).`);
      return;
    }
    case "create-token": {
      const userID = Number(arg("user-id", rest)!);
      const scope = arg("scope", rest)! as TokenScope;
      if (!["ingest", "mcp", "admin"].includes(scope)) {
        console.error(`scope must be one of: ingest, mcp, admin`);
        process.exit(1);
      }
      if (!store.getUser(userID)) {
        console.error(`user #${userID} not found`);
        process.exit(1);
      }
      const label = arg("label", rest, false) ?? null;
      const token = randomBytes(24).toString("hex");
      store.createToken(userID, scope, label, token);
      console.log(`\nToken created (copy this — it won't be shown again):\n`);
      console.log(`  ${token}\n`);
      console.log(`  user_id: ${userID}`);
      console.log(`  scope:   ${scope}`);
      if (label) console.log(`  label:   ${label}`);
      return;
    }
    case "list-tokens": {
      const uidStr = arg("user-id", rest, false);
      const uid = uidStr ? Number(uidStr) : undefined;
      const rows = store.listTokens(uid);
      if (rows.length === 0) { console.log("(no tokens)"); return; }
      for (const t of rows) {
        // Show only a prefix so this command is safe to dump to a log
        const display = t.token.slice(0, 8) + "…" + t.token.slice(-4);
        console.log(
          `${display}\tuser=${t.user_id}\t${t.scope}\t${t.label ?? "-"}\t` +
          `created ${t.created_at}\tlast_used ${t.last_used_at ?? "-"}\t` +
          `${t.revoked ? "REVOKED" : "active"}`
        );
      }
      return;
    }
    case "revoke-token": {
      const token = arg("token", rest)!;
      const ok = store.revokeToken(token);
      console.log(ok ? "Revoked." : "No matching token.");
      return;
    }
    case "create-oauth-client": {
      const userID = Number(arg("user-id", rest)!);
      const label = arg("label", rest)!;
      if (!store.getUser(userID)) {
        console.error(`user #${userID} not found`);
        process.exit(1);
      }
      const clientId = "pr_" + randomBytes(12).toString("hex");
      const secret = randomBytes(32).toString("hex");
      store.createOAuthClient(clientId, hashOAuthSecret(secret), userID, label, ["*"]);
      console.log(`\nOAuth client created (copy the secret — it won't be shown again):\n`);
      console.log(`  client_id:     ${clientId}`);
      console.log(`  client_secret: ${secret}\n`);
      console.log(`  user_id: ${userID}`);
      console.log(`  label:   ${label}`);
      console.log(`  redirect_uris: any (["*"])`);
      return;
    }
    case "list-oauth-clients": {
      const uidStr = arg("user-id", rest, false);
      const uid = uidStr ? Number(uidStr) : undefined;
      const rows = store.listOAuthClients(uid);
      if (rows.length === 0) { console.log("(no oauth clients)"); return; }
      for (const r of rows) {
        console.log(`${r.client_id}\tuser=${r.user_id ?? "-"}\t${r.label ?? "-"}\tcreated ${r.created_at}`);
      }
      return;
    }
    case "delete-oauth-client": {
      const clientId = arg("client-id", rest)!;
      const ok = store.deleteOAuthClient(clientId);
      console.log(ok ? "Deleted." : "No matching client.");
      return;
    }
    case "recompute-summaries": {
      const uidStr = arg("user-id", rest, false);
      const targetUid = uidStr ? Number(uidStr) : undefined;
      const users = targetUid !== undefined ? [store.getUser(targetUid)!] : store.listUsers();
      let total = 0;
      for (const u of users) {
        if (!u) continue;
        const workouts = store.listWorkouts(u.id, { limit: 10_000 });
        // Process oldest-first so each workout's baseline reflects only
        // its predecessors (matches the live ingest order).
        const ordered = [...workouts].sort(
          (a, b) => a.start_time.localeCompare(b.start_time)
        );
        for (const w of ordered) {
          // Reconstruct the samples payload from quantity_samples rows.
          const sampleRows = store.getQuantitySamples(w.id);
          const samples: Record<string, Array<{
            start: string; end: string; value: number; unit: string;
          }>> = {};
          for (const r of sampleRows) {
            (samples[r.type] ??= []).push({
              start: r.start_time, end: r.end_time, value: r.value, unit: r.unit,
            });
          }
          const splits = store.getSplits(w.id);
          const baseline = computeUserBaseline(store, u.id, w.id);
          const summary = computeSummary({
            samples,
            rawMetadata: w.raw_metadata ? JSON.parse(w.raw_metadata) : undefined,
            totalDistanceMeters: w.total_distance_meters,
            durationSeconds: w.duration_seconds,
            splits,
            baseline,
            paceRunnerConfigName: w.pacerunner_config_name,
          });
          store.db.prepare(
            "UPDATE workouts SET summary_json = ? WHERE id = ?"
          ).run(JSON.stringify(summary), w.id);
          total++;
        }
        console.log(`user #${u.id} ${u.name}: ${ordered.length} workouts recomputed`);
      }
      console.log(`\nDone — ${total} workout summaries updated.`);
      return;
    }
    default:
      console.error(`Unknown command: ${cmd}`);
      usage();
  }
}

main();
