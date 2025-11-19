import SwiftUI
import PaceRunnerShared

/// Form for creating or editing a run configuration
///
/// Features:
/// - Name input
/// - Distance picker
/// - Pace configuration (even or progressive)
/// - Cadence and tolerance settings
/// - Validation
/// - Save/cancel actions
///
/// Constitution compliance:
/// - User Experience Consistency: Clear form with validation
/// - Sensible Defaults: Pre-populated with common values
struct ConfigurationDetailView: View {

    @ObservedObject var store: ConfigurationStore
    @Environment(\.dismiss) private var dismiss

    // Editing mode
    private let editingConfiguration: RunConfiguration?
    private let isEditing: Bool

    // Form state
    @State private var name: String
    @State private var distanceMiles: Double
    @State private var isProgressiveRun: Bool
    @State private var evenPace: PaceInput
    @State private var startPace: PaceInput
    @State private var endPace: PaceInput
    @State private var baseCadence: Int
    @State private var paceTolerance: Int

    // Validation
    @State private var showingValidationError = false
    @State private var validationMessage = ""

    // MARK: - Initialization

    init(store: ConfigurationStore, configuration: RunConfiguration? = nil) {
        self.store = store
        self.editingConfiguration = configuration
        self.isEditing = configuration != nil

        // Initialize state from configuration or defaults
        if let config = configuration {
            _name = State(initialValue: config.name)
            _distanceMiles = State(initialValue: config.distance.miles)
            _baseCadence = State(initialValue: config.baseCadence)
            _paceTolerance = State(initialValue: config.paceTolerance)

            // Determine if progressive
            let isProgressive = config.milePaces.count > 1 &&
                               config.milePaces.first != config.milePaces.last
            _isProgressiveRun = State(initialValue: isProgressive)

            if isProgressive {
                _startPace = State(initialValue: PaceInput(from: config.milePaces.first!))
                _endPace = State(initialValue: PaceInput(from: config.milePaces.last!))
                _evenPace = State(initialValue: PaceInput(minutes: 8, seconds: 0))
            } else {
                _evenPace = State(initialValue: PaceInput(from: config.averagePace()))
                _startPace = State(initialValue: PaceInput(minutes: 8, seconds: 0))
                _endPace = State(initialValue: PaceInput(minutes: 7, seconds: 30))
            }
        } else {
            // Defaults for new configuration
            _name = State(initialValue: "")
            _distanceMiles = State(initialValue: 26.2)
            _isProgressiveRun = State(initialValue: false)
            _evenPace = State(initialValue: PaceInput(minutes: 8, seconds: 0))
            _startPace = State(initialValue: PaceInput(minutes: 9, seconds: 0))
            _endPace = State(initialValue: PaceInput(minutes: 7, seconds: 30))
            _baseCadence = State(initialValue: 180)
            _paceTolerance = State(initialValue: 10)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Basic Info") {
                    TextField("Configuration Name", text: $name)
                        .autocorrectionDisabled()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Distance")
                            Spacer()
                            Text(String(format: "%.1f mi", distanceMiles))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $distanceMiles, in: 1.0...100.0, step: 0.1)
                    }

