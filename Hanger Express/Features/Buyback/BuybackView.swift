import SwiftUI

struct BuybackView: View {
    let appModel: AppModel
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue

    enum SearchFilter: CaseIterable, Identifiable {
        case standaloneShips
        case packages
        case upgrades
        case gears

        var id: Self { self }

        var title: String {
            switch self {
            case .standaloneShips:
                return AppLocalizer.string("Standalone ships")
            case .packages:
                return AppLocalizer.string("Packages")
            case .upgrades:
                return AppLocalizer.string("Upgrades")
            case .gears:
                return AppLocalizer.string("Gears")
            }
        }
    }

    let snapshot: HangarSnapshot

    @State private var searchText = ""
    @State private var searchFilters: Set<SearchFilter> = []
    @State private var isSearchPresented = false
    @State private var pendingBuybackGroup: GroupedBuybackPledge?
    @State private var checkoutContext: BuybackCheckoutContext?
    @State private var buybackError: BuybackCheckoutError?
    @State private var isPreparingCheckout = false

    var body: some View {
        NavigationStack {
            List {
                if isSearchPresented {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(SearchFilter.allCases) { searchFilter in
                                    Button {
                                        toggle(searchFilter)
                                    } label: {
                                        Text(searchFilter.title)
                                            .font(.subheadline.weight(.medium))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .foregroundStyle(searchFilters.contains(searchFilter) ? Color.white : Color.accentColor)
                                            .background(
                                                Capsule(style: .continuous)
                                                    .fill(searchFilters.contains(searchFilter) ? Color.accentColor : Color.accentColor.opacity(0.12))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("Common Search Filters")
                    }
                }

                Section {
                    if filteredItemGroups.isEmpty {
                        ContentUnavailableView(
                            emptyStateTitle,
                            systemImage: emptyStateSystemImage,
                            description: Text(emptyStateDescription)
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(filteredItemGroups) { itemGroup in
                            Button {
                                pendingBuybackGroup = itemGroup
                            } label: {
                                BuybackGroupRow(
                                    itemGroup: itemGroup,
                                    reloadToken: appModel.buybackImageReloadToken
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isPreparingCheckout || appModel.isRefreshing)
                        }
                    }
                }
            }
            .id(appLanguageRawValue)
            .searchable(
                text: $searchText,
                isPresented: $isSearchPresented,
                prompt: "Search buy-back titles and notes"
            )
            .onChange(of: isSearchPresented) { _, isPresented in
                guard !isPresented else {
                    return
                }

                searchFilters.removeAll()
            }
            .overlay {
                if isPreparingCheckout {
                    ZStack {
                        Color.black.opacity(0.2)
                            .ignoresSafeArea()

                        ProgressView("Preparing buy-back checkout...")
                            .padding(18)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(.regularMaterial)
                            )
                    }
                }
            }
            .navigationTitle("Buy Back")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await appModel.refresh(scope: .buyback)
                        }
                    } label: {
                        Text(appModel.isRefreshing(.buyback) ? LocalizedStringKey("Refreshing...") : LocalizedStringKey("Refresh"))
                    }
                    .disabled(appModel.isRefreshing)
                }
            }
            .sheet(item: $pendingBuybackGroup) { itemGroup in
                BuybackConfirmationSheet(
                    itemTitle: itemGroup.representative.title,
                    onBack: {
                        pendingBuybackGroup = nil
                    },
                    onOpenBrowser: {
                        pendingBuybackGroup = nil
                        Task {
                            await startBuybackCheckout(for: itemGroup)
                        }
                    }
                )
                .presentationDetents([.height(560)])
                .presentationDragIndicator(.visible)
            }
            .alert(item: $buybackError) { error in
                Alert(
                    title: Text("Buy-back Checkout Failed"),
                    message: Text(error.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .sheet(item: $checkoutContext) { context in
                BuybackCheckoutBrowserView(
                    context: context,
                    onCancel: { cookies in
                        checkoutContext = nil
                        completeBuybackCheckout(exportedCookies: cookies)
                    },
                    onFinished: { cookies in
                        checkoutContext = nil
                        completeBuybackCheckout(exportedCookies: cookies)
                    }
                )
            }
        }
    }

    private var filteredItemGroups: [GroupedBuybackPledge] {
        snapshot.buyback.groupedForBuybackDisplay.filter { itemGroup in
            let item = itemGroup.representative

            guard matchesSearchFilters(for: item) else {
                return false
            }

            guard !searchText.isEmpty else {
                return true
            }

            return item.searchHaystack.contains(searchText.localizedLowercase)
        }
    }

    private func matchesSearchFilters(for item: BuybackPledge) -> Bool {
        searchFilters.allSatisfy { searchFilter in
            switch searchFilter {
            case .standaloneShips:
                return item.isStandaloneShip
            case .packages:
                return item.isPackage
            case .upgrades:
                return item.isUpgrade
            case .gears:
                return item.isGear
            }
        }
    }

    private func toggle(_ searchFilter: SearchFilter) {
        if searchFilters.contains(searchFilter) {
            searchFilters.remove(searchFilter)
        } else {
            searchFilters.insert(searchFilter)
        }
    }

    private func startBuybackCheckout(for itemGroup: GroupedBuybackPledge) async {
        guard !isPreparingCheckout else {
            return
        }

        isPreparingCheckout = true
        defer {
            isPreparingCheckout = false
        }

        do {
            let preparation = try await appModel.prepareBuybackCheckout(for: itemGroup.checkoutPledge)
            let cookies = appModel.session?.cookies ?? preparation.updatedCookies
            checkoutContext = BuybackCheckoutContext(
                itemTitle: itemGroup.representative.title,
                checkoutURL: preparation.checkoutURL,
                cookies: cookies
            )
        } catch {
            buybackError = BuybackCheckoutError(message: error.localizedDescription)
        }
    }

    private func completeBuybackCheckout(exportedCookies: [SessionCookie]) {
        Task {
            await appModel.persistBrowserCookies(exportedCookies)
            await appModel.refresh(scope: .full)
        }
    }

    private var emptyStateTitle: String {
        if snapshot.buyback.isEmpty {
            return AppLocalizer.string("Buy Back Is Empty")
        }

        return AppLocalizer.string("No Matching Buy-Back Items")
    }

    private var emptyStateSystemImage: String {
        if snapshot.buyback.isEmpty {
            return "tray"
        }

        return "magnifyingglass"
    }

    private var emptyStateDescription: String {
        if snapshot.buyback.isEmpty {
            return AppLocalizer.string("This RSI account does not currently have any pledges in buy back.")
        }

        return AppLocalizer.string("Try a different search term or clear one of the active filters.")
    }
}

struct BuybackCheckoutContext: Identifiable, Hashable {
    let id = UUID()
    let itemTitle: String
    let checkoutURL: URL
    let cookies: [SessionCookie]
}

private struct BuybackCheckoutError: Identifiable {
    let id = UUID()
    let message: String
}

private struct BuybackConfirmationSheet: View {
    let itemTitle: String
    let onBack: () -> Void
    let onOpenBrowser: () -> Void

    private let supportedPaymentMethods = [
        "Built-in Card Payment",
        "Apple Pay",
        "Alipay",
        "WeChat Pay"
    ]

    private let unsupportedPaymentMethods = [
        "Paypal",
        "Gpay",
        "Amazon Wallet"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(AppLocalizer.string("Only one buy-back item can be checked out at a time."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                PaymentMethodSection(
                    title: AppLocalizer.string("Supported payment methods"),
                    systemImage: "checkmark.circle.fill",
                    tint: .green,
                    methods: supportedPaymentMethods
                )

                PaymentMethodSection(
                    title: AppLocalizer.string("Unsupported payment methods"),
                    systemImage: "xmark.circle.fill",
                    tint: .red,
                    methods: unsupportedPaymentMethods
                )
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button(role: .cancel) {
                    onBack()
                } label: {
                    Text(AppLocalizer.string("Back"))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

                Button {
                    onOpenBrowser()
                } label: {
                    Text(AppLocalizer.string("Open Browser"))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 42)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var title: String {
        let trimmedTitle = itemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return AppLocalizer.string("Do you want to buyback this item?")
        }

        return AppLocalizer.format("Do you want to buyback %@?", trimmedTitle)
    }
}

private struct PaymentMethodSection: View {
    let title: String
    let systemImage: String
    let tint: Color
    let methods: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(methods, id: \.self) { method in
                    Text(AppLocalizer.string(method))
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.primary)
                        .background(
                            Capsule(style: .continuous)
                                .fill(tint.opacity(0.12))
                        )
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]
    }
}

private extension GroupedBuybackPledge {
    var checkoutPledge: BuybackPledge {
        pledges.first { $0.upgradeContext?.isValid == true } ?? representative
    }
}

private struct BuybackGroupRow: View {
    let itemGroup: GroupedBuybackPledge
    let reloadToken: UUID?

    private var item: BuybackPledge {
        itemGroup.representative
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteThumbnailView(
                url: item.imageURL,
                reloadToken: reloadToken,
                fallbackSystemImage: fallbackSystemImage,
                size: 72
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.headline)

                    if itemGroup.quantity > 1 {
                        Text("x\(itemGroup.quantity)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor.opacity(0.14))
                            )
                    }
                }

                Text(typeSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(metadataLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var typeSummary: String {
        if item.isUpgrade {
            return AppLocalizer.string("Upgrade")
        }

        if item.isPackage {
            return AppLocalizer.string("Package")
        }

        if item.isGear {
            return AppLocalizer.string("Gear")
        }

        if item.isSkin {
            return AppLocalizer.string("Skin")
        }

        if item.isStandaloneShip {
            return AppLocalizer.string("Standalone ship")
        }

        return AppLocalizer.string("Buy-back item")
    }

    private var metadataLine: String {
        if let notes = item.displayedNotes {
            return "\(dateSummary) • \(notes)"
        }

        return dateSummary
    }

    private var dateSummary: String {
        let earliestDate = itemGroup.earliestAddedToBuybackAt
        let latestDate = itemGroup.latestAddedToBuybackAt

        if Calendar.current.isDate(earliestDate, inSameDayAs: latestDate) {
            return latestDate.formatted(date: .abbreviated, time: .omitted)
        }

        return "\(earliestDate.formatted(date: .abbreviated, time: .omitted)) – \(latestDate.formatted(date: .abbreviated, time: .omitted))"
    }

    private var fallbackSystemImage: String {
        if item.isUpgrade {
            return "arrow.triangle.swap"
        }

        if item.isPackage {
            return "shippingbox.fill"
        }

        if item.isGear {
            return "wrench.and.screwdriver.fill"
        }

        if item.isSkin {
            return "paintpalette.fill"
        }

        return "airplane"
    }
}
