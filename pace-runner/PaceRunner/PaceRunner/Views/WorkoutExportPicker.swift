import SwiftUI
import UIKit
import HealthKit

/// Multi-select sheet shown by Settings → Export Debug Data after HealthKit
/// has returned the day's workouts. The caller passes in the candidates and
/// receives the selection (or nil for cancel) via the `onConfirm` closure.
struct WorkoutExportPicker: View {

    let workouts: [HKWorkout]
    let onConfirm: ([HKWorkout]) -> Void
    let onCancel: () -> Void

    @State private var selected: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Group {
                if workouts.isEmpty {
                    ContentUnavailableView {
                        Label("No Health Workouts Returned", systemImage: "heart.text.square")
                    } description: {
                        Text("HealthKit returned no workouts for this day. If you used the Workout app, the most likely cause is that PaceRunner doesn't have read permission for workout data on this device.")
                    } actions: {
                        Button {
                            if let url = URL(string: "x-apple-health://") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Text("Open Health App")
                        }
                        .buttonStyle(.borderedProminent)
                        Text("Then: Profile → Privacy → Apps → PaceRunner → Turn On All.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Include from Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(workouts.isEmpty ? "Done" : "Include \(selected.count)") {
                        let picked = workouts.filter { selected.contains($0.uuid) }
                        onConfirm(picked)
                    }
                    .disabled(!workouts.isEmpty && selected.isEmpty)
                }
            }
            .onAppear {
                // Default to all selected — the common case is "grab everything".
                if selected.isEmpty {
                    selected = Set(workouts.map { $0.uuid })
                }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(workouts, id: \.uuid) { workout in
                    Button {
                        toggle(workout.uuid)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected.contains(workout.uuid)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(workout.uuid) ? .blue : .secondary)
                            WorkoutRow(workout: workout)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Each selected workout will be exported as workout.json + route.gpx + samples.json (heart rate, distance, energy, running dynamics if available).")
            }

            Section {
                Button {
                    if selected.count == workouts.count {
                        selected.removeAll()
                    } else {
                        selected = Set(workouts.map { $0.uuid })
                    }
                } label: {
                    Text(selected.count == workouts.count ? "Deselect All" : "Select All")
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

private struct WorkoutRow: View {
    let workout: HKWorkout

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.blue)
                Text(typeName)
                    .font(.headline)
                Spacer()
                Text(timeRange)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if let dist = workout.totalDistance?.doubleValue(for: .mile()) {
                    Label(String(format: "%.2f mi", dist), systemImage: "ruler")
                }
                Label(durationString, systemImage: "timer")
                Text("Source: \(workout.sourceRevision.source.name)")
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var typeName: String {
        switch workout.workoutActivityType {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .hiking: return "Hiking"
        case .swimming: return "Swimming"
        default: return "Activity"
        }
    }

    private var icon: String {
        switch workout.workoutActivityType {
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .cycling: return "bicycle"
        case .hiking: return "figure.hiking"
        case .swimming: return "figure.pool.swim"
        default: return "figure.mixed.cardio"
        }
    }

    private var durationString: String {
        let s = Int(workout.duration)
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }

    private var timeRange: String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return "\(f.string(from: workout.startDate))–\(f.string(from: workout.endDate))"
    }
}
