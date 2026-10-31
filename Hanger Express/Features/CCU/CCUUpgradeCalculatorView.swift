import Photos
import SwiftUI
import UIKit

struct CCUUpgradeCalculatorView: View {
    let snapshot: HangarSnapshot
    let reloadToken: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var loadState: CCUUpgradeCalculatorLoadState = .idle
    @State private var selectedSourceKey: String?
    @State private var selectedDestinationKey: String?
    @State private var selectedSourceMeltValueUSD: Decimal?
    @State private var excludedCCUs: [String: String] = [:]
    @State private var isRefreshingCatalog = false
    @State private var routeCalculationState: CCUUpgradeRouteCalculationState = .idle
    @State private var exportPayload: CCUCalculationExportPayload?
    @State private var exportNotice: CCUCalculationExportNotice?
    @State private var isExportingCalculation = false

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

    private var sourceMeltValueOptions: [Decimal] {
        guard let selectedSourceShip else { return [] }
        return CCUUpgradePlanner.sourceShipMeltValues(
            for: selectedSourceShip,
            snapshot: snapshot,
            catalogShips: catalogShips
        )
    }

    private var resolvedSourceValueUSD: Decimal? {
        guard let selectedSourceShip else { return nil }
        if sourceMeltValueOptions.isEmpty { return selectedSourceShip.msrpUSD }
        if sourceMeltValueOptions.count == 1 { return sourceMeltValueOptions[0] }
        guard let selectedSourceMeltValueUSD,
              sourceMeltValueOptions.contains(selectedSourceMeltValueUSD) else { return nil }
        return selectedSourceMeltValueUSD
    }

    private var routeCalculationRequest: CCUUpgradeRouteCalculationRequest? {
        guard let catalog = loadedCatalog,
              let selectedSourceShip,
              let selectedDestinationShip,
              let resolvedSourceValueUSD,
              selectedSourceShip.msrpUSD.isLessThan(selectedDestinationShip.msrpUSD) else {
            return nil
        }

        return CCUUpgradeRouteCalculationRequest(
            catalogID: catalog.id,
            sourceKey: selectedSourceShip.key,
            destinationKey: selectedDestinationShip.key,
            sourceValueUSD: resolvedSourceValueUSD,
            excludedCandidateIDs: Set(excludedCCUs.keys)
        )
    }

