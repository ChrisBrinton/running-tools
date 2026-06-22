import Foundation
import Combine

/// Purchase state for entitlement operations
public enum EntitlementPurchaseState: Equatable {
    case idle
    case purchasing
    case restoring
    case failed(String)
}

/// Protocol for managing Pro entitlements via StoreKit 2
///
/// Handles:
/// - Checking Pro unlock status
/// - Purchasing Pro upgrade (one-time, non-consumable)
/// - Restoring purchases
/// - Listening for transaction updates (refunds, family sharing)
///
/// Constitution: Non-blocking, cached for instant startup
@MainActor
public protocol EntitlementManagerProtocol: ObservableObject {
    /// Whether the user has unlocked Pro
    var isPro: Bool { get }

    /// Current purchase operation state
    var purchaseState: EntitlementPurchaseState { get }

    /// Purchase Pro upgrade
    func purchasePro() async

    /// Restore previous purchases
    func restorePurchases() async

    /// Refresh entitlements from StoreKit
    func refreshEntitlements() async
}
