/**
 * Apple App Attest verification.
 *
 * Spec: https://developer.apple.com/documentation/devicecheck/validating_apps_that_connect_to_your_server
 *
 * Steps we perform on the server when /ingest/register fires:
 *
 *   1. Decode the attestation object (CBOR) into { fmt, attStmt, authData }.
 *   2. Verify the certificate chain: x5c[0] (leaf) is signed by x5c[1]
 *      (intermediate), which is signed by Apple's App Attest Root CA.
 *   3. Compute `nonce = SHA256(authData || clientDataHash)` where
 *      clientDataHash = SHA256(challenge). Verify it matches the value
 *      in the leaf cert's nonce extension (OID 1.2.840.113635.100.8.2).
 *   4. Verify `authData.appIdHash` == SHA256("<teamId>.<bundleId>").
 *   5. Verify `authData.counter` == 0 (attestation is the very first time).
 *   6. Verify `authData.aaguid` is "appattest" or "appattestdevelop"
 *      (production vs sandbox).
 *   7. Verify `authData.credentialId` matches the key_id the phone sent
 *      (so we can correlate this attestation to the assertions that follow).
 *   8. Extract the COSE-encoded public key from authData. Convert to PEM
 *      and persist it keyed by install_id for future assertion verification.
 *
 * Apple's root cert is embedded below — it's intentionally distributed
 * out-of-band rather than fetched at runtime.
 *
 * For assertions (future per-request signing — not used in v1 register),
 * the same module can verify the signature against the stored public key.
 */

import { createHash, createPublicKey, X509Certificate, verify as cryptoVerify } from "node:crypto";
import { decode as cborDecode } from "cbor-x";

// -------------------------------------------------------------------------
// Apple's App Attest Root CA. Distributed by Apple, embedded here.
// https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
// -------------------------------------------------------------------------
const APPLE_ROOT_PEM = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

const APPLE_ROOT = new X509Certificate(APPLE_ROOT_PEM);

// OID for the nonce extension Apple includes in the leaf cert.
const APPLE_NONCE_OID = "1.2.840.113635.100.8.2";

export interface AttestationVerificationResult {
  /** The attestation key's identifier; what the phone calls "key_id". */
  keyId: Buffer;
  /** SPKI-DER public key bytes, for future assertion verification. */
  publicKeyDer: Buffer;
  /** "appattest" (production) or "appattestdevelop" (sandbox). */
  environment: "production" | "development";
  /** Echoed back for callers that want it. */
  aaguid: string;
}

export class AttestationError extends Error {
  constructor(msg: string, public readonly step: string) {
    super(`App Attest verification failed at step ${step}: ${msg}`);
  }
}

/**
 * Verify an Apple App Attest attestation object.
 *
 * @param attestationB64   The phone-supplied attestation, base64-encoded.
 * @param keyIdB64         The phone-supplied key identifier (base64).
 * @param challenge        The challenge string the server issued for this phone.
 * @param appId            Your full app ID: "<teamId>.<bundleId>" (e.g. "ABC123XYZ4.com.brintontech.PaceRunner").
 */
