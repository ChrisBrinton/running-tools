import SwiftUI
import PaceRunnerShared

struct ProUpgradeSheet: View {
    @EnvironmentObject var entitlementManager: EntitlementManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.yellow)

                    Text("PaceRunner Pro")
                        .font(.largeTitle.bold())

                    Text("Unlock advanced features")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                // Feature list
                VStack(alignment: .leading, spacing: 16) {
                    featureRow(icon: "arrow.triangle.branch", title: "Multi-Segment Runs", description: "Create runs with varying pace targets per segment")
                    featureRow(icon: "waveform.path.ecg", title: "Advanced Pace Algorithms", description: "PID-tuned pace control for smoother guidance")
                    featureRow(icon: "speaker.wave.3.fill", title: "Dynamic Audio", description: "Polyrhythm profiles and BPM modulation")
                }
                .padding(.horizontal)

                Spacer()

                // Purchase actions
                VStack(spacing: 12) {
                    if case .failed(let message) = entitlementManager.purchaseState {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task { await entitlementManager.purchasePro() }
                    } label: {
                        Group {
                            if entitlementManager.purchaseState == .purchasing {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Upgrade to Pro")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(entitlementManager.purchaseState == .purchasing || entitlementManager.purchaseState == .restoring)

                    Button {
                        Task { await entitlementManager.restorePurchases() }
                    } label: {
                        if entitlementManager.purchaseState == .restoring {
                            ProgressView()
                        } else {
                            Text("Restore Purchase")
                                .font(.subheadline)
                        }
                    }
                    .disabled(entitlementManager.purchaseState == .purchasing || entitlementManager.purchaseState == .restoring)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onChange(of: entitlementManager.isPro) { _, isPro in
                if isPro { dismiss() }
            }
        }
    }

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
