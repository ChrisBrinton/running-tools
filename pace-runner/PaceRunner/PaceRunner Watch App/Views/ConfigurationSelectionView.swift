import SwiftUI
import PaceRunnerShared

struct ConfigurationSelectionView: View {
    @ObservedObject var store: ConfigurationStore

    var body: some View {
        List(store.configurations, id: \.id) { config in
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
        .navigationTitle("Workouts")
    }
}
