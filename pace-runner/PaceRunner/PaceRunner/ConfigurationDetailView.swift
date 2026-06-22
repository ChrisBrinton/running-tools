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

// MARK: - Configuration Summary View (Edit)

/// Summary view for editing an existing config — shows key settings at top level,
/// with "Advanced" NavigationLink to full detail (like Apple Settings pattern)
struct ConfigurationSummaryView: View {
    @ObservedObject var store: ConfigurationStore
    let configuration: RunConfiguration
    @Environment(\.dismiss) private var dismiss

    private let settings = AppSettings.load()

    @State private var name: String
    @State private var distanceMiles: Double
    @State private var evenPace: PaceInput
    @State private var cadenceOffset: Int
    @State private var paceTolerance: Int
    @State private var metronomeMinVolume: Float
    @State private var metronomeMaxVolume: Float
    @State private var autoEndRun: Bool
    @State private var isProgressiveRun: Bool
    @State private var startPace: PaceInput
    @State private var endPace: PaceInput

    @State private var showingValidationError = false
    @State private var validationMessage = ""

    init(store: ConfigurationStore, configuration: RunConfiguration) {
        self.store = store
        self.configuration = configuration

        _name = State(initialValue: configuration.name)
        _distanceMiles = State(initialValue: configuration.distance.miles)
        _cadenceOffset = State(initialValue: configuration.cadenceOffset)
        _paceTolerance = State(initialValue: configuration.paceTolerance)
        _metronomeMinVolume = State(initialValue: configuration.metronomeMinVolume)
        _metronomeMaxVolume = State(initialValue: configuration.metronomeMaxVolume)
        _autoEndRun = State(initialValue: configuration.autoEndRun)

        let isProgressive = configuration.milePaces.count > 1 &&
                           configuration.milePaces.first != configuration.milePaces.last
        _isProgressiveRun = State(initialValue: isProgressive)

        if isProgressive {
            _startPace = State(initialValue: PaceInput(from: configuration.milePaces.first!))
            _endPace = State(initialValue: PaceInput(from: configuration.milePaces.last!))
            _evenPace = State(initialValue: PaceInput(minutes: 8, seconds: 0))
        } else {
            _evenPace = State(initialValue: PaceInput(from: configuration.averagePace()))
            _startPace = State(initialValue: PaceInput(minutes: 8, seconds: 0))
            _endPace = State(initialValue: PaceInput(minutes: 7, seconds: 30))
        }
    }

    private var calculatedBaseBPM: Int {
        let targetPace: Pace
        if isProgressiveRun {
            targetPace = startPace.toPace() ?? Pace(minutes: 8, seconds: 0)
        } else {
            targetPace = evenPace.toPace() ?? Pace(minutes: 8, seconds: 0)
        }
        return settings.calculateBaseBPM(for: targetPace)
    }

