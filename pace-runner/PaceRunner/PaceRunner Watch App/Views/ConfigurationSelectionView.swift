import SwiftUI
import PaceRunnerShared

struct ConfigurationSelectionView: View {
    @ObservedObject var store: ConfigurationStore
    @State private var showingVolumeTest = false
    @State private var settings = AppSettings.load()

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
        return "Stride: \(settings.strideLengthInches)\""
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
                    store.select(config)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(config.name)
                            .font(.headline)
                        Text(String(format: "%.1f miles • Target %@", config.distance.miles, config.milePaces.first?.formatted ?? "--:--"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            }
        }
        .navigationTitle("Workouts")
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
