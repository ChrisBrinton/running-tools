import Foundation
import Combine
import CryptoKit
import DeviceCheck
import UIKit

/// Self-service device registration with pacerunner-server using Apple's
/// App Attest. The flow:
///
///   1. On first run we mint a stable `installID` (a UUID stored in
///      UserDefaults — survives launches, dies on uninstall).
///   2. Call `POST /register/challenge { install_id }` and receive a nonce.
///   3. `DCAppAttestService.generateKey()` — secure-enclave-backed key,
///      identified by an opaque `key_id` string.
///   4. `DCAppAttestService.attestKey(keyId, clientDataHash: SHA256(challenge))`
///      returns a CBOR-encoded attestation blob. Apple signs it with its
///      App Attest root chain; anyone outside Apple cannot forge.
///   5. `POST /register/attest { install_id, key_id, challenge, attestation }`
///      — server verifies the chain + nonce, mints a user + ingest token,
///      returns both.
///   6. Token is stashed in UserDefaults (HealthKitPublisher reads it).
///
/// Re-registration is idempotent on the server side. Calling register twice
/// from the same install_id returns the same token. The phone never has to
/// remember whether it's already registered; it can just call register on
/// first launch and on every "I lost my token, retry" UI affordance.
@MainActor
final class PublisherRegistration: ObservableObject {

    static let shared = PublisherRegistration()

    @Published private(set) var state: State = .idle
    @Published private(set) var lastError: String?

    enum State: Equatable {
        case idle
        case unavailable           // simulator, jailbreak, or App Attest disabled
        case registering(String)   // step label
        case registered            // last register succeeded
        case failed                // see lastError
    }

    private let installIDKey = "publisher_install_id"

    /// Stable UUID identifying this install. Generated once and persisted in
    /// UserDefaults — reinstalling the app yields a new install_id (and
    /// therefore a new user_id on the server, by design).
    var installID: String {
        if let existing = UserDefaults.standard.string(forKey: installIDKey) {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: installIDKey)
        return fresh
    }

    private init() {
        // Restore registration state on launch. The presence of an ingest
        // token in UserDefaults means the device successfully registered
        // in a prior session; without this, the UI would default to .idle
        // on every cold start and show "Register this device" even though
        // the publisher has been auto-syncing the whole time.
        if !HealthKitPublisher.shared.ingestToken.isEmpty {
            state = .registered
        }
    }

    /// Deregister this device and delete all of its data from the server.
    ///
    /// Calls `DELETE /ingest/device` (cascades the user row and removes
    /// per-user files on disk), then wipes local state:
    ///   - ingest token (publisher.ingestToken)
    ///   - install_id (next register mints a fresh user_id)
    ///   - pushed-history (so a fresh register re-publishes from scratch)
    ///
    /// HealthKit data on the phone is untouched — only the server copy
    /// is removed. The user can re-register immediately after this if
    /// they want to start over.
    func deregister() async throws {
        try await HealthKitPublisher.shared.deleteAccountOnServer()
        // Local wipe — order matters: clear token + history first, then
        // install_id last, so any in-flight state-derived UI sees the
        // cleared token before installID flips.
        HealthKitPublisher.shared.wipeLocalCredentials()
        UserDefaults.standard.removeObject(forKey: installIDKey)
        UserDefaults.standard.removeObject(forKey: "publisher_user_id")
        state = .idle
        lastError = nil
    }

    /// Perform the full register-or-recover handshake. On success the
    /// HealthKitPublisher's serverURL + ingestToken are populated and
    /// `state == .registered`.
    func registerIfNeeded(serverBaseURL: URL) async {
        // Already have a token? Nothing to do — the server's /register/attest
        // is idempotent, but we avoid the round-trip when we don't need it.
        let publisher = HealthKitPublisher.shared
        publisher.serverURL = serverBaseURL.absoluteString
        if !publisher.ingestToken.isEmpty {
            state = .registered
            return
        }

        await registerForce(serverBaseURL: serverBaseURL)
    }