    private var effectiveBPM: Int {
        calculatedBaseBPM + cadenceOffset
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Basic") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()

                    HStack {
                        Text("Distance")
                        Spacer()
                        Text(formatDistance(distanceMiles))
                            .foregroundStyle(.secondary)
                    }

                    if configuration.isMultiSegment, let segments = configuration.segments {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            HStack {
                                Text("Seg \(index + 1): \(segment.label)")
                                Spacer()
                                Text("\(segment.distance.formatted) @ \(segment.pace.formatted)/mi")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                        }
                    } else {
                        HStack {
                            Text("Pace")
                            Spacer()
                            if isProgressiveRun {
                                Text("\(startPace.toPace()?.formatted ?? "--") → \(endPace.toPace()?.formatted ?? "--")/mi")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("\(evenPace.toPace()?.formatted ?? "--:--")/mi")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack {
                        Text("Tolerance")
                        Spacer()
                        Text("±\(paceTolerance)s")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Metronome")
                        Spacer()
                        Text("\(effectiveBPM) BPM")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    NavigationLink {
                        advancedForm
                    } label: {
                        HStack {
                            Text("Advanced Settings")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Edit Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveConfiguration() }
                }
            }
            .alert("Invalid Configuration", isPresented: $showingValidationError) {
                Button("OK") { }
            } message: {
                Text(validationMessage)
            }
        }
    }

    private var advancedForm: some View {
        Form {
            Section("Distance") {
                Stepper(value: $distanceMiles, in: 0.25...100.0, step: 0.25) {
                    HStack {
                        Text("Distance")
                        Spacer()
                        Text(formatDistance(distanceMiles))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Picker("Preset", selection: $distanceMiles) {
                    Text("1 mile").tag(1.0)
                    Text("5K (3.1 mi)").tag(3.1)
                    Text("10K (6.2 mi)").tag(6.2)
                    Text("Half (13.1 mi)").tag(13.1)
                    Text("Marathon (26.2 mi)").tag(26.2)
                    Text("50K (31.1 mi)").tag(31.1)
                }
                .pickerStyle(.menu)
            }

            Section("Pace") {
                Toggle("Progressive Run", isOn: $isProgressiveRun)

                if isProgressiveRun {
                    PacePickerView(title: "Starting Pace", pace: $startPace)
                    PacePickerView(title: "Ending Pace", pace: $endPace)
                } else {
                    PacePickerView(title: "Target Pace", pace: $evenPace)
                }
            }

            Section("Metronome") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Tempo")
                        Spacer()
                        Text("\(effectiveBPM) BPM")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Base: \(calculatedBaseBPM)")
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

            Section("Volume") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Min Volume")
                        Spacer()
                        Text("\(Int(metronomeMinVolume * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $metronomeMinVolume, in: 0.0...1.0, step: 0.1)
                        .onChange(of: metronomeMinVolume) { _, newValue in
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
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func saveConfiguration() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationMessage = "Please enter a configuration name"
            showingValidationError = true
            return
        }

        let distance = Distance(miles: distanceMiles)

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

        let updated = RunConfiguration(
            id: configuration.id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            distance: distance,
            milePaces: milePaces,
            cadenceOffset: cadenceOffset,
            paceTolerance: paceTolerance,
            metronomeMinVolume: metronomeMinVolume,
            metronomeMaxVolume: metronomeMaxVolume,
            autoEndRun: autoEndRun
        )

        store.updateConfiguration(updated)
        dismiss()
    }

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

#Preview("Config Summary") {
    ConfigurationSummaryView(
        store: ConfigurationStore(),
        configuration: RunConfiguration(
            name: "5mi Easy",
            distance: Distance(miles: 5),
            targetPace: Pace(minutes: 10, seconds: 0)
        )
    )
}

// MARK: - Quick Create View

/// Draft for a single segment in the multi-segment builder
struct SegmentDraft: Identifiable {
    let id = UUID()
    var distance: Double?
    var pace: NamedPace?
    var cadenceOffset: Int = 0
    var paceTolerance: Int = 10
    var strideLengthOverride: Double?
    var paceCalibrationOverride: Int?
}

struct QuickCreateView: View {
    @ObservedObject var store: ConfigurationStore
    @EnvironmentObject var entitlementManager: EntitlementManager
    @Environment(\.dismiss) private var dismiss

    @State private var settings = AppSettings.load()

    @State private var selectedDistance: Double?
    @State private var selectedPace: NamedPace?
    @State private var nameOverride: String = ""
    @State private var isEditingName = false

    // Multi-segment state (initialized with one draft for Pro users in onAppear)
    @State private var segments: [SegmentDraft] = [SegmentDraft()]

    // Advanced overrides — when user changes distance/pace in advanced form
    @State private var distanceOverridden = false
    @State private var paceOverridden = false
    @State private var advancedDistanceMiles: Double = 5.0
    @State private var advancedPace: PaceInput = PaceInput(minutes: 10, seconds: 0)
    @State private var isProgressiveRun = false
    @State private var startPace: PaceInput = PaceInput(minutes: 9, seconds: 0)
    @State private var endPace: PaceInput = PaceInput(minutes: 7, seconds: 30)

    // Advanced settings
    @State private var cadenceOffset: Int = 0
    @State private var paceTolerance: Int = 10
    @State private var metronomeMinVolume: Float = 0.3
    @State private var metronomeMaxVolume: Float = 1.0
    @State private var autoEndRun: Bool = true
    @State private var strideLengthOverride: Double?
    @State private var paceCalibrationOverride: Int?

    // Inline add distance/pace
    @State private var showingAddDistance = false
    @State private var newDistanceText = ""
    @State private var showingAddPace = false
    @State private var newPaceName = ""
    @State private var newPaceMinutes = 9
    @State private var newPaceSeconds = 0

    /// The effective distance (advanced override wins)
    private var effectiveDistance: Double? {
        if distanceOverridden { return advancedDistanceMiles }
        return selectedDistance
    }

    /// The effective pace (advanced override wins)
    private var effectivePace: Pace? {
        if paceOverridden {
            if isProgressiveRun {
                return startPace.toPace()
            }
            return advancedPace.toPace()
        }
        return selectedPace?.pace
    }

    private var isMultiSegment: Bool {
        segments.count > 1
    }

    private var allSegmentsComplete: Bool {
        !segments.isEmpty && segments.allSatisfy { $0.distance != nil && $0.pace != nil }
    }

    private var derivedName: String {
        if entitlementManager.isPro && allSegmentsComplete {
            if isMultiSegment {
                let runSegments = segments.compactMap { draft -> RunSegment? in
                    guard let dist = draft.distance, let pace = draft.pace else { return nil }
                    return RunSegment(distance: Distance(miles: dist), pace: pace.pace, label: pace.name)
                }
                return AppSettings.derivedSegmentConfigName(segments: runSegments)
            } else if let first = segments.first, let dist = first.distance, let pace = first.pace {
                return AppSettings.derivedConfigName(distanceMiles: dist, paceName: pace.name)
            }
        }
        guard let dist = effectiveDistance else { return "" }
        if paceOverridden {
            let paceStr = effectivePace?.formatted ?? "--:--"
            return AppSettings.derivedConfigName(distanceMiles: dist, paceName: paceStr)
        }
        guard let pace = selectedPace else { return "" }
        return AppSettings.derivedConfigName(distanceMiles: dist, paceName: pace.name)
    }

    private var effectiveName: String {
        let trimmed = nameOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? derivedName : trimmed
    }

    private var canSave: Bool {
        if entitlementManager.isPro {
            return allSegmentsComplete
        }
        return effectiveDistance != nil && effectivePace != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if entitlementManager.isPro {
                    // Pro mode: always show segment-based UI
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        segmentSection(index: index)
                    }

                    // Add segment button
                    Section {
                        Button {
                            segments.append(SegmentDraft())
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Add Segment")
                            }
                        }
                    }
                } else {
                    // Non-Pro: single distance + pace selection (no segments)
                    Section {
                        if distanceOverridden {
                            HStack {
                                Text("Distance")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(formatQuickDistance(advancedDistanceMiles))
                                    .foregroundStyle(.secondary)
                                Text("(set in Advanced)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                            distanceGridContent(selectedDistance: selectedDistance) { dist in
                                selectedDistance = dist
                                advancedDistanceMiles = dist
                            }
                        }
                    } header: {
                        HStack {
                            Text("Distance")
                            if distanceOverridden {
                                Spacer()
                                Button("Reset") {
                                    distanceOverridden = false
                                }
                                .font(.caption)
                            }
                        }
                    }

                    Section {
                        if paceOverridden {
                            HStack {
                                Text("Pace")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if isProgressiveRun {
                                    Text("\(startPace.toPace()?.formatted ?? "--") → \(endPace.toPace()?.formatted ?? "--")/mi")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("\(advancedPace.toPace()?.formatted ?? "--:--")/mi")
                                        .foregroundStyle(.secondary)
                                }
                                Text("(set in Advanced)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                            paceGridContent(selectedPaceId: selectedPace?.id) { namedPace in
                                selectedPace = namedPace
                                advancedPace = PaceInput(from: namedPace.pace)
                            }
                        }
                    } header: {
                        HStack {
                            Text("Pace")
                            if paceOverridden {
                                Spacer()
                                Button("Reset") {
                                    paceOverridden = false
                                    isProgressiveRun = false
                                }
                                .font(.caption)
                            }
                        }
                    }
                }

                if canSave {
                    Section("Name") {
                        HStack {
                            if isEditingName {
                                TextField("Config name", text: $nameOverride)
                                    .autocorrectionDisabled()
                                Button {
                                    isEditingName = false
                                } label: {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            } else {
                                Text(effectiveName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Button {
                                    nameOverride = derivedName
                                    isEditingName = true
                                } label: {
                                    Image(systemName: "pencil")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        quickCreateAdvancedForm
                    } label: {
                        Text("Advanced")
                    }
                }
            }
            .navigationTitle("New Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { saveQuickConfig() }
                        .disabled(!canSave)
                }
            }
            .alert("Add Distance", isPresented: $showingAddDistance) {
                TextField("Miles", text: $newDistanceText)
                    .keyboardType(.decimalPad)
                Button("Add") { addDistanceFromInput() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Enter distance in miles")
            }
            .sheet(isPresented: $showingAddPace) {
                addPaceSheet
            }
        }
    }

    private var quickCreateAdvancedForm: some View {
        Form {
            Section("Distance") {
                Stepper(value: $advancedDistanceMiles, in: 0.25...100.0, step: 0.25) {
                    HStack {
                        Text("Distance")
                        Spacer()
                        Text(formatQuickDistance(advancedDistanceMiles))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .onChange(of: advancedDistanceMiles) { _, _ in
                    distanceOverridden = true
                }

                Picker("Preset", selection: $advancedDistanceMiles) {
                    Text("1 mile").tag(1.0)
                    Text("5K (3.1 mi)").tag(3.1)
                    Text("10K (6.2 mi)").tag(6.2)
                    Text("Half (13.1 mi)").tag(13.1)
                    Text("Marathon (26.2 mi)").tag(26.2)
                    Text("50K (31.1 mi)").tag(31.1)
                }
                .pickerStyle(.menu)
                .onChange(of: advancedDistanceMiles) { _, _ in
                    distanceOverridden = true
                }

                HStack {
                    Text("Custom")
                    Spacer()
                    TextField("miles", value: Binding(
                        get: { advancedDistanceMiles },
                        set: { advancedDistanceMiles = $0; distanceOverridden = true }
                    ), format: .number.precision(.fractionLength(2)))
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
                        paceOverridden = true
                    }

                if isProgressiveRun {
                    PacePickerView(title: "Starting Pace", pace: $startPace)
                        .onChange(of: startPace.minutes) { _, _ in paceOverridden = true }
                        .onChange(of: startPace.seconds) { _, _ in paceOverridden = true }
                    PacePickerView(title: "Ending Pace", pace: $endPace)
                        .onChange(of: endPace.minutes) { _, _ in paceOverridden = true }
                        .onChange(of: endPace.seconds) { _, _ in paceOverridden = true }
                } else {
                    PacePickerView(title: "Target Pace", pace: $advancedPace)
                        .onChange(of: advancedPace.minutes) { _, _ in paceOverridden = true }
                        .onChange(of: advancedPace.seconds) { _, _ in paceOverridden = true }
                }
            }

            Section("Settings") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Cadence Offset")
                        Spacer()
                        Text("\(cadenceOffset > 0 ? "+" : "")\(cadenceOffset) BPM")
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
                            if newValue > metronomeMaxVolume { metronomeMinVolume = metronomeMaxVolume }
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
                            if newValue < metronomeMinVolume { metronomeMaxVolume = metronomeMinVolume }
                        }
                }

                Text("Volume scales from min to max based on how far off pace you are")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Stride & Calibration") {
                Toggle("Override Stride Length", isOn: Binding(
                    get: { strideLengthOverride != nil },
                    set: { strideLengthOverride = $0 ? settings.strideLengthInches : nil }
                ))
                if let _ = strideLengthOverride {
                    Stepper(
                        "Stride: \(String(format: "%.1f", strideLengthOverride ?? settings.strideLengthInches))\"",
                        value: Binding(
                            get: { strideLengthOverride ?? settings.strideLengthInches },
                            set: { strideLengthOverride = $0 }
                        ),
                        in: 20.0...50.0,
                        step: 0.5
                    )
                } else {
                    HStack {
                        Text("Stride Length")
                        Spacer()
                        Text("\(String(format: "%.1f", settings.strideLengthInches))\" (global)")
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Override Pace Calibration", isOn: Binding(
                    get: { paceCalibrationOverride != nil },
                    set: { paceCalibrationOverride = $0 ? settings.paceCalibrationSeconds : nil }
                ))
                if let _ = paceCalibrationOverride {
                    Stepper(
                        "Calibration: \(paceCalibrationOverride.map { $0 > 0 ? "+\($0)" : "\($0)" } ?? "0")s",
                        value: Binding(
                            get: { paceCalibrationOverride ?? settings.paceCalibrationSeconds },
                            set: { paceCalibrationOverride = $0 }
                        ),
                        in: -15...15
                    )
                } else {
                    HStack {
                        Text("Pace Calibration")
                        Spacer()
                        let cal = settings.paceCalibrationSeconds
                        Text("\(cal > 0 ? "+" : "")\(cal)s (global)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Run Completion") {
                Toggle("Auto-end when distance reached", isOn: $autoEndRun)
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Reusable Grid Helpers

    private func distanceGridContent(selectedDistance: Double?, onSelect: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 10) {
                ForEach(settings.commonDistances, id: \.self) { distance in
                    Button {
                        onSelect(distance)
                    } label: {
                        Text(formatQuickDistance(distance))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(selectedDistance == distance ? Color.accentColor : Color(.systemGray5))
                            .foregroundStyle(selectedDistance == distance ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
                // "+" button
                Button {
                    newDistanceText = ""
                    showingAddDistance = true
                } label: {
                    Image(systemName: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.systemGray5))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        }
    }

    private func paceGridContent(selectedPaceId: UUID?, onSelect: @escaping (NamedPace) -> Void) -> some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 10) {
                ForEach(settings.namedPaces) { namedPace in
                    Button {
                        onSelect(namedPace)
                    } label: {
                        VStack(spacing: 2) {
                            Text(namedPace.name)
                                .font(.headline)
                            Text("\(namedPace.pace.formatted)/mi")
                                .font(.caption)
                                .foregroundStyle(selectedPaceId == namedPace.id ? .white.opacity(0.8) : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(selectedPaceId == namedPace.id ? Color.accentColor : Color(.systemGray5))
                        .foregroundStyle(selectedPaceId == namedPace.id ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
                // "+" button
                Button {
                    newPaceName = ""
                    newPaceMinutes = 9
                    newPaceSeconds = 0
                    showingAddPace = true
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "plus")
                            .font(.headline)
                        Text("")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray5))
                    .foregroundStyle(.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        }
    }

    private func addDistanceFromInput() {
        guard let miles = Double(newDistanceText), miles > 0 else { return }
        settings.commonDistances.append(miles)
        settings.save()
    }

    private func addPaceFromInput() {
        let trimmed = newPaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pace = Pace(minutes: newPaceMinutes, seconds: newPaceSeconds)
        settings.namedPaces.append(NamedPace(name: trimmed, pace: pace))
        settings.save()
    }

    private var addPaceSheet: some View {
        NavigationStack {
            Form {
                TextField("Pace Name", text: $newPaceName)
                    .autocorrectionDisabled()

                Picker("Minutes", selection: $newPaceMinutes) {
                    ForEach(4...20, id: \.self) { minute in
                        Text("\(minute) min").tag(minute)
                    }
                }

                Picker("Seconds", selection: $newPaceSeconds) {
                    ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { second in
                        Text(String(format: "%02d sec", second)).tag(second)
                    }
                }
            }
            .navigationTitle("New Pace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAddPace = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addPaceFromInput()
                        showingAddPace = false
                    }
                    .disabled(newPaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func segmentSection(index: Int) -> some View {
        Section {
            distanceGridContent(selectedDistance: segments[index].distance) { dist in
                segments[index].distance = dist
            }
            paceGridContent(selectedPaceId: segments[index].pace?.id) { namedPace in
                segments[index].pace = namedPace
            }
            NavigationLink {
                segmentAdvancedForm(index: index)
            } label: {
                HStack {
                    Text("Settings")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Offset \(segments[index].cadenceOffset > 0 ? "+" : "")\(segments[index].cadenceOffset), ±\(segments[index].paceTolerance)s")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            HStack {
                Text("Segment \(index + 1)")
                if segments.count > 1 {
                    Spacer()
                    Button(role: .destructive) {
                        segments.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func segmentAdvancedForm(index: Int) -> some View {
        let globalSettings = settings
        Form {
            Section("Cadence") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Cadence Offset")
                        Spacer()
                        Text("\(segments[index].cadenceOffset > 0 ? "+" : "")\(segments[index].cadenceOffset) BPM")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(segments[index].cadenceOffset) },
                        set: { segments[index].cadenceOffset = Int($0) }
                    ), in: -15...15, step: 1)
                }
            }

            Section("Pace Tolerance") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Tolerance")
                        Spacer()
                        Text("±\(segments[index].paceTolerance) sec")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(segments[index].paceTolerance) },
                        set: { segments[index].paceTolerance = Int($0) }
                    ), in: 5...30, step: 5)
                }
            }

            Section("Stride & Calibration") {
                Toggle("Override Stride Length", isOn: Binding(
                    get: { segments[index].strideLengthOverride != nil },
                    set: { segments[index].strideLengthOverride = $0 ? globalSettings.strideLengthInches : nil }
                ))
                if let _ = segments[index].strideLengthOverride {
                    Stepper(
                        "Stride: \(String(format: "%.1f", segments[index].strideLengthOverride ?? globalSettings.strideLengthInches))\"",
                        value: Binding(
                            get: { segments[index].strideLengthOverride ?? globalSettings.strideLengthInches },
                            set: { segments[index].strideLengthOverride = $0 }
                        ),
                        in: 20.0...50.0,
                        step: 0.5
                    )
                } else {
                    HStack {
                        Text("Stride Length")
                        Spacer()
                        Text("\(String(format: "%.1f", globalSettings.strideLengthInches))\" (global)")
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Override Pace Calibration", isOn: Binding(
                    get: { segments[index].paceCalibrationOverride != nil },
                    set: { segments[index].paceCalibrationOverride = $0 ? globalSettings.paceCalibrationSeconds : nil }
                ))
                if let _ = segments[index].paceCalibrationOverride {
                    Stepper(
                        "Calibration: \(segments[index].paceCalibrationOverride.map { $0 > 0 ? "+\($0)" : "\($0)" } ?? "0")s",
                        value: Binding(
                            get: { segments[index].paceCalibrationOverride ?? globalSettings.paceCalibrationSeconds },
                            set: { segments[index].paceCalibrationOverride = $0 }
                        ),
                        in: -15...15
                    )
                } else {
                    HStack {
                        Text("Pace Calibration")
                        Spacer()
                        let cal = globalSettings.paceCalibrationSeconds
                        Text("\(cal > 0 ? "+" : "")\(cal)s (global)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Segment \(index + 1) Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func saveQuickConfig() {
        let configName = effectiveName
        let isDefaultName = nameOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Pro segment-based path
        if entitlementManager.isPro && allSegmentsComplete {
            // Duplicate detection for derived names only
            if isDefaultName,
               store.configurations.contains(where: { $0.name == configName }) {
                dismiss()
                return
            }

            if isMultiSegment {
                // Multi-segment: create with segments
                let runSegments = segments.compactMap { draft -> RunSegment? in
                    guard let dist = draft.distance, let pace = draft.pace else { return nil }
                    return RunSegment(
                        distance: Distance(miles: dist),
                        pace: pace.pace,
                        label: pace.name,
                        cadenceOffset: draft.cadenceOffset,
                        paceTolerance: draft.paceTolerance,
                        strideLengthInches: draft.strideLengthOverride,
                        paceCalibrationSeconds: draft.paceCalibrationOverride
                    )
                }

                let configuration = RunConfiguration(
                    name: configName,
                    segments: runSegments,
                    cadenceOffset: cadenceOffset,
                    paceTolerance: paceTolerance,
                    metronomeMinVolume: metronomeMinVolume,
                    metronomeMaxVolume: metronomeMaxVolume,
                    autoEndRun: autoEndRun
                )

                store.createConfiguration(configuration)
                dismiss()
                return
            } else if let first = segments.first, let dist = first.distance, let pace = first.pace {
                // Single segment in Pro: create as normal config
                let configuration = RunConfiguration(
                    name: configName,
                    distance: Distance(miles: dist),
                    targetPace: pace.pace,
                    cadenceOffset: cadenceOffset,
                    paceTolerance: paceTolerance,
                    metronomeMinVolume: metronomeMinVolume,
                    metronomeMaxVolume: metronomeMaxVolume,
                    autoEndRun: autoEndRun,
                    strideLengthInches: first.strideLengthOverride,
                    paceCalibrationSeconds: first.paceCalibrationOverride
                )

                store.createConfiguration(configuration)
                dismiss()
                return
            }
        }

        // Non-Pro single-segment path
        guard let dist = effectiveDistance, let _ = effectivePace else { return }

        // Duplicate detection for derived names only
        if isDefaultName,
           store.configurations.contains(where: { $0.name == configName }) {
            dismiss()
            return
        }

        let distance = Distance(miles: dist)

        // Build mile paces
        let milePaces: [Pace]
        let mileCount = Int(ceil(dist))
        if paceOverridden && isProgressiveRun {
            guard let start = startPace.toPace(),
                  let end = endPace.toPace() else { return }
            milePaces = createProgressivePaces(from: start, to: end, mileCount: mileCount)
        } else if paceOverridden {
            guard let pace = advancedPace.toPace() else { return }
            milePaces = Array(repeating: pace, count: mileCount)
        } else if let pace = selectedPace {
            milePaces = Array(repeating: pace.pace, count: mileCount)
        } else {
            return
        }

        let configuration = RunConfiguration(
            name: configName,
            distance: distance,
            milePaces: milePaces,
            cadenceOffset: cadenceOffset,
            paceTolerance: paceTolerance,
            metronomeMinVolume: metronomeMinVolume,
            metronomeMaxVolume: metronomeMaxVolume,
            autoEndRun: autoEndRun,
            strideLengthInches: strideLengthOverride,
            paceCalibrationSeconds: paceCalibrationOverride
        )

        store.createConfiguration(configuration)
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

    private func formatQuickDistance(_ miles: Double) -> String {
        if miles == miles.rounded() {
            return String(format: "%.0f mi", miles)
        } else {
            return String(format: "%.1f mi", miles)
        }
    }
}

#Preview("Quick Create") {
    QuickCreateView(store: ConfigurationStore())
        .environmentObject(EntitlementManager())
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
