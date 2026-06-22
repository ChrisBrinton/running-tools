import { readFile, writeFile, stat, mkdir } from "node:fs/promises";
import path from "node:path";
import type { Store } from "./db.js";

/**
 * Files are namespaced by user_id so per-user backups, restore, and
 * "delete this user's data" operations are a straightforward `rm -rf`.
 *
 *   data/files/<user_id>/gpx/<workout_id>.gpx
 *   data/files/<user_id>/logs/<file_base>.txt
 */

function userDirs(store: Store, userID: number) {
  const base = path.join(store.dataDir, "files", String(userID));
  return {
    gpx: path.join(base, "gpx"),
    logs: path.join(base, "logs"),
  };
}

async function ensureDir(p: string): Promise<void> {
  await mkdir(p, { recursive: true });
}

export async function writeRouteGPX(
  store: Store,
  userID: number,
  workoutID: string,
  gpx: string
): Promise<string> {
  const dirs = userDirs(store, userID);
  await ensureDir(dirs.gpx);
  const rel = path.join("files", String(userID), "gpx", `${workoutID}.gpx`);
  await writeFile(path.join(store.dataDir, rel), gpx, "utf-8");
  return rel;
}

export async function readRouteGPX(
  store: Store,
  userID: number,
  workoutID: string
): Promise<string | null> {
  const rel = path.join("files", String(userID), "gpx", `${workoutID}.gpx`);
  try {
    return await readFile(path.join(store.dataDir, rel), "utf-8");
  } catch {
    return null;
  }
}

export async function writePaceRunnerLog(
  store: Store,
  userID: number,
  fileBaseName: string,
  text: string
): Promise<string> {
  const dirs = userDirs(store, userID);
  await ensureDir(dirs.logs);
  const rel = path.join("files", String(userID), "logs", `${fileBaseName}.txt`);
  await writeFile(path.join(store.dataDir, rel), text, "utf-8");
  return rel;
}

export async function readPaceRunnerLog(
  store: Store,
  relPath: string
): Promise<string | null> {
  try {
    return await readFile(path.join(store.dataDir, relPath), "utf-8");
  } catch {
    return null;
  }
}

export async function fileSize(store: Store, relPath: string): Promise<number | null> {
  try {
    const st = await stat(path.join(store.dataDir, relPath));
    return st.size;
  } catch {
    return null;
  }
}
