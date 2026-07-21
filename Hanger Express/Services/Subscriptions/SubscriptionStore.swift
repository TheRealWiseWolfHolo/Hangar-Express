import Foundation
import Observation
import StoreKit
import UIKit

nonisolated enum ProSubscriptionConfiguration {
    static let monthlyProductID = "0001"
    static let yearlyProductID = "0002"
    static let lifetimeProductID = "HangarExpLTI"
    static let subscriptionProductIDs: Set<String> = [monthlyProductID, yearlyProductID]
    static let productIDs: Set<String> = [monthlyProductID, yearlyProductID, lifetimeProductID]
    static let productIDOrder = [monthlyProductID, yearlyProductID, lifetimeProductID]
    static let isProDefaultsKey = "subscription.pro.isActive"
    static let activeProductIDsDefaultsKey = "subscription.pro.activeProductIDs"
    static let standardRefreshWorkerLimit = 2
    static let proRefreshWorkerLimit = 10
    static let standardHangarLogEntryLimit = 5
    static let proHangarLogEntryLimit = 500
    static let standardSavedAccountLimit = 1
    static let proSavedAccountLimit = 10

    static var storedIsPro: Bool {
        UserDefaults.standard.bool(forKey: isProDefaultsKey)
    }

    static func refreshWorkerLimit(isPro: Bool) -> Int {
        isPro ? proRefreshWorkerLimit : standardRefreshWorkerLimit
    }

    static func hangarLogEntryLimit(isPro: Bool) -> Int {
        isPro ? proHangarLogEntryLimit : standardHangarLogEntryLimit
    }

    static func savedAccountLimit(isPro: Bool) -> Int {
        isPro ? proSavedAccountLimit : standardSavedAccountLimit
    }

    static func constrainedRefreshWorkerCount(_ count: Int, isPro: Bool) -> Int {
        min(max(count, 1), refreshWorkerLimit(isPro: isPro))
    }

    static func isLifetimeProductID(_ productID: String) -> Bool {
        productID == lifetimeProductID
    }

    static func isSubscriptionProductID(_ productID: String) -> Bool {
        subscriptionProductIDs.contains(productID)
    }

    static func allowsPurchasing(_ productID: String, withActiveProductIDs activeProductIDs: Set<String>) -> Bool {
        guard productIDs.contains(productID) else {
            return false
        }

        if activeProductIDs.contains(lifetimeProductID) {
            return false
        }

        if isLifetimeProductID(productID), !activeProductIDs.isDisjoint(with: subscriptionProductIDs) {
            return false
        }

        return !activeProductIDs.contains(productID)
    }
}

nonisolated struct ProSubscriptionDetails: Equatable {
    let productID: String
    let displayName: String
    let nextRenewalDate: Date?
    let expirationDate: Date?
    let willAutoRenew: Bool?

    var isLifetime: Bool {
        ProSubscriptionConfiguration.isLifetimeProductID(productID)
    }
}

@MainActor
@Observable
final class SubscriptionStore {
    enum PurchaseStatus: Equatable {
        case idle
        case purchasing
        case restoring
        case managing
        case redeeming
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
    var proSubscriptionDetails: ProSubscriptionDetails?
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
        let storedProductIDs = Set(userDefaults.stringArray(forKey: ProSubscriptionConfiguration.activeProductIDsDefaultsKey) ?? [])
            .intersection(productIDs)
        let resolvedPurchasedProductIDs: Set<String>
        if !storedProductIDs.isEmpty {
            resolvedPurchasedProductIDs = storedProductIDs
        } else if userDefaults.bool(forKey: ProSubscriptionConfiguration.isProDefaultsKey) {
            resolvedPurchasedProductIDs = Set([ProSubscriptionConfiguration.monthlyProductID]).intersection(productIDs)
        } else {
            resolvedPurchasedProductIDs = []
        }
        purchasedProductIDs = resolvedPurchasedProductIDs
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    var isPro: Bool {
        !purchasedProductIDs.isDisjoint(with: productIDs)
    }

    var hasLifetimePro: Bool {
        purchasedProductIDs.contains(ProSubscriptionConfiguration.lifetimeProductID)
    }

    var hasActiveProSubscription: Bool {
        !purchasedProductIDs.isDisjoint(with: ProSubscriptionConfiguration.subscriptionProductIDs)
    }

    var proProducts: [Product] {
        products.filter { productIDs.contains($0.id) }
    }

