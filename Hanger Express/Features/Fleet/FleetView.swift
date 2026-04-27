import SwiftUI

struct FleetView: View {
    enum SortMode: String, CaseIterable, Identifiable {
        case manufacturer = "Manufacturer"
        case msrp = "MSRP"
        case function = "Function"

        var id: Self { self }

        var title: String {
            AppLocalizer.string(rawValue)
        }
    }

    enum DisplayMode: String {
        case singleColumn
        case twoColumn

        var toggleSymbolName: String {
            switch self {
            case .singleColumn:
                return "square.grid.2x2"
            case .twoColumn:
                return "rectangle.grid.1x2"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .singleColumn:
                return AppLocalizer.string("Switch to two-column cards")
            case .twoColumn:
                return AppLocalizer.string("Switch to one-column cards")
            }
        }

        var next: Self {
            switch self {
            case .singleColumn:
                return .twoColumn
            case .twoColumn:
                return .singleColumn
            }
        }
    }

    let appModel: AppModel
    let snapshot: HangarSnapshot
    @State private var searchText = ""
    @State private var sortMode: SortMode = .manufacturer
    @State private var selectedShipGroup: GroupedFleetShip?
    @State private var transitionSourceResetToken = 0
    @State private var presentedPledgeSheet: FleetShipPledgeSheetContext?
    @Namespace private var shipCardTransitionNamespace
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @AppStorage("fleetDisplayMode") private var displayModeRawValue = DisplayMode.singleColumn.rawValue

    private var displayMode: DisplayMode {
        DisplayMode(rawValue: displayModeRawValue) ?? .singleColumn
    }

    private let compactGridColumns = [
        GridItem(.flexible(), spacing: 12, alignment: .top),
        GridItem(.flexible(), spacing: 12, alignment: .top)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(displaySections) { section in
                        VStack(alignment: .leading, spacing: 14) {
                            if let title = section.title {
                                Text(title)
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                            }

                            fleetCards(for: section)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 22)
            }
            .id(appLanguageRawValue)
            .searchable(
                text: $searchText,
                prompt: "Search ships, manufacturers, functions"
            )
            .navigationTitle("Fleet")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        displayModeRawValue = displayMode.next.rawValue
                    } label: {
                        Image(systemName: displayMode.toggleSymbolName)
                    }
                    .accessibilityLabel(displayMode.accessibilityLabel)

