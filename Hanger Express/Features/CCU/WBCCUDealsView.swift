import Foundation
import SwiftUI

struct WBCCUDealsView: View {
    let appModel: AppModel
    let reloadToken: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var loadState: WBCCUDealsLoadState = .loading
    @State private var isRefreshing = false
    @State private var refreshErrorMessage: String?
    @State private var cartItems: [String: WBCCUCheckoutItem] = [:]
    @State private var sourcePickerDeal: WBCCUDeal?
    @State private var checkoutContext: RSICheckoutContext?
    @State private var checkoutErrorMessage: String?
    @State private var isPreparingCheckout = false

    var body: some View {
        NavigationStack {
            Group {
                switch loadState {
                case .loading:
                    ProgressView("Loading WBCCU deals...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(message):
                    ContentUnavailableView {
                        Label("Unable to Load Deals", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") {
                            Task { await loadDeals(forceRefresh: true) }
                        }
                    }
                case let .loaded(deals, generatedAt):
                    dealsContent(deals: deals, generatedAt: generatedAt)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("WBCCU Deals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await loadDeals(forceRefresh: true) }
                    } label: {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshing || isPreparingCheckout)
                    .accessibilityLabel(AppLocalizer.string("Refresh WBCCU deals"))
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadDeals(forceRefresh: true)
            }
            .alert("Unable to Refresh Deals", isPresented: refreshErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(refreshErrorMessage ?? "")
            }
            .alert("WBCCU Checkout Failed", isPresented: checkoutErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(checkoutErrorMessage ?? "")
            }
            .sheet(item: $sourcePickerDeal) { deal in
                WBCCUSourceShipPicker(
                    deal: deal,
                    selectedSourceShipID: cartItems[deal.id]?.sourceShipID
                ) { sourceShip in
                    addToCart(deal: deal, sourceShip: sourceShip)
                    sourcePickerDeal = nil
                }
            }
            .sheet(item: $checkoutContext) { context in
                RSICheckoutBrowserView(
                    context: context,
                    onCancel: { cookies in
                        checkoutContext = nil
                        persistCheckoutCookies(cookies, clearCart: false)
                    },
                    onFinished: { cookies in
                        checkoutContext = nil
                        persistCheckoutCookies(cookies, clearCart: true)
                    },
                    onSucceeded: { cookies, _ in
                        checkoutContext = nil
                        persistCheckoutCookies(cookies, clearCart: true)
                    }
                )
            }
        }
    }

    private var refreshErrorBinding: Binding<Bool> {
        Binding {
            refreshErrorMessage != nil
        } set: { isPresented in
            if !isPresented {
                refreshErrorMessage = nil
            }
        }
    }

    private var checkoutErrorBinding: Binding<Bool> {
        Binding {
            checkoutErrorMessage != nil
        } set: { isPresented in
            if !isPresented {
                checkoutErrorMessage = nil
            }
        }
    }

    @ViewBuilder
    private func dealsContent(deals: [WBCCUDeal], generatedAt: Date?) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if deals.isEmpty {
                    ContentUnavailableView(
                        "No WBCCU Deals",
                        systemImage: "tag.slash",
                        description: Text("StarCitizen-Info is not reporting any available Warbond CCU offers right now.")
                    )
                    .padding(.vertical, 44)
                } else {
                    ForEach(deals) { deal in
                        WBCCUDealCard(
                            deal: deal,
                            reloadToken: reloadToken,
                            cartItem: cartItems[deal.id],
                            onChooseSource: { sourcePickerDeal = deal },
                            onRemoveFromCart: { cartItems[deal.id] = nil }
                        )
                    }
                }

                WBCCUDealsTimestampFooter(generatedAt: generatedAt)
            }
            .padding(16)
        }
        .refreshable {
            await loadDeals(forceRefresh: true)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !cartItems.isEmpty {
                WBCCUCheckoutBar(
                    cartItems: Array(cartItems.values),
                    isPreparingCheckout: isPreparingCheckout,
                    onClearCart: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            cartItems.removeAll()
                        }
                    },
                    onCheckout: {
                        Task { await prepareCheckout() }
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func addToCart(deal: WBCCUDeal, sourceShip: RSIShipCatalog.Ship) {
        guard
            let sourceMSRP = sourceShip.msrpUSD,
            let targetShipID = deal.targetShipID,
            let targetSkuID = deal.offer.skuID
        else {
            return
        }

        let item = WBCCUCheckoutItem(
            offerID: deal.id,
            sourceShipID: sourceShip.id,
            sourceShipName: sourceShip.name,
            sourceShipMSRPUSD: sourceMSRP,
            targetShipID: targetShipID,
            targetShipName: deal.targetName,
            targetSkuID: targetSkuID,
            targetWarbondValueUSD: deal.offer.priceUSD
        )
        guard item.isValid else {
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            cartItems[deal.id] = item
        }
    }

    @MainActor
    private func prepareCheckout() async {
        guard !isPreparingCheckout else {
            return
        }

        let items = cartItems.values.sorted {
            $0.targetShipName.localizedCaseInsensitiveCompare($1.targetShipName) == .orderedAscending
        }
        guard !items.isEmpty else {
            return
        }

        isPreparingCheckout = true
        defer { isPreparingCheckout = false }

        do {
            let preparation = try await appModel.prepareWBCCUCheckout(items: items)
            let cookies = RSISessionCookieSet.merging(
                savedCookies: appModel.session?.cookies ?? [],
                refreshedCookies: preparation.updatedCookies
            )
            cartItems.removeAll()
            checkoutContext = RSICheckoutContext(
                itemTitle: AppLocalizer.format("%lld Warbond upgrade(s)", items.count),
                checkoutURL: preparation.checkoutURL,
                cookies: cookies,
                navigationTitle: "WBCCU Checkout",
                completionButtonTitle: "Finished Shopping"
            )
        } catch {
            checkoutErrorMessage = error.localizedDescription
        }
    }

    private func persistCheckoutCookies(_ cookies: [SessionCookie], clearCart: Bool) {
        if clearCart {
            cartItems.removeAll()
        }
        Task {
            await appModel.persistBrowserCookies(cookies)
        }
    }

    @MainActor
    private func loadDeals(forceRefresh: Bool) async {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let catalog = try await HostedShipCatalogStore.shared.catalog(
                using: HostedShipCatalogClient(),
                forceRefresh: forceRefresh
            )
            let deals = WBCCUDeal.makeDeals(from: catalog)
            let availableDealIDs = Set(deals.map(\.id))
            cartItems = cartItems.filter { availableDealIDs.contains($0.key) }
            loadState = .loaded(deals: deals, generatedAt: catalog.generatedAt)
        } catch {
            if case .loaded = loadState {
                refreshErrorMessage = error.localizedDescription
            } else {
                loadState = .failed(error.localizedDescription)
            }
        }
    }
}

private enum WBCCUDealsLoadState {
    case loading
    case loaded(deals: [WBCCUDeal], generatedAt: Date?)
    case failed(String)
}

nonisolated struct WBCCUDeal: Identifiable, Hashable, Sendable {
    let offer: RSIShipCatalog.StoreUpgradeOffer
    let targetShip: RSIShipCatalog.Ship?
    let eligibleSourceShips: [RSIShipCatalog.Ship]

    var id: String { offer.id }

    var targetName: String {
        targetShip?.name ?? offer.targetShipName
    }

    var targetShipID: Int? {
        offer.targetShipID ?? targetShip?.id
    }

    var manufacturer: String {
        targetShip?.manufacturer ?? AppLocalizer.string("Unknown Manufacturer")
    }

    var standardValueUSD: Decimal? {
        offer.targetShipMSRPUSD ?? targetShip?.msrpUSD
    }

    var canAddToCart: Bool {
        targetShipID != nil && offer.skuID != nil && !eligibleSourceShips.isEmpty
    }

    static func makeDeals(from catalog: RSIShipCatalog) -> [WBCCUDeal] {
        catalog.storeUpgradeOffers
            .filter { $0.available && $0.savingsUSD > 0 }
            .map { offer in
                let idMatch = offer.targetShipID.flatMap { targetID in
                    catalog.ships.first { $0.id == targetID }
                }
                let targetShip = idMatch ?? catalog.matchShip(named: offer.targetShipName)
                var seenSourceIDs = Set<Int>()
                let eligibleSources = catalog.ships
                    .filter { ship in
                        guard
                            ship.id > 0,
                            !ship.hiddenInCatalog,
                            !ship.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            let msrp = ship.msrpUSD,
                            msrp >= 0,
                            msrp < offer.priceUSD
                        else {
                            return false
                        }
                        return seenSourceIDs.insert(ship.id).inserted
                    }
                    .sorted { lhs, rhs in
                        let lhsMSRP = lhs.msrpUSD ?? 0
                        let rhsMSRP = rhs.msrpUSD ?? 0
                        if lhsMSRP != rhsMSRP {
                            return lhsMSRP > rhsMSRP
                        }
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    }
                return WBCCUDeal(
                    offer: offer,
                    targetShip: targetShip,
                    eligibleSourceShips: eligibleSources
                )
            }
            .sorted { lhs, rhs in
                if lhs.offer.savingsUSD != rhs.offer.savingsUSD {
                    return lhs.offer.savingsUSD > rhs.offer.savingsUSD
                }
                if lhs.offer.priceUSD != rhs.offer.priceUSD {
                    return lhs.offer.priceUSD < rhs.offer.priceUSD
                }
                return lhs.targetName.localizedCaseInsensitiveCompare(rhs.targetName) == .orderedAscending
            }
    }
}

private struct WBCCUDealCard: View {
    let deal: WBCCUDeal
    let reloadToken: UUID?
    let cartItem: WBCCUCheckoutItem?
    let onChooseSource: () -> Void
    let onRemoveFromCart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            artwork

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    priceBlock(
                        title: "STANDARD VALUE",
                        value: deal.standardValueUSD?.usdString ?? AppLocalizer.string("Unavailable"),
                        isStandardValue: true
                    )