    func start() async {
        guard storeKitEnabled else {
            publishPurchasedProductIDs([], details: nil)
            return
        }

        guard !didStart else {
            if products.isEmpty {
                await loadProducts()
            }
            await refreshPurchasedProducts()
            return
        }

        didStart = true
        observeTransactionUpdates()
        await loadProducts()
        await refreshPurchasedProducts()
    }

    func loadProducts() async {
        guard storeKitEnabled else {
            products = []
            productLoadErrorMessage = nil
            return
        }

        guard !isLoadingProducts else {
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
                productLoadErrorMessage = AppLocalizer.string("The App Store did not return Early Access products 0001, 0002, or HangarExpLTI yet.")
            }

            if !purchasedProductIDs.isEmpty {
                await refreshProSubscriptionDetails(activeProductIDs: purchasedProductIDs, fallbackTransaction: nil)
            }
        } catch {
            productLoadErrorMessage = error.localizedDescription
        }
    }

    func purchasePro(productID: String? = nil) async {
        guard storeKitEnabled else {
            return
        }

        await refreshPurchasedProducts()

        do {
            let product = try await resolvedProProduct(productID: productID)

            guard ProSubscriptionConfiguration.allowsPurchasing(product.id, withActiveProductIDs: purchasedProductIDs) else {
                purchaseStatus = .failed(unavailablePurchaseMessage(for: product.id))
                return
            }

            purchaseStatus = .purchasing
            let result = try await product.purchase()

            switch result {
            case let .success(verificationResult):
                let transaction = try checkVerified(verificationResult)
                await transaction.finish()
                await refreshPurchasedProducts()
                purchaseStatus = .success(AppLocalizer.string("Early Access is active."))
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
                ? .success(AppLocalizer.string("Early Access purchase restored."))
                : .failed(AppLocalizer.string("No active Early Access purchase was found."))
        } catch {
            purchaseStatus = .failed(error.localizedDescription)
        }
    }

    func manageSubscriptions(in scene: UIWindowScene?) async {
        guard storeKitEnabled else {
            return
        }

        guard let scene else {
            purchaseStatus = .failed(AppLocalizer.string("Hangar Express could not open Apple subscription management from this screen."))
            return
        }

        purchaseStatus = .managing

        do {
            try await AppStore.showManageSubscriptions(in: scene)
            await refreshPurchasedProducts()
            purchaseStatus = .idle
        } catch {
            purchaseStatus = .failed(error.localizedDescription)
        }
    }

    func redeemCode(in scene: UIWindowScene?) async {
        guard storeKitEnabled else {
            return
        }

        guard !hasLifetimePro else {
            purchaseStatus = .failed(AppLocalizer.string("Early Access for Life is already active. Other Early Access purchases are unavailable."))
            return
        }

        guard let scene else {
            purchaseStatus = .failed(AppLocalizer.string("Hangar Express could not open StoreKit code redemption from this screen."))
            return
        }

        let wasPro = isPro
        purchaseStatus = .redeeming

        do {
            try await AppStore.presentOfferCodeRedeemSheet(in: scene)
            await refreshPurchasedProducts()
            purchaseStatus = !wasPro && isPro
                ? .success(AppLocalizer.string("Early Access code redeemed."))
                : .idle
        } catch {
            purchaseStatus = .failed(error.localizedDescription)
        }
    }

    func refreshPurchasedProducts() async {
        guard storeKitEnabled else {
            publishPurchasedProductIDs([], details: nil)
            return
        }

        var activeProductIDs = Set<String>()
        var latestActiveTransaction: Transaction?
        var lifetimeTransaction: Transaction?

        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result),
                  productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  !transaction.isUpgraded else {
                continue
            }

            activeProductIDs.insert(transaction.productID)

            if ProSubscriptionConfiguration.isLifetimeProductID(transaction.productID) {
                lifetimeTransaction = latestTransaction(between: lifetimeTransaction, and: transaction)
            } else {
                latestActiveTransaction = latestTransaction(between: latestActiveTransaction, and: transaction)
            }
        }

        let details = await resolvedProSubscriptionDetails(
            activeProductIDs: activeProductIDs,
            fallbackTransaction: lifetimeTransaction ?? latestActiveTransaction
        )
        publishPurchasedProductIDs(activeProductIDs, details: details)
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

    private func publishPurchasedProductIDs(_ productIDs: Set<String>, details: ProSubscriptionDetails?) {
        purchasedProductIDs = productIDs
        proSubscriptionDetails = details
        userDefaults.set(isPro, forKey: ProSubscriptionConfiguration.isProDefaultsKey)
        userDefaults.set(
            ProSubscriptionConfiguration.productIDOrder.filter { productIDs.contains($0) },
            forKey: ProSubscriptionConfiguration.activeProductIDsDefaultsKey
        )
    }