                    Menu {
                        Picker("Sort Fleet", selection: $sortMode) {
                            ForEach(SortMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    } label: {
                        Text("Sort")
                    }

                    Button {
                        Task {
                            await appModel.refresh(scope: .hangar)
                        }
                    } label: {
                        Text(appModel.isRefreshing(.hangar) ? LocalizedStringKey("Refreshing...") : LocalizedStringKey("Refresh"))
                    }
                    .disabled(appModel.isRefreshing)
                }
            }
            .navigationDestination(item: $selectedShipGroup) { shipGroup in
                FleetShipDetailView(
                    shipGroup: shipGroup,
                    reloadToken: appModel.hangarFleetImageReloadToken,
                    transitionNamespace: shipCardTransitionNamespace
                )
            }
            .onChange(of: selectedShipGroup?.id) { _, newValue in
                if newValue == nil {
                    transitionSourceResetToken &+= 1
                }
            }
            .sheet(item: $presentedPledgeSheet) { context in
                FleetShipPledgeSheet(
                    appModel: appModel,
                    context: context,
                    reloadToken: appModel.hangarFleetImageReloadToken
                )
            }
        }
    }

    @ViewBuilder
    private func fleetCards(for section: FleetDisplaySection) -> some View {
        switch displayMode {
        case .singleColumn:
            LazyVStack(spacing: 16) {
                ForEach(section.shipGroups) { shipGroup in
                    fleetCard(for: shipGroup)
                }
            }
        case .twoColumn:
            LazyVGrid(columns: compactGridColumns, alignment: .leading, spacing: 12) {
                ForEach(section.shipGroups) { shipGroup in
                    fleetCard(for: shipGroup)
                }
            }
        }
    }

    @ViewBuilder
    private func fleetCard(for shipGroup: GroupedFleetShip) -> some View {
        let subtitle = cardSubtitle(for: shipGroup)
        let msrpSummary = msrpSummary(for: shipGroup)

        Group {
            switch displayMode {
            case .singleColumn:
                FleetShipHeroCard(
                    shipGroup: shipGroup,
                    subtitle: subtitle,
                    msrpSummary: msrpSummary,
                    reloadToken: appModel.hangarFleetImageReloadToken
                )
            case .twoColumn:
                FleetShipCompactCard(
                    shipGroup: shipGroup,
                    subtitle: subtitle,
                    msrpSummary: msrpSummary,
                    reloadToken: appModel.hangarFleetImageReloadToken
                )
            }
        }
        .id("\(shipGroup.id)-\(transitionSourceResetToken)")
        .contentShape(Rectangle())
        .matchedTransitionSource(
            id: shipGroup.id,
            in: shipCardTransitionNamespace
        ) { source in
            source.clipShape(
                RoundedRectangle(
                    cornerRadius: displayMode == .singleColumn ? 24 : 22,
                    style: .continuous
                )
            )
        }
        .onTapGesture {
            selectedShipGroup = shipGroup
        }
        .onLongPressGesture(minimumDuration: 0.4) {
            presentedPledgeSheet = pledgeSheetContext(for: shipGroup)
        }
    }

    private func pledgeSheetContext(for shipGroup: GroupedFleetShip) -> FleetShipPledgeSheetContext? {
        let sourcePackageIDs = Set(shipGroup.ships.map(\.sourcePackageID))
        let packageGroups = snapshot.packages.groupedForInventoryDisplay.filter { packageGroup in
            packageGroup.packages.contains { package in
                sourcePackageIDs.contains(package.id)
            }
        }

        guard !packageGroups.isEmpty else {
            return nil
        }

        return FleetShipPledgeSheetContext(
            shipName: shipGroup.representative.displayName,
            packageGroups: packageGroups
        )
    }

    private var displaySections: [FleetDisplaySection] {
        switch sortMode {
        case .manufacturer:
            return groupedSections(for: sortedShipGroups) { shipGroup in
                normalizedHeaderTitle(FleetPresentationFormatter.manufacturerDisplayName(shipGroup.representative.manufacturer))
                    ?? AppLocalizer.string("Unknown Manufacturer")
            }
        case .function:
            return functionSections(from: filteredShipGroups)
        case .msrp:
            return [
                FleetDisplaySection(
                    title: nil,
                    shipGroups: sortedShipGroups
                )
            ]
        }
    }

    private var sortedShipGroups: [GroupedFleetShip] {
        filteredShipGroups.sorted { lhs, rhs in
            switch sortMode {
            case .manufacturer:
                if lhs.representative.manufacturer != rhs.representative.manufacturer {
                    return lhs.representative.manufacturer < rhs.representative.manufacturer
                }
            case .msrp:
                switch (lhs.representative.msrpUSD, rhs.representative.msrpUSD) {
                case let (lhsMSRP?, rhsMSRP?):
                    if lhsMSRP != rhsMSRP {
                        return NSDecimalNumber(decimal: lhsMSRP).compare(NSDecimalNumber(decimal: rhsMSRP)) == .orderedDescending
                    }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
            case .function:
                let lhsPrimaryRole = lhs.representative.roleCategories.first ?? lhs.representative.role
                let rhsPrimaryRole = rhs.representative.roleCategories.first ?? rhs.representative.role
                if lhsPrimaryRole != rhsPrimaryRole {
                    return lhsPrimaryRole < rhsPrimaryRole
                }
            }

            if lhs.representative.displayName != rhs.representative.displayName {
                return lhs.representative.displayName < rhs.representative.displayName
            }

            return lhs.representative.insurance < rhs.representative.insurance
        }
    }

    private func groupedSections(
        for shipGroups: [GroupedFleetShip],
        key: (GroupedFleetShip) -> String
    ) -> [FleetDisplaySection] {
        var orderedTitles: [String] = []
        var groupedShipGroups: [String: [GroupedFleetShip]] = [:]

        for shipGroup in shipGroups {
            let title = key(shipGroup)
            if groupedShipGroups[title] == nil {
                orderedTitles.append(title)
            }

            groupedShipGroups[title, default: []].append(shipGroup)
        }

        return orderedTitles.compactMap { title in
            guard let shipGroups = groupedShipGroups[title] else {
                return nil
            }

            return FleetDisplaySection(
                title: title,
                shipGroups: shipGroups
            )
        }
    }

    private func functionSections(from shipGroups: [GroupedFleetShip]) -> [FleetDisplaySection] {
        let seedOrder = shipGroups.sorted { lhs, rhs in
            let lhsPrimaryRole = lhs.representative.roleCategories.first ?? lhs.representative.role
            let rhsPrimaryRole = rhs.representative.roleCategories.first ?? rhs.representative.role

            if lhsPrimaryRole != rhsPrimaryRole {
                return lhsPrimaryRole < rhsPrimaryRole
            }

            if lhs.representative.displayName != rhs.representative.displayName {
                return lhs.representative.displayName < rhs.representative.displayName
            }

            return lhs.representative.manufacturer < rhs.representative.manufacturer
        }

        var orderedTitles: [String] = []
        var groupedShipGroups: [String: [GroupedFleetShip]] = [:]

        for shipGroup in seedOrder {
            let categories = shipGroup.representative.roleCategories.isEmpty
                ? [shipGroup.representative.role]
                : shipGroup.representative.roleCategories

            for category in categories {
                let title = normalizedHeaderTitle(category) ?? AppLocalizer.string("Other Ships")
                if groupedShipGroups[title] == nil {
                    orderedTitles.append(title)
                }

                groupedShipGroups[title, default: []].append(shipGroup)
            }
        }

        return orderedTitles.compactMap { title in
            guard let groups = groupedShipGroups[title] else {
                return nil
            }

            let sortedGroups = groups.sorted { lhs, rhs in
                if lhs.representative.displayName != rhs.representative.displayName {
                    return lhs.representative.displayName < rhs.representative.displayName
                }

                if lhs.representative.manufacturer != rhs.representative.manufacturer {
                    return lhs.representative.manufacturer < rhs.representative.manufacturer
                }

                return lhs.representative.insurance < rhs.representative.insurance
            }

            return FleetDisplaySection(
                title: title,
                shipGroups: sortedGroups
            )
        }
    }

    private var filteredShipGroups: [GroupedFleetShip] {
        let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase

        guard !normalizedSearchText.isEmpty else {
            return snapshot.fleet.groupedForFleetDisplay
        }

        return snapshot.fleet.groupedForFleetDisplay.filter { shipGroup in
            shipGroup.representative.searchHaystack.contains(normalizedSearchText)
        }
    }

    private func cardSubtitle(for shipGroup: GroupedFleetShip) -> String? {
        normalizedHeaderTitle(
            FleetPresentationFormatter.roleSummary(
                role: shipGroup.representative.role,
                categories: shipGroup.representative.roleCategories
            ) ?? shipGroup.representative.role
        )
    }

    private func normalizedHeaderTitle(_ rawValue: String) -> String? {
        rawValue.nilIfBlank
    }

    private func msrpSummary(for shipGroup: GroupedFleetShip) -> String {
        if let msrpUSD = shipGroup.representative.msrpUSD {
            if shipGroup.quantity > 1 {
                return AppLocalizer.format("MSRP %@ each", msrpUSD.usdString)
            }

            return AppLocalizer.format("MSRP %@", msrpUSD.usdString)
        }

        if let msrpLabel = shipGroup.representative.msrpLabel?.nilIfBlank {
            return msrpLabel
        }

        return AppLocalizer.string("MSRP unavailable")
    }
}

enum FleetTool: String, CaseIterable, Identifiable {
    case allShips
    case ccuChainCalculator
    case resetCharacter

    var id: Self { self }

    var title: String {
        switch self {
        case .allShips:
            return AppLocalizer.string("All Ships")
        case .ccuChainCalculator:
            return AppLocalizer.string("CCU Chain Calculator")
        case .resetCharacter:
            return AppLocalizer.string("Reset Character")
        }
    }

    var subtitle: String {
        switch self {
        case .allShips:
            return AppLocalizer.string("Browse the hosted ship catalog")
        case .ccuChainCalculator, .resetCharacter:
            return AppLocalizer.string("To be implemented")
        }
    }

    var systemImage: String {
        switch self {
        case .allShips:
            return "airplane.circle"
        case .ccuChainCalculator:
            return "link.circle"
        case .resetCharacter:
            return "person.crop.circle.badge.exclamationmark"
        }
    }

    var isAvailable: Bool {
        self == .allShips
    }
}

struct FleetToolsSection: View {
    let onSelect: (FleetTool) -> Void
    var showsHeader = true

    init(showsHeader: Bool = true, onSelect: @escaping (FleetTool) -> Void) {
        self.showsHeader = showsHeader
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader {
                Text(AppLocalizer.string("Tools"))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            VStack(spacing: 10) {
                ForEach(FleetTool.allCases) { tool in
                    FleetToolRow(tool: tool) {
                        onSelect(tool)
                    }
                }
            }
        }
    }
}

