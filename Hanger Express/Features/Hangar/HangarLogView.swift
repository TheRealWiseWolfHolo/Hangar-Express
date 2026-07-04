import SwiftUI

struct HangarLogView: View {
    private enum TimeFilter: CaseIterable, Identifiable {
        case all
        case last30Days
        case last90Days
        case lastYear

        var id: Self { self }

        var title: String {
            switch self {
            case .all:
                return AppLocalizer.string("All Time")
            case .last30Days:
                return AppLocalizer.string("30 Days")
            case .last90Days:
                return AppLocalizer.string("90 Days")
            case .lastYear:
                return AppLocalizer.string("1 Year")
            }
        }
    }

    private enum ActionFilter: Hashable, Identifiable {
        case all
        case action(HangarLogAction)

        var id: String {
            switch self {
            case .all:
                return "all"
            case let .action(action):
                return action.rawValue
            }
        }

        var title: String {
            switch self {
            case .all:
                return AppLocalizer.string("All Actions")
            case let .action(action):
                return action.title
            }
        }

        static var allCases: [ActionFilter] {
            [.all] + HangarLogAction.allCases.map(Self.action)
        }
    }

    let appModel: AppModel

    @Environment(\.dismiss) private var dismiss
    @AppStorage(HangarItemLanguage.storageKey) private var hangarItemLanguageRawValue = HangarItemLanguage.original.rawValue
    @State private var searchText = ""
    @State private var timeFilter: TimeFilter = .all
    @State private var actionFilter: ActionFilter = .all
    @State private var didAttemptInitialLoad = false
    @State private var visibleEntryCount = HangarLogFetchMode.initial.entryLimit
    @State private var isRequestingOlderEntries = false
    @State private var lastRemoteExpansionBaselineCount: Int?
    @State private var itemTranslationState = HangarItemTranslationViewState()
    @State private var translationService = OnDeviceHangarItemTranslationService.shared
    @Namespace private var logNavigationNamespace

    private var hangarLogs: [HangarLogEntry] {
        appModel.snapshot?.hangarLogs ?? []
    }

    private var currentPackageGroups: [GroupedHangarPackage] {
        appModel.snapshot?.packages.groupedForInventoryDisplay ?? []
    }

    private var currentShipGroups: [GroupedFleetShip] {
        appModel.snapshot?.fleet.groupedForFleetDisplay ?? []
    }

    private var planLimitedHangarLogs: [HangarLogEntry] {
        Array(hangarLogs.prefix(appModel.hangarLogEntryLimit))
    }

    private var filteredHangarLogs: [HangarLogEntry] {
        planLimitedHangarLogs.filter { entry in
            matchesTimeFilter(entry) && matchesActionFilter(entry) && matchesSearch(entry)
        }
    }

    private var displayedHangarLogs: [HangarLogEntry] {
        Array(filteredHangarLogs.prefix(visibleEntryCount))
    }

    private var hasHiddenResults: Bool {
        filteredHangarLogs.count > displayedHangarLogs.count
    }

    private var entryBatchSize: Int {
        appModel.isPro ? 50 : appModel.hangarLogEntryLimit
    }

