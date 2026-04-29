import Foundation
import Observation
import StoreKit

nonisolated enum ProSubscriptionConfiguration {
    static let monthlyProductID = "0001"
    static let yearlyProductID = "0002"
    static let productIDs: Set<String> = [monthlyProductID, yearlyProductID]
    static let productIDOrder = [monthlyProductID, yearlyProductID]
    static let isProDefaultsKey = "subscription.pro.isActive"
    static let standardRefreshWorkerLimit = 2
    static let proRefreshWorkerLimit = 10
    static let standardHangarLogEntryLimit = 5
    static let proHangarLogEntryLimit = 500

    static var storedIsPro: Bool {
        UserDefaults.standard.bool(forKey: isProDefaultsKey)
    }

    static func refreshWorkerLimit(isPro: Bool) -> Int {
        isPro ? proRefreshWorkerLimit : standardRefreshWorkerLimit
    }

    static func hangarLogEntryLimit(isPro: Bool) -> Int {
        isPro ? proHangarLogEntryLimit : standardHangarLogEntryLimit
    }

    static func constrainedRefreshWorkerCount(_ count: Int, isPro: Bool) -> Int {
        min(max(count, 1), refreshWorkerLimit(isPro: isPro))
    }
}

@MainActor
@Observable
final class SubscriptionStore {
    enum PurchaseStatus: Equatable {
        case idle
        case purchasing
        case restoring
        case success(String)
        case failed(String)
    }

    private let productIDs: Set<String>
    private let userDefaults: UserDefaults
    private let storeKitEnabled: Bool
    @ObservationIgnored private var transactionUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false

    var products: [Product] = []
    var purchasedProductIDs: Set<String>
    var isLoadingProducts = false
    var productLoadErrorMessage: String?
    var purchaseStatus: PurchaseStatus = .idle

    init(
        productIDs: Set<String> = ProSubscriptionConfiguration.productIDs,
        userDefaults: UserDefaults = .standard,
        storeKitEnabled: Bool = true
    ) {
        self.productIDs = productIDs
        self.userDefaults = userDefaults
        self.storeKitEnabled = storeKitEnabled
        purchasedProductIDs = userDefaults.bool(forKey: ProSubscriptionConfiguration.isProDefaultsKey)
            ? productIDs
            : []
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    var isPro: Bool {
        !purchasedProductIDs.isDisjoint(with: productIDs)
    }

    var proProducts: [Product] {
        products.filter { productIDs.contains($0.id) }
    }

    var proPriceLabel: String {
        proProducts.first?.displayPrice ?? AppLocalizer.string("Price unavailable")
    }

    func start() async {
        guard storeKitEnabled else {
            publishPurchasedProductIDs([])
            return
        }

        guard !didStart else {
            await refreshPurchasedProducts()
            return
        }

        didStart = true
        observeTransactionUpdates()
        await refreshPurchasedProducts()
        await loadProducts()
    }

    func loadProducts() async {
        guard storeKitEnabled else {
            products = []
            productLoadErrorMessage = nil
            return
        }

        isLoadingProducts = true
        productLoadErrorMessage = nil
        defer { isLoadingProducts = false }

        do {
            products = try await Product.products(for: Array(productIDs)).sorted { lhs, rhs in
                sortIndex(for: lhs.id) < sortIndex(for: rhs.id)
            }

            if products.isEmpty {
                productLoadErrorMessage = AppLocalizer.string("The App Store did not return Pro products 0001 or 0002 yet.")
            }
        } catch {
            productLoadErrorMessage = error.localizedDescription
        }
    }

    func purchasePro(productID: String? = nil) async {
        guard storeKitEnabled else {
            return
        }

        purchaseStatus = .purchasing

        do {
            let product = try await resolvedProProduct(productID: productID)
            let result = try await product.purchase()

            switch result {
            case let .success(verificationResult):
                let transaction = try checkVerified(verificationResult)
                await transaction.finish()
                await refreshPurchasedProducts()
                purchaseStatus = .success(AppLocalizer.string("Pro is active."))
            case .userCancelled:
                purchaseStatus = .idle
            case .pending:
                purchaseStatus = .success(AppLocalizer.string("The purchase is pending approval."))
            @unknown default:
                purchaseStatus = .idle
            }
        } catch {
            purchaseStatus = .failed(error.localizedDescription)
        }
    }

    func restorePurchases() async {
        guard storeKitEnabled else {
            return
        }

        purchaseStatus = .restoring

        do {
            try await AppStore.sync()
            await refreshPurchasedProducts()
            purchaseStatus = isPro
                ? .success(AppLocalizer.string("Pro purchase restored."))
                : .failed(AppLocalizer.string("No active Pro purchase was found."))
        } catch {
            purchaseStatus = .failed(error.localizedDescription)
        }
    }

    func refreshPurchasedProducts() async {
        guard storeKitEnabled else {
            publishPurchasedProductIDs([])
            return
        }

        var activeProductIDs = Set<String>()

        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result),
                  productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  !transaction.isUpgraded else {
                continue
            }

            activeProductIDs.insert(transaction.productID)
        }

        publishPurchasedProductIDs(activeProductIDs)
    }

    private func observeTransactionUpdates() {
        transactionUpdatesTask?.cancel()
        transactionUpdatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else {
                    return
                }

                do {
                    let transaction = try await MainActor.run {
                        try self.checkVerified(result)
                    }
                    await transaction.finish()
                    await self.refreshPurchasedProducts()
                } catch {
                    await MainActor.run {
                        self.purchaseStatus = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func resolvedProProduct(productID: String?) async throws -> Product {
        if let productID, let product = products.first(where: { $0.id == productID }) {
            return product
        }

        if productID == nil, let product = proProducts.first {
            return product
        }

        await loadProducts()

        if let productID, let product = products.first(where: { $0.id == productID }) {
            return product
        }

        if productID == nil, let product = proProducts.first {
            return product
        }

        throw SubscriptionStoreError.productUnavailable
    }

    private func publishPurchasedProductIDs(_ productIDs: Set<String>) {
        purchasedProductIDs = productIDs
        userDefaults.set(isPro, forKey: ProSubscriptionConfiguration.isProDefaultsKey)
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case let .verified(safe):
            return safe
        case .unverified:
            throw SubscriptionStoreError.failedVerification
        }
    }

    private func sortIndex(for productID: String) -> Int {
        ProSubscriptionConfiguration.productIDOrder.firstIndex(of: productID) ?? Int.max
    }
}

private enum SubscriptionStoreError: LocalizedError {
    case productUnavailable
    case failedVerification

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            return AppLocalizer.string("The App Store did not return Pro products 0001 or 0002 yet. Check both product IDs, prices, localizations, subscription status, Paid Apps agreement, and bundle ID in App Store Connect.")
        case .failedVerification:
            return AppLocalizer.string("The App Store could not verify this purchase.")
        }
    }
}
