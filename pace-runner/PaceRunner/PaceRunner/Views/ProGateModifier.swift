import SwiftUI
import PaceRunnerShared

/// View modifier that gates content behind Pro entitlement.
/// Disables content, adds lock icon, and shows ProUpgradeSheet on tap.
///
/// Not used yet (no features to gate), but ready for Phase 2.
struct ProGateModifier: ViewModifier {
    let featureName: String
    @ObservedObject var entitlementManager: EntitlementManager
    @State private var showingUpgradeSheet = false

    func body(content: Content) -> some View {
        if entitlementManager.isPro {
            content
        } else {
            content
                .disabled(true)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    showingUpgradeSheet = true
                }
                .sheet(isPresented: $showingUpgradeSheet) {
                    ProUpgradeSheet()
                        .environmentObject(entitlementManager)
                }
        }
    }
}

extension View {
    func proGated(featureName: String, entitlementManager: EntitlementManager) -> some View {
        modifier(ProGateModifier(featureName: featureName, entitlementManager: entitlementManager))
    }
}