                    Picker("Distance Preset", selection: $distanceMiles) {
                        Text("5K (3.1 mi)").tag(3.1)
                        Text("10K (6.2 mi)").tag(6.2)
                        Text("Half Marathon (13.1 mi)").tag(13.1)
                        Text("Marathon (26.2 mi)").tag(26.2)
                        Text("50K (31.1 mi)").tag(31.1)
                        Text("50 miles").tag(50.0)
                    }
                }

                Section("Pace") {
                    Toggle("Progressive Run", isOn: $isProgressiveRun)
                        .onChange(of: isProgressiveRun) { _, _ in
                            // Reset paces when switching modes
                        }

                    if isProgressiveRun {
                        PacePickerView(title: "Starting Pace", pace: $startPace)
                        PacePickerView(title: "Ending Pace", pace: $endPace)
                    } else {
                        PacePickerView(title: "Target Pace", pace: $evenPace)
                    }
                }

                Section("Settings") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Base Cadence")
                            Spacer()
                            Text("\(baseCadence) SPM")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(baseCadence) },
                            set: { baseCadence = Int($0) }
                        ), in: 150...200, step: 5)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Pace Tolerance")
                            Spacer()
                            Text("±\(paceTolerance) sec")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(paceTolerance) },
                            set: { paceTolerance = Int($0) }
                        ), in: 5...30, step: 5)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Configuration" : "New Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveConfiguration()
                    }
                }
            }
            .alert("Invalid Configuration", isPresented: $showingValidationError) {
                Button("OK") { }
            } message: {
                Text(validationMessage)
            }
        }
    }

    // MARK: - Actions

    private func saveConfiguration() {
        // Validate
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationMessage = "Please enter a configuration name"
            showingValidationError = true
            return
        }

        guard let distance = try? Distance(miles: distanceMiles) else {
            validationMessage = "Invalid distance"
            showingValidationError = true
            return
        }

        // Create pace array
        let milePaces: [Pace]
        if isProgressiveRun {
            guard let start = startPace.toPace(),
                  let end = endPace.toPace() else {
                validationMessage = "Invalid pace values"
                showingValidationError = true
                return
            }
            milePaces = createProgressivePaces(from: start, to: end, mileCount: Int(ceil(distanceMiles)))
        } else {
            guard let pace = evenPace.toPace() else {
                validationMessage = "Invalid pace value"
                showingValidationError = true
                return
            }
            milePaces = Array(repeating: pace, count: Int(ceil(distanceMiles)))
        }

        // Create or update configuration
        let configuration = RunConfiguration(
            id: editingConfiguration?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            distance: distance,
            milePaces: milePaces,
            baseCadence: baseCadence,
            paceTolerance: paceTolerance
        )

        if isEditing {
            store.updateConfiguration(configuration)
        } else {
            store.createConfiguration(configuration)
        }

        dismiss()
    }

    private func createProgressivePaces(from start: Pace, to end: Pace, mileCount: Int) -> [Pace] {
        guard mileCount > 1 else { return [start] }

        let totalChange = end.totalSeconds - start.totalSeconds
        let changePerMile = Double(totalChange) / Double(mileCount - 1)

        return (0..<mileCount).compactMap { mile in
            let targetSeconds = start.totalSeconds + Int(Double(mile) * changePerMile)
            let minutes = targetSeconds / 60
            let seconds = targetSeconds % 60
            return try? Pace(minutes: minutes, seconds: seconds)
        }
    }
}

// MARK: - Pace Input Helper

struct PaceInput {
    var minutes: Int
    var seconds: Int

    init(minutes: Int, seconds: Int) {
        self.minutes = minutes
        self.seconds = seconds
    }

    init(from pace: Pace) {
        self.minutes = pace.minutes
        self.seconds = pace.seconds
    }

    func toPace() -> Pace? {
        try? Pace(minutes: minutes, seconds: seconds)
    }
}

// MARK: - Pace Picker View

struct PacePickerView: View {
    let title: String
    @Binding var pace: PaceInput

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)

            HStack {
                Picker("Minutes", selection: $pace.minutes) {
                    ForEach(4...20, id: \.self) { minute in
                        Text("\(minute)").tag(minute)
                    }
                }
                .pickerStyle(.wheel)
                .frame(width: 80)

                Text(":")
                    .font(.title)

                Picker("Seconds", selection: $pace.seconds) {
                    ForEach([0, 15, 30, 45], id: \.self) { second in
                        Text(String(format: "%02d", second)).tag(second)
                    }
                }
                .pickerStyle(.wheel)
                .frame(width: 80)

                Spacer()

                Text("min/mile")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Preview

#Preview("New Configuration") {
    ConfigurationDetailView(store: ConfigurationStore())
}

#Preview("Edit Configuration") {
    let store = ConfigurationStore()
    let config = RunConfiguration(
        name: "Marathon - Even Pace",
        distance: Distance(miles: 26.2),
        targetPace: Pace(minutes: 8, seconds: 0)
    )
    return ConfigurationDetailView(store: store, configuration: config)
}