private struct FleetToolRow: View {
    let tool: FleetTool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: tool.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tool.isAvailable ? Color.accentColor : .secondary)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill((tool.isAvailable ? Color.accentColor : Color.secondary).opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(tool.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if tool.isAvailable {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .disabled(!tool.isAvailable)
        .opacity(tool.isAvailable ? 1 : 0.62)
    }
}

struct AllShipsBrowserView: View {
    let reloadToken: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedPriceRange: ClosedRange<Double>?
    @State private var availabilityFilter: AllShipsAvailabilityFilter = .all
    @State private var loadState: AllShipsLoadState = .idle
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue

    private var filteredItems: [AllShipsCatalogItem] {
        guard case let .loaded(items) = loadState else {
            return []
        }

        let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let priceRange = activePriceRange
        let fullPriceRange = priceBounds
        return items.filter { item in
            let matchesSearch = normalizedSearchText.isEmpty || item.searchHaystack.contains(normalizedSearchText)
            return matchesSearch
                && item.isWithinPriceRange(priceRange, fullRange: fullPriceRange)
                && availabilityFilter.includes(item: item)
        }
    }

    private var priceBounds: ClosedRange<Double> {
        guard case let .loaded(items) = loadState else {
            return 0 ... 0
        }

        let prices = items.compactMap(\.priceDouble)
        guard let maximumPrice = prices.max() else {
            return 0 ... 0
        }

        let lowerBound = 0.0
        let upperBound = max(lowerBound, ceil(maximumPrice / 5) * 5)
        return lowerBound ... upperBound
    }

    private var activePriceRange: ClosedRange<Double> {
        selectedPriceRange ?? priceBounds
    }

    var body: some View {
        NavigationStack {
            Group {
                switch loadState {
                case .idle, .loading:
                    AllShipsLoadingView()
                case let .loaded(items):
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            AllShipsQuickFilters(
                                priceRange: Binding(
                                    get: { activePriceRange },
                                    set: { selectedPriceRange = $0 }
                                ),
                                priceBounds: priceBounds,
                                availabilityFilter: $availabilityFilter,
                                resultCount: filteredItems.count,
                                totalCount: items.count
                            )

                            if filteredItems.isEmpty {
                                AllShipsEmptyView()
                            } else {
                                ForEach(filteredItems) { item in
                                    AllShipsCard(item: item, reloadToken: reloadToken)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                case let .failed(message):
                    AllShipsErrorView(message: message) {
                        Task {
                            await loadCatalog(force: true)
                        }
                    }
                }
            }
            .id(appLanguageRawValue)
            .navigationTitle(AppLocalizer.string("All Ships"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                prompt: AppLocalizer.string("Search all ships")
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalizer.string("Done")) {
                        dismiss()
                    }
                }
            }
            .task {
                await loadCatalog(force: false)
            }
        }
    }

    private func loadCatalog(force: Bool) async {
        if !force,
           case .loaded = loadState {
            return
        }

        loadState = .loading

        do {
            async let shipCatalog = HostedShipCatalogStore.shared.catalog(using: HostedShipCatalogClient())
            async let detailCatalog = HostedShipDetailCatalogStore.shared.catalog(using: HostedShipDetailCatalogClient())
            let items = try await AllShipsCatalogItem.makeItems(
                shipCatalog: shipCatalog,
                detailCatalog: detailCatalog
            )
            loadState = .loaded(items)
            selectedPriceRange = Self.priceBounds(for: items)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private static func priceBounds(for items: [AllShipsCatalogItem]) -> ClosedRange<Double>? {
        let prices = items.compactMap(\.priceDouble)
        guard let maximumPrice = prices.max() else {
            return nil
        }

        let lowerBound = 0.0
        let upperBound = max(lowerBound, ceil(maximumPrice / 5) * 5)
        return lowerBound ... upperBound
    }
}

private enum AllShipsLoadState {
    case idle
    case loading
    case loaded([AllShipsCatalogItem])
    case failed(String)
}

private enum AllShipsAvailabilityFilter: String, CaseIterable, Identifiable {
    case all
    case available
    case unavailable

    var id: Self { self }

    var title: String {
        switch self {
        case .all:
            return AppLocalizer.string("Any Availability")
        case .available:
            return AppLocalizer.string("Available in Store")
        case .unavailable:
            return AppLocalizer.string("Unavailable in Store")
        }
    }

    func includes(item: AllShipsCatalogItem) -> Bool {
        switch self {
        case .all:
            return true
        case .available:
            return item.isAvailableInStore == true
        case .unavailable:
            return item.isAvailableInStore == false
        }
    }
}

private struct AllShipsCatalogItem: Identifiable, Hashable {
    let id: String
    let name: String
    let manufacturer: String
    let priceUSD: Decimal?
    let priceLabel: String?
    let storeAvailability: String?
    let inGameStatus: String?
    let imageURL: URL?

    var priceText: String {
        if let priceUSD {
            return priceUSD.usdString
        }

        return priceLabel?.nilIfBlank ?? AppLocalizer.string("MSRP unavailable")
    }

    var availabilityText: String {
        storeAvailability?.nilIfBlank ?? AppLocalizer.string("Unavailable")
    }

    var statusText: String {
        inGameStatus?.nilIfBlank ?? AppLocalizer.string("Unavailable")
    }

    var priceDouble: Double? {
        priceUSD.map { NSDecimalNumber(decimal: $0).doubleValue }
    }

    var isAvailableInStore: Bool? {
        guard let availability = storeAvailability?.nilIfBlank?.localizedLowercase else {
            return nil
        }

        if availability.contains("no longer")
            || availability.contains("not available")
            || availability.contains("unavailable")
            || availability.contains("not for sale") {
            return false
        }

        if availability.contains("available")
            || availability.contains("always")
            || availability.contains("limited")
            || availability.contains("sale") {
            return true
        }

        return nil
    }

    var searchHaystack: String {
        [
            name,
            manufacturer,
            priceText,
            storeAvailability,
            inGameStatus
        ]
        .compactMap { $0?.nilIfBlank }
        .joined(separator: " ")
        .localizedLowercase
    }

    func isWithinPriceRange(_ range: ClosedRange<Double>, fullRange: ClosedRange<Double>) -> Bool {
        guard let priceDouble else {
            return range.isEffectivelyEqual(to: fullRange)
        }

        return range.contains(priceDouble)
    }

    static func makeItems(
        shipCatalog: RSIShipCatalog,
        detailCatalog: RSIShipDetailCatalog
    ) -> [AllShipsCatalogItem] {
        let catalogItems = shipCatalog.ships.map { ship in
            let detail = detailCatalog.matchShip(named: ship.name)
            return AllShipsCatalogItem(
                id: "catalog-\(ship.id)",
                name: ship.name,
                manufacturer: manufacturerName(
                    catalogManufacturer: ship.manufacturer,
                    detailManufacturer: detail?.manufacturer
                ),
                priceUSD: ship.msrpUSD,
                priceLabel: ship.msrpLabel,
                storeAvailability: ship.storeAvailability ?? detail?.storeAvailability ?? detail?.pledgeAvailability,
                inGameStatus: detail?.inGameStatus,
                imageURL: ship.imageURL
            )
        }

        let catalogKeys = Set(shipCatalog.ships.map { UpgradeTitleParser.normalizedShipKey($0.name) })
        let detailOnlyItems = detailCatalog.ships.compactMap { detail -> AllShipsCatalogItem? in
            let detailKey = UpgradeTitleParser.normalizedShipKey(detail.name)
            guard !catalogKeys.contains(detailKey) else {
                return nil
            }

            return AllShipsCatalogItem(
                id: "detail-\(detailKey)",
                name: detail.name,
                manufacturer: manufacturerName(catalogManufacturer: nil, detailManufacturer: detail.manufacturer),
                priceUSD: nil,
                priceLabel: nil,
                storeAvailability: detail.storeAvailability ?? detail.pledgeAvailability,
                inGameStatus: detail.inGameStatus,
                imageURL: nil
            )
        }

        return (catalogItems + detailOnlyItems).sorted { lhs, rhs in
            switch (lhs.priceUSD, rhs.priceUSD) {
            case let (lhsPrice?, rhsPrice?):
                let comparison = NSDecimalNumber(decimal: lhsPrice).compare(NSDecimalNumber(decimal: rhsPrice))
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func manufacturerName(catalogManufacturer: String?, detailManufacturer: String?) -> String {
        let rawManufacturer = catalogManufacturer?.nilIfBlank ?? detailManufacturer?.nilIfBlank
        guard let rawManufacturer else {
            return AppLocalizer.string("Unknown Manufacturer")
        }

        return FleetPresentationFormatter.manufacturerDisplayName(rawManufacturer)
    }
}

private struct AllShipsQuickFilters: View {
    @Binding var priceRange: ClosedRange<Double>
    let priceBounds: ClosedRange<Double>
    @Binding var availabilityFilter: AllShipsAvailabilityFilter
    let resultCount: Int
    let totalCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(AppLocalizer.string("Price Range"))
                        .font(.headline.weight(.semibold))

                    Spacer(minLength: 12)

                    Text(priceRangeSummary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                AllShipsPriceRangeSlider(
                    range: $priceRange,
                    bounds: priceBounds
                )
                .disabled(priceBounds.lowerBound == priceBounds.upperBound)

                HStack(spacing: 10) {
                    AllShipsPriceNumberField(
                        title: AppLocalizer.string("Min"),
                        value: Binding(
                            get: { priceRange.lowerBound },
                            set: { updateLowerPrice($0) }
                        )
                    )

                    AllShipsPriceNumberField(
                        title: AppLocalizer.string("Max"),
                        value: Binding(
                            get: { priceRange.upperBound },
                            set: { updateUpperPrice($0) }
                        )
                    )
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )

            HStack(spacing: 10) {
                filterMenu(
                    title: AppLocalizer.string("Availability"),
                    value: availabilityFilter.title
                ) {
                    Picker(AppLocalizer.string("Availability"), selection: $availabilityFilter) {
                        ForEach(AllShipsAvailabilityFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                }
            }

            Text(AppLocalizer.format("Showing %lld of %lld ships", resultCount, totalCount))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
    }

    private var priceRangeSummary: String {
        "\(currencyText(for: priceRange.lowerBound)) - \(currencyText(for: priceRange.upperBound))"
    }

    private func updateLowerPrice(_ value: Double) {
        let nextLowerBound = min(clampedPrice(value), priceRange.upperBound)
        priceRange = nextLowerBound ... priceRange.upperBound
    }

    private func updateUpperPrice(_ value: Double) {
        let nextUpperBound = max(clampedPrice(value), priceRange.lowerBound)
        priceRange = priceRange.lowerBound ... nextUpperBound
    }

    private func clampedPrice(_ value: Double) -> Double {
        max(priceBounds.lowerBound, min(priceBounds.upperBound, value.rounded()))
    }

    private func filterMenu<Content: View>(
        title: String,
        value: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }

    private func currencyText(for value: Double) -> String {
        NSDecimalNumber(value: value).decimalValue.usdString
    }
}

private struct AllShipsPriceNumberField: View {
    let title: String
    @Binding var value: Double

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Text("$")
                    .foregroundStyle(.secondary)

                TextField("0", text: $text)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .focused($isFocused)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemGroupedBackground))
            )
        }
        .onAppear {
            text = rawText(for: value)
        }
        .onChange(of: value) { _, newValue in
            guard !isFocused else {
                return
            }

            text = rawText(for: newValue)
        }
        .onChange(of: text) { _, newText in
            guard isFocused else {
                return
            }

            let sanitizedText = newText.filter(\.isNumber)
            if sanitizedText != newText {
                text = sanitizedText
                return
            }

            guard !sanitizedText.isEmpty,
                  let parsedValue = Double(sanitizedText) else {
                return
            }

            value = parsedValue
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                text = rawText(for: value)
            }
        }
    }

    private func rawText(for value: Double) -> String {
        String(Int(value.rounded()))
    }
}

private struct AllShipsPriceRangeSlider: View {
    @Binding var range: ClosedRange<Double>
    let bounds: ClosedRange<Double>
    @State private var dragStartRange: ClosedRange<Double>?

    private let handleDiameter: CGFloat = 28
    private let step: Double = 5

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width - handleDiameter, 1)
            let lowerX = xPosition(for: range.lowerBound, width: width)
            let upperX = xPosition(for: range.upperBound, width: width)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: width, height: 6)
                    .offset(x: handleDiameter / 2)

                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.65))
                    .frame(width: max(upperX - lowerX, 0), height: 6)
                    .offset(x: lowerX + handleDiameter / 2)

                sliderHandle
                    .offset(x: lowerX)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                updateLowerBound(
                                    translation: value.translation.width,
                                    width: width
                                )
                            }
                            .onEnded { _ in
                                dragStartRange = nil
                            }
                    )

                sliderHandle
                    .offset(x: upperX)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                updateUpperBound(
                                    translation: value.translation.width,
                                    width: width
                                )
                            }
                            .onEnded { _ in
                                dragStartRange = nil
                            }
                    )
            }
            .frame(height: handleDiameter)
        }
        .frame(height: handleDiameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalizer.string("Price Range"))
        .accessibilityValue("\(NSDecimalNumber(value: range.lowerBound).decimalValue.usdString) - \(NSDecimalNumber(value: range.upperBound).decimalValue.usdString)")
    }

    private var sliderHandle: some View {
        Circle()
            .fill(Color(.systemBackground))
            .frame(width: handleDiameter, height: handleDiameter)
            .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 3)
            .overlay {
                Circle()
                    .stroke(Color.accentColor.opacity(0.72), lineWidth: 2)
            }
    }

    private func xPosition(for value: Double, width: CGFloat) -> CGFloat {
        let span = max(bounds.upperBound - bounds.lowerBound, 1)
        let normalizedValue = (value - bounds.lowerBound) / span
        return CGFloat(max(0, min(1, normalizedValue))) * width
    }

    private func steppedClampedValue(_ value: Double) -> Double {
        let steppedValue = (value / step).rounded() * step
        return max(bounds.lowerBound, min(bounds.upperBound, steppedValue))
    }

    private func valueDelta(for translation: CGFloat, width: CGFloat) -> Double {
        let span = max(bounds.upperBound - bounds.lowerBound, 1)
        return Double(translation / max(width, 1)) * span
    }

    private func updateLowerBound(translation: CGFloat, width: CGFloat) {
        let startRange = dragStartRange ?? range
        dragStartRange = startRange
        let proposedLowerBound = startRange.lowerBound + valueDelta(for: translation, width: width)
        let nextLowerBound = min(steppedClampedValue(proposedLowerBound), startRange.upperBound)
        range = nextLowerBound ... startRange.upperBound
    }

    private func updateUpperBound(translation: CGFloat, width: CGFloat) {
        let startRange = dragStartRange ?? range
        dragStartRange = startRange
        let proposedUpperBound = startRange.upperBound + valueDelta(for: translation, width: width)
        let nextUpperBound = max(steppedClampedValue(proposedUpperBound), startRange.lowerBound)
        range = startRange.lowerBound ... nextUpperBound
    }
}