    /// Bound to a "Register this device" UI button. Always hits the server,
    /// useful for re-trying after a failure.
    func registerForce(serverBaseURL: URL) async {
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            state = .unavailable
            lastError = "App Attest is not available on this device (simulator or unsupported iOS version)."
            return
        }

        do {
            state = .registering("Requesting challenge…")
            let challenge = try await requestChallenge(installID: installID, base: serverBaseURL)

            state = .registering("Generating attestation key…")
            let keyId: String = try await withCheckedThrowingContinuation { cont in
                service.generateKey { keyId, error in
                    if let error = error { cont.resume(throwing: error); return }
                    cont.resume(returning: keyId ?? "")
                }
            }
            guard !keyId.isEmpty else {
                throw RegistrationError("App Attest returned an empty key id")
            }

            state = .registering("Attesting with Apple…")
            // The server hashes the same challenge string to compute its
            // expected nonce. We send the raw challenge bytes; Apple hashes
            // them as clientDataHash inside the attestation. The server
            // recomputes SHA256(challenge) and compares against the nonce
            // extension Apple wrote into the leaf cert.
            let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))
            let attestation: Data = try await withCheckedThrowingContinuation { cont in
                service.attestKey(keyId, clientDataHash: clientDataHash) { data, error in
                    if let error = error { cont.resume(throwing: error); return }
                    cont.resume(returning: data ?? Data())
                }
            }
            guard !attestation.isEmpty else {
                throw RegistrationError("App Attest returned empty attestation")
            }

            state = .registering("Sending to server…")
            let result = try await postAttestation(
                installID: installID,
                keyId: keyId,
                challenge: challenge,
                attestation: attestation,
                base: serverBaseURL
            )

            // Persist into the existing HealthKitPublisher knobs so the rest
            // of the app uses the same paths.
            publisher: do {
                let publisher = HealthKitPublisher.shared
                publisher.serverURL = serverBaseURL.absoluteString
                publisher.ingestToken = result.ingestToken
            }
            UserDefaults.standard.set(result.userID, forKey: "publisher_user_id")
            state = .registered
            lastError = nil
            print("[Registration] success: user_id=\(result.userID) (\(result.alreadyRegistered ? "existing" : "new"))")

        } catch {
            state = .failed
            lastError = error.localizedDescription
            print("[Registration] failed: \(error)")
        }
    }

    // MARK: - Network calls

    private struct ChallengeResponse: Decodable {
        let challenge: String
    }

    private func requestChallenge(installID: String, base: URL) async throws -> String {
        let body: [String: Any] = ["install_id": installID]
        let resp: ChallengeResponse = try await postJSON(
            url: base.appendingPathComponent("register/challenge"),
            body: body
        )
        return resp.challenge
    }

    private struct AttestResponse: Decodable {
        let user_id: Int
        let ingest_token: String
        let already_registered: Bool?
    }

    struct RegisterResult {
        let userID: Int
        let ingestToken: String
        let alreadyRegistered: Bool
    }

    private func postAttestation(
        installID: String,
        keyId: String,
        challenge: String,
        attestation: Data,
        base: URL
    ) async throws -> RegisterResult {
        let body: [String: Any] = [
            "install_id": installID,
            "key_id": keyId,                                            // already base64 from App Attest
            "challenge": challenge,
            "attestation": attestation.base64EncodedString(),
            "display_name": UIDevice.current.name,
        ]
        let resp: AttestResponse = try await postJSON(
            url: base.appendingPathComponent("register/attest"),
            body: body
        )
        return RegisterResult(
            userID: resp.user_id,
            ingestToken: resp.ingest_token,
            alreadyRegistered: resp.already_registered ?? false
        )
    }

    // MARK: - Tiny JSON helper

    private func postJSON<T: Decodable>(url: URL, body: [String: Any]) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw RegistrationError("Non-HTTP response from \(url.path)")
        }
        if !(200...299).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw RegistrationError("HTTP \(http.statusCode) from \(url.path): \(bodyText)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

struct RegistrationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
