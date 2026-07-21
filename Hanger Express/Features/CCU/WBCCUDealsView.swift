import Foundation
import SwiftUI

struct WBCCUDealsView: View {
    let reloadToken: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var loadState: WBCCUDealsLoadState = .loading
    @State private var isRefreshing = false
    @State private var refreshErrorMessage: String?

    private let upgradeStoreURL = URL(string: "https://robertsspaceindustries.com/pledge-store/ship-upgrades")!

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
                    .disabled(isRefreshing)
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

    @ViewBuilder
    private func dealsContent(deals: [WBCCUDeal], generatedAt: Date?) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                WBCCUDealsHero(deals: deals)

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
                            upgradeStoreURL: upgradeStoreURL
                        )
                    }
                }

                WBCCUDealsSourceFooter(
                    generatedAt: generatedAt,
                    upgradeStoreURL: upgradeStoreURL
                )
            }
            .padding(16)
        }
        .refreshable {
            await loadDeals(forceRefresh: true)
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
            loadState = .loaded(
                deals: WBCCUDeal.makeDeals(from: catalog),
                generatedAt: catalog.generatedAt
            )
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

    var id: String { offer.id }

    var targetName: String {
        targetShip?.name ?? offer.targetShipName
    }

    var manufacturer: String {
        targetShip?.manufacturer ?? AppLocalizer.string("Unknown Manufacturer")
    }

    var standardValueUSD: Decimal? {
        offer.targetShipMSRPUSD ?? targetShip?.msrpUSD
    }

    static func makeDeals(from catalog: RSIShipCatalog) -> [WBCCUDeal] {
        catalog.storeUpgradeOffers
            .filter { $0.available && $0.savingsUSD > 0 }
            .map { offer in
                let idMatch = offer.targetShipID.flatMap { targetID in
                    catalog.ships.first { $0.id == targetID }
                }
                return WBCCUDeal(
                    offer: offer,
                    targetShip: idMatch ?? catalog.matchShip(named: offer.targetShipName)
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

private struct WBCCUDealsHero: View {
    let deals: [WBCCUDeal]

    private var highestSavings: Decimal {
        deals.map(\.offer.savingsUSD).max() ?? .zero
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("WARBOND WATCH")
                        .font(.caption.weight(.heavy))
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.75))

                    Text("Upgrade deals, live")
                        .font(.title2.bold())
                        .foregroundStyle(.white)

                    Text("Current limited-time offers from StarCitizen-Info.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer(minLength: 8)

                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 42))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }

            HStack(spacing: 12) {
                WBCCUHeroMetric(
                    value: liveDealCount,
                    label: AppLocalizer.string("AVAILABLE")
                )
                WBCCUHeroMetric(
                    value: highestSavings.usdString,
                    label: AppLocalizer.string("BEST SAVING")
                )
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color(red: 0.03, green: 0.31, blue: 0.47), Color(red: 0.02, green: 0.57, blue: 0.54)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: Color.teal.opacity(0.16), radius: 18, y: 8)
    }

    private var liveDealCount: String {
        AppLocalizer.format("%lld Live Deals", Int64(deals.count))
    }
}

private struct WBCCUHeroMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.bold())
                .foregroundStyle(.white)
            Text(label)
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private struct WBCCUDealCard: View {
    let deal: WBCCUDeal
    let reloadToken: UUID?
    let upgradeStoreURL: URL

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

                HStack(spacing: 10) {
                    Label("New money only", systemImage: "creditcard.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Link(destination: upgradeStoreURL) {
                        Label("RSI Store", systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
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
        .overlay(alignment: .topLeading) {
            Text("AVAILABLE NOW")
                .font(.caption2.weight(.heavy))
                .tracking(0.7)
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.green.opacity(0.9), in: Capsule())
                .padding(12)
        }
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

private struct WBCCUDealsSourceFooter: View {
    let generatedAt: Date?
    let upgradeStoreURL: URL

    var body: some View {
        VStack(spacing: 10) {
            Label("Live data from StarCitizen-Info", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption.weight(.semibold))

            if let generatedAt {
                Text(AppLocalizer.format("Feed updated %@", AppLocalizer.displayDateTime(generatedAt)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("Warbond upgrades require new money. Availability and prices can change without notice; confirm the final offer in the RSI store.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Link(destination: upgradeStoreURL) {
                Label("Open RSI Upgrade Store", systemImage: "safari")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }
}