private struct AllShipsCard: View {
    let item: AllShipsCatalogItem
    let reloadToken: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteThumbnailView(
                url: item.imageURL,
                reloadToken: reloadToken,
                fallbackSystemImage: "airplane",
                size: 78
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(item.manufacturer)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    AllShipsStatusPill(title: item.statusText)
                }

                VStack(alignment: .leading, spacing: 6) {
                    AllShipsMetadataRow(label: AppLocalizer.string("Price"), value: item.priceText)
                    AllShipsMetadataRow(label: AppLocalizer.string("Availability in RSI Store"), value: item.availabilityText)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

private struct AllShipsStatusPill: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(statusTint)
            )
    }

    private var statusTint: Color {
        let normalizedTitle = title.localizedLowercase
        if normalizedTitle.contains("flight") {
            return Color.green.opacity(0.68)
        }

        if normalizedTitle.contains("concept")
            || normalizedTitle.contains("production")
            || normalizedTitle.contains("development") {
            return Color.orange.opacity(0.72)
        }

        if normalizedTitle.contains("unavailable") {
            return Color.secondary.opacity(0.55)
        }

        return Color.accentColor.opacity(0.68)
    }
}

private struct AllShipsMetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AllShipsLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()

            Text(AppLocalizer.string("Loading all ships"))
                .font(.headline)

            Text(AppLocalizer.string("Loading the hosted ship catalog."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct AllShipsEmptyView: View {
    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text(AppLocalizer.string("No matching ships"))
                .font(.headline)

            Text(AppLocalizer.string("Try a different search term or loosen the filters."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

private struct AllShipsErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)

            Text(AppLocalizer.string("Unable to Load Ships"))
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(AppLocalizer.string("Try Again"), action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension ClosedRange where Bound == Double {
    func isEffectivelyEqual(to other: ClosedRange<Double>) -> Bool {
        abs(lowerBound - other.lowerBound) < 0.001
            && abs(upperBound - other.upperBound) < 0.001
    }
}

private struct FleetShipPledgeSheetContext: Identifiable {
    let shipName: String
    let packageGroups: [GroupedHangarPackage]

    var id: String {
        shipName
    }
}

private struct FleetShipPledgeSheet: View {
    let appModel: AppModel
    let context: FleetShipPledgeSheetContext
    let reloadToken: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(context.packageGroups) { packageGroup in
                        NavigationLink {
                            HangarPackageDetailView(
                                appModel: appModel,
                                packageGroup: packageGroup,
                                reloadToken: reloadToken
                            )
                        } label: {
                            HangarPackageGroupRow(
                                packageGroup: packageGroup,
                                reloadToken: reloadToken
                            )
                        }
                    }
                } header: {
                    Text(headerTitle)
                }
            }
            .navigationTitle(context.shipName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var headerTitle: String {
        if context.packageGroups.count == 1 {
            return AppLocalizer.string("1 pledge includes this ship")
        }

        return AppLocalizer.format("%lld pledges include this ship", context.packageGroups.count)
    }
}

private struct FleetManufacturerLogo: View {
    let manufacturerName: String
    let logoURL: URL?
    let reloadToken: UUID?
    let maxHeight: CGFloat
    let maxWidth: CGFloat

    private var adjustedMaxWidth: CGFloat {
        maxWidth * FleetManufacturerLogoSizing.widthMultiplier(for: manufacturerName)
    }

    var body: some View {
        if let logoURL {
            CachedRemoteImage(
                url: logoURL,
                targetSize: CGSize(width: maxHeight * 6, height: maxHeight * 3),
                reloadToken: reloadToken,
                maxRetryCount: 5,
                trimsTransparentPadding: true
            ) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(
                            maxWidth: adjustedMaxWidth,
                            maxHeight: maxHeight,
                            alignment: .trailing
                        )
                        .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 2)
                        .compositingGroup()
                case .empty:
                    ProgressView()
                        .tint(.white.opacity(0.9))
                        .frame(width: maxHeight, height: maxHeight)
                case .failure:
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: min(maxHeight * 0.5, 28), weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .frame(width: maxHeight, height: maxHeight)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: min(maxHeight * 0.5, 28), weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.8))
                .frame(width: maxHeight, height: maxHeight)
        }
    }

}

private struct FleetShipHeroCard: View {
    let shipGroup: GroupedFleetShip
    let subtitle: String?
    let msrpSummary: String
    let reloadToken: UUID?
    @State private var showsCatalogWarning = false

    private var ship: FleetShip {
        shipGroup.representative
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                heroCardBase(size: proxy.size)

                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(ship.displayName)
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                                .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 1)

                            if ship.catalogWarning != nil {
                                Button {
                                    showsCatalogWarning = true
                                } label: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color.orange.opacity(0.96))
                                        .padding(7)
                                        .background(
                                            Circle()
                                                .fill(Color.black.opacity(0.28))
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Ship info incomplete")
                            }

                            if shipGroup.quantity > 1 {
                                Text("x\(shipGroup.quantity)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.cyan.opacity(0.28))
                                    )
                            }
                        }

                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.white.opacity(0.8))
                                .lineLimit(1)
                                .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 1)
                        }
                    }
                    .padding(.trailing, 152)

                    Spacer(minLength: 14)

                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(shipGroup.sourcePackageSummary)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.white.opacity(0.92))
                                .lineLimit(2)

                            Text(msrpSummary)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.white.opacity(0.74))

                            if let warning = ship.catalogWarning {
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.orange.opacity(0.95))
                                    .lineLimit(2)
                            }
                        }

                        Spacer(minLength: 0)

                        fleetBadge(ship.insurance, tint: Color.cyan.opacity(0.18))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 212, alignment: .bottomLeading)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .alert("Ship Info Incomplete", isPresented: $showsCatalogWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ship.catalogWarning ?? AppLocalizer.string("Ship info incomplete. Please send the dev a screenshot so it can be patched."))
        }
    }

    private func heroCardBase(size: CGSize) -> some View {
        let recipe = FleetCardBaseSnapshotRecipe(
            style: .hero,
            pointSize: size,
            manufacturerName: ship.manufacturer,
            backdropURL: ship.imageURL,
            logoURL: ship.manufacturerLogoURL
        )

        return CachedFleetCardBaseImage(
            recipe: recipe,
            reloadToken: reloadToken
        ) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            case .empty:
                FleetCardBaseSnapshotPlaceholder(recipe: recipe, showsProgress: true)
            case .failure:
                FleetCardBaseSnapshotPlaceholder(recipe: recipe)
            }
        }
    }

    private func fleetBadge(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.94))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint)
            )
    }
}

