import SwiftUI

struct BuybackView: View {
    let appModel: AppModel
    enum SearchFilter: String, CaseIterable, Identifiable {
        case standaloneShips = "Standalone ships"
        case packages = "Packages"
        case upgrades = "Upgrades"
        case gears = "Gears"

        var id: Self { self }
    }

    let snapshot: HangarSnapshot

    @State private var searchText = ""
    @State private var searchFilters: Set<SearchFilter> = []
    @State private var isSearchPresented = false

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
                                        Text(searchFilter.rawValue)
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
                            BuybackGroupRow(
                                itemGroup: itemGroup,
                                reloadToken: appModel.buybackImageReloadToken
                            )
                        }
                    }
                }
            }
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
            .navigationTitle("Buy Back")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(appModel.isRefreshing(.buyback) ? "Refreshing..." : "Refresh") {
                        Task {
                            await appModel.refresh(scope: .buyback)
                        }
                    }
                    .disabled(appModel.isRefreshing)
                }
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

    private var emptyStateTitle: String {
        if snapshot.buyback.isEmpty {
            return "Buy Back Is Empty"
        }

        return "No Matching Buy-Back Items"
    }

    private var emptyStateSystemImage: String {
        if snapshot.buyback.isEmpty {
            return "tray"
        }

        return "magnifyingglass"
    }

    private var emptyStateDescription: String {
        if snapshot.buyback.isEmpty {
            return "This RSI account does not currently have any pledges in buy back."
        }

        return "Try a different search term or clear one of the active filters."
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
            return "Upgrade"
        }

        if item.isPackage {
            return "Package"
        }

        if item.isGear {
            return "Gear"
        }

        if item.isSkin {
            return "Skin"
        }

        if item.isStandaloneShip {
            return "Standalone ship"
        }

        return "Buy-back item"
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
