import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
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
  ingested_at: string;
  ingested_by_device: string | null;
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
    `);
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
        pacerunner_log_path, pacerunner_workout_id,
        ingested_at, ingested_by_device
      ) VALUES (
        @id, @user_id, @activity_type, @activity_type_raw, @start_time, @end_time,
        @duration_seconds, @total_distance_meters, @total_energy_kcal,
        @source_name, @source_bundle_id, @raw_metadata,
        @has_route, @has_samples, @has_events, @is_indoor,
        @pacerunner_log_path, @pacerunner_workout_id,
        @ingested_at, @ingested_by_device
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
        ingested_at = excluded.ingested_at,
        ingested_by_device = excluded.ingested_by_device
      WHERE workouts.user_id = excluded.user_id
    `).run({ ...row, ingested_at: ingestedAt });
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
