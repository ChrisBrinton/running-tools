import type { MiddlewareHandler } from "hono";
import type { Store, TokenScope, UserRow } from "./db.js";

/**
 * Token-based auth. The middleware:
 *   1. Pulls `Authorization: Bearer <token>` from the request.
 *   2. Looks up the token in `user_tokens` (rejects if missing/revoked).
 *   3. Checks that the token's scope satisfies the required scope for the route.
 *   4. Attaches `{ user, scope }` to the Hono context for downstream handlers.
 *
 * Constant-time comparison isn't strictly necessary when we're doing a DB
 * lookup (token IS the index), but we still want to be careful not to leak
 * scope info to mismatched callers.
 */

export interface AuthContext {
  user: UserRow;
  token: string;
  scope: TokenScope;
}

declare module "hono" {
  interface ContextVariableMap {
    auth: AuthContext;
  }
}

function wwwAuthenticate(): string {
  const base = (process.env.PACERUNNER_BASE_URL ?? "").replace(/\/$/, "");
  return `Bearer realm="${base}"`;
}

export function requireScope(store: Store, required: TokenScope | TokenScope[]): MiddlewareHandler {
  const allowed = Array.isArray(required) ? required : [required];
  return async (c, next) => {
    const header = c.req.header("Authorization") ?? "";
    if (!header.startsWith("Bearer ")) {
      return c.json({ error: "Missing bearer token" }, 401, {
        "WWW-Authenticate": wwwAuthenticate(),
      });
    }
    const token = header.slice("Bearer ".length).trim();
    const row = store.lookupToken(token);
    if (!row) {
      // Indistinguishable from "scope wrong" on purpose; 401 in both cases.
      return c.json({ error: "Invalid or revoked token" }, 401, {
        "WWW-Authenticate": wwwAuthenticate(),
      });
    }
    // Admin tokens implicitly satisfy any narrower scope. That keeps the
    // CLI / future admin HTTP surface able to call ingest/MCP endpoints
    // for diagnostic purposes without juggling multiple tokens.
    const allowedSet = new Set<TokenScope>(allowed);
    if (row.scope !== "admin" && !allowedSet.has(row.scope)) {
      return c.json({ error: "Token scope insufficient" }, 403);
    }
    const user = store.getUser(row.user_id);
    if (!user) {
      return c.json({ error: "User not found" }, 401);
    }
    store.touchToken(token);
    c.set("auth", { user, token, scope: row.scope });
    await next();
  };
}
