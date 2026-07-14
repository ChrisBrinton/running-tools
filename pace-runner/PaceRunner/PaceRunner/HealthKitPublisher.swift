import Foundation
import HealthKit
import Combine
import UIKit
import UserNotifications
import PaceRunnerShared

/// Publishes PaceRunner / HealthKit data to the always-on home server
/// (pacerunner-server).
///
/// Responsibilities:
///   - Hold the user's server URL + ingest token (UserDefaults, phone-only).
///   - Push workouts (metadata + route GPX + samples + events) via
///     `POST /ingest/workout`, idempotent on the server side.
///   - Push PaceRunner verbose debug logs via `POST /ingest/pacerunner-log`.
///   - Push run configurations and settings snapshots.
///   - Track which HK workout UUIDs we've already pushed so we don't
///     replay history on every launch.
///   - Auto-publish on `.workoutDidEnd` / `.workoutSummarySynced` and on
///     app foreground.
///   - Surface state to the UI: connection status, last push, pending count.
///
/// Failure model: the server is the source of truth. We retry whenever
/// we get a chance (app foreground, new workout, manual button). We do
/// NOT retry tight-loop on the failure callback — that would burn battery
/// on a flat-tire condition.
@MainActor
final class HealthKitPublisher: ObservableObject {

    static let shared = HealthKitPublisher()

    // MARK: - Published state

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastSuccessfulPush: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var totalPushedCount: Int = 0
    @Published private(set) var inFlightWorkoutID: String?

    enum Status: Equatable {
        case idle              // nothing happening
        case pushing(String)   // status text, e.g. "Pushing 3 of 5"
        case ok                // last operation succeeded
        case failed            // last operation failed (see lastError)
        case disabled          // missing URL or token
    }

    // MARK: - Configuration (persisted in UserDefaults)

    private let urlKey = "publisher_server_url"
    private let tokenKey = "publisher_ingest_token"
    private let pushedIDsKey = "publisher_pushed_workout_ids"
    private let pushedLogIDsKey = "publisher_pushed_log_ids"

