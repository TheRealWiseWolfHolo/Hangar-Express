import SwiftUI
import UIKit

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

    private enum PresentationSyncPolicy {
        case immediate
        case buffered
    }

    let appModel: AppModel

    @Environment(\.dismiss) private var dismiss
    @AppStorage(HangarItemLanguage.storageKey) private var hangarItemLanguageRawValue = HangarItemLanguage.original.rawValue
    @State private var searchText = ""
    @State private var timeFilter: TimeFilter = .all
    @State private var actionFilter: ActionFilter = .all
    @State private var didAttemptInitialLoad = false
    @State private var isInitialRefreshPending = true
    @State private var isDiagnosticsPresented = false
    @State private var displayedPresentation = HangarLogPresentationSnapshot.empty
    @State private var pendingPresentation: HangarLogPresentationSnapshot?
    @State private var refreshViewState = HangarLogRefreshViewState()
    @State private var isPresentationInteractionCoolingDown = false
    @State private var presentationIdleTask: Task<Void, Never>?
    @State private var itemTranslationState = HangarItemTranslationViewState()
    @State private var translationService = OnDeviceHangarItemTranslationService.shared
    @GestureState private var isLogListDragActive = false
    @Namespace private var logNavigationNamespace

    private var hangarLogs: [HangarLogEntry] {
        displayedPresentation.hangarLogs
    }

    private var currentPackageGroups: [GroupedHangarPackage] {
        displayedPresentation.packageGroups
    }

    private var currentShipGroups: [GroupedFleetShip] {
        displayedPresentation.shipGroups
    }

    private var planLimitedHangarLogs: [HangarLogEntry] {
        Array(hangarLogs.prefix(displayedPresentation.hangarLogEntryLimit))
    }

    private var filteredHangarLogs: [HangarLogEntry] {
        planLimitedHangarLogs.filter { entry in
            matchesTimeFilter(entry) && matchesActionFilter(entry) && matchesSearch(entry)
        }
    }

    var body: some View {
        let currentItemTranslator = itemTranslator
        let filteredLogs = filteredHangarLogs

        NavigationStack {
            List {
                Section {
                    IMEAwareSearchRow(
                        text: $searchText,
                        prompt: AppLocalizer.string("Search log entries")
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

                        Text("\(filteredLogs.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Search items, pledge IDs, orders, or raw log text. Filters can narrow results by action and time window.")
                }

                if isLoadingEmptyHangarLog {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            ProgressView()
                            Text("Loading your RSI hangar log.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                    }
                } else if filteredLogs.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("No Log Entries", systemImage: "doc.text.magnifyingglass")
                        } description: {
                            Text(emptyStateDescription)
                        } actions: {
                            Button("Show Refresh Logs") {
                                isDiagnosticsPresented = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else {
                    if hasPendingPresentationUpdate {
                        Section {
                            Button {
                                applyPendingPresentation(force: true)
                            } label: {
                                HStack(spacing: 12) {
                                    if refreshViewState.isHangarLogRefreshing {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.down.doc")
                                            .foregroundStyle(Color.accentColor)
                                    }

                                    Text(AppLocalizer.format("Show %lld loaded log entries", pendingLoadedEntryCount))
                                        .font(.subheadline.weight(.semibold))

                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                        }
                    }

                    Section {
                        ForEach(filteredLogs) { entry in
                            logRow(for: entry, itemTranslator: currentItemTranslator)
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
            .simultaneousGesture(
                DragGesture(minimumDistance: 2)
                    .updating($isLogListDragActive) { _, state, _ in
                        state = true
                    }
            )
            .navigationTitle("Hangar Log")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        syncRefreshViewStateFromAppModel()
                        isDiagnosticsPresented = true
                    } label: {
                        Label("Logs", systemImage: "doc.text.magnifyingglass")
                    }

                    Button {
                        Task {
                            await appModel.refresh(scope: .hangarLog)
                            syncPresentationFromAppModel(policy: .buffered)
                        }
                    } label: {
                        Text(refreshViewState.isHangarLogRefreshing ? LocalizedStringKey("Refreshing...") : LocalizedStringKey("Refresh"))
                    }
                    .disabled(refreshViewState.isAnyRefreshing)
                }
            }
            .sheet(isPresented: $isDiagnosticsPresented) {
                HangarLogDiagnosticsView(
                    entries: refreshViewState.diagnosticsEntries,
                    progress: refreshViewState.progress,
                    errorMessage: refreshViewState.errorMessage
                )
            }
            .task {
                syncPresentationFromAppModel(policy: .immediate)
                guard !didAttemptInitialLoad else {
                    return
                }

                didAttemptInitialLoad = true
                guard hangarLogs.isEmpty else {
                    isInitialRefreshPending = false
                    return
                }

                isInitialRefreshPending = true
                defer {
                    isInitialRefreshPending = false
                }

                await Task.yield()
                guard !Task.isCancelled,
                      hangarLogs.isEmpty else {
                    return
                }

                await appModel.refresh(scope: .hangarLog)
            }
            .task {
                await runPresentationSynchronizationLoop()
            }
            .task(id: hangarItemLanguageRawValue) {
                await loadItemTranslationDictionary()
            }
            .onChange(of: hangarLogs.count) { _, newCount in
                if newCount > 0 {
                    isInitialRefreshPending = false
                }
            }
            .onChange(of: isLogListDragActive) { _, isActive in
                updatePresentationInteractionState(isActive: isActive)
            }
            .onChange(of: isDiagnosticsPresented) { _, isPresented in
                if isPresented {
                    syncRefreshViewStateFromAppModel()
                }
            }
            .onDisappear {
                presentationIdleTask?.cancel()
                presentationIdleTask = nil
            }
        }
    }

    private var itemTranslator: HangarItemTranslator {
        itemTranslationState.translator(for: hangarItemLanguageRawValue)
    }

    private func loadItemTranslationDictionary() async {
        await itemTranslationState.loadDictionary(for: hangarItemLanguageRawValue)
    }

    @MainActor
    private func runPresentationSynchronizationLoop() async {
        syncPresentationFromAppModel(policy: .buffered)

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }

            syncPresentationFromAppModel(policy: .buffered)
        }
    }

    @MainActor
    private func syncPresentationFromAppModel(policy: PresentationSyncPolicy) {
        syncRefreshViewStateFromAppModel()

        guard let sourceSnapshot = appModel.hangarLogPresentationSnapshot else {
            return
        }

        let nextPresentation = HangarLogPresentationSnapshot(
            snapshot: sourceSnapshot,
            isPro: appModel.isPro,
            hangarLogEntryLimit: appModel.hangarLogEntryLimit,
            imageReloadToken: appModel.hangarFleetImageReloadToken,
            reusing: displayedPresentation
        )

        guard !nextPresentation.hasSameDisplay(as: displayedPresentation) else {
            pendingPresentation = nil
            return
        }

        let shouldApplyImmediately = policy == .immediate
            || displayedPresentation.hangarLogs.isEmpty
            || (!refreshViewState.isHangarLogRefreshing && !isPresentationInteractionCoolingDown)

        if shouldApplyImmediately {
            displayedPresentation = nextPresentation
            pendingPresentation = nil
        } else {
            pendingPresentation = nextPresentation
        }
    }

    @MainActor
    private func syncRefreshViewStateFromAppModel() {
        let nextState = HangarLogRefreshViewState(
            isAnyRefreshing: appModel.isRefreshing,
            isHangarLogRefreshing: appModel.isRefreshing(.hangarLog),
            progress: appModel.refreshProgress,
            errorMessage: appModel.lastRefreshErrorMessage,
            diagnosticsEntries: appModel.refreshDiagnostics.entries
        )

        if nextState != refreshViewState {
            refreshViewState = nextState
        }
    }

    @MainActor
    private func applyPendingPresentation(force: Bool) {
        guard let pendingPresentation,
              !pendingPresentation.hasSameDisplay(as: displayedPresentation) else {
            self.pendingPresentation = nil
            return
        }

        guard force || (!refreshViewState.isHangarLogRefreshing && !isPresentationInteractionCoolingDown) else {
            return
        }

        displayedPresentation = pendingPresentation
        self.pendingPresentation = nil
    }

    @MainActor
    private func updatePresentationInteractionState(isActive: Bool) {
        if isActive {
            isPresentationInteractionCoolingDown = true
            presentationIdleTask?.cancel()
            presentationIdleTask = nil
            return
        }

        presentationIdleTask?.cancel()
        presentationIdleTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(900))
            } catch {
                return
            }

            await MainActor.run {
                isPresentationInteractionCoolingDown = false
                syncPresentationFromAppModel(policy: .buffered)
                applyPendingPresentation(force: false)
            }
        }
    }

    private var shouldShowProLogLimitMessage: Bool {
        !displayedPresentation.isPro && hangarLogs.count >= displayedPresentation.hangarLogEntryLimit
    }

    private var isLoadingEmptyHangarLog: Bool {
        hangarLogs.isEmpty && (isInitialRefreshPending || refreshViewState.isHangarLogRefreshing)
    }

    private var hasPendingPresentationUpdate: Bool {
        guard let pendingPresentation else {
            return false
        }

        return !pendingPresentation.hasSameDisplay(as: displayedPresentation)
    }

    private var pendingLoadedEntryCount: Int {
        pendingPresentation?.hangarLogs.count ?? hangarLogs.count
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
        case nil:
            HangarLogRow(
                entry: entry,
                upgradeContext: upgradeContext,
                itemTranslator: itemTranslator,
                destinationSummary: nil
            )
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
                reloadToken: displayedPresentation.imageReloadToken
            )
        case let .ship(shipGroup):
            FleetShipDetailView(
                shipGroup: shipGroup,
                itemTranslator: itemTranslator,
                reloadToken: displayedPresentation.imageReloadToken,
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
            if let package = displayedPresentation.packageByPledgeID[pledgeID] {
                return package
            }
        }

        return nil
    }

    private func packageGroup(containingPledgeID pledgeID: Int) -> GroupedHangarPackage? {
        displayedPresentation.packageGroupByPledgeID[pledgeID]
    }

    private func shipGroup(sourcePackageID pledgeID: Int) -> GroupedFleetShip? {
        displayedPresentation.shipGroupBySourcePackageID[pledgeID]
    }

    private func packageGroup(matchingTitle rawTitle: String) -> GroupedHangarPackage? {
        let normalizedTitle = normalizedLookupText(rawTitle)
        guard !normalizedTitle.isEmpty else {
            return nil
        }

        return displayedPresentation.packageGroupByNormalizedTitle[normalizedTitle]
    }

    private func shipGroup(matchingName rawName: String) -> GroupedFleetShip? {
        let normalizedName = normalizedLookupText(rawName)
        guard !normalizedName.isEmpty else {
            return nil
        }

        if let exactMatch = displayedPresentation.shipGroupByNormalizedName[normalizedName] {
            return exactMatch
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
        hangarLogNormalizedLookupText(value)
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

}

private struct HangarLogRefreshViewState: Equatable {
    var isAnyRefreshing = false
    var isHangarLogRefreshing = false
    var progress: RefreshProgress?
    var errorMessage: String?
    var diagnosticsEntries: [RefreshDiagnosticsStore.Entry] = []
}

private struct HangarLogPresentationSnapshot {
    static let empty = HangarLogPresentationSnapshot(
        hangarLogs: [],
        packageGroups: [],
        shipGroups: [],
        packageSignature: .empty,
        fleetSignature: .empty,
        isPro: false,
        hangarLogEntryLimit: ProSubscriptionConfiguration.standardHangarLogEntryLimit,
        imageReloadToken: UUID()
    )

    let hangarLogs: [HangarLogEntry]
    let packageGroups: [GroupedHangarPackage]
    let shipGroups: [GroupedFleetShip]
    let packageSignature: HangarLogCollectionSignature<Int>
    let fleetSignature: HangarLogCollectionSignature<Int>
    let isPro: Bool
    let hangarLogEntryLimit: Int
    let imageReloadToken: UUID
    let packageByPledgeID: [Int: HangarPackage]
    let packageGroupByPledgeID: [Int: GroupedHangarPackage]
    let packageGroupByNormalizedTitle: [String: GroupedHangarPackage]
    let shipGroupBySourcePackageID: [Int: GroupedFleetShip]
    let shipGroupByNormalizedName: [String: GroupedFleetShip]
    private let displayIdentity: HangarLogPresentationIdentity

    init(
        snapshot: HangarSnapshot,
        isPro: Bool,
        hangarLogEntryLimit: Int,
        imageReloadToken: UUID,
        reusing previous: HangarLogPresentationSnapshot?
    ) {
        let packageSignature = HangarLogCollectionSignature(values: snapshot.packages.map(\.id))
        let fleetSignature = HangarLogCollectionSignature(values: snapshot.fleet.map(\.id))
        let packageGroups = previous?.packageSignature == packageSignature
            ? previous?.packageGroups ?? []
            : snapshot.packages.groupedForInventoryDisplay
        let shipGroups = previous?.fleetSignature == fleetSignature
            ? previous?.shipGroups ?? []
            : snapshot.fleet.groupedForFleetDisplay

        self.init(
            hangarLogs: snapshot.hangarLogs,
            packageGroups: packageGroups,
            shipGroups: shipGroups,
            packageSignature: packageSignature,
            fleetSignature: fleetSignature,
            isPro: isPro,
            hangarLogEntryLimit: hangarLogEntryLimit,
            imageReloadToken: imageReloadToken
        )
    }

    private init(
        hangarLogs: [HangarLogEntry],
        packageGroups: [GroupedHangarPackage],
        shipGroups: [GroupedFleetShip],
        packageSignature: HangarLogCollectionSignature<Int>,
        fleetSignature: HangarLogCollectionSignature<Int>,
        isPro: Bool,
        hangarLogEntryLimit: Int,
        imageReloadToken: UUID
    ) {
        self.hangarLogs = hangarLogs
        self.packageGroups = packageGroups
        self.shipGroups = shipGroups
        self.packageSignature = packageSignature
        self.fleetSignature = fleetSignature
        self.isPro = isPro
        self.hangarLogEntryLimit = hangarLogEntryLimit
        self.imageReloadToken = imageReloadToken

        var packageByPledgeID: [Int: HangarPackage] = [:]
        var packageGroupByPledgeID: [Int: GroupedHangarPackage] = [:]
        var packageGroupByNormalizedTitle: [String: GroupedHangarPackage] = [:]
        for packageGroup in packageGroups {
            for package in packageGroup.packages {
                packageByPledgeID[package.id] = package
                packageGroupByPledgeID[package.id] = packageGroup

                let packageTitle = hangarLogNormalizedLookupText(package.title)
                if !packageTitle.isEmpty, packageGroupByNormalizedTitle[packageTitle] == nil {
                    packageGroupByNormalizedTitle[packageTitle] = packageGroup
                }

                for item in package.contents {
                    let itemTitle = hangarLogNormalizedLookupText(item.title)
                    if !itemTitle.isEmpty, packageGroupByNormalizedTitle[itemTitle] == nil {
                        packageGroupByNormalizedTitle[itemTitle] = packageGroup
                    }
                }
            }
        }

        var shipGroupBySourcePackageID: [Int: GroupedFleetShip] = [:]
        var shipGroupByNormalizedName: [String: GroupedFleetShip] = [:]
        for shipGroup in shipGroups {
            for ship in shipGroup.ships {
                shipGroupBySourcePackageID[ship.sourcePackageID] = shipGroup

                let shipName = hangarLogNormalizedLookupText(ship.displayName)
                if !shipName.isEmpty, shipGroupByNormalizedName[shipName] == nil {
                    shipGroupByNormalizedName[shipName] = shipGroup
                }
            }
        }

        self.packageByPledgeID = packageByPledgeID
        self.packageGroupByPledgeID = packageGroupByPledgeID
        self.packageGroupByNormalizedTitle = packageGroupByNormalizedTitle
        self.shipGroupBySourcePackageID = shipGroupBySourcePackageID
        self.shipGroupByNormalizedName = shipGroupByNormalizedName
        displayIdentity = HangarLogPresentationIdentity(
            logIDs: hangarLogs.map(\.id),
            packageSignature: packageSignature,
            fleetSignature: fleetSignature,
            isPro: isPro,
            hangarLogEntryLimit: hangarLogEntryLimit,
            imageReloadToken: imageReloadToken
        )
    }

    func hasSameDisplay(as other: HangarLogPresentationSnapshot) -> Bool {
        displayIdentity == other.displayIdentity
    }
}

private struct HangarLogPresentationIdentity: Equatable {
    let logIDs: [String]
    let packageSignature: HangarLogCollectionSignature<Int>
    let fleetSignature: HangarLogCollectionSignature<Int>
    let isPro: Bool
    let hangarLogEntryLimit: Int
    let imageReloadToken: UUID
}

private struct HangarLogCollectionSignature<Value: Equatable>: Equatable {
    static var empty: Self {
        HangarLogCollectionSignature(values: [])
    }

    let values: [Value]
}

private func hangarLogNormalizedLookupText(_ value: String) -> String {
    value
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .localizedLowercase
}

private struct HangarLogDiagnosticsView: View {
    let entries: [RefreshDiagnosticsStore.Entry]
    let progress: RefreshProgress?
    let errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let progress {
                    Section("Current Refresh") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(progress.stage.title)
                                .font(.headline)
                            Text(progress.detail)
                                .foregroundStyle(.secondary)
                            if let fraction = progress.displayFractionCompleted {
                                ProgressView(value: fraction)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let errorMessage,
                   !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Last Error") {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if entries.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Refresh Logs",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("Run a Hangar Log refresh, then open this view again.")
                        )
                    }
                } else {
                    Section("Refresh Logs") {
                        ForEach(entries.reversed()) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(entry.timestampLabel)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)

                                    Text(entry.level.rawValue)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(color(for: entry.level))

                                    Text(entry.stage)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Text(entry.summary)
                                    .font(.subheadline.weight(.semibold))

                                if let detail = entry.detail {
                                    Text(detail)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Refresh Logs")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Copy") {
                        UIPasteboard.general.string = reportText
                    }
                    .disabled(reportText.isEmpty)
                }
            }
        }
    }

    private var reportText: String {
        var sections: [String] = []

        if let progress {
            sections.append("Current Refresh")
            sections.append("\(progress.stage.title)\n\(progress.detail)")
        }

        if let errorMessage,
           !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Last Error")
            sections.append(errorMessage)
        }

        if !entries.isEmpty {
            sections.append("Refresh Logs")
            sections.append(
                entries.map { entry in
                    let base = "[\(entry.timestampLabel)] \(entry.level.rawValue) \(entry.stage)\n\(entry.summary)"
                    guard let detail = entry.detail else {
                        return base
                    }

                    return "\(base)\n\(detail)"
                }
                .joined(separator: "\n\n")
            )
        }

        return sections.joined(separator: "\n\n")
    }

    private func color(for level: RefreshDiagnosticsStore.Entry.Level) -> Color {
        switch level {
        case .info:
            return .secondary
        case .warning:
            return .orange
        case .error:
            return .red
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
