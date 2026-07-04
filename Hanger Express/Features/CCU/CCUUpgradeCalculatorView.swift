import SwiftUI

struct CCUUpgradeCalculatorView: View {
    let snapshot: HangarSnapshot
    let reloadToken: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var loadState: CCUUpgradeCalculatorLoadState = .idle
    @State private var selectedSourceKey: String?
    @State private var selectedDestinationKey: String?
    @State private var isRefreshingCatalog = false
    @State private var routeCalculationState: CCUUpgradeRouteCalculationState = .idle

    private var loadedCatalog: CCUUpgradeCalculatorCatalog? {
        guard case let .loaded(catalog) = loadState else {
            return nil
        }

        return catalog
    }

    private var catalogShips: [CCUUpgradeCatalogShip] {
        loadedCatalog?.ships ?? []
    }

    private var selectedSourceShip: CCUUpgradeCatalogShip? {
        selectedSourceKey.flatMap { key in
            catalogShips.first { $0.key == key }
        }
    }

    private var selectedDestinationShip: CCUUpgradeCatalogShip? {
        selectedDestinationKey.flatMap { key in
            catalogShips.first { $0.key == key }
        }
    }

    private var routeCalculationRequest: CCUUpgradeRouteCalculationRequest? {
        guard let catalog = loadedCatalog,
              let selectedSourceShip,
              let selectedDestinationShip,
              selectedSourceShip.msrpUSD.isLessThan(selectedDestinationShip.msrpUSD) else {
            return nil
        }

        return CCUUpgradeRouteCalculationRequest(
            catalogID: catalog.id,
            sourceKey: selectedSourceShip.key,
            destinationKey: selectedDestinationShip.key
        )
    }

    private var isLoadingCatalog: Bool {
        if case .loading = loadState {
            return true
        }

        return false
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(value: CCUUpgradeShipPickerRole.source) {
                        CCUUpgradeShipSelectionRow(
                            title: AppLocalizer.string("Source Ship"),
                            ship: selectedSourceShip,
                            placeholder: AppLocalizer.string("Choose source"),
                            reloadToken: reloadToken
                        )
                    }
                    .disabled(catalogShips.isEmpty)

                    NavigationLink(value: CCUUpgradeShipPickerRole.destination) {
                        CCUUpgradeShipSelectionRow(
                            title: AppLocalizer.string("Destination Ship"),
                            ship: selectedDestinationShip,
                            placeholder: AppLocalizer.string("Choose destination"),
                            reloadToken: reloadToken
                        )
                    }
                    .disabled(catalogShips.isEmpty)
                } header: {
                    Text("Ships")
                } footer: {
                    Text("Store availability comes from the hosted Star Citizen ship feed.")
                }

