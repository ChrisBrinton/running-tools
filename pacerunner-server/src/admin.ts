import { randomBytes } from "node:crypto";
import { Store, type TokenScope } from "./db.js";
import { hashOAuthSecret } from "./oauth.js";

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
    default:
      console.error(`Unknown command: ${cmd}`);
      usage();
  }
}

main();
