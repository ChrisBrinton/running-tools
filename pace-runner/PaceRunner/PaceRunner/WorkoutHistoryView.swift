import SwiftUI
import PaceRunnerShared

/// Displays completed workouts synced from the watch.
@MainActor
struct WorkoutHistoryView: View {

    @ObservedObject var store: WorkoutHistoryStore

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
                    Button {
                        store.reload()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
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
                NavigationLink {
                    WorkoutSummaryDetailView(summary: summary)
                } label: {
                    WorkoutSummaryRow(summary: summary)
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
    @State private var showingShareSheet = false
    @State private var debugLogFileURL: URL?

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
                            }
                        }
                    }
                }
            }

            // Debug log export section
            Section("Debug Data") {
                if let debugLog = summary.debugLog {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(debugLog.events.count) events recorded")
                                .font(.body)
                            Text("Version: \(debugLog.appVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            debugLogFileURL = createDebugLogFile(debugLog: debugLog)
                            if debugLogFileURL != nil {
                                showingShareSheet = true
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                } else {
                    Text("No debug data available.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(summary.configurationName)
        .sheet(isPresented: $showingShareSheet) {
            if let fileURL = debugLogFileURL {
                ShareSheet(items: [fileURL])
            }
        }
    }

    /// Creates a temporary file with the debug log content for sharing as an attachment
    private func createDebugLogFile(debugLog: DebugLog) -> URL? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = dateFormatter.string(from: summary.startTime)
        let fileName = "pacerunner_debug_\(timestamp).txt"

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            let content = debugLog.exportAsText()
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            print("Failed to create debug log file: \(error)")
            return nil
        }
    }
}

// MARK: - Share Sheet

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
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