                catalogStatusSection
                calculationSection
            }
            .navigationTitle("CCU Calculator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            await refreshCatalog()
                        }
                    } label: {
                        if isRefreshingCatalog || isLoadingCatalog {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Refresh")
                        }
                    }
                    .disabled(isRefreshingCatalog || isLoadingCatalog)
                    .accessibilityLabel(AppLocalizer.string("Refresh hosted ship catalog"))
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .navigationDestination(for: CCUUpgradeShipPickerRole.self) { role in
                CCUUpgradeShipPickerView(
                    role: role,
                    ships: selectableShips(for: role),
                    selectedKey: binding(for: role),
                    reloadToken: reloadToken
                )
            }
            .task {
                await loadCatalog(force: true)
            }
            .task(id: routeCalculationRequest) {
                await calculateRoute(for: routeCalculationRequest)
            }
        }
    }

    @ViewBuilder
    private var catalogStatusSection: some View {
        switch loadState {
        case .idle, .loaded:
            EmptyView()
        case .loading:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading hosted ship catalog...")
                        .foregroundStyle(.secondary)
                }
            }
        case let .failed(message):
            Section {
                ContentUnavailableView(
                    "Unable to Load Ships",
                    systemImage: "wifi.exclamationmark",
                    description: Text(message)
                )

                Button("Try Again") {
                    Task {
                        await loadCatalog(force: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var calculationSection: some View {
        Section {
            if case .loaded = loadState {
                if selectedSourceShip == nil || selectedDestinationShip == nil {
                    ContentUnavailableView(
                        "Select Ships",
                        systemImage: "arrow.left.arrow.right",
                        description: Text("Choose both ships to calculate the chain.")
                    )
                } else if let selectedSourceShip,
                          let selectedDestinationShip,
                          !selectedSourceShip.msrpUSD.isLessThan(selectedDestinationShip.msrpUSD) {
                    ContentUnavailableView(
                        "Destination Too Low",
                        systemImage: "exclamationmark.triangle",
                        description: Text("The destination ship must have a higher MSRP than the source ship.")
                    )
                } else if let routeCalculationRequest {
                    switch routeCalculationState {
                    case let .loaded(loadedRequest, route) where loadedRequest == routeCalculationRequest:
                        if let route {
                            CCUUpgradeRouteSummaryCard(route: route)

                            if route.hasUnavailableStoreStep {
                                CCUUpgradeRouteWarningView()
                            }

                            ForEach(Array(route.steps.enumerated()), id: \.element.id) { offset, step in
                                CCUUpgradeStepRow(
                                    number: offset + 1,
                                    step: step,
                                    paymentRequirement: route.paymentRequirement(for: step),
                                    reloadToken: reloadToken
                                )
                            }
                        } else {
                            ContentUnavailableView(
                                "No CCU Path",
                                systemImage: "link.badge.plus",
                                description: Text("No valid upgrade chain was found for these ships.")
                            )
                        }
                    default:
                        HStack(spacing: 12) {
                            ProgressView()

                            Text("Calculating CCU chain...")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No CCU Path",
                        systemImage: "link.badge.plus",
                        description: Text("No valid upgrade chain was found for these ships.")
                    )
                }
            }
        } header: {
            Text("Calculation")
        }
    }

    private func selectableShips(for role: CCUUpgradeShipPickerRole) -> [CCUUpgradeCatalogShip] {
        switch role {
        case .source:
            guard let selectedDestinationShip else {
                return catalogShips
            }

            return catalogShips.filter { $0.msrpUSD.isLessThan(selectedDestinationShip.msrpUSD) }
        case .destination:
            guard let selectedSourceShip else {
                return catalogShips
            }

            return catalogShips.filter { $0.msrpUSD.isGreaterThan(selectedSourceShip.msrpUSD) }
        }
    }

    private func binding(for role: CCUUpgradeShipPickerRole) -> Binding<String?> {
        switch role {
        case .source:
            return Binding(
                get: { selectedSourceKey },
                set: { selectedSourceKey = $0 }
            )
        case .destination:
            return Binding(
                get: { selectedDestinationKey },
                set: { selectedDestinationKey = $0 }
            )
        }
    }

    @MainActor
    private func refreshCatalog() async {
        guard !isRefreshingCatalog else {
            return
        }

        isRefreshingCatalog = true
        defer {
            isRefreshingCatalog = false
        }

        await loadCatalog(force: true, showsLoadingState: false)
    }

    @MainActor
    private func loadCatalog(force: Bool, showsLoadingState: Bool = true) async {
        if !force,
           case .loaded = loadState {
            return
        }

        if showsLoadingState {
            loadState = .loading
        }

        do {
            let catalog = try await HostedShipCatalogStore.shared.catalog(
                using: HostedShipCatalogClient(),
                forceRefresh: force
            )
            let ships = CCUUpgradeCatalogShip.makeShips(from: catalog)
            loadState = .loaded(
                CCUUpgradeCalculatorCatalog(
                    id: UUID(),
                    ships: ships,
                    storeUpgradeOffers: catalog.storeUpgradeOffers
                )
            )
            reconcileSelections(with: ships)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func reconcileSelections(with ships: [CCUUpgradeCatalogShip]) {
        let validKeys = Set(ships.map(\.key))
        if let selectedSourceKey,
           !validKeys.contains(selectedSourceKey) {
            self.selectedSourceKey = nil
        }

        if let selectedDestinationKey,
           !validKeys.contains(selectedDestinationKey) {
            self.selectedDestinationKey = nil
        }
    }

    @MainActor
    private func calculateRoute(for request: CCUUpgradeRouteCalculationRequest?) async {
        guard let request else {
            routeCalculationState = .idle
            return
        }

        guard let catalog = loadedCatalog,
              catalog.id == request.catalogID,
              let sourceShip = catalog.ships.first(where: { $0.key == request.sourceKey }),
              let destinationShip = catalog.ships.first(where: { $0.key == request.destinationKey }),
              sourceShip.msrpUSD.isLessThan(destinationShip.msrpUSD) else {
            routeCalculationState = .idle
            return
        }

        if case let .loaded(loadedRequest, _) = routeCalculationState,
           loadedRequest == request {
            return
        }

        routeCalculationState = .calculating(request)
        await Task.yield()

        guard !Task.isCancelled else {
            return
        }

        let snapshot = snapshot
        let catalogShips = catalog.ships
        let storeUpgradeOffers = catalog.storeUpgradeOffers
        let route = await Task.detached(priority: .userInitiated) {
            CCUUpgradePlanner.bestRoute(
                from: sourceShip,
                to: destinationShip,
                snapshot: snapshot,
                catalogShips: catalogShips,
                storeUpgradeOffers: storeUpgradeOffers
            )
        }.value

        guard !Task.isCancelled,
              routeCalculationRequest == request else {
            return
        }

        routeCalculationState = .loaded(request, route)
    }
}

private struct CCUUpgradeCalculatorCatalog {
    let id: UUID
    let ships: [CCUUpgradeCatalogShip]
    let storeUpgradeOffers: [RSIShipCatalog.StoreUpgradeOffer]
}

private struct CCUUpgradeRouteCalculationRequest: Hashable, Sendable {
    let catalogID: UUID
    let sourceKey: String
    let destinationKey: String
}

private enum CCUUpgradeRouteCalculationState {
    case idle
    case calculating(CCUUpgradeRouteCalculationRequest)
    case loaded(CCUUpgradeRouteCalculationRequest, CCUUpgradeRoute?)
}

private enum CCUUpgradeCalculatorLoadState {
    case idle
    case loading
    case loaded(CCUUpgradeCalculatorCatalog)
    case failed(String)
}

private enum CCUUpgradeShipPickerRole: Hashable {
    case source
    case destination

    var title: String {
        switch self {
        case .source:
            return AppLocalizer.string("Source Ship")
        case .destination:
            return AppLocalizer.string("Destination Ship")
        }
    }
}

private struct CCUUpgradeShipSelectionRow: View {
    let title: String
    let ship: CCUUpgradeCatalogShip?
    let placeholder: String
    let reloadToken: UUID?

    var body: some View {
        HStack(spacing: 12) {
            if let ship {
                RemoteThumbnailView(
                    url: ship.imageURL,
                    reloadToken: reloadToken,
                    fallbackSystemImage: "airplane",
                    size: 48
                )
            } else {
                Image(systemName: "airplane")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.tertiarySystemGroupedBackground))
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(ship?.name ?? placeholder)
                    .font(.headline)
                    .foregroundStyle(ship == nil ? .secondary : .primary)

                if let ship {
                    Text(AppLocalizer.format("%@ • MSRP %@", ship.manufacturer, ship.displayPrice))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CCUUpgradeShipPickerView: View {
    let role: CCUUpgradeShipPickerRole
    let ships: [CCUUpgradeCatalogShip]
    @Binding var selectedKey: String?
    let reloadToken: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredShips: [CCUUpgradeCatalogShip] {
        let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !normalizedSearchText.isEmpty else {
            return ships
        }

        return ships.filter { $0.searchHaystack.contains(normalizedSearchText) }
    }

    var body: some View {
        List {
            if filteredShips.isEmpty {
                ContentUnavailableView(
                    "No Matching Ships",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different ship name or manufacturer.")
                )
            } else {
                ForEach(filteredShips) { ship in
                    Button {
                        selectedKey = ship.key
                        dismiss()
                    } label: {
                        CCUUpgradeShipPickerRow(
                            ship: ship,
                            isSelected: selectedKey == ship.key,
                            reloadToken: reloadToken
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(role.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search ships")
    }
}

private struct CCUUpgradeShipPickerRow: View {
    let ship: CCUUpgradeCatalogShip
    let isSelected: Bool
    let reloadToken: UUID?

    var body: some View {
        HStack(spacing: 12) {
            RemoteThumbnailView(
                url: ship.imageURL,
                reloadToken: reloadToken,
                fallbackSystemImage: "airplane",
                size: 50
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(ship.name)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("\(ship.manufacturer) • \(ship.displayPrice)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(ship.displayAvailability)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ship.isStoreUpgradeAvailable ? .green : .orange)
            }

            Spacer(minLength: 8)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CCUUpgradeRouteSummaryCard: View {
    let route: CCUUpgradeRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Best CCU Chain")
                        .font(.headline)

                    Text(AppLocalizer.format("%@ to %@", route.sourceShip.name, route.destinationShip.name))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(route.totalSavingsUSD.usdString)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(route.totalSavingsUSD.isNegative ? .orange : .green)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    CCUUpgradeMetricLabel(title: "Direct Value", value: route.standardUpgradeValueUSD.usdString)
                    CCUUpgradeMetricLabel(title: "Value Used", value: route.totalEffectiveCostUSD.usdString)
                }

                GridRow {
                    CCUUpgradeMetricLabel(title: "CCU Purchases", value: route.totalNewPurchaseCostUSD.usdString)
                    CCUUpgradeMetricLabel(title: "Store Credit", value: route.totalStoreCreditNeededUSD.usdString)
                }

                GridRow {
                    CCUUpgradeMetricLabel(title: "New Money", value: route.totalNewMoneyNeededUSD.usdString)
                    CCUUpgradeMetricLabel(title: "Steps", value: "\(route.steps.count)")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

private struct CCUUpgradeMetricLabel: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AppLocalizer.string(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CCUUpgradeRouteWarningView: View {
    var body: some View {
        Label {
            Text("This chain includes at least one CCU that is not purchasable right now.")
                .font(.subheadline)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.orange)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }
}

private struct CCUUpgradeStepRow: View {
    let number: Int
    let step: CCUUpgradeCandidate
    let paymentRequirement: CCUUpgradePaymentRequirement?
    let reloadToken: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(Color(.tertiarySystemGroupedBackground))
                )

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.routeValueText)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(step.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    CCUUpgradeSourcePill(kind: step.kind)
                }

                HStack(spacing: 10) {
                    CCUUpgradeStepValue(title: "Current", value: step.currentValueUSD.usdString)
                    CCUUpgradeStepValue(title: "Cost", value: step.effectiveCostUSD.usdString)
                    CCUUpgradeStepValue(title: "Saving", value: step.savingsUSD.usdString)
                }

                if step.kind.requiresNewPurchase {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            AppLocalizer.format("Purchase %@", purchaseCostText),
                            systemImage: step.kind.isUnavailableStoreStep ? "cart.badge.questionmark" : "cart"
                        )

                        Text(AppLocalizer.format(
                            "Store credit %@ • New money %@",
                            storeCreditText,
                            newMoneyText
                        ))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .foregroundStyle(step.kind.isUnavailableStoreStep ? .orange : .secondary)
                } else if let referenceID = step.referenceID {
                    Label(
                        AppLocalizer.format("Already in hangar %@", referenceID),
                        systemImage: "shippingbox"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var purchaseCostText: String {
        paymentRequirement?.purchaseCostUSD.usdString ?? step.newPurchaseCostUSD.usdString
    }

    private var storeCreditText: String {
        paymentRequirement?.storeCreditUSD.usdString ?? Decimal.zero.usdString
    }

    private var newMoneyText: String {
        paymentRequirement?.newMoneyUSD.usdString ?? step.newPurchaseCostUSD.usdString
    }
}

private struct CCUUpgradeSourcePill: View {
    let kind: CCUUpgradeSourceKind

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(kind.title)
                .font(.caption.weight(.bold))
                .lineLimit(2)
                .multilineTextAlignment(.trailing)

            Text(kind.detail)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(pillColor.opacity(0.14))
        )
        .foregroundStyle(pillColor)
    }

    private var pillColor: Color {
        switch kind {
        case .hangarWarbond:
            return .green
        case .hangarStandardMeltAboveCurrent, .hangarStandardMeltMatchesCurrent:
            return .blue
        case .buyback:
            return .purple
        case .storeWarbond:
            return .green
        case .store:
            return .teal
        case .unavailableStore:
            return .orange
        }
    }
}

private struct CCUUpgradeStepValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AppLocalizer.string(title))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension Decimal {
    var isNegative: Bool {
        NSDecimalNumber(decimal: self).compare(NSDecimalNumber.zero) == .orderedAscending
    }

    func isLessThan(_ other: Decimal) -> Bool {
        NSDecimalNumber(decimal: self).compare(NSDecimalNumber(decimal: other)) == .orderedAscending
    }

    func isGreaterThan(_ other: Decimal) -> Bool {
        NSDecimalNumber(decimal: self).compare(NSDecimalNumber(decimal: other)) == .orderedDescending
    }
}