private struct FleetShipCompactCard: View {
    let shipGroup: GroupedFleetShip
    let subtitle: String?
    let msrpSummary: String
    let reloadToken: UUID?

    @State private var showsCatalogWarning = false

    private var ship: FleetShip {
        shipGroup.representative
    }

    private var shouldShowSourcePackageSummary: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom != .phone
#else
        true
#endif
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                compactCardBase(size: proxy.size)

                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 8) {
                            Text(ship.displayName)
                                .font(.headline.weight(.heavy))
                                .foregroundStyle(.white)
                                .lineLimit(3)
                                .minimumScaleFactor(0.82)

                            if ship.catalogWarning != nil {
                                Button {
                                    showsCatalogWarning = true
                                } label: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color.orange.opacity(0.96))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Ship info incomplete")
                            }
                        }

                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.white.opacity(0.82))
                                .lineLimit(2)
                        }
                    }
                    .padding(.top, 10)
                    .padding(.trailing, compactTitleTrailingPadding(forCardWidth: proxy.size.width))

                    Spacer(minLength: 14)

                    VStack(alignment: .leading, spacing: 5) {
                        if shouldShowSourcePackageSummary {
                            Text(shipGroup.sourcePackageSummary)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.white.opacity(0.9))
                                .lineLimit(2)
                        }

                        Text(msrpSummary)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.76))
                            .lineLimit(1)

                        if ship.catalogWarning != nil {
                            Text("Info incomplete. Send screenshot.")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.orange.opacity(0.95))
                                .lineLimit(2)
                        }
                    }

                    HStack(alignment: .center, spacing: 8) {
                        if shipGroup.quantity > 1 {
                            compactBadge("x\(shipGroup.quantity)", tint: Color.cyan.opacity(0.24))
                        }

                        Spacer(minLength: 0)

                        compactBadge(ship.insurance, tint: Color.cyan.opacity(0.18))
                    }
                    .padding(.top, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 232, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .alert("Ship Info Incomplete", isPresented: $showsCatalogWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ship.catalogWarning ?? AppLocalizer.string("Ship info incomplete. Please send the dev a screenshot so it can be patched."))
        }
    }

    private func compactTitleTrailingPadding(forCardWidth cardWidth: CGFloat) -> CGFloat {
        let desiredLogoClearance: CGFloat = 56
        let halfWidthSafePadding = max(24, (cardWidth / 2) - 32)
        return min(desiredLogoClearance, halfWidthSafePadding)
    }

    private func compactCardBase(size: CGSize) -> some View {
        let recipe = FleetCardBaseSnapshotRecipe(
            style: .compact,
            pointSize: size,
            manufacturerName: ship.manufacturer,
            backdropURL: ship.imageURL,
            logoURL: ship.manufacturerLogoURL
        )

        return CachedFleetCardBaseImage(
            recipe: recipe,
            reloadToken: reloadToken
        ) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            case .empty:
                FleetCardBaseSnapshotPlaceholder(recipe: recipe, showsProgress: true)
            case .failure:
                FleetCardBaseSnapshotPlaceholder(recipe: recipe)
            }
        }
    }

    private func compactBadge(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white.opacity(0.96))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint)
            )
            .lineLimit(1)
    }
}

