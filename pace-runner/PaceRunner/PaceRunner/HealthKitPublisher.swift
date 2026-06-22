import Foundation
import HealthKit
import Combine
import UIKit
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

    // MARK: - High-level operations

    /// Manual button. Looks back `daysBack` days for any HK workout that
    /// isn't already in `pushedWorkoutIDs` and pushes it. Returns
    /// (success_count, failure_count, skipped_count).
    @discardableResult
    func publishAll(daysBack: Int = 90) async -> (succeeded: Int, failed: Int, skipped: Int) {
        guard isConfigured else { return (0, 0, 0) }
        let exporter = HealthKitExporter.shared
        do {
            try await exporter.requestAuthorization()
        } catch {
            await MainActor.run { self.fail("HealthKit auth failed: \(error.localizedDescription)") }
            return (0, 0, 0)
        }

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
        guard !pending.isEmpty else {
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
            case .failure(let err):
                fail += 1
                await MainActor.run { self.lastError = err.localizedDescription }
                // Stop early on auth failures — every subsequent call will
                // also 401 and there's no point hammering.
                if case .unauthorized = err { break }
            }
        }

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
    private func publishPendingWorkouts(daysBack: Int) async {
        _ = await publishAll(daysBack: daysBack)
    }

    /// Push the PR verbose log for a just-completed workout, plus try to
    /// resolve+push the HK workout once it's available.
    private func handleSummaryReady(_ summary: WorkoutSummary) async {
        guard isConfigured else { return }

        // Push the verbose log first — we always have the PR UUID. Time
        // attachment to the HK workout happens server-side via the
        // start-time window matcher.
        if let log = DebugLogStore.shared.load(for: summary.id) {
            _ = await pushPaceRunnerLog(
                paceRunnerID: summary.id,
                startTime: summary.startTime,
                text: log
            )
        }

        // The HK workout may not be on this phone yet — Apple syncs HK
        // workouts from the watch on its own schedule. Schedule a retry
        // in 30s; the foreground hook will pick it up after that.
        Task {
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            await publishPendingWorkouts(daysBack: 7)
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

    /// Build the payload for an HK workout, post it, mark as pushed on success.
    private func pushOneWorkout(_ workout: HKWorkout) async -> Result<Void, PushError> {
        let exporter = HealthKitExporter.shared
        let payload = await exporter.buildWorkoutPayload(for: workout)
        return await post(path: "/ingest/workout", body: payload, label: "workout \(workout.uuid.uuidString)")
    }

    private func pushPaceRunnerLog(
        paceRunnerID: UUID,
        startTime: Date,
        text: String
    ) async -> Result<Void, PushError> {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let payload: [String: Any] = [
            "pacerunner_workout_id": paceRunnerID.uuidString,
            "started_at": iso.string(from: startTime),
            "log": text,
            "device": UIDevice.current.name,
        ]
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