export function verifyAttestation(
  attestationB64: string,
  keyIdB64: string,
  challenge: string,
  appId: string
): AttestationVerificationResult {
  // -------- Step 1: decode the CBOR attestation object -----------------
  const attBuf = Buffer.from(attestationB64, "base64");
  const keyId = Buffer.from(keyIdB64, "base64");
  let decoded: any;
  try {
    decoded = cborDecode(attBuf);
  } catch (e) {
    throw new AttestationError(`CBOR decode: ${(e as Error).message}`, "1.cbor");
  }
  if (decoded?.fmt !== "apple-appattest") {
    throw new AttestationError(`Unexpected fmt: ${decoded?.fmt}`, "1.fmt");
  }
  const attStmt = decoded.attStmt;
  const authData: Buffer = decoded.authData;
  if (!attStmt || !Array.isArray(attStmt.x5c) || !authData) {
    throw new AttestationError("Missing attStmt.x5c or authData", "1.shape");
  }

  // -------- Step 2: verify the certificate chain -----------------------
  // x5c[0] = leaf (the attestation), x5c[1] = Apple intermediate signed by root.
  const leaf = new X509Certificate(Buffer.from(attStmt.x5c[0]));
  const intermediate = new X509Certificate(Buffer.from(attStmt.x5c[1]));
  // X509Certificate.verify checks the signature on `this` using the given key.
  if (!intermediate.verify(APPLE_ROOT.publicKey)) {
    throw new AttestationError("Intermediate not signed by Apple root", "2.intermediate");
  }
  if (!leaf.verify(intermediate.publicKey)) {
    throw new AttestationError("Leaf not signed by intermediate", "2.leaf");
  }

  // -------- Step 3: nonce extension matches SHA256(authData||clientDataHash)
  const clientDataHash = sha256(Buffer.from(challenge, "utf-8"));
  const expectedNonce = sha256(Buffer.concat([authData, clientDataHash]));
  const certNonce = extractNonceExtension(leaf);
  if (!certNonce) {
    throw new AttestationError("Leaf cert missing nonce extension", "3.ext-missing");
  }
  if (!certNonce.equals(expectedNonce)) {
    throw new AttestationError(
      `Nonce mismatch (cert ${certNonce.toString("hex")} vs computed ${expectedNonce.toString("hex")})`,
      "3.nonce"
    );
  }

  // -------- Step 4: app ID hash matches -------------------------------
  const parsed = parseAuthData(authData);
  const expectedAppIdHash = sha256(Buffer.from(appId, "utf-8"));
  if (!parsed.appIdHash.equals(expectedAppIdHash)) {
    throw new AttestationError(
      `App ID mismatch (got ${parsed.appIdHash.toString("hex")} expected ${expectedAppIdHash.toString("hex")})`,
      "4.app-id"
    );
  }

  // -------- Step 5: counter must be 0 for an attestation --------------
  if (parsed.counter !== 0) {
    throw new AttestationError(`Expected counter=0, got ${parsed.counter}`, "5.counter");
  }

  // -------- Step 6: AAGUID identifies App Attest production/dev -------
  const aaguidStr = parsed.aaguid.toString("ascii").replace(/\0+$/, "");
  if (aaguidStr !== "appattest" && aaguidStr !== "appattestdevelop") {
    throw new AttestationError(`Unexpected AAGUID: ${JSON.stringify(aaguidStr)}`, "6.aaguid");
  }
  const environment = aaguidStr === "appattest" ? "production" : "development";

  // -------- Step 7: credential ID equals the phone-supplied keyId ------
  if (!parsed.credentialId.equals(keyId)) {
    throw new AttestationError("credentialId in authData doesn't match phone-supplied key_id", "7.key-id");
  }

  // -------- Step 8: extract public key from leaf cert (SPKI DER) -------
  // The leaf cert's subjectPublicKeyInfo IS the key Apple is attesting.
  const pubKey = createPublicKey(leaf.publicKey);
  const publicKeyDer = pubKey.export({ type: "spki", format: "der" });

  return {
    keyId,
    publicKeyDer: Buffer.from(publicKeyDer),
    environment,
    aaguid: aaguidStr,
  };
}

/**
 * Verify a per-request App Attest assertion. Use this if/when we want to
 * sign every ingest request (not just registration). Not wired into the
 * v1 register flow but available for follow-up work.
 *
 * @param assertionB64  The CBOR-encoded assertion from `DCAppAttestService.generateAssertion`.
 * @param clientDataJson  The exact bytes you also hash to clientDataHash on the phone.
 * @param storedPublicKeyDer  Public key from a prior attestation verification.
 * @param lastCounter   Highest counter we've seen for this key (must increase).
 *
 * Returns the new counter value (caller persists it).
 */
