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
  errorMessage?: string;
}): string {
  const errBlock = params.errorMessage
    ? `<p class="err">${esc(params.errorMessage)}</p>`
    : "";
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
  .id{font-size:.8rem;color:#888;font-family:monospace;margin:0 0 24px;word-break:break-all}
  .scope{font-size:.9rem;color:#444;margin:0 0 20px;line-height:1.5}
  .field-label{display:block;font-size:.9rem;font-weight:600;margin:0 0 6px;color:#222}
  .hint{font-size:.8rem;color:#666;margin:4px 0 16px;line-height:1.4}
  input[type=text]{width:100%;box-sizing:border-box;font-size:1.6rem;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;text-align:center;letter-spacing:.4rem;padding:14px;border:1px solid #ccc;border-radius:8px;margin:0 0 20px}
  input[type=text]:focus{outline:none;border-color:#0066cc;box-shadow:0 0 0 3px rgba(0,102,204,.15)}
  .err{background:#fee;color:#a00;padding:10px 12px;border-radius:6px;font-size:.9rem;margin:0 0 16px}
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
  ${errBlock}
  <form method="POST">
    <label class="field-label" for="pcode">Pairing code</label>
    <p class="hint">Generate a code in the PaceRunner app (Settings → Home Server → Connect a coach) and type it here. The code expires after 10 minutes.</p>
    <input type="text" id="pcode" name="pairing_code" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" autocomplete="one-time-code" required autofocus>
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

    // Don't associate a client with any user at registration time. The
    // user binding happens at /authorize via the pairing-code handshake.
    // This is what makes multi-user OAuth work — different users can
    // independently approve the same client, each getting auth codes
    // scoped to their own data.
    store.createOAuthClient(clientId, hashOAuthSecret(secret), null, label, redirectUris);

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

  // Authorization endpoint — process approval. Now requires a pairing
  // code so the resulting auth code is bound to a specific user (instead
  // of silently defaulting to users[0]). The pairing code is created via
  // POST /ingest/pairing-codes from the phone and entered by the user
  // on the approval HTML.
  app.post("/authorize", async (c) => {
    const body = await c.req.parseBody();
    const clientId = body.client_id as string | undefined;
    const redirectUri = body.redirect_uri as string | undefined;
    const state = (body.state as string | undefined) ?? "";
    const codeChallenge = (body.code_challenge as string | undefined) || null;
    const codeChallengeMethod = (body.code_challenge_method as string | undefined) || null;
    const pairingCodeRaw = (body.pairing_code as string | undefined) ?? "";
    const pairingCode = pairingCodeRaw.replace(/\D/g, ""); // strip whitespace / dashes

    if (!clientId || !redirectUri) return c.text("invalid_request", 400);

    const client = store.getOAuthClient(clientId);
    if (!client) return c.text("unauthorized_client", 400);

    const allowed = JSON.parse(client.redirect_uris) as string[];
    if (!redirectUriAllowed(allowed, redirectUri)) return c.text("invalid_request", 400);

    // The form posts a pairing code from the user's phone. Without it,
    // we re-render the approval page with an error rather than silently
    // proceeding with users[0] — that auto-pick broke multi-user setups.
    if (!pairingCode || pairingCode.length < 4) {
      return c.html(approvalHtml({
        clientId,
        label: client.label ?? clientId,
        redirectUri,
        state,
        codeChallenge: codeChallenge ?? "",
        codeChallengeMethod: codeChallengeMethod ?? "S256",
        errorMessage: "Enter the 6-digit pairing code from the PaceRunner app.",
      }), 400);
    }

    const pairing = store.consumePairingCode(pairingCode, clientId);
    if (!pairing) {
      return c.html(approvalHtml({
        clientId,
        label: client.label ?? clientId,
        redirectUri,
        state,
        codeChallenge: codeChallenge ?? "",
        codeChallengeMethod: codeChallengeMethod ?? "S256",
        errorMessage: "Pairing code invalid, expired, or already used. Generate a new one in the PaceRunner app and try again.",
      }), 401);
    }

    const code = store.createOAuthCode(
      clientId, pairing.user_id, redirectUri, codeChallenge, codeChallengeMethod
    );

    console.log(
      `[oauth] /authorize approved client=${clientId} → user_id=${pairing.user_id} via pairing code ${pairingCode.slice(0, 2)}…${pairingCode.slice(-2)}`
    );

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
