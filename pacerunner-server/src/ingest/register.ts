import { Hono } from "hono";
import { randomBytes } from "node:crypto";
import type { Store } from "../db.js";
import { verifyAttestation, AttestationError } from "../attest.js";

/**
 * Self-service iPhone registration via App Attest.
 *
 * Two-step handshake (mirrors what the iPhone's DCAppAttestService expects):
 *
 *   POST /register/challenge { install_id }
 *     → { challenge: "<random>", expires_at }
 *   POST /register/attest { install_id, key_id, challenge, attestation }
 *     → { user_id, ingest_token }            -- on success
 *     → 401 { error: "...", step: "..." }    -- on attestation failure
 *
 * Idempotency: a second /register/attest call from the same install_id
 * skips re-attestation and returns the previously-issued user + token.
 * That lets the phone safely re-register on every launch as a self-heal.
 *
 * Neither endpoint requires a pre-existing bearer token. App Attest
 * verification is what gates registration — anyone without a real
 * PaceRunner build signed by the configured team ID cannot produce a
 * valid attestation, so an unattested POST is rejected.
 *
 * The PACERUNNER_APP_ID env var holds the expected app ID, e.g.
 * "ABC123XYZ4.com.brintontech.PaceRunner". Without it the server refuses
 * to register anyone — fail-closed.
 */
export function mountRegistration(app: Hono, store: Store) {
  app.post("/register/challenge", async (c) => {
    let body: { install_id?: string };
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: "Invalid JSON" }, 400);
    }
    if (!isInstallID(body.install_id)) {
      return c.json({ error: "Missing or invalid install_id (expected a UUID)" }, 400);
    }
    const challenge = randomBytes(32).toString("hex");
    store.createChallenge(challenge, body.install_id!, /*ttl=*/ 300);
    // Opportunistic GC of expired entries — cheap, runs once per ~N requests.
    if (Math.random() < 0.05) store.purgeExpiredChallenges();
    return c.json({
      challenge,
      expires_in_seconds: 300,
    });
  });

  app.post("/register/attest", async (c) => {
    const appId = process.env.PACERUNNER_APP_ID;
    if (!appId) {
      console.error("[register] PACERUNNER_APP_ID env var not set — refusing to register");
      return c.json({ error: "Server not configured for App Attest" }, 503);
    }

    let body: {
      install_id?: string;
      key_id?: string;          // base64
      challenge?: string;
      attestation?: string;     // base64 CBOR
      display_name?: string;
    };
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: "Invalid JSON" }, 400);
    }
    if (!isInstallID(body.install_id)) {
      return c.json({ error: "Missing or invalid install_id" }, 400);
    }
    if (!body.key_id || !body.challenge || !body.attestation) {
      return c.json({ error: "Missing key_id, challenge, or attestation" }, 400);
    }
    const installID = body.install_id!;

    // ---- Idempotent path: already-registered installs just get their token back.
    const existing = store.getDeviceRegistration(installID);
    if (existing) {
      return c.json({
        user_id: existing.user_id,
        ingest_token: existing.ingest_token,
        already_registered: true,
        registered_at: existing.registered_at,
      });
    }

    // ---- First-time path: require an unused, matching, unexpired challenge.
    const challengeRow = store.consumeChallenge(body.challenge, installID);
    if (!challengeRow) {
      return c.json({
        error: "Challenge invalid, expired, already used, or doesn't match install_id",
        step: "challenge",
      }, 401);
    }

    // ---- Verify App Attest attestation against Apple's root + our app ID.
    let verification: ReturnType<typeof verifyAttestation>;
    try {
      verification = verifyAttestation(
        body.attestation,
        body.key_id,
        body.challenge,
        appId,
      );
    } catch (e) {
      const step = e instanceof AttestationError ? e.step : "verify";
      console.warn(`[register] attestation rejected: ${(e as Error).message}`);
      return c.json({ error: (e as Error).message, step }, 401);
    }

    // ---- Mint user + token, persist the device registration.
    const displayName = sanitizeDisplayName(body.display_name) ?? defaultDeviceName(installID);
    const user = store.createUser(displayName, undefined, `Self-registered via App Attest (${verification.environment})`);
    const ingestToken = randomBytes(24).toString("hex");
    store.createToken(user.id, "ingest", "self-registered", ingestToken);
    store.createDeviceRegistration({
      install_id: installID,
      user_id: user.id,
      ingest_token: ingestToken,
      attest_key_id: verification.keyId,
      attest_public_key: verification.publicKeyDer,
      attest_environment: verification.environment,
      attest_counter: 0,
    });

    console.log(
      `[register] new device: install_id=${installID.slice(0, 8)}… user_id=${user.id} ` +
      `name="${displayName}" env=${verification.environment}`
    );

    return c.json({
      user_id: user.id,
      ingest_token: ingestToken,
      already_registered: false,
    }, 201);
  });
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

function isInstallID(s: unknown): s is string {
  return typeof s === "string" && UUID_RE.test(s);
}

function sanitizeDisplayName(s: unknown): string | null {
  if (typeof s !== "string") return null;
  const trimmed = s.trim();
  if (trimmed.length === 0 || trimmed.length > 80) return null;
  return trimmed;
}

function defaultDeviceName(installID: string): string {
  return `iPhone-${installID.slice(0, 8)}`;
}