                    Divider()
                        .frame(height: 42)

                    priceBlock(
                        title: "WARBOND VALUE",
                        value: deal.offer.priceUSD.usdString,
                        isStandardValue: false
                    )

                    Spacer(minLength: 0)

                    Text(AppLocalizer.format("Save %@", deal.offer.savingsUSD.usdString))
                        .font(.subheadline.bold())
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.green.opacity(0.12), in: Capsule())
                }

                Divider()

                if let cartItem {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Label("In Cart", systemImage: "cart.fill.badge.plus")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                            Spacer()
                            Text(AppLocalizer.format("Upgrade cost %@", cartItem.purchaseCostUSD.usdString))
                                .font(.caption.weight(.semibold))
                        }

                        Text(AppLocalizer.format("%@ → %@", cartItem.sourceShipName, cartItem.targetShipName))
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)

                        HStack {
                            Button("Change Source", action: onChooseSource)
                                .buttonStyle(.bordered)
                            Spacer()
                            Button("Remove", role: .destructive, action: onRemoveFromCart)
                                .buttonStyle(.bordered)
                        }
                        .controlSize(.small)
                    }
                } else {
                    HStack(spacing: 10) {
                        Spacer()

                        Button(action: onChooseSource) {
                            Label("Add to Cart", systemImage: "cart.badge.plus")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!deal.canAddToCart)
                    }

                    if !deal.canAddToCart {
                        Text("This offer is missing the RSI upgrade identifiers needed for checkout.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(cartItem == nil ? Color.primary.opacity(0.06) : Color.green.opacity(0.45), lineWidth: cartItem == nil ? 1 : 2)
        )
    }

    private var artwork: some View {
        ZStack(alignment: .bottomLeading) {
            CachedRemoteImage(
                url: deal.targetShip?.imageURL,
                targetSize: CGSize(width: 720, height: 340),
                reloadToken: reloadToken
            ) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                case .empty, .failure:
                    ZStack {
                        LinearGradient(
                            colors: [Color.blue.opacity(0.38), Color.black.opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Image(systemName: "airplane")
                            .font(.system(size: 54, weight: .light))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            .frame(height: 170)
            .frame(maxWidth: .infinity)
            .clipped()
            .accessibilityHidden(true)

            LinearGradient(
                colors: [.clear, .black.opacity(0.82)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(deal.manufacturer.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.9)
                    .foregroundStyle(.white.opacity(0.72))
                Text(deal.targetName)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
            .padding(16)
        }
        .frame(height: 170)
    }

    private func priceBlock(
        title: LocalizedStringKey,
        value: String,
        isStandardValue: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(isStandardValue ? Color.secondary : Color.primary)
                .strikethrough(isStandardValue, color: .secondary)
        }
    }
}

private struct WBCCUSourceShipPicker: View {
    let deal: WBCCUDeal
    let selectedSourceShipID: Int?
    let onSelect: (RSIShipCatalog.Ship) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List(filteredShips, id: \.id) { ship in
                Button {
                    onSelect(ship)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ship.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(ship.manufacturer ?? AppLocalizer.string("Unknown Manufacturer"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 3) {
                            Text(ship.msrpUSD?.usdString ?? AppLocalizer.string("Unavailable"))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            if let msrp = ship.msrpUSD {
                                Text(AppLocalizer.format("%@ upgrade", max(deal.offer.priceUSD - msrp, 0).usdString))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if ship.id == selectedSourceShipID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if filteredShips.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .searchable(text: $searchText, prompt: "Search source ships")
            .navigationTitle("Choose Source Ship")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                VStack(spacing: 3) {
                    Text(AppLocalizer.format("Upgrade to %@", deal.targetName))
                        .font(.subheadline.weight(.semibold))
                    Text("Closest-valued ships are listed first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var filteredShips: [RSIShipCatalog.Ship] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else {
            return deal.eligibleSourceShips
        }

        return deal.eligibleSourceShips.filter { ship in
            ship.name.localizedCaseInsensitiveContains(trimmedSearch)
                || (ship.manufacturer?.localizedCaseInsensitiveContains(trimmedSearch) ?? false)
        }
    }
}

private struct WBCCUDealsTimestampFooter: View {
    let generatedAt: Date?

    var body: some View {
        if let generatedAt {
            Text(AppLocalizer.format("Feed updated %@", AppLocalizer.displayDateTime(generatedAt)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 16)
        }
    }
}

private struct WBCCUCheckoutBar: View {
    let cartItems: [WBCCUCheckoutItem]
    let isPreparingCheckout: Bool
    let onClearCart: () -> Void
    let onCheckout: () -> Void

    private var cartTotal: Decimal {
        cartItems.reduce(0) { $0 + $1.purchaseCostUSD }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label(
                    AppLocalizer.format("%lld upgrade(s)", cartItems.count),
                    systemImage: "cart.fill"
                )
                Spacer()
                Text(AppLocalizer.format("Cart total %@", cartTotal.usdString))
            }
            .font(.subheadline.weight(.semibold))

            HStack(spacing: 10) {
                Button("Clear Cart", role: .destructive, action: onClearCart)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.large)

                Button(action: onCheckout) {
                    HStack {
                        if isPreparingCheckout {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "cart.fill")
                        }
                        Text(isPreparingCheckout ? "Preparing Cart..." : "Check Out")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .disabled(isPreparingCheckout)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
