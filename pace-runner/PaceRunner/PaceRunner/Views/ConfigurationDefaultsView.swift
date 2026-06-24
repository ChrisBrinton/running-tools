import SwiftUI
import PaceRunnerShared

/// Sub-page that owns everything related to "what shows up when I build a
/// new run configuration": default tolerance, the quick-distance list, and
/// the named-pace list (with add/edit sheets).
///
/// Lives behind a NavigationLink from the main Settings page so the top-
/// level Settings stays scannable — only the rows the user actually wants
/// to see day-to-day live there.
@MainActor
struct ConfigurationDefaultsView: View {

    @Binding var settings: AppSettings
    let onSave: () -> Void

    @State private var showingAddDistance = false
    @State private var newDistanceText = ""
    @State private var showingAddPace = false
    @State private var editingPace: NamedPace?
    @State private var paceSheetName = ""
    @State private var paceSheetMinutes = 9
    @State private var paceSheetSeconds = 0

    var body: some View {
        Form {
            Section {
                Stepper(
                    "Default Tolerance: \(settings.defaultTolerance)s",
                    value: $settings.defaultTolerance,
                    in: 1...60
                )
                .onChange(of: settings.defaultTolerance) { _, _ in onSave() }
            } header: {
                Text("Defaults for New Configurations")
            } footer: {
                Text("Initial pace tolerance applied to new run configurations. You can change it per-configuration later.")
            }

            Section(header: Text("Quick Distances")) {
                ForEach(Array(settings.commonDistances.enumerated()), id: \.offset) { index, distance in
                    HStack {
                        Text(formatQuickDistance(distance))
                        Spacer()
                        Button(role: .destructive) {
                            settings.commonDistances.remove(at: index)
                            onSave()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onMove { source, destination in
                    settings.commonDistances.move(fromOffsets: source, toOffset: destination)
                    onSave()
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
                                onSave()
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
                    onSave()
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
        }
        .navigationTitle("Configuration Defaults")
        .alert("Add Quick Distance", isPresented: $showingAddDistance) {
            TextField("Miles", text: $newDistanceText)
                .keyboardType(.decimalPad)
            Button("Add") {
                if let miles = Double(newDistanceText), miles > 0 {
                    settings.commonDistances.append(miles)
                    settings.commonDistances.sort()
                    onSave()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter distance in miles")
        }
        .sheet(isPresented: $showingAddPace) {
            paceEditSheet
        }
    }

    // MARK: - Helpers carried over from SettingsView

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
                Section("Pace Name") {
                    TextField("e.g. Easy, Tempo, Long", text: $paceSheetName)
                }
                Section("Pace") {
                    HStack {
                        Picker("Min", selection: $paceSheetMinutes) {
                            ForEach(4...20, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        Text(":")
                        Picker("Sec", selection: $paceSheetSeconds) {
                            ForEach(0..<60, id: \.self) {
                                Text(String(format: "%02d", $0)).tag($0)
                            }
                        }
                        .pickerStyle(.wheel)
                    }
                    .frame(maxHeight: 150)
                }
            }
            .navigationTitle(editingPace == nil ? "Add Pace" : "Edit Pace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAddPace = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = paceSheetName.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        let pace = Pace(minutes: paceSheetMinutes, seconds: paceSheetSeconds)
                        if let editing = editingPace,
                           let idx = settings.namedPaces.firstIndex(where: { $0.id == editing.id }) {
                            settings.namedPaces[idx] = NamedPace(id: editing.id, name: trimmed, pace: pace)
                        } else {
                            settings.namedPaces.append(NamedPace(name: trimmed, pace: pace))
                        }
                        onSave()
                        showingAddPace = false
                    }
                }
            }
        }
    }
}
