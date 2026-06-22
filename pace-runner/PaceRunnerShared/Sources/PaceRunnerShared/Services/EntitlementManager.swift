import Foundation
import StoreKit
import Combine

/// StoreKit 2 entitlement manager for PaceRunner Pro
///
/// Manages a single non-consumable IAP product that unlocks Pro features.
/// Caches entitlement state in UserDefaults for instant startup reads.
/// Listens for Transaction.updates to handle refunds and family sharing changes.
///
/// Product ID: com.brintontech.pacerunner.pro
@MainActor
public final class EntitlementManager: ObservableObject, EntitlementManagerProtocol {

    // MARK: - Published Properties

    @Published public private(set) var isPro: Bool {
        didSet {
            UserDefaults.standard.set(isPro, forKey: Self.cacheKey)
        }
    }

    @Published public private(set) var purchaseState: EntitlementPurchaseState = .idle

    // MARK: - Constants

    public static let productID = "com.brintontech.pacerunner.pro"
    private static let cacheKey = "entitlement_is_pro"
    private static let debugOverrideKey = "entitlement_debug_override"
    private let loggerPrefix = "[EntitlementManager]"

    // MARK: - Private Properties

    private var transactionListener: Task<Void, Never>?
    private var product: Product?

    /// When true, `refreshEntitlements` is skipped so the debug value sticks
    private var isDebugOverride: Bool

    // MARK: - Initialization

    public init() {
        // Check if debug override is active
        self.isDebugOverride = UserDefaults.standard.bool(forKey: Self.debugOverrideKey)

        // Read cached value for instant startup
        self.isPro = UserDefaults.standard.bool(forKey: Self.cacheKey)

        // Start listening for transaction updates
        transactionListener = listenForTransactions()

        // Refresh entitlements from StoreKit on launch (skip if debug override)
        Task {
            if !isDebugOverride {
                await refreshEntitlements()
            }
            await loadProduct()
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Debug

    /// Debug override for Pro status (used in Settings → Debug section)
    /// Persists via UserDefaults so it survives app restarts and works on Watch too
    public func debugSetPro(_ value: Bool) {
        isDebugOverride = value
        UserDefaults.standard.set(value, forKey: Self.debugOverrideKey)
        isPro = value
    }

    // MARK: - Public Methods

    public func purchasePro() async {
        guard let product = product else {
            print("\(loggerPrefix) purchasePro: product not loaded")
            purchaseState = .failed("Product not available")
            return
        }

        purchaseState = .purchasing

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                isPro = true
                purchaseState = .idle
                print("\(loggerPrefix) purchasePro: success")

            case .userCancelled:
                purchaseState = .idle
                print("\(loggerPrefix) purchasePro: user cancelled")

            case .pending:
                purchaseState = .idle
                print("\(loggerPrefix) purchasePro: pending (ask to buy)")

            @unknown default:
                purchaseState = .idle
            }
        } catch {
            print("\(loggerPrefix) purchasePro: failed - \(error)")
            purchaseState = .failed(error.localizedDescription)
        }
    }

    public func restorePurchases() async {
        purchaseState = .restoring
        print("\(loggerPrefix) restorePurchases: starting")

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            purchaseState = .idle
            print("\(loggerPrefix) restorePurchases: complete, isPro=\(isPro)")
        } catch {
            print("\(loggerPrefix) restorePurchases: failed - \(error)")
            purchaseState = .failed(error.localizedDescription)
        }
    }

    public func refreshEntitlements() async {
        // Don't override debug setting
        guard !isDebugOverride else {
            print("\(loggerPrefix) refreshEntitlements: skipped (debug override active, isPro=\(isPro))")
            return
        }

        var foundPro = false

        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result),
               transaction.productID == Self.productID {
                foundPro = true
                break
            }
        }

        isPro = foundPro
        print("\(loggerPrefix) refreshEntitlements: isPro=\(isPro)")
    }

    // MARK: - Private Methods

    private func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.productID])
            product = products.first
            print("\(loggerPrefix) loadProduct: \(product != nil ? "loaded" : "not found")")
        } catch {
            print("\(loggerPrefix) loadProduct: failed - \(error)")
        }
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self = self else { return }
                if let transaction = try? await self.checkVerified(result) {
                    if transaction.productID == Self.productID {
                        let isRevoked = transaction.revocationDate != nil
                        await MainActor.run {
                            self.isPro = !isRevoked
                        }
                        await transaction.finish()
                        print("[EntitlementManager] transactionUpdate: isPro=\(!isRevoked)")
                    }
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }
}