    var body: some View {
        let currentItemTranslator = itemTranslator

        NavigationStack {
            List {
                Section {
                    IMEAwareSearchRow(
                        text: $searchText,
                        prompt: AppLocalizer.string("Search log entries"),
                        onCommittedTextChange: resetVisibleEntryCount
                    )

                    HStack(spacing: 12) {
                        Menu {
                            Picker("Action", selection: $actionFilter) {
                                ForEach(ActionFilter.allCases) { filter in
                                    Text(filter.title).tag(filter)
                                }
                            }
                        } label: {
                            filterChip(
                                title: actionFilter.title,
                                systemImage: "line.3.horizontal.decrease.circle"
                            )
                        }

                        Menu {
                            Picker("Time", selection: $timeFilter) {
                                ForEach(TimeFilter.allCases) { filter in
                                    Text(filter.title).tag(filter)
                                }
                            }
                        } label: {
                            filterChip(
                                title: timeFilter.title,
                                systemImage: "calendar"
                            )
                        }

                        Spacer()

                        Text("\(filteredHangarLogs.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Search items, pledge IDs, orders, or raw log text. Filters can narrow results by action and time window.")
                }

                if appModel.isRefreshing(.hangarLog), hangarLogs.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            ProgressView()
                            Text("Loading your RSI hangar log.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                    }
                } else if filteredHangarLogs.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Log Entries",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text(emptyStateDescription)
                        )
                    }
                } else {
                    Section {
                        ForEach(displayedHangarLogs) { entry in
                            logRow(for: entry, itemTranslator: currentItemTranslator)
                        }
                    }

                    if hasHiddenResults {
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Showing \(displayedHangarLogs.count) of \(filteredHangarLogs.count) log entries.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 12) {
                                    Button("Load More") {
                                        revealNextBatch()
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Load All") {
                                        visibleEntryCount = filteredHangarLogs.count
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Spacer()
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }

                    if shouldShowProLogLimitMessage {
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Standard shows the latest 5 hangar log entries. Early Access unlocks up to 500 while Extended Hangar Log is in beta.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                Button("Get Early Access") {
                                    Task {
                                        await appModel.subscriptionStore.purchasePro()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Hangar Log")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await appModel.refresh(scope: .hangarLog)
                        }
                    } label: {
                        Text(appModel.isRefreshing(.hangarLog) ? LocalizedStringKey("Refreshing...") : LocalizedStringKey("Refresh"))
                    }
                    .disabled(appModel.isRefreshing)
                }
            }
            .task {
                guard !didAttemptInitialLoad else {
                    return
                }

                didAttemptInitialLoad = true
                resetVisibleEntryCount()
                guard hangarLogs.isEmpty else {
                    return
                }

                await appModel.refresh(scope: .hangarLog)
            }
            .task(id: hangarItemLanguageRawValue) {
                await loadItemTranslationDictionary()
                resetVisibleEntryCount()
            }
            .onChange(of: searchText) { _, _ in
                resetVisibleEntryCount()
            }
            .onChange(of: timeFilter) { _, _ in
                resetVisibleEntryCount()
            }
            .onChange(of: actionFilter) { _, _ in
                resetVisibleEntryCount()
            }
            .onChange(of: hangarLogs.count) { _, newCount in
                let initialVisibleCount = min(entryBatchSize, filteredHangarLogs.count)
                if newCount > 0,
                   visibleEntryCount < initialVisibleCount {
                    resetVisibleEntryCount()
                }

                if let lastRemoteExpansionBaselineCount,
                   newCount > lastRemoteExpansionBaselineCount {
                    self.lastRemoteExpansionBaselineCount = nil
                }
            }
            .onChange(of: appModel.isPro) { _, _ in
                resetVisibleEntryCount()
            }
        }
    }

    private var itemTranslator: HangarItemTranslator {
        itemTranslationState.translator(for: hangarItemLanguageRawValue)
    }

    private func loadItemTranslationDictionary() async {
        await itemTranslationState.loadDictionary(for: hangarItemLanguageRawValue)
    }

    private var shouldShowProLogLimitMessage: Bool {
        !appModel.isPro && hangarLogs.count >= appModel.hangarLogEntryLimit
    }

    private var emptyStateDescription: String {
        if !hangarLogs.isEmpty {
            return AppLocalizer.string("Try adjusting the search text or filters.")
        }

        return AppLocalizer.string("Open the log again after a refresh, or pull a fresh copy from RSI with the Refresh button.")
    }

