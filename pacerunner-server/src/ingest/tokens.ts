import { Hono } from "hono";
import { randomBytes, randomInt } from "node:crypto";
import type { Store, TokenScope } from "../db.js";

/**
 * Self-service token management for the authenticated user.
 *
 * The phone holds an `ingest` token. We let it mint additional `mcp` tokens
 * for the same user_id so the user can generate coach / chat-session
 * credentials from inside the iPhone app without touching the admin CLI.
 *
 * Security: an ingest token already grants write access to all of this
 * user's data. Letting it create read-only mcp tokens for itself is
 * lateral (same blast radius), not an escalation. We deliberately do NOT
 * let an ingest token mint another ingest token or an admin token —
 * those still require the admin CLI.
 */
export function mountTokenManagement(app: Hono, store: Store) {

  /** Create a new token for the authenticated user. Returns the raw token
   *  value exactly once. */
  app.post("/ingest/tokens", async (c) => {
    const auth = c.get("auth");

    let body: { scope?: string; label?: string };
    try { body = await c.req.json(); } catch { return c.json({ error: "Invalid JSON" }, 400); }

    const requestedScope = (body.scope ?? "mcp") as TokenScope;
    if (requestedScope !== "mcp" && auth.scope !== "admin") {
      return c.json({
        error: "ingest scope can only mint 'mcp' tokens; use admin CLI for other scopes",
      }, 403);
    }

    const label = sanitizeLabel(body.label) ?? "phone-generated";
    const token = randomBytes(24).toString("hex"); // 48 hex chars
    store.createToken(auth.user.id, requestedScope, label, token);

    return c.json({
      token,
      user_id: auth.user.id,
      scope: requestedScope,
      label,
    }, 201);
  });

  /** List existing tokens for the authenticated user. The full token value
   *  is never returned (it was shown once on create). We surface enough to
   *  let the user identify tokens by label and see their last-used time,
   *  which is useful for deciding which to revoke. */
  app.get("/ingest/tokens", async (c) => {
    const auth = c.get("auth");
    const rows = store.listTokens(auth.user.id);
    return c.json({
      tokens: rows.map((t) => ({
        token_prefix: t.token.slice(0, 8) + "…" + t.token.slice(-4),
        scope: t.scope,
        label: t.label,
        created_at: t.created_at,
        last_used_at: t.last_used_at,
        revoked: t.revoked === 1,
      })),
    });
  });

  /** Revoke a token by its full value. The phone never sees previously-issued
   *  tokens (we don't echo them), but the user can paste one in from wherever
   *  they saved it. */
  app.delete("/ingest/tokens", async (c) => {
    const auth = c.get("auth");
    let body: { token?: string };
    try { body = await c.req.json(); } catch { return c.json({ error: "Invalid JSON" }, 400); }
    if (!body.token) return c.json({ error: "Missing 'token'" }, 400);

    // Look up the token first; refuse to revoke a token that belongs to
    // a different user (this user shouldn't be able to touch other users'
    // tokens, even via guess-the-value).
    const row = store.lookupToken(body.token);
    if (!row || row.user_id !== auth.user.id) {
      return c.json({ ok: true, revoked: false, reason: "not_found_for_user" });
    }
    const revoked = store.revokeToken(body.token);
    return c.json({ ok: true, revoked });
  });
}

function sanitizeLabel(s: unknown): string | null {
  if (typeof s !== "string") return null;
  const t = s.trim();
  if (t.length === 0 || t.length > 80) return null;
  return t;
}

/**
 * Mount the pairing-code endpoint. Generates a short numeric code that the
 * user types on the OAuth /authorize page to bind a Claude Desktop (or any
 * OAuth-only MCP client) connection to a specific user.
 *
 * Without this, /authorize had to fall back to users[0] which broke
 * multi-user setups. Now: phone authenticates with its ingest token,
 * receives a code, displays it; user types code into the browser-based
 * approval; /authorize binds the resulting auth_code to the phone's user.
 */
export function mountPairingCodes(app: Hono, store: Store) {
  app.post("/ingest/pairing-codes", async (c) => {
    const auth = c.get("auth");
    // Body is optional — accept empty for the no-args case.
    let ttl = 600; // 10 min default
    try {
      const body = await c.req.json().catch(() => ({}));
      const requested = (body as any)?.ttl_seconds;
      if (typeof requested === "number" && requested >= 60 && requested <= 3600) {
        ttl = Math.floor(requested);
      }
    } catch { /* ignore — body is optional */ }

    // 6-digit zero-padded code — easy to read off the phone and type on a
    // desktop. 1M possibilities, 10-min TTL, single use; combined with
    // server-side rate limiting (TODO) the brute force window is small.
    let code: string;
    let attempts = 0;
    while (true) {
      code = String(randomInt(0, 1_000_000)).padStart(6, "0");
      try {
        store.createPairingCode(code, auth.user.id, ttl);
        break;
      } catch (e) {
        // Collision on the PK — try again. 1M codes / 10min TTL means this is
        // exceedingly rare but possible.
        if (++attempts >= 5) throw e;
      }
    }

    // Opportunistic GC of expired codes.
    if (Math.random() < 0.1) store.purgeExpiredPairingCodes();

    return c.json({
      code,
      expires_in_seconds: ttl,
      user_id: auth.user.id,
    }, 201);
  });
}