    private var displayedRoute: CCUUpgradeRoute? {
        guard let routeCalculationRequest,
              case let .loaded(loadedRequest, route) = routeCalculationState,
              loadedRequest == routeCalculationRequest else {
            return nil
        }
        return route
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
                            placeholder: AppLocalizer.string("Choose source")
                        )
                    }
                    .disabled(catalogShips.isEmpty)

                    NavigationLink(value: CCUUpgradeShipPickerRole.destination) {
                        CCUUpgradeShipSelectionRow(
                            title: AppLocalizer.string("Destination Ship"),
                            ship: selectedDestinationShip,
                            placeholder: AppLocalizer.string("Choose destination")
                        )
                    }
                    .disabled(catalogShips.isEmpty)

                    if sourceMeltValueOptions.count > 1 {
                        Picker("Source Ship Value", selection: $selectedSourceMeltValueUSD) {
                            Text("Choose melt value").tag(nil as Decimal?)
                            ForEach(sourceMeltValueOptions, id: \.self) { value in
                                Text(value.usdString).tag(value as Decimal?)
                            }
                        }
                        .pickerStyle(.menu)
                    } else if let resolvedSourceValueUSD, !sourceMeltValueOptions.isEmpty {
                        LabeledContent("Melt Value", value: resolvedSourceValueUSD.usdString)
                    }
                }

                catalogStatusSection
                calculationSection
                excludedCCUsSection
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
            .sheet(item: $exportPayload) { payload in
                CCUCalculationShareSheet(activityItems: [payload.fileURL])
            }
            .alert(item: $exportNotice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .overlay {
                if isExportingCalculation {
                    ZStack {
                        Color.black.opacity(0.18)
                            .ignoresSafeArea()

                        ProgressView("Creating image...")
                            .padding(18)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(.regularMaterial)
                            )
                    }
                }
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
                    CCUCalculatorStatusRow(
                        "Select Ships",
                        systemImage: "arrow.left.arrow.right",
                        message: "Choose both ships to calculate the chain."
                    )
                } else if sourceMeltValueOptions.count > 1 && resolvedSourceValueUSD == nil {
                    CCUCalculatorStatusRow(
                        "Choose Source Value",
                        systemImage: "dollarsign.circle",
                        message: "You own this ship at multiple melt values. Choose which one to use."
                    )
                } else if let selectedSourceShip,
                          let selectedDestinationShip,
                          !selectedSourceShip.msrpUSD.isLessThan(selectedDestinationShip.msrpUSD) {
                    CCUCalculatorStatusRow(
                        "Destination Too Low",
                        systemImage: "exclamationmark.triangle",
                        message: "The destination ship must have a higher MSRP than the source ship."
                    )
                } else if let routeCalculationRequest {
                    switch routeCalculationState {
                    case let .loaded(loadedRequest, route) where loadedRequest == routeCalculationRequest:
                        if let route {
                            CCUUpgradeRouteSummary(route: route)

                            if route.hasUnavailableStoreStep {
                                CCUUpgradeRouteWarningView()
                            }

                            ForEach(Array(route.steps.enumerated()), id: \.element.id) { offset, step in
                                CCUUpgradeStepRow(
                                    number: offset + 1,
                                    step: step,
                                    paymentRequirement: route.paymentRequirement(for: step),
                                    onExclude: { exclude(step) }
                                )
                            }

                            CCUCalculationExportButtons(
                                isExporting: isExportingCalculation,
                                onSave: { Task { await saveCalculationToPhotos(route) } },
                                onShare: { Task { await shareCalculation(route) } }
                            )
                        } else {
                            CCUCalculatorStatusRow(
                                "No CCU Path",
                                systemImage: "link.badge.plus",
                                message: "No valid upgrade chain was found for these ships."
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
                    CCUCalculatorStatusRow(
                        "No CCU Path",
                        systemImage: "link.badge.plus",
                        message: "No valid upgrade chain was found for these ships."
                    )
                }
            }
        } header: {
            Text(displayedRoute == nil ? "Calculation" : "Best CCU Chain")
        }
    }

    @ViewBuilder
    private var excludedCCUsSection: some View {
        if !excludedCCUs.isEmpty {
            Section {
                ForEach(excludedCCUs.keys.sorted(), id: \.self) { candidateID in
                    HStack {
                        Text(excludedCCUs[candidateID] ?? candidateID)
                            .lineLimit(2)
                        Spacer()
                        Button("Restore") {
                            excludedCCUs.removeValue(forKey: candidateID)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Excluded CCUs")
            } footer: {
                Text("Restoring a CCU recalculates the path and allows it to be used again.")
            }
        }
    }

    private func exclude(_ step: CCUUpgradeCandidate) {
        excludedCCUs[step.id] = step.routeValueText
    }

    @MainActor
    private func saveCalculationToPhotos(_ route: CCUUpgradeRoute) async {
        guard !isExportingCalculation else { return }
        isExportingCalculation = true
        defer { isExportingCalculation = false }

        do {
            let image = try CCUCalculationImageGenerator.makeImage(for: route)
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                throw CCUCalculationExportError.photoAccessDenied
            }

            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            exportNotice = CCUCalculationExportNotice(
                title: AppLocalizer.string("Saved to Photos"),
                message: AppLocalizer.string("The CCU calculation image was added to your photo library.")
            )
        } catch {
            exportNotice = CCUCalculationExportNotice(
                title: AppLocalizer.string("Unable to Save Image"),
                message: error.localizedDescription
            )
        }
    }

    @MainActor
    private func shareCalculation(_ route: CCUUpgradeRoute) async {
        guard !isExportingCalculation else { return }
        isExportingCalculation = true
        defer { isExportingCalculation = false }

        do {
            exportPayload = CCUCalculationExportPayload(
                fileURL: try CCUCalculationImageGenerator.makePNG(for: route)
            )
        } catch {
            exportNotice = CCUCalculationExportNotice(
                title: AppLocalizer.string("Unable to Share Image"),
                message: error.localizedDescription
            )
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
                set: {
                    selectedSourceKey = $0
                    selectedSourceMeltValueUSD = nil
                    excludedCCUs.removeAll()
                }
            )
        case .destination:
            return Binding(
                get: { selectedDestinationKey },
                set: {
                    selectedDestinationKey = $0
                    excludedCCUs.removeAll()
                }
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

#if DEBUG || HANGAR_BENCHMARKS
        if ProcessInfo.processInfo.environment["HANGAR_BENCHMARK_UI_SIZE"] != nil,
           ProcessInfo.processInfo.environment["HANGAR_CCU_UI_FIXTURE"] == "1" {
            let catalog = Self.uiFixtureCatalog()
            let ships = CCUUpgradeCatalogShip.makeShips(from: catalog)
            loadState = .loaded(CCUUpgradeCalculatorCatalog(
                id: UUID(), ships: ships, storeUpgradeOffers: catalog.storeUpgradeOffers
            ))
            reconcileSelections(with: ships)
            return
        }
#endif

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

#if DEBUG || HANGAR_BENCHMARKS
    private static func uiFixtureCatalog() -> RSIShipCatalog {
        RSIShipCatalog(
            ships: [
                .init(id: 1001, name: "Aurora MR", manufacturer: "RSI", msrpUSD: 30,
                      storeAvailable: true, imageURL: nil),
                .init(id: 1002, name: "Cutlass Black", manufacturer: "Drake", msrpUSD: 110,
                      storeAvailable: true, imageURL: nil),
                .init(id: 1003, name: "Zeus Mk II MR", manufacturer: "RSI", msrpUSD: 190,
                      storeAvailable: true, imageURL: nil)
            ],
            storeUpgradeOffers: [
                .init(id: "ccu-ui-war-bond", skuID: 9001, title: "Warbond Edition",
                      targetShipID: 1002, targetShipName: "Cutlass Black",
                      targetShipMSRPUSD: 110, priceUSD: 95, savingsUSD: 15,
                      available: true, unlimitedStock: true, availableStock: 0)
            ]
        )
    }
#endif

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
                storeUpgradeOffers: storeUpgradeOffers,
                selectedSourceMeltValueUSD: request.sourceValueUSD,
                excludedCandidateIDs: request.excludedCandidateIDs
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
    let sourceValueUSD: Decimal
    let excludedCandidateIDs: Set<String>
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
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(ship?.name ?? placeholder)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ship == nil ? .secondary : .primary)
            }

            Spacer(minLength: 4)

            if let ship {
                Text(AppLocalizer.format("MSRP %@", ship.displayPrice))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CCUUpgradeShipPickerView: View {
    let role: CCUUpgradeShipPickerRole
    let ships: [CCUUpgradeCatalogShip]
    @Binding var selectedKey: String?
    let reloadToken: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isSearchPresented = false

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
                        isSearchPresented = false
                        searchText = ""
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
        .searchable(
            text: $searchText,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search ships"
        )
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

            VStack(alignment: .leading, spacing: 5) {
                Text(ship.name)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(ship.manufacturer)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(ship.displayPrice)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()

                Text(ship.displayAvailability)
                    .font(.caption)
                    .foregroundStyle(ship.isStoreUpgradeAvailable ? .green : .secondary)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct CCUCalculatorStatusRow: View {
    let title: String
    let systemImage: String
    let message: String

    init(_ title: String, systemImage: String, message: String) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalizer.string(title))
                    .font(.subheadline.weight(.semibold))
                Text(AppLocalizer.string(message))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

private struct CCUUpgradeRouteSummary: View {
    let route: CCUUpgradeRoute
    @State private var showsCostDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    primaryMetric("Total Savings", value: route.totalSavingsUSD.usdString,
                                  color: route.totalSavingsUSD.isNegative ? .orange : .green)
                    primaryMetric("New Money", value: route.totalNewMoneyNeededUSD.usdString,
                                  color: .primary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    primaryMetric("Total Savings", value: route.totalSavingsUSD.usdString,
                                  color: route.totalSavingsUSD.isNegative ? .orange : .green)
                    primaryMetric("New Money", value: route.totalNewMoneyNeededUSD.usdString,
                                  color: .primary)
                }
            }

            DisclosureGroup("Cost details", isExpanded: $showsCostDetails) {
                VStack(spacing: 7) {
                    CCUUpgradeSummaryRow(title: "Destination MSRP", value: route.standardUpgradeValueUSD.usdString)
                    CCUUpgradeSummaryRow(title: "Total Cost", value: route.totalEffectiveCostUSD.usdString)
                    CCUUpgradeSummaryRow(title: "CCU Purchases", value: route.totalNewPurchaseCostUSD.usdString)
                    CCUUpgradeSummaryRow(title: "Store Credit", value: route.totalStoreCreditNeededUSD.usdString)
                }
                .padding(.top, 5)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func primaryMetric(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AppLocalizer.string(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CCUUpgradeSummaryRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(AppLocalizer.string(title))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
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
        .padding(8)
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
    let onExclude: () -> Void

    @State private var showsDetails = false

    var body: some View {
        DisclosureGroup(isExpanded: $showsDetails) {
            VStack(alignment: .leading, spacing: 8) {
                Text(step.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(step.kind.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    CCUUpgradeStepValue(title: "Current", value: step.currentValueUSD.usdString)
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

                Button(role: .destructive, action: onExclude) {
                    Label("Exclude", systemImage: "minus.circle")
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.top, 5)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 17, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(step.routeValueText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Text(step.kind.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 4)

                        Text(step.effectiveCostUSD.usdString)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.vertical, 1)
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

private struct CCUCalculationExportButtons: View {
    let isExporting: Bool
    let onSave: () -> Void
    let onShare: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSave) {
                Label("Save Image", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(AppLocalizer.string("Save to Photos"))

            Button(action: onShare) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .disabled(isExporting)
    }
}

private struct CCUCalculationExportPayload: Identifiable {
    let id = UUID()
    let fileURL: URL
}

private struct CCUCalculationExportNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum CCUCalculationExportError: LocalizedError {
    case imageGenerationFailed
    case photoAccessDenied

    var errorDescription: String? {
        switch self {
        case .imageGenerationFailed:
            return AppLocalizer.string("The CCU calculation image could not be created.")
        case .photoAccessDenied:
            return AppLocalizer.string("Photo access is required to save the CCU calculation image.")
        }
    }
}

private struct CCUCalculationShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

@MainActor
private enum CCUCalculationImageGenerator {
    static func makeImage(for route: CCUUpgradeRoute) throws -> UIImage {
        let content = CCUCalculationExportView(route: route)
            .frame(width: 540)
            .fixedSize(horizontal: false, vertical: true)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.uiImage else {
            throw CCUCalculationExportError.imageGenerationFailed
        }
        return image
    }

    static func makePNG(for route: CCUUpgradeRoute) throws -> URL {
        let image = try makeImage(for: route)
        guard let data = image.pngData() else {
            throw CCUCalculationExportError.imageGenerationFailed
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Hangar-Express-CCU-\(UUID().uuidString).png")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}

private struct CCUCalculationExportView: View {
    let route: CCUUpgradeRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Hangar Express")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                    Text("Best CCU Chain")
                        .font(.title2.weight(.bold))
                    Text(AppLocalizer.format("%@ to %@", route.sourceShip.name, route.destinationShip.name))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text("Total Savings")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(route.totalSavingsUSD.usdString)
                        .font(.title.weight(.bold))
                        .foregroundStyle(route.totalSavingsUSD.isNegative ? .orange : .green)
                }
            }

            Divider()

            VStack(spacing: 12) {
                exportSummaryRow("Destination MSRP", route.standardUpgradeValueUSD.usdString)
                exportSummaryRow("Total Cost", route.totalEffectiveCostUSD.usdString)
            }

            HStack(alignment: .top, spacing: 18) {
                CCUUpgradeMetricLabel(title: "CCU Purchases", value: route.totalNewPurchaseCostUSD.usdString)
                CCUUpgradeMetricLabel(title: "Store Credit", value: route.totalStoreCreditNeededUSD.usdString)
                CCUUpgradeMetricLabel(title: "New Money", value: route.totalNewMoneyNeededUSD.usdString)
            }

            Divider()

            VStack(spacing: 0) {
                ForEach(Array(route.steps.enumerated()), id: \.element.id) { offset, step in
                    CCUCalculationExportStep(
                        number: offset + 1,
                        step: step,
                        payment: route.paymentRequirement(for: step)
                    )

                    if offset < route.steps.count - 1 {
                        Divider()
                            .padding(.leading, 42)
                    }
                }
            }

            Text("Generated by Hangar Express")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(28)
        .background(Color(uiColor: .systemBackground))
        .foregroundStyle(Color.primary)
        .environment(\.colorScheme, .dark)
    }

    private func exportSummaryRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(AppLocalizer.string(title))
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.title3.weight(.bold))
        }
    }
}

private struct CCUCalculationExportStep: View {
    let number: Int
    let step: CCUUpgradeCandidate
    let payment: CCUUpgradePaymentRequirement?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.secondary.opacity(0.16)))

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(step.routeValueText)
                        .font(.headline)
                    Spacer()
                    Text(step.kind.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }

                HStack(spacing: 20) {
                    exportValue("Current", step.currentValueUSD.usdString)
                    exportValue("Cost", step.effectiveCostUSD.usdString)
                    exportValue("Saving", step.savingsUSD.usdString)
                }

                if let payment {
                    Text(AppLocalizer.format(
                        "Store credit %@ • New money %@",
                        payment.storeCreditUSD.usdString,
                        payment.newMoneyUSD.usdString
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 14)
    }

    private func exportValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AppLocalizer.string(title))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
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