    var serverURL: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: urlKey)
            recomputeStatus()
        }
    }

    var ingestToken: String {
        get { UserDefaults.standard.string(forKey: tokenKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: tokenKey)
            recomputeStatus()
        }
    }

    var isConfigured: Bool {
        !serverURL.isEmpty && !ingestToken.isEmpty && URL(string: serverURL) != nil
    }

    // MARK: - Bookkeeping

    private var pushedWorkoutIDs: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: pushedIDsKey) ?? []
            return Set(arr)
        }
        set {
            // Cap to a generous history — last 1000 IDs is plenty.
            let arr = Array(newValue).suffix(1000)
            UserDefaults.standard.set(Array(arr), forKey: pushedIDsKey)
        }
    }

    /// PaceRunner workout UUIDs whose verbose log has been successfully
    /// attached server-side. Tracked separately from `pushedWorkoutIDs`
    /// because a log often isn't available at the instant its HK workout is
    /// first pushed (the watch syncs the workout before, or independently of,
    /// the log being persisted). Decoupling lets `backfillPaceRunnerLogs`
    /// attach the log on a later pass without re-pushing the workout.
    private var pushedLogIDs: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: pushedLogIDsKey) ?? []
            return Set(arr)
        }
        set {
            let arr = Array(newValue).suffix(1000)
            UserDefaults.standard.set(Array(arr), forKey: pushedLogIDsKey)
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var foregroundObserver: NSObjectProtocol?

    private init() {
        recomputeStatus()
        wireHooks()
    }

    // MARK: - Wiring

    private func wireHooks() {
        // Auto-publish when a workout finishes on this phone, or when a
        // summary arrives from the watch (HK row should show up via Apple
        // sync shortly after — we'll retry on subsequent foregrounds if
        // the HK record isn't there yet).
        NotificationCenter.default.publisher(for: .workoutDidEnd)
            .compactMap { $0.object as? WorkoutSummary }
            .sink { [weak self] summary in
                Task { await self?.handleSummaryReady(summary) }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workoutSummarySynced)
            .compactMap { $0.object as? WorkoutSummary }
            .sink { [weak self] summary in
                Task { await self?.handleSummaryReady(summary) }
            }
            .store(in: &cancellables)

        // Periodic catch-up on foreground
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isConfigured else { return }
                // Light catch-up: look back 7 days. The manual Publish All
                // button uses a wider window.
                await self.publishPendingWorkouts(daysBack: 7)
            }
        }
    }

    /// Install the HealthKit background-delivery observer so the OS wakes the
    /// app to push new workouts even when it isn't in the foreground. The
    /// exporter only installs the underlying query once, so this is cheap to
    /// call repeatedly. When woken, we run a 7-day catch-up with per-workout
    /// notifications so the user still gets the "synced" ping in the background.
    private func enableBackgroundSync() {
        guard isConfigured else { return }
        HealthKitExporter.shared.startWorkoutBackgroundDelivery { [weak self] in
            await self?.publishPendingWorkouts(daysBack: 7, notifyEach: true)
        }
    }

    // MARK: - High-level operations

    /// Manual button. Looks back `daysBack` days for any HK workout that
    /// isn't already in `pushedWorkoutIDs` and pushes it. Returns
    /// (success_count, failure_count, skipped_count).
    @discardableResult
    func publishAll(daysBack: Int = 90, notifyEach: Bool = false) async -> (succeeded: Int, failed: Int, skipped: Int) {
        guard isConfigured else { return (0, 0, 0) }
        let exporter = HealthKitExporter.shared
        do {
            try await exporter.requestAuthorization()
        } catch {
            await MainActor.run { self.fail("HealthKit auth failed: \(error.localizedDescription)") }
            return (0, 0, 0)
        }

        // Now that we're configured and authorized, make sure the background
        // observer is installed so future runs sync without opening the app.
        enableBackgroundSync()

        let now = Date()
        let since = Calendar.current.date(byAdding: .day, value: -daysBack, to: now) ?? now
        let workouts: [HKWorkout]
        do {
            workouts = try await exporter.fetchWorkouts(from: since, to: now)
        } catch {
            await MainActor.run { self.fail("Fetch failed: \(error.localizedDescription)") }
            return (0, 0, 0)
        }

        let pushed = pushedWorkoutIDs
        let pending = workouts.filter { !pushed.contains($0.uuid.uuidString) }

        // Even when nothing is pending, run the log backfill: an already-pushed
        // workout may still be missing its PaceRunner log (log not yet available
        // when the workout was first pushed).
        guard !pending.isEmpty else {
            await backfillPaceRunnerLogs(workouts)
            await MainActor.run { self.status = .ok }
            return (0, 0, workouts.count)
        }

        var ok = 0
        var fail = 0
        for (i, workout) in pending.enumerated() {
            await MainActor.run {
                self.status = .pushing("Pushing \(i + 1) of \(pending.count)")
                self.inFlightWorkoutID = workout.uuid.uuidString
            }
            let result = await pushOneWorkout(workout)
            switch result {
            case .success:
                ok += 1
                await MainActor.run { self.markPushed(workout.uuid.uuidString) }
                if notifyEach {
                    await postWorkoutSyncNotification(for: workout)
                }
            case .failure(let err):
                fail += 1
                await MainActor.run { self.lastError = err.localizedDescription }
                // Stop early on auth failures — every subsequent call will
                // also 401 and there's no point hammering.
                if case .unauthorized = err { break }
            }
        }

        // Attach PaceRunner logs across all fetched workouts (freshly pushed
        // and previously pushed alike) now that their HK workouts are on the
        // server.
        await backfillPaceRunnerLogs(workouts)

        await MainActor.run {
            self.inFlightWorkoutID = nil
            if fail == 0 {
                self.status = .ok
                self.lastSuccessfulPush = Date()
                self.lastError = nil
            } else if ok > 0 {
                self.status = .ok
                self.lastSuccessfulPush = Date()
                // lastError set above; partial-success leaves it visible.
            } else {
                self.status = .failed
            }
        }
        return (ok, fail, workouts.count - pending.count)
    }

    /// Like publishAll, but only the recent window. Cheap to call on app
    /// foreground — most of the time everything's already in pushedIDs.
    /// `notifyEach=true` is used for the post-workout auto-publish path
    /// (single workout, surface it). On launch foreground catch-up
    /// `notifyEach=false` so multiple unsynced workouts don't spam.
    private func publishPendingWorkouts(daysBack: Int, notifyEach: Bool = false) async {
        _ = await publishAll(daysBack: daysBack, notifyEach: notifyEach)
    }

    /// React to a just-completed (or just-synced) PaceRunner workout by
    /// scheduling a publish pass once the HK workout has had time to sync from
    /// the watch. The workout push, config-name tagging, and verbose-log
    /// attachment all happen inside that pass (publishAll → backfill).
    private func handleSummaryReady(_ summary: WorkoutSummary) async {
        guard isConfigured else { return }
        _ = summary // retained for signature/observer symmetry; state comes from UserDefaults

        // The PaceRunner verbose log is attached by backfillPaceRunnerLogs
        // (invoked from publishPendingWorkouts below) once the HK workout has
        // synced from the watch and been pushed — it's keyed by hk_workout_id
        // so it attaches deterministically rather than being orphaned by a
        // premature push before the workout exists server-side.

        // The HK workout may not be on this phone yet — Apple syncs HK
        // workouts from the watch on its own schedule. Schedule a retry
        // in 30s; the foreground hook will pick it up after that. Use
        // notifyEach=true so the user sees a confirmation when the live
        // post-workout sync lands.
        Task {
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            await publishPendingWorkouts(daysBack: 7, notifyEach: true)
        }
    }

    /// Manually re-push everything (or push a backfill window). Bound to
    /// a Settings button.
    func publishConfigurations(_ configs: [RunConfiguration]) async {
        guard isConfigured else { return }
        // Server endpoint accepts a batch under `{ "configurations": [...] }`.
        // Use the same JSON shape we already encode for sync-to-watch.
        let payload: [String: Any] = [
            "configurations": configs.map { config -> [String: Any] in
                var data: [String: Any] = ["name": config.name]
                if let encoded = try? JSONEncoder().encode(config),
                   let object = try? JSONSerialization.jsonObject(with: encoded) {
                    data["data"] = object
                }
                return [
                    "id": config.id.uuidString,
                    "name": config.name,
                    "data": data["data"] ?? [:],
                ]
            }
        ]
        _ = await post(path: "/ingest/configs", body: payload, label: "configs")
    }

    func publishSettings(_ settings: AppSettings) async {
        guard isConfigured else { return }
        guard let encoded = try? JSONEncoder().encode(settings),
              let object = try? JSONSerialization.jsonObject(with: encoded) else { return }
        _ = await post(path: "/ingest/settings", body: ["data": object], label: "settings")
    }

    func resetPushedHistory() {
        pushedWorkoutIDs = []
        totalPushedCount = 0
        lastSuccessfulPush = nil
        lastError = nil
        recomputeStatus()
    }

    // MARK: - Notifications

    /// Posts a local notification confirming that a workout was synced to
    /// the server. iOS shows these as banners + adds to Notification
    /// Center. We requested .alert/.sound auth at app launch already
    /// (see PaceRunnerApp.init); if the user denied permission this
    /// just no-ops silently.
    private func postWorkoutSyncNotification(for workout: HKWorkout) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Workout synced"
        content.body = workoutSyncBody(workout)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "workout-sync-\(workout.uuid.uuidString)",
            content: content,
            trigger: nil // deliver immediately
        )
        do {
            try await center.add(request)
        } catch {
            print("[Publisher] notification add failed: \(error)")
        }
    }

    /// Produces the body text shown in the notification banner.
    /// Example: "5.21 mi · 50:33 · 9:42/mi"
    private func workoutSyncBody(_ workout: HKWorkout) -> String {
        var parts: [String] = []
        if let distance = workout.totalDistance?.doubleValue(for: .mile()) {
            parts.append(String(format: "%.2f mi", distance))
        }
        parts.append(formatDuration(workout.duration))
        if let distance = workout.totalDistance?.doubleValue(for: .mile()),
           distance > 0, workout.duration > 0 {
            let secPerMile = workout.duration / distance
            parts.append("\(formatPace(secPerMile))/mi")
        }
        return parts.joined(separator: " · ")
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func formatPace(_ secPerMile: TimeInterval) -> String {
        let s = Int(round(secPerMile))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Account deletion

    /// Calls `DELETE /ingest/device` to wipe the user + all of their data
    /// from the server. Returns when the server confirms the deletion;
    /// caller is expected to also clear local state (install_id, token,
    /// pushed-history) immediately afterwards.
    func deleteAccountOnServer() async throws {
        guard isConfigured else { throw PushError.notConfigured }
        guard let base = URL(string: serverURL),
              let url = URL(string: "/ingest/device", relativeTo: base) else {
            throw PushError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(ingestToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw PushError.http(0, "non-HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw PushError.unauthorized }
        if !(200...299).contains(http.statusCode) {
            throw PushError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Local-only wipe: forget the ingest token, the pushed-workout history,
    /// and the cached status. Caller (typically PublisherRegistration) is
    /// responsible for also clearing the install_id so a re-register
    /// produces a fresh user_id on the server.
    func wipeLocalCredentials() {
        ingestToken = ""
        pushedWorkoutIDs = []
        totalPushedCount = 0
        lastSuccessfulPush = nil
        lastError = nil
        inFlightWorkoutID = nil
        recomputeStatus()
    }

    // MARK: - Token management

    /// Calls `POST /ingest/tokens` to mint a new MCP-scoped token for THIS
    /// user (the one our ingest token is bound to). The server's policy
    /// allows ingest scope to create mcp scope laterally — same blast
    /// radius — so we don't need an admin handshake.
    ///
    /// Returns the freshly-minted token string. The caller is responsible
    /// for displaying it; we don't persist it on the phone (the server
    /// won't echo it again on subsequent reads).
    func createMCPToken(label: String) async throws -> String {
        guard isConfigured else { throw PushError.notConfigured }
        guard let base = URL(string: serverURL),
              let url = URL(string: "/ingest/tokens", relativeTo: base) else {
            throw PushError.notConfigured
        }
        let body: [String: Any] = ["scope": "mcp", "label": label]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(ingestToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw PushError.http(0, "non-HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw PushError.unauthorized
        }
        if !(200...299).contains(http.statusCode) {
            throw PushError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Response: Decodable { let token: String }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.token
    }

    /// Result of `createPairingCode` — pairs the 6-digit code with its TTL
    /// so the UI can display a countdown.
    struct PairingCodeResult {
        let code: String
        let expiresAt: Date
    }

    /// Calls `POST /ingest/pairing-codes` to mint a short-lived numeric
    /// code that the user types on the OAuth `/authorize` approval page,
    /// binding the resulting Claude Desktop / web session to THIS user.
    func createPairingCode() async throws -> PairingCodeResult {
        guard isConfigured else { throw PushError.notConfigured }
        guard let base = URL(string: serverURL),
              let url = URL(string: "/ingest/pairing-codes", relativeTo: base) else {
            throw PushError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(ingestToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [String: Any]())
        req.timeoutInterval = 30

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw PushError.http(0, "non-HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw PushError.unauthorized }
        if !(200...299).contains(http.statusCode) {
            throw PushError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Response: Decodable {
            let code: String
            let expires_in_seconds: Int
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return PairingCodeResult(
            code: decoded.code,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in_seconds))
        )
    }

    // MARK: - Push primitives

    private enum PushError: LocalizedError {
        case notConfigured
        case unauthorized
        case http(Int, String)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Server URL or ingest token not set"
            case .unauthorized:  return "Server rejected token (401)"
            case .http(let code, let body):
                return "HTTP \(code)\(body.isEmpty ? "" : ": \(body)")"
            case .transport(let e):
                return "Network: \(e.localizedDescription)"
            }
        }
    }

    /// Find the PaceRunner workout summary that corresponds to an HK workout
    /// by *time-interval overlap*, not just start time. The PaceRunner workout
    /// is usually shorter than the overall HK workout and the two can start in
    /// either order (HK often begins during a warm-up before PaceRunner is
    /// started, or vice-versa). We pick the summary whose [start, end] interval
    /// overlaps the HK workout's interval the most; a small tolerance lets
    /// back-to-back-but-not-quite-overlapping intervals (starts within a couple
    /// of minutes) still match. Reads directly from UserDefaults rather than
    /// depending on a WorkoutHistoryStore instance — keeps the publisher
    /// decoupled.
    @MainActor
    private func matchingSummary(for workout: HKWorkout) -> WorkoutSummary? {
        bestOverlappingSummary(for: workout, among: loadWorkoutSummaries())
    }

    /// Decode the persisted PaceRunner workout summaries from UserDefaults.
    @MainActor
    private func loadWorkoutSummaries() -> [WorkoutSummary] {
        guard let data = UserDefaults.standard.data(forKey: "workoutSummaries") else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([WorkoutSummary].self, from: data)) ?? []
    }

    /// Pick the summary whose [start, end] interval overlaps the HK workout's
    /// interval the most. Positive overlap = seconds of true overlap; negative
    /// = gap between the two intervals — larger is always better. A small
    /// tolerance lets near-adjacent intervals (a few minutes' clock skew
    /// between watch and phone) still match.
    private func bestOverlappingSummary(
        for workout: HKWorkout,
        among summaries: [WorkoutSummary]
    ) -> WorkoutSummary? {
        let hkStart = workout.startDate
        let hkEnd = workout.endDate
        let tolerance: TimeInterval = 2 * 60
        var best: WorkoutSummary?
        var bestOverlap = -Double.greatestFiniteMagnitude
        for summary in summaries {
            let overlap = min(summary.endTime, hkEnd).timeIntervalSince(max(summary.startTime, hkStart))
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = summary
            }
        }
        return bestOverlap > -tolerance ? best : nil
    }

    /// Build the payload for an HK workout, tag it with its PaceRunner config
    /// name when one matches, post it, mark as pushed on success. The PaceRunner
    /// verbose log is attached separately by `backfillPaceRunnerLogs` so that a
    /// log which isn't yet available at push time still lands on a later pass.
    private func pushOneWorkout(_ workout: HKWorkout) async -> Result<Void, PushError> {
        let exporter = HealthKitExporter.shared
        var payload = await exporter.buildWorkoutPayload(for: workout)
        if let summary = await matchingSummary(for: workout) {
            payload["pacerunner_config_name"] = summary.configurationName
        }
        return await post(path: "/ingest/workout", body: payload, label: "workout \(workout.uuid.uuidString)")
    }

    /// Self-healing PaceRunner-log attachment. Runs over *every* fetched HK
    /// workout (not just freshly-pushed ones), so a log that wasn't available
    /// when its workout was first pushed still attaches on a later pass. Each
    /// log is keyed by `hk_workout_id` for deterministic server-side
    /// attachment and recorded in `pushedLogIDs` so we don't re-upload
    /// multi-MB logs every pass. Best-effort: a failed push simply isn't
    /// recorded and is retried next time.
    private func backfillPaceRunnerLogs(_ workouts: [HKWorkout]) async {
        let summaries = loadWorkoutSummaries()
        guard !summaries.isEmpty else { return }
        for workout in workouts {
            guard let summary = bestOverlappingSummary(for: workout, among: summaries) else {
                continue
            }
            let prID = summary.id.uuidString
            if pushedLogIDs.contains(prID) { continue }
            guard let log = DebugLogStore.shared.load(for: summary.id) else { continue }
            let result = await pushPaceRunnerLog(
                paceRunnerID: summary.id,
                startTime: summary.startTime,
                endTime: summary.endTime,
                hkWorkoutID: workout.uuid.uuidString,
                text: log,
                configName: summary.configurationName
            )
            if case .success = result {
                var attached = pushedLogIDs
                attached.insert(prID)
                pushedLogIDs = attached
            }
        }
    }

    private func pushPaceRunnerLog(
        paceRunnerID: UUID,
        startTime: Date,
        endTime: Date? = nil,
        hkWorkoutID: String? = nil,
        text: String,
        configName: String? = nil
    ) async -> Result<Void, PushError> {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var payload: [String: Any] = [
            "pacerunner_workout_id": paceRunnerID.uuidString,
            "started_at": iso.string(from: startTime),
            "log": text,
            "device": UIDevice.current.name,
        ]
        // Sending the end time lets the server correlate by interval overlap
        // when no explicit hk_workout_id is supplied.
        if let endTime = endTime {
            payload["ended_at"] = iso.string(from: endTime)
        }
        // When we already know which HK workout this log belongs to, name it
        // so the server attaches deterministically instead of guessing by time.
        if let hkWorkoutID = hkWorkoutID {
            payload["hk_workout_id"] = hkWorkoutID
        }
        if let configName = configName {
            payload["pacerunner_config_name"] = configName
        }
        return await post(path: "/ingest/pacerunner-log", body: payload, label: "pr-log")
    }

    private func post(path: String, body: [String: Any], label: String) async -> Result<Void, PushError> {
        guard isConfigured, let base = URL(string: serverURL) else {
            return .failure(.notConfigured)
        }
        guard let url = URL(string: path, relativeTo: base) else {
            return .failure(.notConfigured)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(ingestToken)", forHTTPHeaderField: "Authorization")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return .failure(.transport(error))
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .failure(.http(0, "non-HTTP response"))
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                print("[Publisher] \(label): \(http.statusCode)")
                return .failure(.unauthorized)
            }
            if !(200...299).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[Publisher] \(label): HTTP \(http.statusCode) \(body)")
                return .failure(.http(http.statusCode, body))
            }
            print("[Publisher] \(label): OK")
            return .success(())
        } catch {
            return .failure(.transport(error))
        }
    }

    // MARK: - State helpers

    @MainActor
    private func markPushed(_ id: String) {
        var set = pushedWorkoutIDs
        set.insert(id)
        pushedWorkoutIDs = set
        totalPushedCount += 1
    }

    @MainActor
    private func fail(_ message: String) {
        lastError = message
        status = .failed
    }

    @MainActor
    private func recomputeStatus() {
        if !isConfigured {
            status = .disabled
        } else if status == .disabled {
            status = .idle
        }
    }
}
