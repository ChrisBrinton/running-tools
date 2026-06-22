import SwiftUI
import WebKit
import HealthKit
import PaceRunnerShared

/// Displays completed workouts synced from the watch.
@MainActor
struct WorkoutHistoryView: View {

    @ObservedObject var store: WorkoutHistoryStore
    @State private var mapSummary: WorkoutSummary?

    var body: some View {
        NavigationStack {
            Group {
                if store.summaries.isEmpty {
                    emptyState
                } else {
                    historyList
                }
            }
            .navigationTitle("Workout History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    syncButton
                }
            }
            .overlay(alignment: .top) {
                syncStatusBanner
            }
        }
    }

    @ViewBuilder
    private var syncButton: some View {
        Button {
            store.requestWorkoutsFromWatch()
        } label: {
            if case .syncing = store.syncStatus {
                ProgressView()
                    .progressViewStyle(.circular)
            } else {
                Label("Sync", systemImage: "arrow.clockwise")
            }
        }
        .disabled(store.syncStatus == .syncing)
    }

    @ViewBuilder
    private var syncStatusBanner: some View {
        switch store.syncStatus {
        case .idle:
            EmptyView()

        case .syncing:
            SyncBanner(message: "Syncing with watch...", icon: "arrow.triangle.2.circlepath", color: .blue)

        case .success(let count):
            if count > 0 {
                SyncBanner(message: "Synced \(count) workout\(count == 1 ? "" : "s")", icon: "checkmark.circle.fill", color: .green)
            } else {
                SyncBanner(message: "Up to date", icon: "checkmark.circle.fill", color: .green)
            }

        case .watchNotReachable:
            SyncBanner(message: "Watch not reachable", icon: "applewatch.slash", color: .orange)

        case .failed(let error):
            SyncBanner(message: error, icon: "exclamationmark.triangle.fill", color: .red)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Workouts Yet", systemImage: "clock.badge.exclamationmark")
        } description: {
            Text("Complete a workout on the watch to see it here.")
        }
    }

    private var historyList: some View {
        List {
            ForEach(store.summaries) { summary in
                HStack(spacing: 0) {
                    NavigationLink {
                        WorkoutSummaryDetailView(summary: summary)
                    } label: {
                        WorkoutSummaryRow(summary: summary)
                    }

                    // Inline map button — only enabled if we have a debug log on disk for this workout
                    if DebugLogStore.shared.storedIDs().contains(summary.id) {
                        Button {
                            mapSummary = summary
                        } label: {
                            Image(systemName: "map.fill")
                                .imageScale(.medium)
                                .padding(8)
                        }
                        .buttonStyle(.borderless)
                        .tint(.blue)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.delete(summary)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            store.requestWorkoutsFromWatch()
            // Wait for sync to complete
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        .sheet(item: $mapSummary) { summary in
            RunMapSheet(summary: summary)
        }
    }
}

// MARK: - Map Sheet

private struct RunMapSheet: View {
    let summary: WorkoutSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let logText = DebugLogStore.shared.load(for: summary.id) {
                    let html = GPSMapRenderer.renderHTML(fromDebugLog: logText, title: summary.configurationName)
                    HTMLWebView(html: html)
                } else {
                    ContentUnavailableView {
                        Label("No GPS Data", systemImage: "map")
                    } description: {
                        Text("This workout doesn't have a stored debug log. Enable Verbose GPS Logging in Settings → Debug to capture data for future runs.")
                    }
                }
            }
            .navigationTitle(summary.configurationName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct HTMLWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: config)
        view.loadHTMLString(html, baseURL: URL(string: "https://unpkg.com"))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Sync Banner

private struct SyncBanner: View {
    let message: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(message)
                .font(.subheadline)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(color, in: Capsule())
        .shadow(radius: 2)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.3), value: message)
    }
}

// MARK: - Row