    @ViewBuilder
    private func logRow(for entry: HangarLogEntry, itemTranslator: HangarItemTranslator) -> some View {
        let destination = resolvedDestination(for: entry)
        let upgradeContext = effectiveUpgradeContext(for: entry, destination: destination)

        switch destination {
        case let .package(packageGroup, pledgeID):
            NavigationLink {
                destinationView(for: .package(packageGroup, pledgeID: pledgeID), itemTranslator: itemTranslator)
            } label: {
                HangarLogRow(
                    entry: entry,
                    upgradeContext: upgradeContext,
                    itemTranslator: itemTranslator,
                    destinationSummary: destination?.rowSummary(using: itemTranslator)
                )
            }
            .onAppear {
                loadMoreIfNeeded(currentEntry: entry)
            }
        case let .ship(shipGroup):
            NavigationLink {
                destinationView(for: .ship(shipGroup), itemTranslator: itemTranslator)
            } label: {
                HangarLogRow(
                    entry: entry,
                    upgradeContext: upgradeContext,
                    itemTranslator: itemTranslator,
                    destinationSummary: destination?.rowSummary(using: itemTranslator)
                )
            }
            .matchedTransitionSource(
                id: shipGroup.id,
                in: logNavigationNamespace
            ) { source in
                source.clipShape(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .onAppear {
                loadMoreIfNeeded(currentEntry: entry)
            }
        case nil:
            HangarLogRow(
                entry: entry,
                upgradeContext: upgradeContext,
                itemTranslator: itemTranslator,
                destinationSummary: nil
            )
            .onAppear {
                loadMoreIfNeeded(currentEntry: entry)
            }
        }
    }

    @ViewBuilder
    private func destinationView(
        for destination: HangarLogResolvedDestination,
        itemTranslator: HangarItemTranslator
    ) -> some View {
        switch destination {
        case let .package(packageGroup, _):
            HangarPackageDetailView(
                appModel: appModel,
                packageGroup: packageGroup,
                itemTranslator: itemTranslator,
                reloadToken: appModel.hangarFleetImageReloadToken
            )
        case let .ship(shipGroup):
            FleetShipDetailView(
                shipGroup: shipGroup,
                itemTranslator: itemTranslator,
                reloadToken: appModel.hangarFleetImageReloadToken,
                transitionNamespace: logNavigationNamespace
            )
        }
    }

    private func resolvedDestination(for entry: HangarLogEntry) -> HangarLogResolvedDestination? {
        for pledgeID in navigationPledgeIDs(for: entry) {
            if let packageGroup = packageGroup(containingPledgeID: pledgeID) {
                return .package(packageGroup, pledgeID: pledgeID)
            }

            if let shipGroup = shipGroup(sourcePackageID: pledgeID) {
                return .ship(shipGroup)
            }
        }

        if let packageGroup = packageGroup(matchingTitle: entry.itemName) {
            return .package(packageGroup, pledgeID: nil)
        }

        if let shipGroup = shipGroup(matchingName: entry.itemName) {
            return .ship(shipGroup)
        }

        return nil
    }

    private func navigationPledgeIDs(for entry: HangarLogEntry) -> [Int] {
        let rawIDs: [String?]

        switch entry.action {
        case .consumed:
            rawIDs = [entry.sourcePledgeID, entry.targetPledgeID]
        case .appliedUpgrade:
            rawIDs = [entry.targetPledgeID, entry.sourcePledgeID]
        case .created,
             .reclaimed,
             .buyback,
             .gift,
             .giftClaimed,
             .giftCancelled,
             .nameChange,
             .nameChangeReclaimed,
             .giveaway,
             .unknown:
            rawIDs = [entry.targetPledgeID, entry.sourcePledgeID]
        }

        var resolvedIDs: [Int] = []
        for rawID in rawIDs {
            guard let rawID,
                  let pledgeID = Int(rawID.trimmingCharacters(in: .whitespacesAndNewlines)),
                  pledgeID > 0,
                  !resolvedIDs.contains(pledgeID) else {
                continue
            }

            resolvedIDs.append(pledgeID)
        }

        return resolvedIDs
    }

    private func effectiveUpgradeContext(
        for entry: HangarLogEntry,
        destination: HangarLogResolvedDestination?
    ) -> HangarLogUpgradeContext? {
        guard entry.action == .appliedUpgrade else {
            return nil
        }

        let fallbackContext = currentUpgradeContext(for: entry, destination: destination)
            ?? HangarLogUpgradeContext.inferred(from: [entry.reason, entry.itemName])

        if let upgradeContext = entry.upgradeContext {
            let mergedContext = upgradeContext.merging(with: fallbackContext)
            return mergedContext.hasDisplayableContext ? mergedContext : nil
        }

        return fallbackContext?.hasDisplayableContext == true ? fallbackContext : nil
    }

    private func currentUpgradeContext(
        for entry: HangarLogEntry,
        destination: HangarLogResolvedDestination?
    ) -> HangarLogUpgradeContext? {
        if case let .ship(shipGroup)? = destination {
            return HangarLogUpgradeContext(
                sourceShipName: entry.upgradeContext?.sourceShipName,
                targetShipName: shipGroup.representative.displayName,
                upgradeName: entry.reason
            )
        }

        guard let package = resolvedPackage(for: entry, destination: destination) else {
            return nil
        }

        if let pricing = package.contents.compactMap(\.upgradePricing).first {
            return HangarLogUpgradeContext(
                sourceShipName: pricing.sourceShipName,
                targetShipName: pricing.targetShipName,
                upgradeName: entry.reason
            )
        }

        return HangarLogUpgradeContext(
            sourceShipName: entry.upgradeContext?.sourceShipName,
            targetShipName: package.upgradedShipDisplayTitle ?? package.contents.first(where: \.isShipLike)?.title,
            upgradeName: entry.reason
        )
    }

    private func resolvedPackage(
        for entry: HangarLogEntry,
        destination: HangarLogResolvedDestination?
    ) -> HangarPackage? {
        if case let .package(packageGroup, pledgeID)? = destination {
            if let pledgeID,
               let package = packageGroup.packages.first(where: { $0.id == pledgeID }) {
                return package
            }

            return packageGroup.representative
        }

        for pledgeID in navigationPledgeIDs(for: entry) {
            if let package = currentPackageGroups
                .flatMap(\.packages)
                .first(where: { $0.id == pledgeID }) {
                return package
            }
        }

        return nil
    }

    private func packageGroup(containingPledgeID pledgeID: Int) -> GroupedHangarPackage? {
        currentPackageGroups.first { packageGroup in
            packageGroup.packages.contains { package in
                package.id == pledgeID
            }
        }
    }

    private func shipGroup(sourcePackageID pledgeID: Int) -> GroupedFleetShip? {
        currentShipGroups.first { shipGroup in
            shipGroup.ships.contains { ship in
                ship.sourcePackageID == pledgeID
            }
        }
    }

    private func packageGroup(matchingTitle rawTitle: String) -> GroupedHangarPackage? {
        let normalizedTitle = normalizedLookupText(rawTitle)
        guard !normalizedTitle.isEmpty else {
            return nil
        }

        return currentPackageGroups.first { packageGroup in
            packageGroup.packages.contains { package in
                normalizedLookupText(package.title) == normalizedTitle
                    || package.contents.contains { item in
                        normalizedLookupText(item.title) == normalizedTitle
                    }
            }
        }
    }

    private func shipGroup(matchingName rawName: String) -> GroupedFleetShip? {
        let normalizedName = normalizedLookupText(rawName)
        guard !normalizedName.isEmpty else {
            return nil
        }

        return currentShipGroups.first { shipGroup in
            shipGroup.ships.contains { ship in
                let shipName = normalizedLookupText(ship.displayName)
                return lookupTextsMatch(shipName, normalizedName)
            }
        }
    }

    private func lookupTextsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return false
        }

        if lhs == rhs {
            return true
        }

        let shorterText = lhs.count <= rhs.count ? lhs : rhs
        let longerText = lhs.count > rhs.count ? lhs : rhs
        return shorterText.count > 3 && longerText.contains(shorterText)
    }

