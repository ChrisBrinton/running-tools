import SwiftUI
import PaceRunnerShared

struct SettingsView: View {
    let syncManager: SyncManagerProtocol
    @State private var settings = AppSettings.load()

    private var beatVolumeLabel: String {
        if settings.beatVolume <= 1.0 {
            return "\(Int(settings.beatVolume * 100))%"
        } else {
            return String(format: "%.1fx", settings.beatVolume)
        }
    }

    /// Dynamic explanation of what pace calibration does
    private var paceCalibrationExplanation: String {
        let calibration = settings.paceCalibrationSeconds
        if calibration == 0 {
            return "No adjustment applied"
        }
        // Example: If PaceRunner shows 9:45 but actual is 10:00, user adds +15s
        // The calibration makes reported pace slower (higher number)
        let exampleRawPace = 585 // 9:45 in seconds
        let adjustedSeconds = exampleRawPace + calibration
        let rawMin = exampleRawPace / 60
        let rawSec = exampleRawPace % 60
        let adjMin = adjustedSeconds / 60
        let adjSec = adjustedSeconds % 60
        return String(format: "%d:%02d/mi → %d:%02d/mi reported", rawMin, rawSec, adjMin, adjSec)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Audio")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Master Volume")
                            Spacer()
                            Text("\(Int(settings.masterVolume * 100))%")
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: $settings.masterVolume,
                            in: 0.0...1.0,
                            step: 0.05
                        )
                        .onChange(of: settings.masterVolume) { _, _ in
                            saveSettings()
                        }
                        Text("Controls voice alert volume")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Beat Volume")
                            Spacer()
                            Text(beatVolumeLabel)
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: $settings.beatVolume,
                            in: 0.0...30.0,
                            step: 1.0
                        )
                        .onChange(of: settings.beatVolume) { _, _ in
                            saveSettings()
                        }
                        Text("3=low, 10=medium, 30=high")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Toggle("Audio Beats Enabled", isOn: $settings.audioBeatsEnabled)
                        .onChange(of: settings.audioBeatsEnabled) { _, _ in
                            saveSettings()
                        }

                    Toggle("Emphasis Beat Enabled", isOn: $settings.emphasisBeatEnabled)
                        .onChange(of: settings.emphasisBeatEnabled) { _, _ in
                            saveSettings()
                        }

                    if settings.emphasisBeatEnabled {
                        Picker("Emphasis Interval", selection: $settings.emphasisBeatInterval) {
                            Text("Every 2nd beat").tag(2)
                            Text("Every 4th beat").tag(4)
                            Text("Every 8th beat").tag(8)
                        }
                        .onChange(of: settings.emphasisBeatInterval) { _, _ in
                            saveSettings()
                        }
                        Text("Plays accented beat on interval. Can use alone (metronome off) or with metronome.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Toggle("Voice Alerts Enabled", isOn: $settings.voiceAlertsEnabled)
                        .onChange(of: settings.voiceAlertsEnabled) { _, _ in
                            saveSettings()
                        }

                    Toggle("Announce Mile Markers", isOn: $settings.announceMileMarkers)
                        .onChange(of: settings.announceMileMarkers) { _, _ in
                            saveSettings()
                        }

                    Toggle("Adaptive Metronome Volume", isOn: $settings.adaptiveMetronomeVolume)
                        .onChange(of: settings.adaptiveMetronomeVolume) { _, _ in
                            saveSettings()
                        }

                    Picker("Voice Cue Interval", selection: $settings.alertThrottleInterval) {
                        Text("30 sec").tag(30)
                        Text("60 sec").tag(60)
                        Text("90 sec").tag(90)
                        Text("120 sec").tag(120)
                    }
                    .onChange(of: settings.alertThrottleInterval) { _, _ in
                        saveSettings()
                    }
                }

                Section(header: Text("Stride & Calibration")) {
                    Stepper(
                        "Stride Length: \(settings.strideLengthInches)\"",
                        value: $settings.strideLengthInches,
                        in: 20...50
                    )
                    .onChange(of: settings.strideLengthInches) { _, _ in
                        saveSettings()
                    }
                    Text("Base BPM at 10:00/mi = \(settings.calculateBaseBPM(for: Pace(minutes: 10, seconds: 0)))")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Stepper(
                        "Pace Calibration: \(settings.paceCalibrationSeconds > 0 ? "+" : "")\(settings.paceCalibrationSeconds)s",
                        value: $settings.paceCalibrationSeconds,
                        in: -15...15
                    )
                    .onChange(of: settings.paceCalibrationSeconds) { _, _ in
                        saveSettings()
                    }
                    Text(paceCalibrationExplanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Debug")) {
                    Toggle("GPS Filter Debug Sounds", isOn: $settings.gpsFilterDebugSounds)
                        .onChange(of: settings.gpsFilterDebugSounds) { _, _ in
                            saveSettings()
                        }
                    Text("Plays woodblock click when GPS points are filtered")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Workout Mode")) {
                    Toggle("Companion Mode", isOn: $settings.companionMode)
                        .onChange(of: settings.companionMode) { _, _ in
                            saveSettings()
                        }
                    Text("Run alongside native Workout app")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Use HealthKit Distance", isOn: $settings.useHealthKitDistance)
                        .onChange(of: settings.useHealthKitDistance) { _, _ in
                            saveSettings()
                        }
                    Text(settings.companionMode
                        ? "Query distance samples from Workout app"
                        : "Match Apple Workout app distance (recommended)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Pace Averaging")) {
                    Picker("Fast Average", selection: $settings.fastAverageSeconds) {
                        Text("60s (1 min)").tag(60)
                        Text("90s (1.5 min)").tag(90)
                        Text("120s (2 min)").tag(120)
                        Text("150s (2.5 min)").tag(150)
                    }
                    .onChange(of: settings.fastAverageSeconds) { _, _ in
                        saveSettings()
                    }

                    Picker("Medium Average", selection: $settings.mediumAverageSeconds) {
                        Text("180s (3 min)").tag(180)
                        Text("210s (3.5 min)").tag(210)
                        Text("240s (4 min)").tag(240)
                        Text("270s (4.5 min)").tag(270)
                        Text("300s (5 min)").tag(300)
                    }
                    .onChange(of: settings.mediumAverageSeconds) { _, _ in
                        saveSettings()
                    }

                    Picker("Slow Average (Master)", selection: $settings.slowAverageMiles) {
                        Text("0.5 mi").tag(0.5)
                        Text("1.0 mi").tag(1.0)
                        Text("1.5 mi").tag(1.5)
                        Text("2.0 mi").tag(2.0)
                        Text("2.5 mi").tag(2.5)
                        Text("3.0 mi").tag(3.0)
                    }
                    .onChange(of: settings.slowAverageMiles) { _, _ in
                        saveSettings()
                    }

                    Text("Slow is the master pace for voice cues")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Display")) {
                    Toggle("Use Metric Units", isOn: $settings.useMetricUnits)
                        .onChange(of: settings.useMetricUnits) { _, _ in
                            saveSettings()
                        }

                    Toggle("Show Pace Deviation", isOn: $settings.showPaceDeviation)
                        .onChange(of: settings.showPaceDeviation) { _, _ in
                            saveSettings()
                        }
                }

                Section(header: Text("Defaults for New Configurations")) {
                    Stepper(
                        "Default Tolerance: \(settings.defaultTolerance)s",
                        value: $settings.defaultTolerance,
                        in: 1...60
                    )
                    .onChange(of: settings.defaultTolerance) { _, _ in
                        saveSettings()
                    }
                }

                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    /// App version and build number
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func saveSettings() {
        settings.save()
        syncManager.syncSettings(settings)
    }
}

#Preview {
    SettingsView(syncManager: SyncManager())
}
