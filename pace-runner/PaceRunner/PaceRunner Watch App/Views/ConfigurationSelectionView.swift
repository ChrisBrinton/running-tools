import SwiftUI
import PaceRunnerShared

struct ConfigurationSelectionView: View {
    @ObservedObject var store: ConfigurationStore
    @ObservedObject var workoutStore: WatchWorkoutStore
    let syncManager: SyncManagerProtocol
    @EnvironmentObject var entitlementManager: EntitlementManager
    @State private var showingVolumeTest = false
    @State private var showingProAlert = false
    @State private var settings = AppSettings.load()
    @State private var syncResult: String?
    @State private var syncResultColor: Color = .green

    /// Publisher for settings sync notification
    private let settingsSyncedPublisher = NotificationCenter.default.publisher(for: .settingsSynced)

    /// Format calibration info for display
    private var calibrationInfo: String {
        let cal = settings.paceCalibrationSeconds
        let factor = settings.distanceCalibrationFactor()
        let sign = cal >= 0 ? "+" : ""
        return "Pace: \(sign)\(cal)s (×\(String(format: "%.3f", factor)))"
    }

    private var strideInfo: String {
        return "Stride: \(String(format: "%.1f", settings.strideLengthInches))\""
    }

    /// App version and build number
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    var body: some View {
        List {
            ForEach(store.configurations, id: \.id) { config in
                Button {
                    if config.requiresPro && !entitlementManager.isPro {
                        showingProAlert = true
                    } else {
                        store.select(config)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(config.name)
                                .font(.headline)
                            Text(String(format: "%.1f miles • Target %@", config.distance.miles, config.milePaces.first?.formatted ?? "--:--"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if config.requiresPro && !entitlementManager.isPro {
                            Spacer()
                            Image(systemName: "crown.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                        }
                    }
                }
            }

            // Debug tests
            Section(header: Text("Debug")) {
                // Version info
                HStack {
                    Text("Version")
                        .font(.caption)
                    Spacer()
                    Text(appVersion)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                // Settings info (shows what watch has loaded)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loaded Settings")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(calibrationInfo)
                        .font(.system(.caption, design: .monospaced))
                    Text(strideInfo)
                        .font(.system(.caption, design: .monospaced))
                }
                .onAppear {
                    // Reload settings when view appears
                    settings = AppSettings.load()
                }

                NavigationLink(destination: VolumeTestView()) {
                    HStack {
                        Image(systemName: "speaker.wave.3")
                            .foregroundColor(.orange)
                        Text("Volume Test")
                    }
                }
                NavigationLink(destination: BeatPatternTestView()) {
                    HStack {
                        Image(systemName: "metronome")
                            .foregroundColor(.blue)
                        Text("Beat Pattern Test")
                    }
                }

                // Sync status and force sync
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Workouts")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(workoutStore.summaries.count) stored, \(workoutStore.unsyncedSummaries.count) unsynced")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    if let result = syncResult {
                        Text(result)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(syncResultColor)
                    }
                }

                Button {
                    // Request configs + settings from phone
                    let reachable = syncManager.requestAllData()

                    // Also push workouts to phone
                    let result = workoutStore.forceSync()

                    if reachable {
                        if result.total > 0 {
                            syncResult = "Syncing: sent \(result.sent)/\(result.total) workouts"
                        } else {
                            syncResult = "Requested configs & settings"
                        }
                        syncResultColor = .green
                    } else {
                        syncResult = "Queued (phone not active)"
                        syncResultColor = .orange
                    }
                    // Clear after delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        syncResult = nil
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.cyan)
                        Text("Force Sync")
                    }
                }
                // Last debug log — cheap existence check only; tail-loaded lazily in destination
                if DebugLogStore.shared.lastWorkoutID != nil {
                    NavigationLink {
                        LastDebugLogView()
                    } label: {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundColor(.orange)
                            Text("Last Debug Log")
                        }
                    }
                }
            }
        }
        .navigationTitle("Workouts")
        .alert("Pro Feature", isPresented: $showingProAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This configuration requires PaceRunner Pro. Upgrade on your iPhone.")
        }
        .onReceive(settingsSyncedPublisher) { notification in
            // Reload settings when synced from phone
            if let syncedSettings = notification.object as? AppSettings {
                settings = syncedSettings
                print("ConfigurationSelectionView: Settings synced - cal=\(syncedSettings.paceCalibrationSeconds)")
            } else {
                // Fallback: reload from UserDefaults
                settings = AppSettings.load()
            }
        }
    }
}

/// Lazy-loaded preview of the most recent debug log.
///
/// Verbose-GPS logs can exceed 1–2 MB, which the watch cannot render in a
/// single SwiftUI `Text`. We load only the **tail** (last ~24 KB) on appear
/// so the parent view is cheap to construct and scene restoration cannot
/// trap the app in a memory-blowing destination.
private struct LastDebugLogView: View {
    private static let maxTailBytes = 24 * 1024
    @State private var tail: String?
    @State private var totalBytes: Int = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if totalBytes > Self.maxTailBytes {
                    Text("Showing last \(Self.maxTailBytes / 1024) KB of \(totalBytes / 1024) KB. Full log is on iPhone.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let tail {
                    Text(tail)
                        .font(.system(.caption2, design: .monospaced))
                } else {
                    Text("Loading…")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(4)
        }
        .navigationTitle("Debug Log")
        .onAppear {
            guard let id = DebugLogStore.shared.lastWorkoutID else { return }
            totalBytes = DebugLogStore.shared.fileSize(for: id) ?? 0
            tail = DebugLogStore.shared.loadTail(for: id, maxBytes: Self.maxTailBytes)
        }
    }
}