export function verifyAssertion(
  assertionB64: string,
  clientDataJson: Buffer,
  storedPublicKeyDer: Buffer,
  lastCounter: number,
  appId: string
): number {
  const buf = Buffer.from(assertionB64, "base64");
  let decoded: any;
  try {
    decoded = cborDecode(buf);
  } catch (e) {
    throw new AttestationError(`CBOR decode: ${(e as Error).message}`, "assert.1");
  }
  const sig: Buffer = decoded.signature;
  const authData: Buffer = decoded.authenticatorData;
  if (!sig || !authData) {
    throw new AttestationError("Assertion missing signature or authenticatorData", "assert.shape");
  }
  const clientDataHash = sha256(clientDataJson);
  const signedData = Buffer.concat([authData, clientDataHash]);
  const pubKey = createPublicKey({ key: storedPublicKeyDer, format: "der", type: "spki" });
  const valid = cryptoVerify("sha256", signedData, pubKey, sig);
  if (!valid) throw new AttestationError("Bad signature", "assert.sig");

  // App ID + counter checks
  const parsed = parseAuthData(authData);
  const expectedAppIdHash = sha256(Buffer.from(appId, "utf-8"));
  if (!parsed.appIdHash.equals(expectedAppIdHash)) {
    throw new AttestationError("App ID mismatch on assertion", "assert.app-id");
  }
  if (parsed.counter <= lastCounter) {
    throw new AttestationError(
      `Counter regression (got ${parsed.counter}, stored ${lastCounter})`,
      "assert.counter"
    );
  }
  return parsed.counter;
}

// -------------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------------

function sha256(data: Buffer): Buffer {
  return createHash("sha256").update(data).digest();
}

interface ParsedAuthData {
  appIdHash: Buffer;       // 32 bytes
  flags: number;           // 1 byte
  counter: number;         // 4 bytes big-endian
  aaguid: Buffer;          // 16 bytes
  credentialId: Buffer;    // variable
  /** Remainder of authData (COSE public key etc.). */
  remainder: Buffer;
}

function parseAuthData(authData: Buffer): ParsedAuthData {
  // Format per WebAuthn / Apple App Attest:
  //   32 bytes rpIdHash (appIdHash)
  //    1 byte  flags
  //    4 bytes signCount (counter), big-endian
  //   16 bytes aaguid
  //    2 bytes credentialIdLength, big-endian
  //    N bytes credentialId
  //    M bytes attested credential data (COSE)
  if (authData.length < 37) {
    throw new AttestationError(`authData too short: ${authData.length}`, "parse.len");
  }
  const appIdHash = authData.subarray(0, 32);
  const flags = authData[32];
  const counter = authData.readUInt32BE(33);
  if (authData.length < 37 + 18) {
    return {
      appIdHash, flags, counter,
      aaguid: Buffer.alloc(16),
      credentialId: Buffer.alloc(0),
      remainder: authData.subarray(37),
    };
  }
  const aaguid = authData.subarray(37, 53);
  const credIdLen = authData.readUInt16BE(53);
  const credentialId = authData.subarray(55, 55 + credIdLen);
  const remainder = authData.subarray(55 + credIdLen);
  return { appIdHash, flags, counter, aaguid, credentialId, remainder };
}

/**
 * Pull the bytes out of the leaf cert's nonce extension (OID 1.2.840.113635.100.8.2).
 *
 * Apple wraps the 32-byte nonce in an ASN.1 sequence: `SEQUENCE { [1] EXPLICIT OCTET STRING }`,
 * so we walk the DER manually rather than pulling in a full ASN.1 library.
 */
function extractNonceExtension(cert: X509Certificate): Buffer | null {
  // Node's X509Certificate doesn't expose extensions directly, but the raw
  // DER is available via `cert.raw`. Search the DER for the OID and then
  // walk forward to the OCTET STRING.
  const der = cert.raw;
  // OID 1.2.840.113635.100.8.2 encoded in DER: 06 0a 2a 86 48 86 f7 63 64 08 02
  const oidPattern = Buffer.from([0x06, 0x0a, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x08, 0x02]);
  const idx = der.indexOf(oidPattern);
  if (idx < 0) return null;
  // Skip OID, then expect: <SEQUENCE | OCTET STRING wrapping> ... <OCTET STRING> 0x20 <32 bytes>
  // Cheapest reliable extraction: scan forward for `0x04 0x20` (OCTET STRING, length 32) and
  // take the following 32 bytes. The nonce is always 32 bytes (SHA-256 output).
  for (let i = idx + oidPattern.length; i < der.length - 33; i++) {
    if (der[i] === 0x04 && der[i + 1] === 0x20) {
      return Buffer.from(der.subarray(i + 2, i + 2 + 32));
    }
  }
  return null;
}
