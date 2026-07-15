import SwiftUI
import Combine
import PaceRunnerShared

/// Observes the SyncManager's tri-domain snapshot and republishes it for SwiftUI.
@MainActor
final class WatchSyncStatusModel: ObservableObject {
    @Published private(set) var snapshot = WatchSyncSnapshot()
    private let syncManager: SyncManagerProtocol
    private var cancellable: AnyCancellable?

    init(syncManager: SyncManagerProtocol) {
        self.syncManager = syncManager
        cancellable = syncManager.syncSnapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.snapshot = snapshot
            }
    }

    func forceResync() {
        syncManager.forceFullResync()
    }
}

/// Compact watch-sync status indicator: an applewatch-family SF Symbol plus a
/// short label. Tapping forces a full resync across configs, settings, and history.
struct WatchSyncStatusView: View {
    @ObservedObject var model: WatchSyncStatusModel

    var body: some View {
        Button {
            model.forceResync()
        } label: {
            HStack(spacing: 6) {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                }
                Image(systemName: symbolName)
                    .foregroundStyle(tint)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var s: WatchSyncSnapshot { model.snapshot }

    private var showsProgress: Bool {
        s.connection == .reachable && s.isSyncing
    }

    private var symbolName: String {
        if s.lastError != nil { return "exclamationmark.applewatch" }
        switch s.connection {
        case .noWatch: return "applewatch.slash"
        case .notReachable: return "applewatch"
        case .reachable:
            if s.isSyncing { return "applewatch" }
            return s.isFullySynced ? "checkmark.applewatch" : "applewatch"
        }
    }

    private var tint: Color {
        if s.lastError != nil { return .red }
        switch s.connection {
        case .noWatch, .notReachable: return .gray
        case .reachable:
            if s.isSyncing { return .blue }
            return s.isFullySynced ? .green : .orange
        }
    }

    private var label: String {
        if s.lastError != nil { return "Sync failed" }
        switch s.connection {
        case .noWatch: return "No Apple Watch"
        case .notReachable: return "Watch not connected"
        case .reachable:
            if s.isSyncing { return "Syncing…" }
            if s.isFullySynced { return "Synced" }
            return pendingLabel
        }
    }

    private var pendingLabel: String {
        var domains: [String] = []
        if !s.configsSynced { domains.append("configs") }
        if !s.settingsSynced { domains.append("settings") }
        if !s.historySynced { domains.append("history") }
        if domains.isEmpty { return "Sync pending" }
        return "Sync pending (\(domains.joined(separator: ", ")))"
    }
}
