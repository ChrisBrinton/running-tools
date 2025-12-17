import SwiftUI
import PaceRunnerShared

struct ConfigurationSelectionView: View {
    @ObservedObject var store: ConfigurationStore
    @State private var showingVolumeTest = false

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

            // Volume test button (debug)
            Section {
                NavigationLink(destination: VolumeTestView()) {
                    HStack {
                        Image(systemName: "speaker.wave.3")
                            .foregroundColor(.orange)
                        Text("Volume Test")
                    }
                }
            }
        }
        .navigationTitle("Workouts")
    }
}
