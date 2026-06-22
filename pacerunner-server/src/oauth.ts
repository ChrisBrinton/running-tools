import { randomBytes, createHash, timingSafeEqual } from "node:crypto";
import type { Hono } from "hono";
import type { Store } from "./db.js";

export function hashOAuthSecret(s: string): string {
  return createHash("sha256").update(s, "utf8").digest("hex");
}

function verifySecret(provided: string, storedHash: string): boolean {
  const a = Buffer.from(hashOAuthSecret(provided), "hex");
  const b = Buffer.from(storedHash, "hex");
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

function verifyPKCE(verifier: string, challenge: string, method: string): boolean {
  if (method === "S256") {
    const computed = createHash("sha256").update(verifier, "ascii").digest("base64url");
    return computed === challenge;
  }
  // plain
  const a = Buffer.from(verifier);
  const b = Buffer.from(challenge);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

function redirectUriAllowed(stored: string[], incoming: string): boolean {
  if (stored.includes("*")) return true;
  return stored.includes(incoming);
}

function getBaseUrl(c: { req: { header: (k: string) => string | undefined } }): string {
  const env = process.env.PACERUNNER_BASE_URL;
  if (env) return env.replace(/\/$/, "");
  const proto = c.req.header("x-forwarded-proto") ?? "http";
  const host = c.req.header("host") ?? "localhost:8080";
  return `${proto}://${host}`;
}

function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function approvalHtml(params: {
  clientId: string;
  label: string;
  redirectUri: string;
  state: string;
  codeChallenge: string;
  codeChallengeMethod: string;
}): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>PaceRunner — Authorize</title>
<style>
  body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;max-width:480px;margin:80px auto;padding:0 24px;color:#1a1a1a;background:#f5f5f5}
  .card{background:#fff;border-radius:12px;padding:32px;box-shadow:0 2px 12px rgba(0,0,0,.08)}
  h1{font-size:1.25rem;margin:0 0 8px}
  .label{font-size:1rem;font-weight:600;margin:0 0 4px}
  .id{font-size:.8rem;color:#888;font-family:monospace;margin:0 0 28px;word-break:break-all}
  .scope{font-size:.9rem;color:#444;margin:0 0 28px;line-height:1.5}
  button{background:#0066cc;color:#fff;border:none;padding:12px 0;border-radius:8px;font-size:1rem;cursor:pointer;width:100%;font-weight:500}
  button:hover{background:#0055aa}
  .deny{display:block;text-align:center;margin-top:12px;font-size:.85rem;color:#888;text-decoration:none}
  .deny:hover{color:#444}
</style>
</head>
<body>
<div class="card">
  <h1>Authorize access</h1>
  <p class="label">${esc(params.label)}</p>
  <p class="id">${esc(params.clientId)}</p>
  <p class="scope">Read-only access to your PaceRunner workout data, configurations, and settings.</p>
  <form method="POST">
    <input type="hidden" name="client_id" value="${esc(params.clientId)}">
    <input type="hidden" name="redirect_uri" value="${esc(params.redirectUri)}">
    <input type="hidden" name="state" value="${esc(params.state)}">
    <input type="hidden" name="code_challenge" value="${esc(params.codeChallenge)}">
    <input type="hidden" name="code_challenge_method" value="${esc(params.codeChallengeMethod)}">
    <button type="submit">Authorize</button>
  </form>
  <a class="deny" href="javascript:window.close()">Cancel</a>
</div>
</body>
</html>`;
}

export function mountOAuth(app: Hono, store: Store) {
  // RFC 9728 — protected resource metadata (used by some MCP clients to discover the auth server)
  app.get("/.well-known/oauth-protected-resource", (c) => {
    const base = getBaseUrl(c);
    return c.json({
      resource: base,
      authorization_servers: [base],
      bearer_methods_supported: ["header"],
    });
  });

  // RFC 8414 — authorization server metadata
  app.get("/.well-known/oauth-authorization-server", (c) => {
    const base = getBaseUrl(c);
    return c.json({
      issuer: base,
      authorization_endpoint: `${base}/authorize`,
      token_endpoint: `${base}/token`,
      registration_endpoint: `${base}/register`,
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["client_secret_post", "client_secret_basic"],
    });
  });

  // RFC 7591 — dynamic client registration
  app.post("/register", async (c) => {
    let body: Record<string, unknown>;
    try { body = await c.req.json(); }
    catch { return c.json({ error: "invalid_request" }, 400); }

    const redirectUris = body.redirect_uris as string[] | undefined;
    if (!Array.isArray(redirectUris) || redirectUris.length === 0) {
      return c.json({ error: "invalid_request", error_description: "redirect_uris required" }, 400);
    }
    if (redirectUris.some((u) => typeof u !== "string")) {
      return c.json({ error: "invalid_request", error_description: "redirect_uris must be strings" }, 400);
    }

    const label = typeof body.client_name === "string" ? body.client_name : null;
    const clientId = "pr_" + randomBytes(12).toString("hex");
    const secret = randomBytes(32).toString("hex");

    // Associate with the first user on a single-user server
    const users = store.listUsers();
    const userId = users.length > 0 ? users[0].id : null;

    store.createOAuthClient(clientId, hashOAuthSecret(secret), userId, label, redirectUris);

    return c.json({
      client_id: clientId,
      client_secret: secret,
      client_id_issued_at: Math.floor(Date.now() / 1000),
      client_secret_expires_at: 0,
      redirect_uris: redirectUris,
      grant_types: ["authorization_code"],
      response_types: ["code"],
      token_endpoint_auth_method: "client_secret_post",
    }, 201);
  });

  // Authorization endpoint — approval page
  app.get("/authorize", (c) => {
    const clientId = c.req.query("client_id");
    const redirectUri = c.req.query("redirect_uri");
    const responseType = c.req.query("response_type");
    const state = c.req.query("state") ?? "";
    const codeChallenge = c.req.query("code_challenge") ?? "";
    const codeChallengeMethod = c.req.query("code_challenge_method") ?? "S256";

    if (!clientId || !redirectUri || responseType !== "code") {
      return c.text("invalid_request: missing client_id, redirect_uri, or response_type=code", 400);
    }

    const client = store.getOAuthClient(clientId);
    if (!client) return c.text("unauthorized_client", 400);

    const allowed = JSON.parse(client.redirect_uris) as string[];
    if (!redirectUriAllowed(allowed, redirectUri)) {
      return c.text("invalid_request: redirect_uri not registered for this client", 400);
    }

    return c.html(approvalHtml({
      clientId,
      label: client.label ?? clientId,
      redirectUri,
      state,
      codeChallenge,
      codeChallengeMethod,
    }));
  });

  // Authorization endpoint — process approval
  app.post("/authorize", async (c) => {
    const body = await c.req.parseBody();
    const clientId = body.client_id as string | undefined;
    const redirectUri = body.redirect_uri as string | undefined;
    const state = (body.state as string | undefined) ?? "";
    const codeChallenge = (body.code_challenge as string | undefined) || null;
    const codeChallengeMethod = (body.code_challenge_method as string | undefined) || null;

    if (!clientId || !redirectUri) return c.text("invalid_request", 400);

    const client = store.getOAuthClient(clientId);
    if (!client) return c.text("unauthorized_client", 400);

    const allowed = JSON.parse(client.redirect_uris) as string[];
    if (!redirectUriAllowed(allowed, redirectUri)) return c.text("invalid_request", 400);

    const users = store.listUsers();
    if (users.length === 0) return c.text("server_error: no users configured", 500);
    const userId = users[0].id;

    const code = store.createOAuthCode(clientId, userId, redirectUri, codeChallenge, codeChallengeMethod);

    const url = new URL(redirectUri);
    url.searchParams.set("code", code);
    if (state) url.searchParams.set("state", state);
    return c.redirect(url.toString(), 302);
  });

  // Token endpoint
  app.post("/token", async (c) => {
    const contentType = c.req.header("content-type") ?? "";
    let params: Record<string, string>;
    if (contentType.includes("application/json")) {
      params = await c.req.json();
    } else {
      const body = await c.req.parseBody();
      params = Object.fromEntries(
        Object.entries(body).map(([k, v]) => [k, String(v)])
      );
    }

    // Support Basic auth for client credentials
    let clientId = params.client_id;
    let clientSecret = params.client_secret;
    const authHeader = c.req.header("authorization");
    if (authHeader?.startsWith("Basic ")) {
      const decoded = Buffer.from(authHeader.slice(6), "base64").toString("utf8");
      const colon = decoded.indexOf(":");
      if (colon >= 0) {
        clientId = decoded.slice(0, colon);
        clientSecret = decoded.slice(colon + 1);
      }
    }

    if (params.grant_type !== "authorization_code") {
      return c.json({ error: "unsupported_grant_type" }, 400);
    }
    if (!clientId || !clientSecret) {
      return c.json({ error: "invalid_client", error_description: "client credentials required" }, 401);
    }
    if (!params.code || !params.redirect_uri) {
      return c.json({ error: "invalid_request", error_description: "code and redirect_uri required" }, 400);
    }

    const client = store.getOAuthClient(clientId);
    if (!client || !verifySecret(clientSecret, client.client_secret_hash)) {
      return c.json({ error: "invalid_client" }, 401);
    }

    const codeRow = store.getAndConsumeOAuthCode(params.code, clientId, params.redirect_uri);
    if (!codeRow) {
      return c.json({ error: "invalid_grant", error_description: "code invalid, expired, or already used" }, 400);
    }

    if (codeRow.code_challenge) {
      if (!params.code_verifier) {
        return c.json({ error: "invalid_grant", error_description: "code_verifier required" }, 400);
      }
      if (!verifyPKCE(params.code_verifier, codeRow.code_challenge, codeRow.code_challenge_method ?? "S256")) {
        return c.json({ error: "invalid_grant", error_description: "code_verifier mismatch" }, 400);
      }
    }

    // Issue a new mcp-scoped bearer token — the existing /mcp middleware accepts it as-is
    const accessToken = randomBytes(24).toString("hex");
    store.createToken(codeRow.user_id, "mcp", `oauth:${client.label ?? clientId}`, accessToken);

    return c.json({
      access_token: accessToken,
      token_type: "bearer",
      expires_in: 7776000, // 90 days; revoke via admin CLI if needed
    });
  });
}
