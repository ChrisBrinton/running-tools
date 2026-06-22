import SwiftUI
import HealthKit
import PaceRunnerShared

struct SettingsView: View {
    let syncManager: SyncManagerProtocol
    var configurationStore: ConfigurationStore?
    var historyStore: WorkoutHistoryStore?
    @EnvironmentObject var entitlementManager: EntitlementManager
    @State private var settings = AppSettings.load()
    @State private var showingProUpgrade = false
    @State private var showingAddDistance = false
    @State private var newDistanceText = ""
    @State private var showingAddPace = false
    @State private var editingPace: NamedPace?
    @State private var paceSheetName = ""
    @State private var paceSheetMinutes = 8
    @State private var paceSheetSeconds = 0
    @State private var showingResetConfirmation = false
    @State private var debugExportItem: DebugExportItem?
    @State private var mapExportItem: MapExportItem?

    // Multi-step async flow for "Export Debug Data":
    //   isExportLoading   → progress overlay while we query HealthKit
    //   pickerWorkouts    → non-nil triggers the multi-select sheet
    //   bundleURL         → non-nil triggers the share sheet for the zip
    //   exportErrorText   → non-nil shows an alert
    @State private var isExportLoading = false
    @State private var pickerWorkouts: [HKWorkout]?
    @State private var bundleURL: URL?
    @State private var exportErrorText: String?

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
                Section(header: Text("PaceRunner Pro")) {
                    if entitlementManager.isPro {
                        HStack {
                            Image(systemName: "crown.fill")
                                .foregroundStyle(.yellow)
                            Text("Pro Unlocked")
                                .fontWeight(.medium)
                        }
                    } else {
                        Button {
                            showingProUpgrade = true
                        } label: {
                            HStack {
                                Image(systemName: "crown")
                                    .foregroundStyle(.yellow)
                                Text("Upgrade to Pro")
                            }
                        }

                        Button {
                            Task { await entitlementManager.restorePurchases() }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Restore Purchase")
                            }
                        }
                        .disabled(entitlementManager.purchaseState == .restoring)
                    }
                }

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
                        "Stride Length: \(String(format: "%.1f", settings.strideLengthInches))\"",
                        value: $settings.strideLengthInches,
                        in: 20.0...50.0,
                        step: 0.5
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
                    Toggle("Pro Override", isOn: Binding(
                        get: { entitlementManager.isPro },
                        set: { newValue in
                            entitlementManager.debugSetPro(newValue)
                            settings.debugProOverride = newValue
                            saveSettings()
                        }
                    ))
                    Text("Override Pro status for testing (syncs to Watch)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("GPS Filter Debug Sounds", isOn: $settings.gpsFilterDebugSounds)
                        .onChange(of: settings.gpsFilterDebugSounds) { _, _ in
                            saveSettings()
                        }
                    Text("Plays woodblock click when GPS points are filtered")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Verbose GPS Logging", isOn: $settings.verboseGPSLogging)
                        .onChange(of: settings.verboseGPSLogging) { _, _ in
                            saveSettings()
                        }
                    Text("Logs every GPS sample (lat/lng/speed/course/delta/alt/baro). Auto-marks turns ≥60°. When on, all distance methods run in parallel and each is logged per sample. Heavy — use only for diagnostics.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Distance Method", selection: $settings.distanceCalcMethod) {
                        ForEach(DistanceCalcMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .onChange(of: settings.distanceCalcMethod) { _, _ in
                        saveSettings()
                    }
                    Text("Algorithm that drives workout total distance. 'Speed Floor' uses max(chord, GPS speed × dt) — helps with corner-cutting at sharp turns.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button {
                        startExportFlow()
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            if isExportLoading {
                                Text("Preparing…")
                                ProgressView()
                                    .padding(.leading, 4)
                            } else {
                                Text("Export Debug Data")
                            }
                        }
                    }
                    .disabled(isExportLoading)
                    Text("Exports settings, configs, last workout log, plus any selected Apple Health workouts (route GPX + metrics) as a single zip.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button {
                        if let url = generateMapHTML() {
                            mapExportItem = MapExportItem(url: url)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "map")
                            Text("Export Run Map")
                        }
                    }
                    .disabled(WorkoutManager.loadLastDebugLog() == nil)
                    Text("Renders the last workout's GPS path to an HTML map, colored by pace. Requires verbose GPS logging to have been on.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(role: .destructive) {
                        showingResetConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Reset All Data")
                        }
                        .foregroundStyle(.red)
                    }
                    Text("Clears all configs, history, and settings on iPhone and Watch")
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

                Section(header: Text("Quick Distances")) {
                    ForEach(Array(settings.commonDistances.enumerated()), id: \.offset) { index, distance in
                        HStack {
                            Text(formatQuickDistance(distance))
                            Spacer()
                            Button(role: .destructive) {
                                settings.commonDistances.remove(at: index)
                                saveSettings()
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onMove { source, destination in
                        settings.commonDistances.move(fromOffsets: source, toOffset: destination)
                        saveSettings()
                    }

                    Button {
                        newDistanceText = ""
                        showingAddDistance = true
                    } label: {
                        Label("Add Distance", systemImage: "plus.circle.fill")
                    }
                }
                .environment(\.editMode, .constant(.active))

                Section(header: Text("Quick Paces")) {
                    ForEach(settings.namedPaces) { namedPace in
                        HStack {
                            Button {
                                editingPace = namedPace
                                paceSheetName = namedPace.name
                                paceSheetMinutes = namedPace.pace.minutes
                                paceSheetSeconds = namedPace.pace.seconds
                                showingAddPace = true
                            } label: {
                                HStack {
                                    Text(namedPace.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(namedPace.pace.formatted)/mi")
                                        .foregroundColor(.secondary)
                                }
                            }
                            Button(role: .destructive) {
                                if let idx = settings.namedPaces.firstIndex(where: { $0.id == namedPace.id }) {
                                    settings.namedPaces.remove(at: idx)
                                    saveSettings()
                                }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onMove { source, destination in
                        settings.namedPaces.move(fromOffsets: source, toOffset: destination)
                        saveSettings()
                    }

                    Button {
                        editingPace = nil
                        paceSheetName = ""
                        paceSheetMinutes = 9
                        paceSheetSeconds = 0
                        showingAddPace = true
                    } label: {
                        Label("Add Pace", systemImage: "plus.circle.fill")
                    }
                }
                .environment(\.editMode, .constant(.active))

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
            .sheet(isPresented: $showingProUpgrade) {
                ProUpgradeSheet()
            }
            .alert("Add Distance", isPresented: $showingAddDistance) {
                TextField("Miles", text: $newDistanceText)
                    .keyboardType(.decimalPad)
                Button("Add") {
                    if let miles = Double(newDistanceText), miles > 0 {
                        settings.commonDistances.append(miles)
                        saveSettings()
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Enter distance in miles")
            }
            .sheet(isPresented: $showingAddPace) {
                paceEditSheet
            }
            .sheet(item: $debugExportItem) { item in
                ShareSheet(text: item.text)
            }
            .sheet(item: $mapExportItem) { item in
                FileShareSheet(url: item.url)
            }
            .sheet(item: Binding(
                get: { pickerWorkouts.map { WorkoutPickerItem(workouts: $0) } },
                set: { newValue in pickerWorkouts = newValue?.workouts }
            )) { item in
                WorkoutExportPicker(
                    workouts: item.workouts,
                    onConfirm: { picked in
                        pickerWorkouts = nil
                        Task { await buildBundle(includingHKWorkouts: picked) }
                    },
                    onCancel: {
                        pickerWorkouts = nil
                        // Skip HK entirely; still build a text-only export so the
                        // user gets *something* — preserves the pre-HK behaviour.
                        Task { await buildBundle(includingHKWorkouts: []) }
                    }
                )
            }
            .sheet(item: Binding(
                get: { bundleURL.map { FileURLItem(url: $0) } },
                set: { newValue in bundleURL = newValue?.url }
            )) { item in
                FileShareSheet(url: item.url)
            }
            .alert("Export Failed", isPresented: Binding(
                get: { exportErrorText != nil },
                set: { if !$0 { exportErrorText = nil } }
            ), presenting: exportErrorText) { _ in
                Button("OK", role: .cancel) { }
            } message: { msg in
                Text(msg)
            }
            .alert("Reset All Data?", isPresented: $showingResetConfirmation) {
                Button("Reset Everything", role: .destructive) {
                    performResetAll()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will delete all configurations, workout history, and settings on both iPhone and Watch. This cannot be undone.")
            }
        }
    }

    /// App version and build number
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func formatQuickDistance(_ miles: Double) -> String {
        if miles == miles.rounded() {
            return String(format: "%.0f mi", miles)
        } else {
            return String(format: "%.1f mi", miles)
        }
    }

    private var paceEditSheet: some View {
        NavigationStack {
            Form {
                TextField("Pace Name", text: $paceSheetName)
                    .autocorrectionDisabled()

                Picker("Minutes", selection: $paceSheetMinutes) {
                    ForEach(4...20, id: \.self) { minute in
                        Text("\(minute) min").tag(minute)
                    }
                }

                Picker("Seconds", selection: $paceSheetSeconds) {
                    ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { second in
                        Text(String(format: "%02d sec", second)).tag(second)
                    }
                }
            }
            .navigationTitle(editingPace == nil ? "New Pace" : "Edit Pace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAddPace = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = paceSheetName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let pace = Pace(minutes: paceSheetMinutes, seconds: paceSheetSeconds)
                        if let existing = editingPace,
                           let index = settings.namedPaces.firstIndex(where: { $0.id == existing.id }) {
                            settings.namedPaces[index].name = trimmed
                            settings.namedPaces[index].pace = pace
                        } else {
                            settings.namedPaces.append(NamedPace(name: trimmed, pace: pace))
                        }
                        saveSettings()
                        showingAddPace = false
                    }
                }
            }
        }
    }

    private var store_syncStatusDescription: String {
        switch configurationStore?.syncStatus {
        case .notActivated: return "notActivated"
        case .activated: return "activated"
        case .syncing: return "syncing"
        case .synced: return "synced"
        case .queued: return "queued"
        case .failed(let msg): return "failed: \(msg)"
        case .none: return "configurationStore is nil"
        }
    }

    /// Generates a Leaflet HTML map of the last workout's GPS path,
    /// writes it to a temp file, and returns the URL for sharing.
    /// Returns nil if no debug log is available.
    private func generateMapHTML() -> URL? {
        guard let logText = WorkoutManager.loadLastDebugLog() else { return nil }
        let html = GPSMapRenderer.renderHTML(fromDebugLog: logText, title: "PaceRunner Run")
        let dateStr = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PaceRunner-Map-\(dateStr).html")
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("[SettingsView] Failed to write map HTML: \(error)")
            return nil
        }
    }

    // MARK: - Debug export flow

    /// Anchor date for the HK workout search. Prefer the most recent
    /// PaceRunner workout's start time; fall back to now if no history.
    private var hkSearchAnchor: Date {
        historyStore?.summaries.first?.startTime ?? Date()
    }

    private func startExportFlow() {
        isExportLoading = true
        Task {
            do {
                let exporter = HealthKitExporter.shared
                // Authorization is async and may pop a system sheet on first run.
                try await exporter.requestAuthorization()

                let cal = Calendar.current
                let day = cal.startOfDay(for: hkSearchAnchor)
                let nextDay = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
                let workouts = try await exporter.fetchWorkouts(from: day, to: nextDay)
                print("[Export] Found \(workouts.count) HK workout(s) on \(day) for export")

                isExportLoading = false
                // Always show the picker so the user gets feedback (and a
                // link to the Health app) when nothing came back.
                pickerWorkouts = workouts
            } catch {
                isExportLoading = false
                exportErrorText = error.localizedDescription
            }
        }
    }

    private func buildBundle(includingHKWorkouts hkWorkouts: [HKWorkout]) async {
        isExportLoading = true
        do {
            let debugText = generateDebugExport()
            // Include the watch's last verbose log if we have it on disk.
            let verboseLog = DebugLogStore.shared.loadLast()
            let exporter = HealthKitExporter.shared
            let dir = try await exporter.exportBundle(
                workouts: hkWorkouts,
                debugText: debugText,
                verboseLog: verboseLog
            )
            let zipURL = try await exporter.zipDirectoryForSharing(dir)
            isExportLoading = false
            bundleURL = zipURL
        } catch {
            isExportLoading = false
            exportErrorText = error.localizedDescription
        }
    }

    private func generateDebugExport() -> String {
        var lines: [String] = []
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        lines.append("=== PaceRunner Debug Export ===")
        lines.append("Version: \(version) (\(build))")
        lines.append("Date: \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))")
        lines.append("")

        // Current settings
        let s = settings
        lines.append("=== Current Settings ===")
        lines.append("Companion Mode: \(s.companionMode)")
        lines.append("HealthKit Distance: \(s.useHealthKitDistance)")
        let calSign = s.paceCalibrationSeconds >= 0 ? "+" : ""
        lines.append("Pace Calibration: \(calSign)\(s.paceCalibrationSeconds)s (factor: \(String(format: "%.4f", s.distanceCalibrationFactor())))")
        lines.append("Stride Length: \(String(format: "%.1f", s.strideLengthInches))\"")
        lines.append("Fast Avg: \(s.fastAverageSeconds)s | Med Avg: \(s.mediumAverageSeconds)s | Slow Avg: \(String(format: "%.1f", s.slowAverageMiles))mi")
        lines.append("Audio: beats=\(s.audioBeatsEnabled ? "on" : "off"), voice=\(s.voiceAlertsEnabled ? "on" : "off"), volume=\(Int(s.masterVolume * 100))%, beat=\(String(format: "%.1f", s.beatVolume))x")
        lines.append("Emphasis: \(s.emphasisBeatEnabled ? "every \(s.emphasisBeatInterval)" : "off")")
        lines.append("Debug Pro Override: \(s.debugProOverride)")
        lines.append("Pro Status: \(entitlementManager.isPro)")
        lines.append("")

        // Configurations
        if let configs = configurationStore?.configurations {
            lines.append("=== Configurations (\(configs.count)) ===")
            for config in configs {
                var desc = "\(config.name): \(config.distance.formatted)"
                if config.isMultiSegment, let segs = config.segments {
                    desc += " [\(segs.count) segments]"
                } else {
                    desc += " @ \(config.averagePace().formatted)/mi"
                }
                if let stride = config.strideLengthInches {
                    desc += " stride=\(String(format: "%.1f", stride))\""
                }
                if let cal = config.paceCalibrationSeconds {
                    desc += " cal=\(cal)s"
                }
                lines.append(desc)
            }
            lines.append("")
        }

        // Last workout with debug log
        let summaryCount = historyStore?.summaries.count ?? -1
        lines.append("=== Workout History (\(summaryCount) total) ===")
        if let lastWorkout = historyStore?.summaries.first {
            lines.append(lastWorkout.exportAsText())
        } else {
            if historyStore == nil {
                lines.append("historyStore is nil — not wired up")
            } else {
                lines.append("No workouts in history")
            }
        }

        // Watch debug log (synced independently — may be newer than last workout)
        // Prefer the file-based DebugLogStore (handles multi-MB logs); fall back
        // to the legacy UserDefaults mirror for older runs.
        lines.append("")
        if let watchLog = DebugLogStore.shared.loadLast()
            ?? UserDefaults.standard.string(forKey: "lastWatchDebugLog") {
            lines.append("=== Watch Debug Log (synced) ===")
            lines.append(watchLog)
        } else {
            lines.append("=== No Watch Debug Log synced to phone ===")
        }

        // Sync diagnostics
        lines.append("")
        lines.append("=== Sync Diagnostics ===")
        lines.append("Watch reachable: \(syncManager.isWatchReachable)")
        lines.append("Sync status: \(store_syncStatusDescription)")

        return lines.joined(separator: "\n")
    }

    private func performResetAll() {
        // Clear local UserDefaults
        let keysToRemove = [
            "configurations",
            "workoutSummaries",
            "workoutSummaries_pending",
            "app_settings",
            "entitlement_is_pro",
            "entitlement_debug_override"
        ]
        for key in keysToRemove {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // Reset in-memory state
        settings = AppSettings()
        entitlementManager.debugSetPro(false)
        configurationStore?.resetAll()
        historyStore?.resetAll()

        // Tell Watch to reset too
        syncManager.sendResetAll()

        // Re-sync empty state
        syncManager.syncSettings(settings)
        syncManager.syncAllConfigurations([])
    }

    private func saveSettings() {
        settings.save()
        syncManager.syncSettings(settings)
    }
}

// MARK: - Share Sheet

private struct DebugExportItem: Identifiable {
    let id = UUID()
    let text: String
}

private struct MapExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct WorkoutPickerItem: Identifiable {
    let id = UUID()
    let workouts: [HKWorkout]
}

private struct FileURLItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct FileShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
        let subject = "PaceRunner Debug Export - \(dateStr)"
        let vc = UIActivityViewController(activityItems: [SubjectText(subject: subject, body: text)], applicationActivities: nil)
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Wrapper to provide a subject line for email/messages
private class SubjectText: NSObject, UIActivityItemSource {
    let subject: String
    let body: String

    init(subject: String, body: String) {
        self.subject = subject
        self.body = body
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        body
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        body
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        subject
    }
}

#Preview {
    SettingsView(syncManager: SyncManager())
        .environmentObject(EntitlementManager())
}