private struct FleetShipDetailView: View {
    let shipGroup: GroupedFleetShip
    let reloadToken: UUID?
    let transitionNamespace: Namespace.ID

    @State private var loadState: FleetShipDetailLoadState = .loading

    private var ship: FleetShip {
        shipGroup.representative
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    FleetShipDetailHeroCard(
                        shipGroup: shipGroup,
                        detail: loadState.detail,
                        reloadToken: reloadToken
                    )

                    switch loadState {
                    case .loading:
                        FleetShipDetailLoadingCard()

                    case let .loaded(detail):
                        FleetShipOverviewCard(detail: detail)

                        if detail.isUnavailable {
                            FleetShipUnavailableCard(
                                message: detail.unavailableReason
                                    ?? AppLocalizer.string("Ship info unavailable for this variant.")
                            )
                        }

                        if !detail.isUnavailable || detail.description?.nilIfBlank != nil {
                            FleetShipDescriptionCard(description: detail.description)
                        }

                        if detail.hasSpecificationData {
                            FleetShipLoadoutCard(detail: detail)
                        }

                        FleetShipTechnicalSpecsCard(detail: detail)

                        FleetShipSourceLinks(detail: detail)

                    case let .unavailable(message):
                        FleetShipUnavailableCard(message: message)

                    case let .failed(message):
                        FleetShipUnavailableCard(message: message)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .frame(width: proxy.size.width, alignment: .topLeading)
            }
            .contentMargins(.top, 0, for: .scrollContent)
            .clipped()
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(ship.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTransition(
            .zoom(
                sourceID: shipGroup.id,
                in: transitionNamespace
            )
        )
        .task(id: ship.id) {
            await loadShipDetail()
        }
    }

    private func loadShipDetail() async {
        if case .loaded = loadState {
            return
        }

        loadState = .loading

        do {
            let detailCatalog = try await HostedShipDetailCatalogStore.shared.catalog(
                using: HostedShipDetailCatalogClient()
            )

            guard let detail = detailCatalog.matchShip(named: ship.displayName) else {
                loadState = .unavailable(AppLocalizer.string("Ship info unavailable for this variant."))
                return
            }

            loadState = .loaded(detail)
        } catch {
            loadState = .failed(
                AppLocalizer.format("Unable to load ship info right now. %@", error.localizedDescription)
            )
        }
    }
}

private enum FleetShipDetailLoadState {
    case loading
    case loaded(RSIShipDetailCatalog.ShipDetail)
    case unavailable(String)
    case failed(String)

