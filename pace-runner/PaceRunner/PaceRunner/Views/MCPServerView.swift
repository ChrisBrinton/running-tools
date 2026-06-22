import SwiftUI
import UIKit

/// Tab view for the in-app MCP server. Shows server state, the URL/pairing
/// code an MCP client needs to connect, and a live request log so you can
/// see the coach AI doing things.
@MainActor
struct MCPServerView: View {

    @ObservedObject var server: MCPServer = .shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusRow
                    if case .running = server.state {
                        urlRow
                        pairingCodeRow
                    }
                }

                if case .running = server.state {
                    Section("Configure your MCP client") {
                        Text("Add this to the client config (Claude Code, Cursor, etc.):")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        clientConfigBlock
                    }
                }

                Section("Available tools") {
                    toolRow(name: "list_workouts",
                            blurb: "Directory of HealthKit workouts with metadata.")
                    toolRow(name: "get_workout",
                            blurb: "Per-workout metadata, route GPX, samples, events, PR log.")
                    toolRow(name: "get_pacerunner_log",
                            blurb: "Verbose GPS debug log for a workout.")
                }

                Section("Recent requests") {
                    if server.requestLog.isEmpty {
                        Text("No requests yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(server.requestLog) { entry in
                            logRow(entry: entry)
                        }
                    }
                }

                Section {
                    actionButtons
                } footer: {
                    Text("The server runs only while this app is in the foreground. Switch away or lock the phone and it will pause; come back and start it again.")
                        .font(.caption)
                }
            }
            .navigationTitle("MCP Server")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private var statusRow: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .font(.title2)
            VStack(alignment: .leading) {
                Text(statusText)
                    .font(.headline)
                if case .failed(let msg) = server.state {
                    Text(msg).font(.caption).foregroundStyle(.red)
                } else if case .running = server.state {
                    Text("\(server.connectedClients) connected · port \(server.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var urlRow: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Endpoint URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("http://\(server.host):\(server.port)/mcp")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                UIPasteboard.general.string = "http://\(server.host):\(server.port)/mcp"
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
    }

    private var pairingCodeRow: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Bearer token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(server.pairingCode)
                    .font(.system(.title2, design: .monospaced))
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
            }
            Spacer()
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = server.pairingCode
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                Button {
                    server.regeneratePairingCode()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private var clientConfigBlock: some View {
        let url = "http://\(server.host):\(server.port)/mcp"
        let snippet = """
        {
          "mcpServers": {
            "pacerunner": {
              "type": "http",
              "url": "\(url)",
              "headers": { "Authorization": "Bearer \(server.pairingCode)" }
            }
          }
        }
        """
        return VStack(alignment: .leading) {
            Text(snippet)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            Button {
                UIPasteboard.general.string = snippet
            } label: {
                Label("Copy snippet", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func toolRow(name: String, blurb: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
            Text(blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func logRow(entry: MCPServer.LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.ok ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(entry.ok ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.detail)
                    .font(.system(.callout, design: .monospaced))
                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionButtons: some View {
        Group {
            switch server.state {
            case .stopped, .failed:
                Button {
                    server.start()
                } label: {
                    Label("Start Server", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            case .starting:
                HStack {
                    ProgressView()
                    Text("Starting…")
                }
            case .running:
                Button(role: .destructive) {
                    server.stop()
                } label: {
                    Label("Stop Server", systemImage: "stop.circle.fill")
                }
            }
        }
    }

    // MARK: - Status chrome

    private var statusIcon: String {
        switch server.state {
        case .stopped: return "antenna.radiowaves.left.and.right.slash"
        case .starting: return "antenna.radiowaves.left.and.right"
        case .running: return "antenna.radiowaves.left.and.right.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch server.state {
        case .stopped: return .secondary
        case .starting: return .blue
        case .running: return .green
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch server.state {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .failed: return "Failed"
        }
    }
}

#Preview {
    MCPServerView()
}