    private func unavailablePurchaseMessage(for productID: String) -> String {
        if hasLifetimePro {
            return AppLocalizer.string("Early Access for Life is already active. Other Early Access purchases are unavailable.")
        }

        if ProSubscriptionConfiguration.isLifetimeProductID(productID), hasActiveProSubscription {
            return AppLocalizer.string("Early Access for Life can be purchased after your current Early Access subscription ends.")
        }

        return AppLocalizer.string("This Early Access plan is already active.")
    }

    private func refreshProSubscriptionDetails(
        activeProductIDs: Set<String>,
        fallbackTransaction: Transaction?
    ) async {
        proSubscriptionDetails = await resolvedProSubscriptionDetails(
            activeProductIDs: activeProductIDs,
            fallbackTransaction: fallbackTransaction
        )
    }

    private func resolvedProSubscriptionDetails(
        activeProductIDs: Set<String>,
        fallbackTransaction: Transaction?
    ) async -> ProSubscriptionDetails? {
        guard !activeProductIDs.isEmpty else {
            return nil
        }

        var fallbackDetails = fallbackTransaction.map { transaction in
            makeSubscriptionDetails(
                productID: transaction.productID,
                nextRenewalDate: transaction.expirationDate,
                expirationDate: transaction.expirationDate,
                willAutoRenew: nil
            )
        }

        if fallbackDetails?.isLifetime == true {
            return fallbackDetails
        }

        guard let subscription = proProducts.compactMap(\.subscription).first else {
            return fallbackDetails
        }

        do {
            let statuses = try await subscription.status
            let statusDetails = statuses.compactMap { status -> ProSubscriptionDetails? in
                guard status.state == .subscribed
                    || status.state == .inGracePeriod
                    || status.state == .inBillingRetryPeriod else {
                    return nil
                }

                guard let transaction = try? checkVerified(status.transaction),
                      activeProductIDs.contains(transaction.productID) else {
                    return nil
                }

                let renewalInfo = try? checkVerified(status.renewalInfo)
                return makeSubscriptionDetails(
                    productID: transaction.productID,
                    nextRenewalDate: renewalInfo?.renewalDate ?? transaction.expirationDate,
                    expirationDate: transaction.expirationDate,
                    willAutoRenew: renewalInfo?.willAutoRenew
                )
            }

            fallbackDetails = statusDetails.max { lhs, rhs in
                subscriptionSortDate(lhs) < subscriptionSortDate(rhs)
            } ?? fallbackDetails
        } catch {
            productLoadErrorMessage = error.localizedDescription
        }

        return fallbackDetails
    }

    private func makeSubscriptionDetails(
        productID: String,
        nextRenewalDate: Date?,
        expirationDate: Date?,
        willAutoRenew: Bool?
    ) -> ProSubscriptionDetails {
        ProSubscriptionDetails(
            productID: productID,
            displayName: productDisplayName(for: productID),
            nextRenewalDate: nextRenewalDate,
            expirationDate: expirationDate,
            willAutoRenew: willAutoRenew
        )
    }

    private func productDisplayName(for productID: String) -> String {
        products.first(where: { $0.id == productID })?.displayName ?? planFallbackName(for: productID)
    }

    private func planFallbackName(for productID: String) -> String {
        switch productID {
        case ProSubscriptionConfiguration.monthlyProductID:
            return AppLocalizer.string("Monthly Early Access")
        case ProSubscriptionConfiguration.yearlyProductID:
            return AppLocalizer.string("Yearly Early Access")
        case ProSubscriptionConfiguration.lifetimeProductID:
            return AppLocalizer.string("Early Access for Life")
        default:
            return AppLocalizer.string("Hangar Express Early Access")
        }
    }

    private func latestTransaction(between lhs: Transaction?, and rhs: Transaction) -> Transaction {
        guard let lhs else {
            return rhs
        }

        let lhsDate = lhs.expirationDate ?? lhs.purchaseDate
        let rhsDate = rhs.expirationDate ?? rhs.purchaseDate
        return rhsDate > lhsDate ? rhs : lhs
    }

    private func subscriptionSortDate(_ details: ProSubscriptionDetails) -> Date {
        details.expirationDate ?? details.nextRenewalDate ?? .distantPast
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
            return AppLocalizer.string("The App Store did not return Early Access products 0001, 0002, or HangarExpLTI yet. Check the product IDs, prices, localizations, product status, Paid Apps agreement, and bundle ID in App Store Connect.")
        case .failedVerification:
            return AppLocalizer.string("The App Store could not verify this purchase.")
        }
    }
}
