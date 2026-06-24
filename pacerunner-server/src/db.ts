import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { randomBytes } from "node:crypto";
import path from "node:path";

/**
 * SQLite-backed multi-user store for ingested PaceRunner / HealthKit data.
 *
 * Identity model:
 *   - `users` (id, name, ...) — one row per app user.
 *   - `user_tokens` (token, user_id, scope) — bearer tokens. Scopes are
 *     'ingest' (phone push), 'mcp' (chat read), or 'admin' (CLI / future
 *     admin HTTP). Multiple tokens per user are encouraged so each chat
 *     client / phone can be revoked independently.
 *
 * Data isolation:
 *   - Every workout / config / settings row carries `user_id`.
 *   - Files on disk live under `data/files/<user_id>/{gpx,logs}/<workout_id>...`
 *     so backups + per-user wipes are trivial.
 *   - Samples / events / weather inherit isolation via workouts.user_id.
 */

export type TokenScope = "ingest" | "mcp" | "admin";

export interface UserRow {
  id: number;
  name: string;
  email: string | null;
  created_at: string;
  notes: string | null;
}

export interface TokenRow {
  token: string;
  user_id: number;
  scope: TokenScope;
  label: string | null;
  created_at: string;
  last_used_at: string | null;
  revoked: number;
}

export interface OAuthClientRow {
  client_id: string;
  client_secret_hash: string;
  user_id: number | null;
  label: string | null;
  redirect_uris: string; // JSON-encoded string[]; ["*"] means allow any
  created_at: string;
}

export interface OAuthCodeRow {
  code: string;
  client_id: string;
  user_id: number;
  redirect_uri: string;
  code_challenge: string | null;
  code_challenge_method: string | null;
  expires_at: string;
  used: number;
}

export interface WorkoutRow {
  id: string;
  user_id: number;
  activity_type: string;
  activity_type_raw: number | null;
  start_time: string;
  end_time: string;
  duration_seconds: number;
  total_distance_meters: number | null;
  total_energy_kcal: number | null;
  source_name: string | null;
  source_bundle_id: string | null;
  raw_metadata: string | null;
  has_route: number;
  has_samples: number;
  has_events: number;
  is_indoor: number;
  pacerunner_log_path: string | null;
  pacerunner_workout_id: string | null;
  /** Name of the PaceRunner run configuration this workout used, e.g.
   *  "5mi Easy" or "Tempo Progression". Comes from the phone alongside
   *  the PR debug log when present — direct user-intent signal that the
   *  classifier in summary.ts prefers over HR-based heuristics. */
  pacerunner_config_name: string | null;
  ingested_at: string;
  ingested_by_device: string | null;
  /** JSON-encoded WorkoutSummary blob (avg/min/max HR, pace, power, etc.).
   *  Computed at ingest from samples + raw metadata; null on workouts that
   *  were ingested before the summary feature shipped. */
  summary_json: string | null;
}

export interface DeviceRegistrationRow {
  install_id: string;
  user_id: number;
  ingest_token: string;
  attest_key_id: Buffer;
  attest_public_key: Buffer;
  attest_environment: string;
  attest_counter: number;
  registered_at: string;
}

export interface RegisterChallengeRow {
  challenge: string;
  install_id: string;
  expires_at: string;
  used: number;
}

export interface PairingCodeRow {
  code: string;
  user_id: number;
  expires_at: string;
  used: number;
  used_by_client_id: string | null;
  used_at: string | null;
}

export interface WorkoutSplitRow {
  workout_id: string;
  split_number: number;
  unit: string;
  cumulative_distance_meters: number;
  distance_meters: number;
  start_time: string;
  end_time: string;
  duration_seconds: number;
  pace_seconds_per_mile: number | null;
  avg_heart_rate_bpm: number | null;
  avg_running_power_watts: number | null;
  elevation_gain_meters: number;
  elevation_loss_meters: number;
}

export interface QuantitySampleRow {
  workout_id: string;
  type: string;
  start_time: string;
  end_time: string;
  value: number;
  unit: string;
}

export interface WorkoutEventRow {
  workout_id: string;
  type: string;
  start_time: string;
  duration_seconds: number;
}