    var detail: RSIShipDetailCatalog.ShipDetail? {
        if case let .loaded(detail) = self {
            return detail
        }

        return nil
    }
}

private struct FleetShipDetailHeroCard: View {
    let shipGroup: GroupedFleetShip
    let detail: RSIShipDetailCatalog.ShipDetail?
    let reloadToken: UUID?

    private var ship: FleetShip {
        shipGroup.representative
    }

    private var roleSummary: String? {
        if let detail {
            return FleetRoleFormatter.summary(type: detail.career, focus: detail.role)
        }

        return FleetPresentationFormatter.roleSummary(
            role: ship.role,
            categories: ship.roleCategories
        )
    }

    private var manufacturerName: String {
        detail?.manufacturer ?? ship.manufacturer
    }

    private var manufacturerLogoURL: URL? {
        detail?.manufacturerLogoURL ?? ship.manufacturerLogoURL
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.11, blue: 0.16),
                            Color(red: 0.06, green: 0.18, blue: 0.25),
                            Color(red: 0.05, green: 0.26, blue: 0.31)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.cyan.opacity(0.18), lineWidth: 1)
                }

            GeometryReader { proxy in
                ZStack {
                    Color.black.opacity(0.2)

                    CachedRemoteImage(
                        url: ship.imageURL,
                        targetSize: proxy.size,
                        reloadToken: reloadToken,
                        maxRetryCount: 5
                    ) { phase in
                        switch phase {
                        case let .success(image):
                            detailBackdropImage(image, size: proxy.size)
                        case .empty:
                            ProgressView()
                                .tint(.white.opacity(0.85))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        case .failure:
                            Image(systemName: "airplane")
                                .font(.system(size: 56, weight: .light))
                                .foregroundStyle(Color.white.opacity(0.16))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            .overlay(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.78),
                        Color.black.opacity(0.48),
                        Color.black.opacity(0.12)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(detail?.name ?? ship.displayName)
                        .font(.system(size: 34, weight: .heavy, design: .default))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.72)
                }
                .padding(.trailing, 176)

                Spacer(minLength: 18)

                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 14) {
                        if let roleSummary, !roleSummary.isEmpty {
                            Text(roleSummary)
                                .font(.headline.weight(.medium))
                                .foregroundStyle(Color.white.opacity(0.84))
                                .lineLimit(2)
                        }

                        HStack(spacing: 10) {
                            FleetShipDetailPill(
                                title: AppLocalizer.format("Crew %@", detail?.crewSummary ?? AppLocalizer.string("Unavailable")),
                                tint: Color.white.opacity(0.10)
                            )

                            FleetShipDetailPill(
                                title: detail?.size?.nilIfBlank ?? AppLocalizer.string("Size unavailable"),
                                tint: Color.white.opacity(0.10)
                            )
                        }
                    }

                    Spacer(minLength: 0)

                    if let status = detail?.inGameStatus?.nilIfBlank {
                        FleetShipDetailPill(
                            title: status,
                            tint: Color.cyan.opacity(0.24)
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .overlay(alignment: .topTrailing) {
            FleetManufacturerLogo(
                manufacturerName: manufacturerName,
                logoURL: manufacturerLogoURL,
                reloadToken: reloadToken,
                maxHeight: 66,
                maxWidth: 98
            )
            .padding(.top, 16)
            .padding(.trailing, 18)
            .zIndex(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func detailBackdropImage(_ image: Image, size: CGSize) -> some View {
        image
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
    }
}

private struct FleetShipOverviewCard: View {
    let detail: RSIShipDetailCatalog.ShipDetail

    var body: some View {
        FleetShipDetailPanel(title: "SHIP OVERVIEW", subtitle: nil) {
            VStack(spacing: 0) {
                FleetShipOverviewRow(label: "Role", value: detail.role?.nilIfBlank ?? AppLocalizer.string("Unavailable"))
                FleetShipOverviewRow(label: "Function", value: detail.career?.nilIfBlank ?? AppLocalizer.string("Unavailable"))
                FleetShipOverviewRow(label: "Max Crew", value: detail.maxCrew.map(String.init) ?? detail.crewSummary ?? AppLocalizer.string("Unavailable"))
                FleetShipOverviewRow(label: "Size", value: detail.size?.nilIfBlank ?? AppLocalizer.string("Unavailable"))
                FleetShipOverviewRow(label: "In Game Status", value: detail.inGameStatus?.nilIfBlank ?? AppLocalizer.string("Unavailable"))
                FleetShipOverviewRow(
                    label: "Pledge Availability",
                    value: detail.pledgeAvailability?.nilIfBlank ?? AppLocalizer.string("Unavailable"),
                    showsDivider: false
                )
            }
        }
    }
}

private struct FleetShipDescriptionCard: View {
    let description: String?

    var body: some View {
        FleetShipDetailPanel(title: "DESCRIPTION", subtitle: nil) {
            Text(description?.nilIfBlank ?? AppLocalizer.string("Description unavailable."))
                .font(.body)
                .foregroundStyle(Color.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FleetShipLoadoutCard: View {
    let detail: RSIShipDetailCatalog.ShipDetail

    var body: some View {
        FleetShipDetailPanel(
            title: "LOADOUT",
            subtitle: "Powered by SPViewer."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if !detail.weaponsUtilitySections.isEmpty {
                    FleetShipSpecificationCategoryView(
                        title: "WEAPONS & UTILITY",
                        summary: detail.weaponsUtilitySummary,
                        sections: detail.weaponsUtilitySections
                    )
                }

                if !detail.componentSections.isEmpty {
                    FleetShipSpecificationCategoryView(
                        title: "COMPONENTS",
                        summary: detail.componentSummary,
                        sections: detail.componentSections
                    )
                }
            }
        }
    }
}

private struct FleetShipSpecificationCategoryView: View {
    let title: LocalizedStringKey
    let summary: RSIShipDetailCatalog.SpecificationSummary
    let sections: [RSIShipDetailCatalog.SpecificationSection]

    private var summaryText: String? {
        guard summary.totalEntries > 0 else {
            return nil
        }

        return AppLocalizer.format(
            "%lld total across %lld entries",
            summary.totalCount,
            summary.totalEntries
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.cyan.opacity(0.9))

                Spacer(minLength: 0)

                if let summaryText {
                    Text(summaryText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .multilineTextAlignment(.trailing)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(sections.indices, id: \.self) { index in
                    FleetShipSpecificationSectionView(section: sections[index])
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.cyan.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct FleetShipSpecificationSectionView: View {
    let section: RSIShipDetailCatalog.SpecificationSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(section.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))

                Spacer(minLength: 0)

                if !section.summaryBySize.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(section.summaryBySize.indices, id: \.self) { index in
                            let summary = section.summaryBySize[index]
                            FleetShipSpecCountPill(summary: summary)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(section.items.indices, id: \.self) { index in
                    FleetShipSpecificationItemRow(item: section.items[index])
                }
            }
        }
        .padding(.top, 4)
    }
}

private struct FleetShipSpecificationItemRow: View {
    let item: RSIShipDetailCatalog.SpecificationItem

    private var leadingLabel: String? {
        let parts = [item.quantityLabel, item.size].compactMap { $0?.nilIfBlank }
        guard !parts.isEmpty else {
            return nil
        }

        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle = item.subtitle?.nilIfBlank {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            if let leadingLabel {
                Text(leadingLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.cyan.opacity(0.86))
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.16))
        )
    }
}

private struct FleetShipSpecCountPill: View {
    let summary: RSIShipDetailCatalog.SizeSummary

    private var label: String {
        guard let size = summary.size?.nilIfBlank else {
            return "\(summary.count)x"
        }

        return "\(summary.count)x \(size)"
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white.opacity(0.86))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.cyan.opacity(0.16))
            )
            .lineLimit(1)
    }
}

private struct FleetShipSourceLinks: View {
    let detail: RSIShipDetailCatalog.ShipDetail

    private static let spviewerFallbackURL = URL(string: "https://www.spviewer.eu/")!

    private var wikiURL: URL? {
        detail.pageURL
    }

    private var spviewerURL: URL? {
        guard detail.hasSpecificationData else {
            return nil
        }

        return detail.spviewerPageURL ?? Self.spviewerFallbackURL
    }

    var body: some View {
        if wikiURL != nil || spviewerURL != nil {
            HStack(spacing: 12) {
                if let wikiURL {
                    sourceLink(title: "Wiki", systemImage: "book", destination: wikiURL)
                }

                if let spviewerURL {
                    sourceLink(title: "SPViewer", systemImage: "scope", destination: spviewerURL)
                }
            }
        }
    }

    private func sourceLink(
        title: LocalizedStringKey,
        systemImage: String,
        destination: URL
    ) -> some View {
        Link(destination: destination) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.cyan.opacity(0.22))
    }
}

private struct FleetShipTechnicalSpecsCard: View {
    let detail: RSIShipDetailCatalog.ShipDetail

    private let columns = [
        GridItem(.flexible(), spacing: 16, alignment: .top),
        GridItem(.flexible(), spacing: 16, alignment: .top)
    ]

    var body: some View {
        FleetShipDetailPanel(
            title: "TECHNICAL SPECS",
            subtitle: nil
        ) {
            VStack(alignment: .leading, spacing: 20) {
                if !detail.technicalSpecs.isEmpty {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(detail.technicalSpecs.indices, id: \.self) { index in
                            FleetShipSpecTile(item: detail.technicalSpecs[index])
                        }
                    }
                }

                if !detail.technicalSectionsForDisplay.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(detail.technicalSectionsForDisplay.indices, id: \.self) { index in
                            FleetShipTechnicalSectionCard(section: detail.technicalSectionsForDisplay[index])
                        }
                    }
                }

                if detail.technicalSpecs.isEmpty, detail.technicalSectionsForDisplay.isEmpty {
                    Text("Technical specs unavailable.")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.72))
                }
            }
        }
    }
}