    private func normalizedLookupText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
    }

    @ViewBuilder
    private func filterChip(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(Color.accentColor)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
    }

    private func matchesSearch(_ entry: HangarLogEntry) -> Bool {
        guard !searchText.isEmpty else {
            return true
        }

        let normalizedSearchText = searchText.localizedLowercase
        _ = translationService.cacheGeneration

        if translationService
            .hangarLogSearchableText(for: entry, using: itemTranslator)
            .contains(normalizedSearchText) {
            return true
        }

        return enrichedSearchableText(for: entry).localizedLowercase.contains(normalizedSearchText)
    }

    private func enrichedSearchableText(for entry: HangarLogEntry) -> String {
        let destination = resolvedDestination(for: entry)
        let upgradeContext = effectiveUpgradeContext(for: entry, destination: destination)
        let components = [
            translationService.searchableText(forOptional: upgradeContext?.sourceShipName, using: itemTranslator),
            translationService.searchableText(forOptional: upgradeContext?.targetShipName, using: itemTranslator),
            translationService.searchableText(forOptional: upgradeContext?.upgradeName, using: itemTranslator),
            upgradeContext.flatMap { itemTranslator.hangarLogUpgradeSummary(for: $0) },
            destination?.searchableText(
                using: itemTranslator,
                translationService: translationService
            )
        ]

        return components
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func matchesActionFilter(_ entry: HangarLogEntry) -> Bool {
        switch actionFilter {
        case .all:
            return true
        case let .action(action):
            return entry.action == action
        }
    }

    private func matchesTimeFilter(_ entry: HangarLogEntry) -> Bool {
        guard let thresholdDate = thresholdDate(for: timeFilter) else {
            return true
        }

        return entry.occurredAt >= thresholdDate
    }

    private func thresholdDate(for filter: TimeFilter) -> Date? {
        switch filter {
        case .all:
            return nil
        case .last30Days:
            return Calendar.current.date(byAdding: .day, value: -30, to: .now)
        case .last90Days:
            return Calendar.current.date(byAdding: .day, value: -90, to: .now)
        case .lastYear:
            return Calendar.current.date(byAdding: .year, value: -1, to: .now)
        }
    }

    private func resetVisibleEntryCount() {
        visibleEntryCount = min(entryBatchSize, filteredHangarLogs.count)
        lastRemoteExpansionBaselineCount = nil
    }

    private func loadMoreIfNeeded(currentEntry: HangarLogEntry) {
        guard hasHiddenResults else {
            attemptRemoteExpansionIfNeeded(currentEntry: currentEntry)
            return
        }

        let trailingEntries = displayedHangarLogs.suffix(8)
        guard trailingEntries.contains(where: { $0.id == currentEntry.id }) else {
            return
        }

        revealNextBatch()
    }

    private func revealNextBatch() {
        visibleEntryCount = min(visibleEntryCount + entryBatchSize, filteredHangarLogs.count)
    }

    private func attemptRemoteExpansionIfNeeded(currentEntry: HangarLogEntry) {
        guard searchText.isEmpty,
              timeFilter == .all,
              actionFilter == .all,
              appModel.isPro,
              !appModel.isRefreshing(.hangarLog),
              !isRequestingOlderEntries,
              displayedHangarLogs.last?.id == currentEntry.id,
              displayedHangarLogs.count == planLimitedHangarLogs.count,
              hangarLogs.count >= HangarLogFetchMode.initial.entryLimit,
              hangarLogs.count < appModel.hangarLogEntryLimit,
              lastRemoteExpansionBaselineCount != hangarLogs.count else {
            return
        }

        lastRemoteExpansionBaselineCount = hangarLogs.count
        isRequestingOlderEntries = true

        Task {
            await appModel.loadMoreHangarLogEntries()
            await MainActor.run {
                isRequestingOlderEntries = false
            }
        }
    }
}

