import Foundation

/// Per-workout debug log file storage.
///
/// Debug logs from verbose-GPS workouts can exceed 1MB, which makes them
/// unsuitable for UserDefaults (memory + size limits) and for the small
/// WatchConnectivity `sendMessage`/`transferUserInfo` paths. Storing them
/// as files in Caches lets us:
///
/// 1. Persist them long-term keyed by workout ID, separate from the
///    `WorkoutSummary` (which is kept lean).
/// 2. Sync them across devices via `WCSession.transferFile`, which handles
///    arbitrary file sizes.
/// 3. Render the map for any historical workout that has a log on disk.
///
/// Files are stored under `Caches/debugLogs/{uuid}.txt`. Caches is used
/// (rather than Documents) because debug logs are diagnostic — the OS may
/// purge them under disk pressure, which is fine.
public final class DebugLogStore {

    public static let shared = DebugLogStore()

    private let fm = FileManager.default
    private let folderName = "debugLogs"

    /// "Last" pointer key in UserDefaults so callers can find the most recent
    /// workout's log without scanning the directory.
    private let lastWorkoutIDKey = "debugLogStore_lastWorkoutID"

    public init() {
        ensureFolderExists()
        purgeLegacyUserDefaultsKeys()
    }

    // MARK: - Migration / Cleanup

    /// Older builds wrote the full multi-MB log into UserDefaults under
    /// `lastDebugLog` / `lastWatchDebugLog`. On the watch, that bloated
    /// `standard.plist` so badly that the OS struggled to deserialize it at
    /// launch (manifested as "app won't restart"). New builds never write
    /// these keys; this migration removes them on first launch after upgrade.
    public func purgeLegacyUserDefaultsKeys() {
        let defaults = UserDefaults.standard
        var freedBytes = 0
        for key in ["lastDebugLog", "lastWatchDebugLog"] {
            if let s = defaults.string(forKey: key) {
                freedBytes += s.utf8.count
                defaults.removeObject(forKey: key)
            }
        }
        if freedBytes > 0 {
            print("[DebugLogStore] Purged legacy UserDefaults log keys (\(freedBytes / 1024) KB)")
            defaults.synchronize()
        }
    }

    /// Deletes all but the most recent `keep` log files (by modification date).
    /// Prevents unbounded accumulation of per-workout logs in Caches/debugLogs/.
    public func pruneOldLogs(keepingMostRecent keep: Int) {
        guard let names = try? fm.contentsOfDirectory(atPath: folderURL.path) else { return }
        let urls = names
            .filter { UUID(uuidString: ($0 as NSString).deletingPathExtension) != nil }
            .map { folderURL.appendingPathComponent($0) }
        guard urls.count > keep else { return }
        let dated: [(URL, Date)] = urls.compactMap { url in
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let date = attrs[.modificationDate] as? Date else { return nil }
            return (url, date)
        }
        let sorted = dated.sorted { $0.1 > $1.1 }
        for (url, _) in sorted.dropFirst(keep) {
            try? fm.removeItem(at: url)
        }
        print("[DebugLogStore] Pruned \(sorted.count - keep) old log file(s), kept \(keep)")
    }

    // MARK: - Save / Load

    /// Write the log text for a given workout ID. Overwrites any existing file.
    @discardableResult
    public func save(_ text: String, for workoutID: UUID) -> URL? {
        let url = fileURL(for: workoutID)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(workoutID.uuidString, forKey: lastWorkoutIDKey)
            print("[DebugLogStore] Saved \(text.count) chars for \(workoutID)")
            return url
        } catch {
            print("[DebugLogStore] Save failed for \(workoutID): \(error)")
            return nil
        }
    }

    /// Returns the log text for a workout ID, or nil if none on disk.
    public func load(for workoutID: UUID) -> String? {
        let url = fileURL(for: workoutID)
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Returns the URL for the file (used for `WCSession.transferFile`).
    public func fileURL(for workoutID: UUID) -> URL {
        folderURL.appendingPathComponent("\(workoutID.uuidString).txt")
    }

    /// Returns the workout ID of the most recently saved log, or nil.
    public var lastWorkoutID: UUID? {
        guard let raw = UserDefaults.standard.string(forKey: lastWorkoutIDKey) else { return nil }
        return UUID(uuidString: raw)
    }

    /// Returns the text of the most recently saved log, or nil.
    public func loadLast() -> String? {
        guard let id = lastWorkoutID else { return nil }
        return load(for: id)
    }

    /// File size in bytes for a stored log, or nil if missing. Cheap — no read.
    public func fileSize(for workoutID: UUID) -> Int? {
        let url = fileURL(for: workoutID)
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    /// Returns at most the last `maxBytes` of the log for a workout, decoded as
    /// UTF-8. Intended for previewing huge logs on the watch without loading
    /// the whole file into memory.
    public func loadTail(for workoutID: UUID, maxBytes: Int) -> String? {
        let url = fileURL(for: workoutID)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = fileSize(for: workoutID) else { return nil }
        let offset = max(0, size - maxBytes)
        try? handle.seek(toOffset: UInt64(offset))
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Tail of the most recently saved log.
    public func loadLastTail(maxBytes: Int) -> String? {
        guard let id = lastWorkoutID else { return nil }
        return loadTail(for: id, maxBytes: maxBytes)
    }

    public func delete(for workoutID: UUID) {
        let url = fileURL(for: workoutID)
        try? fm.removeItem(at: url)
    }

    /// All workout IDs that currently have logs on disk.
    public func storedIDs() -> Set<UUID> {
        guard let contents = try? fm.contentsOfDirectory(atPath: folderURL.path) else { return [] }
        var ids: Set<UUID> = []
        for name in contents {
            let stem = (name as NSString).deletingPathExtension
            if let id = UUID(uuidString: stem) {
                ids.insert(id)
            }
        }
        return ids
    }

    /// Removes all stored logs. Used by debug "Reset All Data".
    public func clearAll() {
        try? fm.removeItem(at: folderURL)
        ensureFolderExists()
        UserDefaults.standard.removeObject(forKey: lastWorkoutIDKey)
    }

    // MARK: - Filesystem

    private var folderURL: URL {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent(folderName, isDirectory: true)
    }

    private func ensureFolderExists() {
        if !fm.fileExists(atPath: folderURL.path) {
            try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }
    }
}