export interface WeatherRow {
  workout_id: string;
  fetched_at: string;
  provider: string;
  lat: number;
  lon: number;
  observed_at: string;
  temp_c: number | null;
  humidity_pct: number | null;
  precip_mm: number | null;
  wind_mps: number | null;
  wind_dir_deg: number | null;
  cloud_cover_pct: number | null;
  pressure_hpa: number | null;
  pm25_ug_m3: number | null;
  pm10_ug_m3: number | null;
  us_aqi: number | null;
  raw_json: string | null;
}

export class Store {
  readonly db: Database.Database;
  readonly dataDir: string;

  constructor(dataDir: string) {
    this.dataDir = dataDir;
    mkdirSync(path.join(dataDir, "files"), { recursive: true });

    const dbPath = path.join(dataDir, "workouts.db");
    this.db = new Database(dbPath);
    this.db.pragma("journal_mode = WAL");
    this.db.pragma("foreign_keys = ON");
    this.applySchema();
  }

  private applySchema() {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        email TEXT,
        created_at TEXT NOT NULL,
        notes TEXT
      );

      CREATE TABLE IF NOT EXISTS user_tokens (
        token TEXT PRIMARY KEY,
        user_id INTEGER NOT NULL,
        scope TEXT NOT NULL CHECK (scope IN ('ingest','mcp','admin')),
        label TEXT,
        created_at TEXT NOT NULL,
        last_used_at TEXT,
        revoked INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS idx_tokens_user ON user_tokens(user_id);

      CREATE TABLE IF NOT EXISTS workouts (
        id TEXT PRIMARY KEY,
        user_id INTEGER NOT NULL,
        activity_type TEXT NOT NULL,
        activity_type_raw INTEGER,
        start_time TEXT NOT NULL,
        end_time TEXT NOT NULL,
        duration_seconds REAL NOT NULL,
        total_distance_meters REAL,
        total_energy_kcal REAL,
        source_name TEXT,
        source_bundle_id TEXT,
        raw_metadata TEXT,
        has_route INTEGER NOT NULL DEFAULT 0,
        has_samples INTEGER NOT NULL DEFAULT 0,
        has_events INTEGER NOT NULL DEFAULT 0,
        is_indoor INTEGER NOT NULL DEFAULT 0,
        pacerunner_log_path TEXT,
        pacerunner_workout_id TEXT,
        ingested_at TEXT NOT NULL,
        ingested_by_device TEXT,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS idx_workouts_user_start ON workouts(user_id, start_time);
      CREATE INDEX IF NOT EXISTS idx_workouts_user_type ON workouts(user_id, activity_type);
      CREATE INDEX IF NOT EXISTS idx_workouts_pr_id ON workouts(user_id, pacerunner_workout_id);

      CREATE TABLE IF NOT EXISTS quantity_samples (
        workout_id TEXT NOT NULL,
        type TEXT NOT NULL,
        start_time TEXT NOT NULL,
        end_time TEXT NOT NULL,
        value REAL NOT NULL,
        unit TEXT NOT NULL,
        FOREIGN KEY (workout_id) REFERENCES workouts(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS idx_samples_workout_type
        ON quantity_samples(workout_id, type);

      CREATE TABLE IF NOT EXISTS workout_events (
        workout_id TEXT NOT NULL,
        type TEXT NOT NULL,
        start_time TEXT NOT NULL,
        duration_seconds REAL NOT NULL,
        FOREIGN KEY (workout_id) REFERENCES workouts(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS idx_events_workout ON workout_events(workout_id);

      CREATE TABLE IF NOT EXISTS weather (
        workout_id TEXT PRIMARY KEY,
        fetched_at TEXT NOT NULL,
        provider TEXT NOT NULL,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        observed_at TEXT NOT NULL,
        temp_c REAL,
        humidity_pct REAL,
        precip_mm REAL,
        wind_mps REAL,
        wind_dir_deg REAL,
        cloud_cover_pct REAL,
        pressure_hpa REAL,
        pm25_ug_m3 REAL,
        pm10_ug_m3 REAL,
        us_aqi REAL,
        raw_json TEXT,
        FOREIGN KEY (workout_id) REFERENCES workouts(id) ON DELETE CASCADE
      );

      CREATE TABLE IF NOT EXISTS configurations (
        id TEXT NOT NULL,
        user_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        data TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (user_id, id),
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );

      CREATE TABLE IF NOT EXISTS settings_snapshots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        data TEXT NOT NULL,
        taken_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS idx_settings_user
        ON settings_snapshots(user_id, taken_at);

      CREATE TABLE IF NOT EXISTS oauth_clients (
        client_id TEXT PRIMARY KEY,
        client_secret_hash TEXT NOT NULL,
        user_id INTEGER,
        label TEXT,
        redirect_uris TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS oauth_codes (
        code TEXT PRIMARY KEY,
        client_id TEXT NOT NULL,
        user_id INTEGER NOT NULL,
        redirect_uri TEXT NOT NULL,
        code_challenge TEXT,
        code_challenge_method TEXT,
        expires_at TEXT NOT NULL,
        used INTEGER NOT NULL DEFAULT 0
      );

      CREATE TABLE IF NOT EXISTS workout_splits (
        workout_id TEXT NOT NULL,
        split_number INTEGER NOT NULL,
        unit TEXT NOT NULL,
        cumulative_distance_meters REAL NOT NULL,
        distance_meters REAL NOT NULL,
        start_time TEXT NOT NULL,
        end_time TEXT NOT NULL,
        duration_seconds REAL NOT NULL,
        pace_seconds_per_mile REAL,
        avg_heart_rate_bpm REAL,
        avg_running_power_watts REAL,
        elevation_gain_meters REAL NOT NULL DEFAULT 0,
        elevation_loss_meters REAL NOT NULL DEFAULT 0,
        PRIMARY KEY (workout_id, unit, split_number),
        FOREIGN KEY (workout_id) REFERENCES workouts(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS idx_splits_workout ON workout_splits(workout_id);

      -- Self-service device registration via Apple App Attest.
      --
      -- Each iPhone install generates an install_id (UUID) locally + creates
      -- an App Attest key. The first time it calls /ingest/register the
      -- server verifies the attestation, mints a user + ingest token, and
      -- persists the install→user mapping plus the attested public key.
      -- Subsequent calls with the same install_id are idempotent — same
      -- user, same token returned.
      CREATE TABLE IF NOT EXISTS device_registrations (
        install_id TEXT PRIMARY KEY,
        user_id INTEGER NOT NULL,
        ingest_token TEXT NOT NULL,
        attest_key_id BLOB NOT NULL,
        attest_public_key BLOB NOT NULL,
        attest_environment TEXT NOT NULL,
        attest_counter INTEGER NOT NULL DEFAULT 0,
        registered_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );

      -- Short-lived challenges issued for App Attest's "attest this key
      -- against this nonce" handshake. Each challenge is consumable once.
      CREATE TABLE IF NOT EXISTS register_challenges (
        challenge TEXT PRIMARY KEY,
        install_id TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        used INTEGER NOT NULL DEFAULT 0
      );

      -- Short-lived pairing codes for OAuth user binding. Phone generates
      -- one of these via /ingest/pairing-codes; user types it on the
      -- /authorize approval page so the resulting OAuth code is bound to
      -- THAT phone's user (rather than defaulting to users[0]). Single use,
      -- 10 min TTL. Decouples Claude Desktop's dynamic client registration
      -- from user identification in a multi-user world.
      CREATE TABLE IF NOT EXISTS pairing_codes (
        code TEXT PRIMARY KEY,
        user_id INTEGER NOT NULL,
        expires_at TEXT NOT NULL,
        used INTEGER NOT NULL DEFAULT 0,
        used_by_client_id TEXT,
        used_at TEXT,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    `);

    // Additive column migrations — safe to re-run; ALTER TABLE ADD COLUMN
    // is idempotent if we guard on PRAGMA table_info.
    this.addColumnIfMissing("workouts", "summary_json", "TEXT");
    this.addColumnIfMissing("workouts", "pacerunner_config_name", "TEXT");
  }

  private addColumnIfMissing(table: string, column: string, type: string): void {
    const cols = this.db.prepare(`PRAGMA table_info(${table})`).all() as Array<{ name: string }>;
    if (cols.some((c) => c.name === column)) return;
    this.db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${type}`);
  }

  // ---------------------------------------------------------------------
  // Users + tokens
  // ---------------------------------------------------------------------

  createUser(name: string, email?: string, notes?: string): UserRow {
    const stmt = this.db.prepare(`
      INSERT INTO users (name, email, created_at, notes)
      VALUES (?, ?, ?, ?)
    `);
    const info = stmt.run(name, email ?? null, new Date().toISOString(), notes ?? null);
    return this.getUser(Number(info.lastInsertRowid))!;
  }

  getUser(id: number): UserRow | undefined {
    return this.db.prepare("SELECT * FROM users WHERE id = ?").get(id) as UserRow | undefined;
  }

  listUsers(): UserRow[] {
    return this.db.prepare("SELECT * FROM users ORDER BY id").all() as UserRow[];
  }

  createToken(userID: number, scope: TokenScope, label: string | null, token: string): TokenRow {
    this.db.prepare(`
      INSERT INTO user_tokens (token, user_id, scope, label, created_at, revoked)
      VALUES (?, ?, ?, ?, ?, 0)
    `).run(token, userID, scope, label, new Date().toISOString());
    return this.lookupToken(token)!;
  }

  lookupToken(token: string): TokenRow | undefined {
    return this.db.prepare(
      "SELECT * FROM user_tokens WHERE token = ? AND revoked = 0"
    ).get(token) as TokenRow | undefined;
  }

  touchToken(token: string): void {
    this.db.prepare("UPDATE user_tokens SET last_used_at = ? WHERE token = ?")
      .run(new Date().toISOString(), token);
  }

  revokeToken(token: string): boolean {
    const info = this.db.prepare("UPDATE user_tokens SET revoked = 1 WHERE token = ?").run(token);
    return info.changes > 0;
  }

  listTokens(userID?: number): TokenRow[] {
    if (userID !== undefined) {
      return this.db.prepare(
        "SELECT * FROM user_tokens WHERE user_id = ? ORDER BY created_at DESC"
      ).all(userID) as TokenRow[];
    }
    return this.db.prepare(
      "SELECT * FROM user_tokens ORDER BY user_id, created_at DESC"
    ).all() as TokenRow[];
  }

  // ---------------------------------------------------------------------
  // Device registrations + challenges
  // ---------------------------------------------------------------------

  createChallenge(challenge: string, installID: string, ttlSeconds: number = 300): void {
    const expires = new Date(Date.now() + ttlSeconds * 1000).toISOString();
    this.db.prepare(`
      INSERT INTO register_challenges (challenge, install_id, expires_at, used)
      VALUES (?, ?, ?, 0)
    `).run(challenge, installID, expires);
  }

  /** Consume a challenge: returns the row if it exists, isn't used, isn't
   *  expired, and matches the install_id. Marks it used in the process. */
  consumeChallenge(challenge: string, installID: string): RegisterChallengeRow | undefined {
    const row = this.db.prepare(
      "SELECT * FROM register_challenges WHERE challenge = ?"
    ).get(challenge) as RegisterChallengeRow | undefined;
    if (!row) return undefined;
    if (row.used) return undefined;
    if (row.install_id !== installID) return undefined;
    if (new Date(row.expires_at).getTime() < Date.now()) return undefined;
    this.db.prepare("UPDATE register_challenges SET used = 1 WHERE challenge = ?").run(challenge);
    return row;
  }

  /** Garbage-collect expired challenges. Cheap; called occasionally. */
  purgeExpiredChallenges(): number {
    const info = this.db.prepare(
      "DELETE FROM register_challenges WHERE expires_at < ?"
    ).run(new Date().toISOString());
    return info.changes;
  }

  createDeviceRegistration(row: Omit<DeviceRegistrationRow, "registered_at">): void {
    this.db.prepare(`
      INSERT INTO device_registrations (
        install_id, user_id, ingest_token,
        attest_key_id, attest_public_key, attest_environment,
        attest_counter, registered_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      row.install_id, row.user_id, row.ingest_token,
      row.attest_key_id, row.attest_public_key, row.attest_environment,
      row.attest_counter, new Date().toISOString(),
    );
  }

  getDeviceRegistration(installID: string): DeviceRegistrationRow | undefined {
    return this.db.prepare(
      "SELECT * FROM device_registrations WHERE install_id = ?"
    ).get(installID) as DeviceRegistrationRow | undefined;
  }

  updateDeviceCounter(installID: string, counter: number): void {
    this.db.prepare(
      "UPDATE device_registrations SET attest_counter = ? WHERE install_id = ?"
    ).run(counter, installID);
  }

  // ---------------------------------------------------------------------
  // OAuth pairing codes (phone-to-coach handshake)
  // ---------------------------------------------------------------------

  createPairingCode(code: string, userID: number, ttlSeconds: number): void {
    const expires = new Date(Date.now() + ttlSeconds * 1000).toISOString();
    this.db.prepare(`
      INSERT INTO pairing_codes (code, user_id, expires_at, used)
      VALUES (?, ?, ?, 0)
    `).run(code, userID, expires);
  }

  /** Consume a pairing code. Returns the row if valid/unused/unexpired; marks
   *  the code consumed atomically. Returns undefined for any invalid case
   *  without distinguishing why (don't leak which codes exist). */
  consumePairingCode(code: string, clientID: string): PairingCodeRow | undefined {
    const row = this.db.prepare(
      "SELECT * FROM pairing_codes WHERE code = ?"
    ).get(code) as PairingCodeRow | undefined;
    if (!row) return undefined;
    if (row.used) return undefined;
    if (new Date(row.expires_at).getTime() < Date.now()) return undefined;
    this.db.prepare(
      "UPDATE pairing_codes SET used = 1, used_by_client_id = ?, used_at = ? WHERE code = ?"
    ).run(clientID, new Date().toISOString(), code);
    return row;
  }

  purgeExpiredPairingCodes(): number {
    const info = this.db.prepare(
      "DELETE FROM pairing_codes WHERE expires_at < ?"
    ).run(new Date().toISOString());
    return info.changes;
  }

  // ---------------------------------------------------------------------
  // OAuth2 clients
  // ---------------------------------------------------------------------

  createOAuthClient(
    clientId: string,
    secretHash: string,
    userId: number | null,
    label: string | null,
    redirectUris: string[],
  ): void {
    this.db.prepare(`
      INSERT INTO oauth_clients (client_id, client_secret_hash, user_id, label, redirect_uris, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(clientId, secretHash, userId, label, JSON.stringify(redirectUris), new Date().toISOString());
  }

  getOAuthClient(clientId: string): OAuthClientRow | undefined {
    return this.db.prepare(
      "SELECT * FROM oauth_clients WHERE client_id = ?"
    ).get(clientId) as OAuthClientRow | undefined;
  }

  listOAuthClients(userId?: number): OAuthClientRow[] {
    if (userId !== undefined) {
      return this.db.prepare(
        "SELECT * FROM oauth_clients WHERE user_id = ? ORDER BY created_at DESC"
      ).all(userId) as OAuthClientRow[];
    }
    return this.db.prepare(
      "SELECT * FROM oauth_clients ORDER BY created_at DESC"
    ).all() as OAuthClientRow[];
  }

  deleteOAuthClient(clientId: string): boolean {
    return this.db.prepare(
      "DELETE FROM oauth_clients WHERE client_id = ?"
    ).run(clientId).changes > 0;
  }

  // ---------------------------------------------------------------------
  // OAuth2 authorization codes
  // ---------------------------------------------------------------------

  createOAuthCode(
    clientId: string,
    userId: number,
    redirectUri: string,
    codeChallenge: string | null,
    codeChallengeMethod: string | null,
  ): string {
    const code = randomBytes(32).toString("hex");
    const expiresAt = new Date(Date.now() + 5 * 60 * 1000).toISOString();
    this.db.prepare(`
      INSERT INTO oauth_codes
        (code, client_id, user_id, redirect_uri, code_challenge, code_challenge_method, expires_at, used)
      VALUES (?, ?, ?, ?, ?, ?, ?, 0)
    `).run(code, clientId, userId, redirectUri, codeChallenge, codeChallengeMethod, expiresAt);
    return code;
  }

  getAndConsumeOAuthCode(code: string, clientId: string, redirectUri: string): OAuthCodeRow | null {
    return (this.db.transaction((): OAuthCodeRow | null => {
      const row = this.db.prepare(
        "SELECT * FROM oauth_codes WHERE code = ? AND used = 0"
      ).get(code) as OAuthCodeRow | undefined;
      if (!row) return null;
      if (row.client_id !== clientId) return null;
      if (row.redirect_uri !== redirectUri) return null;
      if (new Date(row.expires_at) < new Date()) return null;
      this.db.prepare("UPDATE oauth_codes SET used = 1 WHERE code = ?").run(code);
      return row;
    }))();
  }

  // ---------------------------------------------------------------------
  // Workouts
  // ---------------------------------------------------------------------

  upsertWorkout(row: Omit<WorkoutRow, "ingested_at">): void {
    const ingestedAt = new Date().toISOString();
    this.db.prepare(`
      INSERT INTO workouts (
        id, user_id, activity_type, activity_type_raw, start_time, end_time,
        duration_seconds, total_distance_meters, total_energy_kcal,
        source_name, source_bundle_id, raw_metadata,
        has_route, has_samples, has_events, is_indoor,
        pacerunner_log_path, pacerunner_workout_id, pacerunner_config_name,
        ingested_at, ingested_by_device, summary_json
      ) VALUES (
        @id, @user_id, @activity_type, @activity_type_raw, @start_time, @end_time,
        @duration_seconds, @total_distance_meters, @total_energy_kcal,
        @source_name, @source_bundle_id, @raw_metadata,
        @has_route, @has_samples, @has_events, @is_indoor,
        @pacerunner_log_path, @pacerunner_workout_id, @pacerunner_config_name,
        @ingested_at, @ingested_by_device, @summary_json
      )
      ON CONFLICT(id) DO UPDATE SET
        activity_type = excluded.activity_type,
        activity_type_raw = excluded.activity_type_raw,
        start_time = excluded.start_time,
        end_time = excluded.end_time,
        duration_seconds = excluded.duration_seconds,
        total_distance_meters = excluded.total_distance_meters,
        total_energy_kcal = excluded.total_energy_kcal,
        source_name = excluded.source_name,
        source_bundle_id = excluded.source_bundle_id,
        raw_metadata = excluded.raw_metadata,
        has_route = MAX(workouts.has_route, excluded.has_route),
        has_samples = MAX(workouts.has_samples, excluded.has_samples),
        has_events = MAX(workouts.has_events, excluded.has_events),
        is_indoor = excluded.is_indoor,
        pacerunner_log_path = COALESCE(excluded.pacerunner_log_path, workouts.pacerunner_log_path),
        pacerunner_workout_id = COALESCE(excluded.pacerunner_workout_id, workouts.pacerunner_workout_id),
        pacerunner_config_name = COALESCE(excluded.pacerunner_config_name, workouts.pacerunner_config_name),
        ingested_at = excluded.ingested_at,
        ingested_by_device = excluded.ingested_by_device,
        summary_json = COALESCE(excluded.summary_json, workouts.summary_json)
      WHERE workouts.user_id = excluded.user_id
    `).run({ ...row, ingested_at: ingestedAt });
  }

  /** Update just the PR-side fields when a /ingest/pacerunner-log call
   *  attaches a verbose log + config name to an existing workout row. */
  attachPaceRunnerLogAndConfig(
    userID: number,
    hkID: string,
    relPath: string,
    prID: string,
    configName: string | null
  ): boolean {
    const info = this.db.prepare(`
      UPDATE workouts
      SET pacerunner_log_path = ?,
          pacerunner_workout_id = ?,
          pacerunner_config_name = COALESCE(?, pacerunner_config_name)
      WHERE user_id = ? AND id = ?
    `).run(relPath, prID, configName, userID, hkID);
    return info.changes > 0;
  }

  // ---------------------------------------------------------------------
  // Splits
  // ---------------------------------------------------------------------

  /** Replace all splits for a workout atomically. Idempotent re-ingest. */
  replaceSplits(workoutID: string, rows: WorkoutSplitRow[]): void {
    const txn = this.db.transaction((rs: WorkoutSplitRow[]) => {
      this.db.prepare("DELETE FROM workout_splits WHERE workout_id = ?").run(workoutID);
      const ins = this.db.prepare(`
        INSERT INTO workout_splits (
          workout_id, split_number, unit,
          cumulative_distance_meters, distance_meters,
          start_time, end_time, duration_seconds,
          pace_seconds_per_mile, avg_heart_rate_bpm, avg_running_power_watts,
          elevation_gain_meters, elevation_loss_meters
        ) VALUES (
          @workout_id, @split_number, @unit,
          @cumulative_distance_meters, @distance_meters,
          @start_time, @end_time, @duration_seconds,
          @pace_seconds_per_mile, @avg_heart_rate_bpm, @avg_running_power_watts,
          @elevation_gain_meters, @elevation_loss_meters
        )
      `);
      for (const r of rs) ins.run(r);
    });
    txn(rows);
  }

  getSplits(workoutID: string, unit: string = "mile"): WorkoutSplitRow[] {
    return this.db.prepare(
      "SELECT * FROM workout_splits WHERE workout_id = ? AND unit = ? ORDER BY split_number"
    ).all(workoutID, unit) as WorkoutSplitRow[];
  }

  listWorkouts(userID: number, opts: {
    since?: string;
    until?: string;
    activityType?: string;
    limit?: number;
  }): WorkoutRow[] {
    const conditions: string[] = ["user_id = @user_id"];
    const params: Record<string, unknown> = { user_id: userID };
    if (opts.since) { conditions.push("start_time >= @since"); params.since = opts.since; }
    if (opts.until) { conditions.push("start_time < @until"); params.until = opts.until; }
    if (opts.activityType) {
      conditions.push("LOWER(activity_type) = LOWER(@activity_type)");
      params.activity_type = opts.activityType;
    }
    params.limit = opts.limit ?? 100;
    return this.db.prepare(
      `SELECT * FROM workouts WHERE ${conditions.join(" AND ")} ORDER BY start_time DESC LIMIT @limit`
    ).all(params) as WorkoutRow[];
  }

  getWorkout(userID: number, id: string): WorkoutRow | undefined {
    return this.db.prepare(
      "SELECT * FROM workouts WHERE user_id = ? AND id = ?"
    ).get(userID, id) as WorkoutRow | undefined;
  }

  getWorkoutByPaceRunnerID(userID: number, prID: string): WorkoutRow | undefined {
    return this.db.prepare(
      "SELECT * FROM workouts WHERE user_id = ? AND pacerunner_workout_id = ?"
    ).get(userID, prID) as WorkoutRow | undefined;
  }

  attachPaceRunnerLog(userID: number, hkID: string, relPath: string, prID: string): boolean {
    const info = this.db.prepare(`
      UPDATE workouts
      SET pacerunner_log_path = ?, pacerunner_workout_id = ?
      WHERE user_id = ? AND id = ?
    `).run(relPath, prID, userID, hkID);
    return info.changes > 0;
  }

  // ---------------------------------------------------------------------
  // Samples / events
  // ---------------------------------------------------------------------

  replaceQuantitySamples(workoutID: string, rows: QuantitySampleRow[]): void {
    const txn = this.db.transaction((rs: QuantitySampleRow[]) => {
      this.db.prepare("DELETE FROM quantity_samples WHERE workout_id = ?").run(workoutID);
      const ins = this.db.prepare(`
        INSERT INTO quantity_samples (workout_id, type, start_time, end_time, value, unit)
        VALUES (@workout_id, @type, @start_time, @end_time, @value, @unit)
      `);
      for (const r of rs) ins.run(r);
    });
    txn(rows);
  }

  getQuantitySamples(workoutID: string): QuantitySampleRow[] {
    return this.db.prepare(
      "SELECT * FROM quantity_samples WHERE workout_id = ? ORDER BY start_time ASC"
    ).all(workoutID) as QuantitySampleRow[];
  }

  replaceEvents(workoutID: string, events: WorkoutEventRow[]): void {
    const txn = this.db.transaction((rs: WorkoutEventRow[]) => {
      this.db.prepare("DELETE FROM workout_events WHERE workout_id = ?").run(workoutID);
      const ins = this.db.prepare(`
        INSERT INTO workout_events (workout_id, type, start_time, duration_seconds)
        VALUES (@workout_id, @type, @start_time, @duration_seconds)
      `);
      for (const r of rs) ins.run(r);
    });
    txn(events);
  }

  getEvents(workoutID: string): WorkoutEventRow[] {
    return this.db.prepare(
      "SELECT * FROM workout_events WHERE workout_id = ? ORDER BY start_time ASC"
    ).all(workoutID) as WorkoutEventRow[];
  }

  // ---------------------------------------------------------------------
  // Weather
  // ---------------------------------------------------------------------

  upsertWeather(row: WeatherRow): void {
    this.db.prepare(`
      INSERT INTO weather (
        workout_id, fetched_at, provider, lat, lon, observed_at,
        temp_c, humidity_pct, precip_mm, wind_mps, wind_dir_deg,
        cloud_cover_pct, pressure_hpa, pm25_ug_m3, pm10_ug_m3, us_aqi, raw_json
      ) VALUES (
        @workout_id, @fetched_at, @provider, @lat, @lon, @observed_at,
        @temp_c, @humidity_pct, @precip_mm, @wind_mps, @wind_dir_deg,
        @cloud_cover_pct, @pressure_hpa, @pm25_ug_m3, @pm10_ug_m3, @us_aqi, @raw_json
      )
      ON CONFLICT(workout_id) DO UPDATE SET
        fetched_at = excluded.fetched_at,
        provider = excluded.provider,
        lat = excluded.lat,
        lon = excluded.lon,
        observed_at = excluded.observed_at,
        temp_c = excluded.temp_c,
        humidity_pct = excluded.humidity_pct,
        precip_mm = excluded.precip_mm,
        wind_mps = excluded.wind_mps,
        wind_dir_deg = excluded.wind_dir_deg,
        cloud_cover_pct = excluded.cloud_cover_pct,
        pressure_hpa = excluded.pressure_hpa,
        pm25_ug_m3 = excluded.pm25_ug_m3,
        pm10_ug_m3 = excluded.pm10_ug_m3,
        us_aqi = excluded.us_aqi,
        raw_json = excluded.raw_json
    `).run(row);
  }

  getWeather(workoutID: string): WeatherRow | undefined {
    return this.db.prepare(
      "SELECT * FROM weather WHERE workout_id = ?"
    ).get(workoutID) as WeatherRow | undefined;
  }

  // ---------------------------------------------------------------------
  // Configurations
  // ---------------------------------------------------------------------

  upsertConfiguration(userID: number, id: string, name: string, data: unknown): void {
    this.db.prepare(`
      INSERT INTO configurations (id, user_id, name, data, updated_at, deleted)
      VALUES (?, ?, ?, ?, ?, 0)
      ON CONFLICT(user_id, id) DO UPDATE SET
        name = excluded.name,
        data = excluded.data,
        updated_at = excluded.updated_at,
        deleted = 0
    `).run(id, userID, name, JSON.stringify(data), new Date().toISOString());
  }

  deleteConfiguration(userID: number, id: string): void {
    this.db.prepare(
      "UPDATE configurations SET deleted = 1 WHERE user_id = ? AND id = ?"
    ).run(userID, id);
  }

  listConfigurations(userID: number): { id: string; name: string; data: unknown; updated_at: string }[] {
    const rows = this.db.prepare(
      "SELECT id, name, data, updated_at FROM configurations WHERE user_id = ? AND deleted = 0 ORDER BY name"
    ).all(userID) as { id: string; name: string; data: string; updated_at: string }[];
    return rows.map((r) => ({ ...r, data: JSON.parse(r.data) }));
  }

  // ---------------------------------------------------------------------
  // Settings snapshots
  // ---------------------------------------------------------------------

  insertSettingsSnapshot(userID: number, data: unknown): void {
    this.db.prepare(
      "INSERT INTO settings_snapshots (user_id, data, taken_at) VALUES (?, ?, ?)"
    ).run(userID, JSON.stringify(data), new Date().toISOString());
  }

  latestSettings(userID: number): { data: unknown; taken_at: string } | undefined {
    const row = this.db.prepare(
      "SELECT data, taken_at FROM settings_snapshots WHERE user_id = ? ORDER BY id DESC LIMIT 1"
    ).get(userID) as { data: string; taken_at: string } | undefined;
    return row ? { ...row, data: JSON.parse(row.data) } : undefined;
  }
}