private enum HangarLogResolvedDestination {
    case package(GroupedHangarPackage, pledgeID: Int?)
    case ship(GroupedFleetShip)

    func rowSummary(using itemTranslator: HangarItemTranslator) -> String {
        switch self {
        case let .package(packageGroup, pledgeID?):
            if packageGroup.containsMultipleCopies {
                return AppLocalizer.format("Opens package group with pledge #%lld", pledgeID)
            }

            return AppLocalizer.format("Opens current pledge #%lld", pledgeID)
        case .package:
            return AppLocalizer.string("Opens current package")
        case let .ship(shipGroup):
            return AppLocalizer.format("Opens current ship %@", itemTranslator.translated(shipGroup.representative.displayName))
        }
    }

    func searchableText(
        using itemTranslator: HangarItemTranslator,
        translationService: OnDeviceHangarItemTranslationService
    ) -> String {
        switch self {
        case let .package(packageGroup, _):
            return packageGroup.packages
                .flatMap { package in
                    [
                        translationService.searchableText(for: package.title, using: itemTranslator),
                        package.status,
                        package.searchableInsuranceText,
                        translationService.searchableText(
                            for: package.contents.flatMap { item -> [String] in
                                var titles = [item.title]
                                if let pricing = item.upgradePricing {
                                    titles.append(pricing.sourceShipName)
                                    titles.append(pricing.targetShipName)
                                }
                                return titles
                            },
                            using: itemTranslator
                        )
                    ]
                }
                .joined(separator: " ")
        case let .ship(shipGroup):
            return shipGroup.ships
                .map { translationService.fleetSearchableText(for: $0, using: itemTranslator) }
                .joined(separator: " ")
        }
    }
}

