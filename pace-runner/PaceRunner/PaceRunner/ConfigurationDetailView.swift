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

    // Global settings (for stride-based BPM calculation)
    private let settings: AppSettings

    // Form state
    @State private var name: String
    @State private var distanceMiles: Double
    @State private var isProgressiveRun: Bool
    @State private var evenPace: PaceInput
    @State private var startPace: PaceInput
    @State private var endPace: PaceInput
    @State private var cadenceOffset: Int  // Offset from calculated base BPM (-15 to +15)
    @State private var paceTolerance: Int
    @State private var metronomeMinVolume: Float
    @State private var metronomeMaxVolume: Float
    @State private var autoEndRun: Bool

    // Validation
    @State private var showingValidationError = false
    @State private var validationMessage = ""

    // MARK: - Initialization

    init(store: ConfigurationStore, configuration: RunConfiguration? = nil) {
        self.store = store
        self.editingConfiguration = configuration
        self.isEditing = configuration != nil
        self.settings = AppSettings.load()

        // Initialize state from configuration or defaults
        if let config = configuration {
            _name = State(initialValue: config.name)
            _distanceMiles = State(initialValue: config.distance.miles)
            _cadenceOffset = State(initialValue: config.cadenceOffset)
            _paceTolerance = State(initialValue: config.paceTolerance)
            _metronomeMinVolume = State(initialValue: config.metronomeMinVolume)
            _metronomeMaxVolume = State(initialValue: config.metronomeMaxVolume)
            _autoEndRun = State(initialValue: config.autoEndRun)

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
            _cadenceOffset = State(initialValue: 0)  // Start at base BPM
            _paceTolerance = State(initialValue: 10)
            _metronomeMinVolume = State(initialValue: 0.3)
            _metronomeMaxVolume = State(initialValue: 1.0)
            _autoEndRun = State(initialValue: true)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Basic Info") {
                    TextField("Configuration Name", text: $name)
                        .autocorrectionDisabled()
                }

                Section("Distance") {
                    // Stepper with 0.25 mile increments
                    Stepper(value: $distanceMiles, in: 0.25...100.0, step: 0.25) {
                        HStack {
                            Text("Distance")
                            Spacer()
                            Text(formatDistance(distanceMiles))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    // Common presets
                    Picker("Preset", selection: $distanceMiles) {
                        Text("1 mile").tag(1.0)
                        Text("5K (3.1 mi)").tag(3.1)
                        Text("10K (6.2 mi)").tag(6.2)
                        Text("Half (13.1 mi)").tag(13.1)
                        Text("Marathon (26.2 mi)").tag(26.2)
                        Text("50K (31.1 mi)").tag(31.1)
                    }
                    .pickerStyle(.menu)

                    // Custom distance input
                    HStack {
                        Text("Custom")
                        Spacer()
                        TextField("miles", value: $distanceMiles, format: .number.precision(.fractionLength(2)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("mi")
                            .foregroundStyle(.secondary)
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
                            Text("Metronome Tempo")
                            Spacer()
                            Text("\(effectiveBPM) BPM")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Base from stride: \(calculatedBaseBPM)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Offset: \(cadenceOffset > 0 ? "+" : "")\(cadenceOffset)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(cadenceOffset) },
                            set: { cadenceOffset = Int($0) }
                        ), in: -15...15, step: 1)
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

                Section("Metronome Volume") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Min Volume")
                            Spacer()
                            Text("\(Int(metronomeMinVolume * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $metronomeMinVolume, in: 0.0...1.0, step: 0.1)
                            .onChange(of: metronomeMinVolume) { _, newValue in
                                // Ensure min doesn't exceed max
                                if newValue > metronomeMaxVolume {
                                    metronomeMinVolume = metronomeMaxVolume
                                }
                            }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Max Volume")
                            Spacer()
                            Text("\(Int(metronomeMaxVolume * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $metronomeMaxVolume, in: 0.0...1.0, step: 0.1)
                            .onChange(of: metronomeMaxVolume) { _, newValue in
                                // Ensure max doesn't go below min
                                if newValue < metronomeMinVolume {
                                    metronomeMaxVolume = metronomeMinVolume
                                }
                            }
                    }

                    Text("Volume scales from min to max based on how far off pace you are")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Run Completion") {
                    Toggle("Auto-end when distance reached", isOn: $autoEndRun)
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

    // MARK: - Computed Properties

    /// Base BPM calculated from stride length and target pace
    private var calculatedBaseBPM: Int {
        let targetPace: Pace
        if isProgressiveRun {
            // Use start pace for progressive runs
            targetPace = startPace.toPace() ?? Pace(minutes: 8, seconds: 0)
        } else {
            targetPace = evenPace.toPace() ?? Pace(minutes: 8, seconds: 0)
        }
        return settings.calculateBaseBPM(for: targetPace)
    }

    /// Effective BPM = base + offset
    private var effectiveBPM: Int {
        calculatedBaseBPM + cadenceOffset
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
            cadenceOffset: cadenceOffset,
            paceTolerance: paceTolerance,
            metronomeMinVolume: metronomeMinVolume,
            metronomeMaxVolume: metronomeMaxVolume,
            autoEndRun: autoEndRun
        )

        if isEditing {
            store.updateConfiguration(configuration)
        } else {
            store.createConfiguration(configuration)
        }

        dismiss()
    }

    /// Formats distance as whole number or with fraction
    private func formatDistance(_ miles: Double) -> String {
        if miles == miles.rounded() {
            return String(format: "%.0f mi", miles)
        } else {
            return String(format: "%.2f mi", miles)
        }
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

// MARK: - Compact Pace Picker View

/// A compact pace picker that shows the value as tappable text
/// and expands to wheel pickers when editing
struct PacePickerView: View {
    let title: String
    @Binding var pace: PaceInput
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Compact display - tap to expand
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(title)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(formattedPace)
                        .foregroundStyle(isExpanded ? .blue : .secondary)
                        .monospacedDigit()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            // Expanded wheel pickers
            if isExpanded {
                HStack {
                    Picker("Minutes", selection: $pace.minutes) {
                        ForEach(4...20, id: \.self) { minute in
                            Text("\(minute)").tag(minute)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 70, height: 100)
                    .clipped()

                    Text(":")
                        .font(.title2)

                    Picker("Seconds", selection: $pace.seconds) {
                        ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { second in
                            Text(String(format: "%02d", second)).tag(second)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 70, height: 100)
                    .clipped()

                    Spacer()

                    Text("min/mi")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var formattedPace: String {
        String(format: "%d:%02d min/mi", pace.minutes, pace.seconds)
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
