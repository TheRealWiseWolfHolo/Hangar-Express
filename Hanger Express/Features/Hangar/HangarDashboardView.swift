import SwiftUI

struct HangarDashboardView: View {
    enum PackageFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case giftable = "Giftable"
        case reclaimable = "Reclaimable"

        var id: Self { self }
    }

    enum SearchFilter: String, CaseIterable, Identifiable {
        case lti = "LTI"
        case upgrades = "Upgrades"
        case packages = "Packages"

        var id: Self { self }

        var title: String {
            rawValue
        }
    }

    let appModel: AppModel
    let snapshot: HangarSnapshot

    @State private var filter: PackageFilter = .all
    @State private var searchText = ""
    @State private var searchFilters: Set<SearchFilter> = []
    @State private var isSearchPresented = false
    @State private var isLogPresented = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Filter", selection: $filter) {
                        ForEach(PackageFilter.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

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
                    } footer: {
                        Text("Packages only includes pledges with more than one ship or vehicle.")
                    }
                }

                Section {
                    ForEach(filteredPackageGroups) { packageGroup in
                        NavigationLink {
                            HangarPackageDetailView(
                                packageGroup: packageGroup,
                                reloadToken: appModel.imageReloadToken
                            )
                        } label: {
                            HangarPackageGroupRow(
                                packageGroup: packageGroup,
                                reloadToken: appModel.imageReloadToken
                            )
                        }
                    }
                } header: {
                    Text("Pledges")
                }
            }
            .searchable(
                text: $searchText,
                isPresented: $isSearchPresented,
                prompt: "Search packages, ships, insurance"
            )
            .onChange(of: isSearchPresented) { _, isPresented in
                guard !isPresented else {
                    return
                }

                searchFilters.removeAll()
            }
            .navigationTitle("Hangar")
            .sheet(isPresented: $isLogPresented) {
                HangarLogView(appModel: appModel)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Log") {
                        isLogPresented = true
                    }

                    Button(appModel.isRefreshing(.hangar) ? "Refreshing..." : "Refresh") {
                        Task {
                            await appModel.refresh(scope: .hangar)
                        }
                    }
                    .disabled(appModel.isRefreshing)
                }
            }
        }
    }

    private var filteredPackageGroups: [GroupedHangarPackage] {
        snapshot.packages.groupedForInventoryDisplay.filter { packageGroup in
            let package = packageGroup.representative
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .giftable:
                matchesFilter = package.canGift
            case .reclaimable:
                matchesFilter = package.canReclaim
            }

            guard matchesFilter else {
                return false
            }

            guard matchesSearchFilters(for: package) else {
                return false
            }

            guard !searchText.isEmpty else {
                return true
            }

            let haystack = [
                package.title,
                package.status,
                package.searchableInsuranceText,
                package.contents.map(\.title).joined(separator: " ")
            ].joined(separator: " ").localizedLowercase

            return haystack.contains(searchText.localizedLowercase)
        }
    }

    private func matchesSearchFilters(for package: HangarPackage) -> Bool {
        searchFilters.allSatisfy { searchFilter in
            switch searchFilter {
            case .lti:
                return package.hasLifetimeInsurance
            case .upgrades:
                return package.hasUpgradeItems
            case .packages:
                return package.isMultiShipPackage
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
}

private struct HangarPackageGroupRow: View {
    let packageGroup: GroupedHangarPackage
    let reloadToken: UUID?

    private var package: HangarPackage {
        packageGroup.representative
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteThumbnailView(
                url: package.thumbnailURL,
                reloadToken: reloadToken,
                fallbackSystemImage: "shippingbox.fill",
                size: 72
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(package.title)
                        .font(.headline)

                    if packageGroup.containsMultipleCopies {
                        Text("x\(packageGroup.quantity)")
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

                Text(statusSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
                    Text(valueSummary)
                    Text(package.canGift ? "Giftable" : "Locked")
                    Text(package.canReclaim ? "Reclaimable" : "No Melt")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var valueSummary: String {
        packageGroup.containsMultipleCopies ? "Each \(package.originalValueUSD.usdString)" : package.originalValueUSD.usdString
    }

    private var statusSummary: String {
        if let displayedInsurance = package.displayedInsurance {
            return "\(package.status) • \(displayedInsurance)"
        }

        return package.status
    }
}

private struct HangarPackageDetailView: View {
    let packageGroup: GroupedHangarPackage
    let reloadToken: UUID?

    private var package: HangarPackage {
        packageGroup.representative
    }

    var body: some View {
        List {
            if let thumbnailURL = package.thumbnailURL {
                Section {
                    RemoteThumbnailView(
                        url: thumbnailURL,
                        reloadToken: reloadToken,
                        fallbackSystemImage: "shippingbox.fill",
                        size: 180
                    )
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                }
            }

            Section {
                LabeledContent("Status", value: package.status)
                if let detailInsuranceText = package.detailInsuranceText {
                    LabeledContent("Insurance", value: detailInsuranceText)
                }
                LabeledContent("Acquired", value: package.acquiredAt.formatted(date: .abbreviated, time: .omitted))
                LabeledContent(originalValueLabel, value: package.originalValueUSD.usdString)
                LabeledContent(currentValueLabel, value: package.currentValueUSD.usdString)
                if packageGroup.containsMultipleCopies {
                    LabeledContent("Copies", value: "\(packageGroup.quantity)")
                }
            } header: {
                Text("Package")
            }

            Section {
                ForEach(package.contents) { item in
                    PackageItemRow(
                        item: item,
                        reloadToken: reloadToken
                    )
                }
            } header: {
                Text("Contents")
            }
        }
        .navigationTitle(package.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var originalValueLabel: String {
        packageGroup.containsMultipleCopies ? "Melt Value (Each)" : "Melt Value"
    }

    private var currentValueLabel: String {
        packageGroup.containsMultipleCopies ? "Current Value (Each)" : "Current Value"
    }
}

private struct PackageItemRow: View {
    let item: PackageItem
    let reloadToken: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteThumbnailView(
                url: item.imageURL,
                reloadToken: reloadToken,
                fallbackSystemImage: fallbackSystemImage,
                size: 72
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)

                Text("\(item.category.rawValue) • \(item.detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let pricing = item.upgradePricing {
                    UpgradePricingSummary(pricing: pricing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var fallbackSystemImage: String {
        switch item.category {
        case .ship:
            return "airplane"
        case .vehicle:
            return "car.fill"
        case .gamePackage:
            return "shippingbox.fill"
        case .flair:
            return "sparkles"
        case .upgrade:
            return "arrow.up.right.square"
        case .perk:
            return "gift.fill"
        }
    }
}

private struct UpgradePricingSummary: View {
    let pricing: PackageItem.UpgradePricing

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledValueRow(label: "Melt Value", value: pricing.meltValueUSD?.usdString ?? "Not separable from this package")
            LabeledValueRow(label: "Actual Value", value: pricing.actualValueUSD?.usdString ?? "Unavailable")
            LabeledValueRow(
                label: "From",
                value: "\(pricing.sourceShipName) • MSRP \(pricing.sourceShipMSRPUSD?.usdString ?? "Unavailable")"
            )
            LabeledValueRow(
                label: "To",
                value: "\(pricing.targetShipName) • MSRP \(pricing.targetShipMSRPUSD?.usdString ?? "Unavailable")"
            )
        }
        .padding(.top, 4)
    }
}

private struct LabeledValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }
}

struct RemoteThumbnailView: View {
    let url: URL?
    let reloadToken: UUID?
    let fallbackSystemImage: String
    let size: CGFloat

    init(
        url: URL?,
        reloadToken: UUID? = nil,
        fallbackSystemImage: String,
        size: CGFloat
    ) {
        self.url = url
        self.reloadToken = reloadToken
        self.fallbackSystemImage = fallbackSystemImage
        self.size = size
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))

            if let url {
                CachedRemoteImage(url: url, reloadToken: reloadToken) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        fallback
                    case .empty:
                        ProgressView()
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var fallback: some View {
        Image(systemName: fallbackSystemImage)
            .font(.title2)
            .foregroundStyle(.secondary)
    }
}