private struct HangarLogRow: View {
    let entry: HangarLogEntry
    let upgradeContext: HangarLogUpgradeContext?
    let itemTranslator: HangarItemTranslator
    let destinationSummary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HangarTranslatedText(
                        source: entry.itemName,
                        itemTranslator: itemTranslator
                    )
                        .font(.headline)

                    Text(AppLocalizer.displayDateTime(entry.occurredAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(entry.actionTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )
            }

            if let summary = summaryText {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let metadata = metadataText {
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var summaryText: String? {
        switch entry.action {
        case .created:
            var parts: [String] = []
            if let operatorName = entry.operatorName {
                parts.append("Created by \(operatorName)")
            }
            if let orderCode = entry.orderCode {
                parts.append("Order #\(orderCode)")
            }
            if let priceUSD = entry.priceUSD {
                parts.append(priceUSD.usdString)
            }
            return joined(parts)
        case .reclaimed:
            var parts: [String] = []
            if let operatorName = entry.operatorName {
                parts.append("Melted by \(operatorName)")
            }
            if let priceUSD = entry.priceUSD {
                parts.append(priceUSD.usdString)
            }
            return joined(parts)
        case .consumed:
            var parts: [String] = []
            if let sourcePledgeID = entry.sourcePledgeID {
                parts.append("Consumed on pledge #\(sourcePledgeID)")
            }
            if let priceUSD = entry.priceUSD {
                parts.append(priceUSD.usdString)
            }
            return joined(parts)
        case .appliedUpgrade:
            var parts: [String] = []
            if let upgradeSummary = upgradeContext.flatMap({ itemTranslator.hangarLogUpgradeSummary(for: $0) }) {
                parts.append(upgradeSummary)
            }
            if let sourcePledgeID = entry.sourcePledgeID {
                parts.append("Upgrade from pledge #\(sourcePledgeID)")
            }
            if upgradeContext.flatMap({ itemTranslator.hangarLogUpgradeSummary(for: $0) }) == nil,
               let reason = entry.reason {
                parts.append(itemTranslator.translated(reason))
            }
            if let priceUSD = entry.priceUSD {
                parts.append("New value \(priceUSD.usdString)")
            }
            return joined(parts)
        case .buyback:
            var parts: [String] = []
            if let operatorName = entry.operatorName {
                parts.append("Bought back by \(operatorName)")
            }
            if let orderCode = entry.orderCode {
                parts.append("Order #\(orderCode)")
            }
            return joined(parts)
        case .gift:
            var parts: [String] = []
            if let operatorName = entry.operatorName {
                parts.append("Gifted to \(operatorName)")
            }
            if let priceUSD = entry.priceUSD {
                parts.append(priceUSD.usdString)
            }
            return joined(parts)
        case .giftClaimed:
            var parts: [String] = []
            if let operatorName = entry.operatorName {
                parts.append("Claimed by \(operatorName)")
            }
            if let priceUSD = entry.priceUSD {
                parts.append(priceUSD.usdString)
            }
            return joined(parts)
        case .giftCancelled:
            var parts: [String] = []
            if let operatorName = entry.operatorName {
                parts.append("Cancelled by \(operatorName)")
            }
            if let priceUSD = entry.priceUSD {
                parts.append(priceUSD.usdString)
            }
            return joined(parts)
        case .nameChange, .nameChangeReclaimed, .giveaway, .unknown:
            return entry.reason ?? entry.rawText
        }
    }

    private var metadataText: String? {
        let parts = [
            entry.targetPledgeID.map { "Target #\($0)" },
            entry.sourcePledgeID.map { "Source #\($0)" },
            destinationSummary
        ]
        .compactMap { $0 }

        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func joined(_ parts: [String]) -> String? {
        let filteredParts = parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return filteredParts.isEmpty ? nil : filteredParts.joined(separator: " • ")
    }
}
