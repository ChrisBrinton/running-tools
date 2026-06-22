import SwiftUI
import UIKit
import PaceRunnerShared

/// Settings sub-view for the always-on home server publisher. Lives behind a
/// `NavigationLink` from the main Settings screen so the row footprint there
/// stays small.
///
/// Flow:
///   - User pastes the server URL once and the ingest token once.
///   - Auto-publish kicks in for every subsequent workout end + foreground.
///   - Manual Publish All button backfills the last N days.
@MainActor
struct PublisherSettingsView: View {
    @ObservedObject var publisher: HealthKitPublisher = .shared
    @ObservedObject var registration: PublisherRegistration = .shared

    @State private var urlText: String = ""
    @State private var showingResetConfirm = false
    @State private var backfillDays: Int = 90
    @State private var lastBackfillSummary: String?

    // Coach token UI state.
    @State private var coachTokenLabel: String = "Claude Code"
    @State private var generatedCoachToken: String?
    @State private var isGeneratingToken = false
    @State private var coachTokenError: String?
    @State private var showingAdvanced = false

    var body: some View {
        Form {
            Section("Server") {
                TextField("https://pacerunner.example.com", text: $urlText)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onChange(of: urlText) { _, newValue in
                        publisher.serverURL = newValue.trimmingCharacters(in: .whitespaces)
                    }

                registerRow
                statusRow
            }

            Section("Backfill") {
                Picker("Look back", selection: $backfillDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                .pickerStyle(.menu)

                Button {
                    Task {
                        let r = await publisher.publishAll(daysBack: backfillDays)
                        lastBackfillSummary =
                            "\(r.succeeded) pushed, \(r.failed) failed, \(r.skipped) already on server"
                    }
                } label: {
                    HStack {
                        if case .pushing(let text) = publisher.status {
                            ProgressView()
                            Text(text)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("Publish All Pending")
                        }
                    }
                }
                .disabled(!publisher.isConfigured || isPushing)

                if let summary = lastBackfillSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            coachAccessSection

            Section {
                Button(role: .destructive) {
                    showingResetConfirm = true
                } label: {
                    Label("Reset push history", systemImage: "arrow.counterclockwise")
                }
                .disabled(isPushing)
            } header: {
                Text("Maintenance")
            } footer: {
                Text("Clears the local record of which workouts have been pushed. The next sync will re-evaluate everything in the backfill window (server upserts by UUID, so this is safe — nothing gets duplicated).")
            }
        }
        .navigationTitle("Home Server")
        .onAppear {
            urlText = publisher.serverURL
        }
        .alert("Reset push history?", isPresented: $showingResetConfirm) {
            Button("Reset", role: .destructive) {
                publisher.resetPushedHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Re-evaluates which workouts to push. Server deduplicates by UUID, so this won't create duplicate entries — it just lets you re-run the backfill from scratch.")
        }
    }

    // MARK: - Registration row

    @ViewBuilder
    private var registerRow: some View {
        let canRegister = !urlText.isEmpty && URL(string: urlText) != nil && !isRegistering
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: registrationIcon)
                    .foregroundStyle(registrationColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(registrationStatusText)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Install ID: \(registration.installID.prefix(8))…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }

            if let err = registration.lastError, registration.state == .failed {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                Button {
                    guard let base = URL(string: urlText) else { return }
                    Task { await registration.registerForce(serverBaseURL: base) }
                } label: {
                    if isRegistering {
                        HStack {
                            ProgressView()
                            Text("Registering…")
                        }
                    } else {
                        Label(registration.state == .registered ? "Re-register" : "Register this device",
                              systemImage: "iphone.gen3.radiowaves.left.and.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRegister)
            }
        }
    }

    private var isRegistering: Bool {
        if case .registering = registration.state { return true }
        return false
    }

    private var registrationIcon: String {
        switch registration.state {
        case .registered: return "checkmark.shield"
        case .registering: return "shield"
        case .unavailable: return "exclamationmark.shield"
        case .failed: return "xmark.shield"
        case .idle: return "shield"
        }
    }

    private var registrationColor: Color {
        switch registration.state {
        case .registered: return .green
        case .registering, .idle: return .blue
        case .unavailable: return .orange
        case .failed: return .red
        }
    }

    private var registrationStatusText: String {
        switch registration.state {
        case .registered: return "Registered with server"
        case .registering(let s): return s
        case .unavailable: return "App Attest unavailable (simulator?)"
        case .failed: return "Registration failed"
        case .idle:
            return publisher.ingestToken.isEmpty
                ? "Not registered"
                : "Token present (legacy / manual)"
        }
    }

    // MARK: - Coach access

    /// Section that mints + displays an MCP-scoped token for an AI chat
    /// session. Visible only when the device is registered (we need a
    /// valid ingest token to call /ingest/tokens).
    @ViewBuilder
    private var coachAccessSection: some View {
        if publisher.isConfigured && registration.state == .registered {
            Section {
                Text("Generate a token for an AI chat session (Claude Code, running coach, etc.) to read your workout data over MCP. The token is shown once — copy or share it immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Label (e.g. 'running coach')", text: $coachTokenLabel)
                    .disableAutocorrection(true)
                    .autocapitalization(.words)

                Button {
                    Task { await generateCoachToken() }
                } label: {
                    HStack {
                        if isGeneratingToken {
                            ProgressView()
                            Text("Generating…")
                        } else {
                            Label("Generate coach token", systemImage: "key.horizontal.fill")
                        }
                    }
                }
                .disabled(isGeneratingToken || coachTokenLabel.trimmingCharacters(in: .whitespaces).isEmpty)

                if let err = coachTokenError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let token = generatedCoachToken {
                    coachTokenDisplay(token)
                }
            } header: {
                Text("Coach access")
            } footer: {
                Text("Tokens only grant read access (cannot push or modify data). Tokens you no longer need can be revoked via the admin CLI on the server.")
            }
        }
    }

    /// Token-just-issued display: token in monospace + Copy + Share + Dismiss.
    @ViewBuilder
    private func coachTokenDisplay(_ token: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("New token (save it now)", systemImage: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.caption.weight(.semibold))

            Text(token)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = token
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                ShareLink(item: clientConfigSnippet(token: token)) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Dismiss") {
                    generatedCoachToken = nil
                }
                .buttonStyle(.borderless)
            }

            // Always-visible ready-to-paste config block so the user can
            // see what they're sharing before they tap Share.
            Text("MCP client config:")
                .font(.caption.weight(.semibold))
                .padding(.top, 4)
            Text(clientConfigSnippet(token: token))
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func clientConfigSnippet(token: String) -> String {
        let url = publisher.serverURL.trimmingCharacters(in: .whitespaces)
        let mcpURL = url.hasSuffix("/") ? "\(url)mcp" : "\(url)/mcp"
        return """
        {
          "mcpServers": {
            "pacerunner": {
              "type": "http",
              "url": "\(mcpURL)",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    private func generateCoachToken() async {
        coachTokenError = nil
        isGeneratingToken = true
        defer { isGeneratingToken = false }
        do {
            let label = coachTokenLabel.trimmingCharacters(in: .whitespaces)
            let token = try await publisher.createMCPToken(label: label)
            generatedCoachToken = token
        } catch {
            coachTokenError = error.localizedDescription
        }
    }

    // MARK: - Status row

    private var isPushing: Bool {
        if case .pushing = publisher.status { return true }
        return false
    }

    @ViewBuilder
    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(statusText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if publisher.totalPushedCount > 0 {
                    Text("\(publisher.totalPushedCount) pushed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let when = publisher.lastSuccessfulPush {
                Text("Last success \(when.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let err = publisher.lastError, publisher.status != .ok {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var statusIcon: String {
        switch publisher.status {
        case .idle:     return "cloud"
        case .pushing:  return "cloud.bolt"
        case .ok:       return "checkmark.icloud"
        case .failed:   return "exclamationmark.icloud"
        case .disabled: return "icloud.slash"
        }
    }

    private var statusColor: Color {
        switch publisher.status {
        case .idle, .pushing: return .blue
        case .ok:             return .green
        case .failed:         return .red
        case .disabled:       return .secondary
        }
    }

    private var statusText: String {
        switch publisher.status {
        case .idle:                   return "Idle"
        case .pushing(let detail):    return detail
        case .ok:                     return "Up to date"
        case .failed:                 return "Last push failed"
        case .disabled:               return "Not configured"
        }
    }
}

#Preview {
    NavigationStack {
        PublisherSettingsView()
    }
}