private struct WorkoutSummaryRow: View {
    let summary: WorkoutSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.configurationName)
                .font(.headline)

            HStack(spacing: 12) {
                Label(summary.formattedDate, systemImage: "calendar")
                Label(summary.formattedTime, systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                MetricLabel(
                    title: "Distance",
                    value: summary.totalDistance.formatted,
                    icon: "ruler"
                )
                MetricLabel(
                    title: "Avg Pace",
                    value: summary.averagePace.formatted,
                    icon: "gauge.with.dots.needle.67percent"
                )
                MetricLabel(
                    title: "Duration",
                    value: summary.formattedDuration,
                    icon: "timer"
                )
            }
            .font(.caption)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Detail View

private struct WorkoutSummaryDetailView: View {
    let summary: WorkoutSummary

    // Per-workout export flow — mirrors SettingsView's pattern but anchored
    // on this workout's startTime so the HK picker offers the right day.
    @State private var isExportLoading = false
    @State private var pickerWorkouts: [HKWorkout]?
    @State private var bundleURL: URL?
    @State private var exportErrorText: String?

    /// Combines the summary export with the disk-resident debug log so the
    /// shared file contains everything a developer would want.
    private var combinedExport: String {
        let base = summary.exportAsText()
        guard let log = DebugLogStore.shared.load(for: summary.id) else { return base }
        return base + "\n\n=== Debug Log ===\n" + log
    }

    var body: some View {
        List {
            Section("Overview") {
                WorkoutSummaryHeader(summary: summary)
            }

            Section("Splits") {
                if summary.mileSplits.isEmpty {
                    Text("No split data recorded.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(summary.mileSplits, id: \.mileNumber) { split in
                        HStack {
                            Text("Mile \(split.mileNumber)")
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("Actual \(split.actualPace.formatted)")
                                Text("Target \(split.targetPace.formatted)")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                if let hr = split.averageHeartRate {
                                    Text("HR \(hr) bpm")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }

            // Debug + Health export section. Tapping the Export button
            // builds a zip containing the PR text export, the verbose GPS
            // log (if recorded), plus selectable HealthKit workouts from
            // the same day (route GPX + metrics + events). See
            // `HealthKitExporter` for the bundle layout.
            Section("Debug Data") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if let logSize = DebugLogStore.shared.fileSize(for: summary.id) {
                            Text("Debug log on disk")
                                .font(.body)
                            Text("\(logSize / 1024) KB · plus Health for \(summary.formattedDate)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No verbose log for this run")
                                .font(.body)
                            Text("Export still includes summary + Health data for \(summary.formattedDate)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        startExportFlow()
                    } label: {
                        if isExportLoading {
                            ProgressView()
                        } else {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(isExportLoading)
                }
            }
        }
        .navigationTitle(summary.configurationName)
        .sheet(item: Binding(
            get: { pickerWorkouts.map { WorkoutPickerSheetItem(workouts: $0) } },
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
                    Task { await buildBundle(includingHKWorkouts: []) }
                }
            )
        }
        .sheet(item: Binding(
            get: { bundleURL.map { BundleURLItem(url: $0) } },
            set: { newValue in bundleURL = newValue?.url }
        )) { item in
            FileShareSheetWrapper(url: item.url)
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportErrorText != nil },
            set: { if !$0 { exportErrorText = nil } }
        ), presenting: exportErrorText) { _ in
            Button("OK", role: .cancel) { }
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Export flow

    private func startExportFlow() {
        isExportLoading = true
        Task {
            do {
                let exporter = HealthKitExporter.shared
                try await exporter.requestAuthorization()

                let cal = Calendar.current
                let day = cal.startOfDay(for: summary.startTime)
                let nextDay = cal.date(byAdding: .day, value: 1, to: day)
                    ?? day.addingTimeInterval(86400)
                let workouts = try await exporter.fetchWorkouts(from: day, to: nextDay)
                print("[Export] Found \(workouts.count) HK workout(s) on \(day) for export")

                isExportLoading = false
                // Always show the picker — even when empty — so the user gets
                // explicit feedback and can navigate to Health → Privacy if
                // permission is the missing piece.
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
            // `combinedExport` already appends the on-disk verbose log to the
            // text, so we deliberately pass nil for the separate file to
            // avoid a 1MB duplicate inside the zip.
            let exporter = HealthKitExporter.shared
            let dir = try await exporter.exportBundle(
                workouts: hkWorkouts,
                debugText: combinedExport,
                verboseLog: nil
            )
            let zipURL = try await exporter.zipDirectoryForSharing(dir)
            isExportLoading = false
            bundleURL = zipURL
        } catch {
            isExportLoading = false
            exportErrorText = error.localizedDescription
        }
    }
}

private struct WorkoutPickerSheetItem: Identifiable {
    let id = UUID()
    let workouts: [HKWorkout]
}

private struct BundleURLItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Wraps UIActivityViewController for sharing a single file URL — this view
/// is private to SettingsView in that file, so it's re-declared here for the
/// detail view to avoid coupling.
private struct FileShareSheetWrapper: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Reusable Views

private struct WorkoutSummaryHeader: View {
    let summary: WorkoutSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                MetricLabel(title: "Date", value: summary.formattedDate, icon: "calendar")
                Spacer()
                MetricLabel(title: "Start", value: summary.formattedTime, icon: "clock")
            }

            HStack {
                MetricLabel(title: "Distance", value: summary.totalDistance.formatted, icon: "ruler")
                Spacer()
                MetricLabel(title: "Duration", value: summary.formattedDuration, icon: "timer")
                Spacer()
                MetricLabel(title: "Avg Pace", value: summary.averagePace.formatted, icon: "gauge.with.dots.needle.67percent")
            }
        }
        .font(.subheadline)
    }
}

private struct MetricLabel: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
        }
    }
}

// MARK: - Preview

#if DEBUG
private extension WorkoutSummary {
    static let longRunPreview: WorkoutSummary = {
        WorkoutSummary(
            configurationName: "Long Easy",
            startTime: Date().addingTimeInterval(-86_400),
            endTime: Date().addingTimeInterval(-83_400),
            totalDistance: Distance(miles: 12.4),
            averagePace: Pace(minutes: 8, seconds: 20),
            mileSplits: (1...6).map { mile in
                MileSplit(
                    mileNumber: mile,
                    actualPace: Pace(minutes: 8, seconds: 15),
                    targetPace: Pace(minutes: 8, seconds: 30),
                    distance: Distance(miles: 1.0)
                )
            }
        )
    }()

    static let tempoPreview: WorkoutSummary = {
        WorkoutSummary(
            configurationName: "Tempo Progression",
            startTime: Date().addingTimeInterval(-15_000),
            endTime: Date().addingTimeInterval(-12_600),
            totalDistance: Distance(miles: 6.2),
            averagePace: Pace(minutes: 7, seconds: 5),
            mileSplits: (1...4).map { mile in
                MileSplit(
                    mileNumber: mile,
                    actualPace: Pace(minutes: 7, seconds: max(0, 20 - mile * 3)),
                    targetPace: Pace(minutes: 7, seconds: 30),
                    distance: Distance(miles: 1.0)
                )
            }
        )
    }()
}

#Preview {
    MainActor.assumeIsolated {
        WorkoutHistoryView(
            store: WorkoutHistoryStore(
                initialSummaries: [
                    .tempoPreview,
                    .longRunPreview
                ],
                notificationCenter: NotificationCenter()
            )
        )
    }
}
#endif
