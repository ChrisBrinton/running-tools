import { Hono } from "hono";
import { randomBytes } from "node:crypto";
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