private struct FleetShipDetailLoadingCard: View {
    var body: some View {
        FleetShipDetailPanel(title: "LOADING SHIP DATA", subtitle: "Fetching the hosted ship detail feed") {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(.white)

                Text("Loading ship detail...")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.84))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FleetShipUnavailableCard: View {
    let message: String

    var body: some View {
        FleetShipDetailPanel(title: "SHIP INFO UNAVAILABLE", subtitle: "No hosted variant data is available for this ship.") {
            Text(message)
                .font(.body)
                .foregroundStyle(Color.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FleetShipDetailPanel<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(.white)

                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.07, green: 0.19, blue: 0.28),
                            Color(red: 0.06, green: 0.22, blue: 0.31)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.cyan.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct FleetShipOverviewRow: View {
    let label: LocalizedStringKey
    let value: String
    var showsDivider: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.7))

                Spacer(minLength: 0)

                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 12)

            if showsDivider {
                Divider()
                    .overlay(Color.cyan.opacity(0.14))
            }
        }
    }
}

private struct FleetShipSpecTile: View {
    let item: RSIShipDetailCatalog.SpecItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.label.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(Color.cyan.opacity(0.78))

            if let value = item.value.nilIfBlank {
                Text(value)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.cyan.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct FleetShipTechnicalSectionCard: View {
    let section: RSIShipDetailCatalog.TechnicalSection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title.uppercased())
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.cyan.opacity(0.9))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(section.items.indices, id: \.self) { index in
                    let item = section.items[index]
                    if let value = item.value.nilIfBlank {
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(item.label)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.white.opacity(0.72))

                            Spacer(minLength: 0)

                            Text(value)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .multilineTextAlignment(.trailing)
                        }
                    } else {
                        Text(item.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.8))
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.cyan.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct FleetShipDetailPill: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.94))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(tint)
            )
            .lineLimit(1)
    }
}

private struct FleetDisplaySection: Identifiable {
    let title: String?
    let shipGroups: [GroupedFleetShip]

    var id: String {
        title ?? "all-ships"
    }
}

private extension String {
    var logoSizingKey: String {
        unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .localizedLowercase
    }

    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
