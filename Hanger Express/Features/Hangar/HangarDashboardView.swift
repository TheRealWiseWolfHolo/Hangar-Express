import Photos
import SwiftUI
import UIKit

struct HangarDashboardView: View {
    enum PackageFilter: CaseIterable, Identifiable {
        case all
        case giftable
        case reclaimable

        var id: Self { self }

        var title: String {
            switch self {
            case .all:
                return AppLocalizer.string("All")
            case .giftable:
                return AppLocalizer.string("Giftable")
            case .reclaimable:
                return AppLocalizer.string("Reclaimable")
            }
        }
    }

    enum SearchFilter: CaseIterable, Identifiable {
        case lti
        case upgrades
        case packages

        var id: Self { self }

        var title: String {
            switch self {
            case .lti:
                return "LTI"
            case .upgrades:
                return AppLocalizer.string("Upgrades")
            case .packages:
                return AppLocalizer.string("Packages")
            }
        }
    }

    let appModel: AppModel
    let snapshot: HangarSnapshot
    private let allPackageGroups: [GroupedHangarPackage]

    @Environment(\.displayScale) private var displayScale
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @AppStorage(HangarItemLanguage.storageKey) private var hangarItemLanguageRawValue = HangarItemLanguage.original.rawValue
    @AppStorage(DisplayPreferences.hangarUpgradedShipDisplayModeKey) private var showsUpgradedShipInHangar = DisplayPreferences.hangarUpgradedShipDisplayEnabledByDefault
    @AppStorage(DisplayPreferences.compositeUpgradeThumbnailModeKey) private var usesCompositeUpgradeThumbnails = DisplayPreferences.compositeUpgradeThumbnailsEnabledByDefault
    @AppStorage(DisplayPreferences.hangarGiftedHighlightKey) private var highlightsGiftedHangarRows = DisplayPreferences.hangarGiftedHighlightEnabledByDefault
    @AppStorage(DisplayPreferences.hangarUpgradedHighlightKey) private var highlightsUpgradedHangarRows = DisplayPreferences.hangarUpgradedHighlightEnabledByDefault
    @AppStorage(DisplayPreferences.sharePictureAutoCopiesDebugLogKey) private var autoCopiesSharePictureDebugLog = DisplayPreferences.sharePictureAutoCopiesDebugLogEnabledByDefault
    @AppStorage(DisplayPreferences.hangarBulkSelectionKey) private var enablesBulkSelection = DisplayPreferences.hangarBulkSelectionEnabledByDefault
    @State private var filter: PackageFilter = .all
    @State private var searchText = ""
    @State private var searchFilters: Set<SearchFilter> = []
    @State private var isSearchPresented = false
    @State private var isLogPresented = false
    @State private var isSelectingPackages = false
    @State private var selectedPackageGroupIDs: Set<String> = []
    @State private var presentedBulkAction: HangarBulkActionRequest?
    @State private var sharePicturePayload: HangarSharePicturePayload?
    @State private var sharePictureError: HangarSharePictureError?
    @State private var photoSaveNotice: HangarPhotoSaveNotice?
    @State private var isGeneratingSharePicture = false
    @State private var itemTranslationState = HangarItemTranslationViewState()
    @State private var translationService = OnDeviceHangarItemTranslationService.shared
    @State private var searchHaystackCache = HangarPackageSearchHaystackCache()
    @State private var hangarImagePrefetchTask: Task<Void, Never>?

    private static let hangarImagePrefetchLookaheadCount = 10
    private static let hangarThumbnailPointSize = CGSize(width: 76, height: 76)

    init(appModel: AppModel, snapshot: HangarSnapshot) {
        self.appModel = appModel
        self.snapshot = snapshot
        allPackageGroups = snapshot.packages.groupedForInventoryDisplay
    }

    var body: some View {
        let currentItemTranslator = itemTranslator
        let visiblePackageGroups = filteredPackageGroups
        let selection = selectionState(for: visiblePackageGroups)

        NavigationStack {
            List {
                Section {
                    IMEAwareSearchRow(
                        text: $searchText,
                        isActive: $isSearchPresented,
                        prompt: AppLocalizer.string("Search packages, ships, insurance"),
                        onCommittedTextChange: pruneSelectionToVisibleGroups
                    )
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    Picker("Filter", selection: $filter) {
                        ForEach(PackageFilter.allCases) { option in
                            Text(option.title).tag(option)
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

                if isSelectingPackages {
                    Section {
                        HangarBulkSelectionSummaryView(
                            selectedRowCount: selection.selectedRowCount,
                            selectedPledgeCount: selection.selectedPledgeCount,
                            canGift: selection.canGift,
                            canReclaim: selection.canReclaim,
                            onClear: clearSelection,
                            onGift: presentBulkGift,
                            onReclaim: presentBulkReclaim
                        )
                    } header: {
                        Text("Selection")
                    } footer: {
                        Text(selectionFooterText(for: selection))
                    }
                }

                Section {
                    ForEach(Array(visiblePackageGroups.enumerated()), id: \.element.id) { offset, packageGroup in
                        let isSelected = selectedPackageGroupIDs.contains(packageGroup.id)

                        if isSelectingPackages {
                            Button {
                                toggleSelection(for: packageGroup)
                            } label: {
                                HangarSelectablePackageGroupRow(
                                    packageGroup: packageGroup,
                                    itemTranslator: currentItemTranslator,
                                    isSelected: isSelected,
                                    reloadToken: appModel.hangarFleetImageReloadToken
                                )
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                scheduleHangarImagePrefetch(startingAt: offset, in: visiblePackageGroups)
                            }
                            .listRowBackground(
                                hangarRowBackground(
                                    for: packageGroup.representative,
                                    isSelected: isSelected
                                )
                            )
                        } else {
                            NavigationLink {
                                HangarPackageDetailView(
                                    appModel: appModel,
                                    packageGroup: packageGroup,
                                    itemTranslator: currentItemTranslator,
                                    reloadToken: appModel.hangarFleetImageReloadToken
                                )
                            } label: {
                                HangarPackageGroupRow(
                                    packageGroup: packageGroup,
                                    itemTranslator: currentItemTranslator,
                                    reloadToken: appModel.hangarFleetImageReloadToken
                                )
                            }
                            .contextMenu {
                                Button {
                                    Task {
                                        await savePictureToPhotos(for: packageGroup)
                                    }
                                } label: {
                                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                                }
                                .disabled(isGeneratingSharePicture)

                                Button {
                                    Task {
                                        await presentSharePicture(for: packageGroup)
                                    }
                                } label: {
                                    Label("Share Picture", systemImage: "photo.on.rectangle.angled")
                                }
                                .disabled(isGeneratingSharePicture)

                                Divider()

                                Button {
                                    UIPasteboard.general.string = hangarCardDebugExport(for: packageGroup)
                                } label: {
                                    Label("Copy Raw Card Data", systemImage: "doc.on.doc")
                                }

                                ShareLink(
                                    item: hangarCardDebugExport(for: packageGroup),
                                    subject: Text("Hangar Card Debug Export"),
                                    message: Text("Raw Hangar Express card data")
                                ) {
                                    Label("Share Raw Card Data", systemImage: "square.and.arrow.up")
                                }
                            }
                            .onAppear {
                                scheduleHangarImagePrefetch(startingAt: offset, in: visiblePackageGroups)
                            }
                            .listRowBackground(hangarRowBackground(for: packageGroup.representative))
                        }
                    }
                } header: {
                    Text("Pledges")
                }
            }
            .id(appLanguageRawValue)
            .task(id: hangarItemLanguageRawValue) {
                await loadItemTranslationDictionary()
            }
            .task(id: hangarImagePrefetchID(for: visiblePackageGroups)) {
                await prefetchHangarImages(startingAt: 0, in: visiblePackageGroups)
            }
            .onDisappear {
                hangarImagePrefetchTask?.cancel()
                hangarImagePrefetchTask = nil
            }
            .onChange(of: isSearchPresented) { _, isPresented in
                guard !isPresented else {
                    return
                }

                searchFilters.removeAll()
            }
            .onChange(of: enablesBulkSelection) { _, isEnabled in
                if !isEnabled {
                    endSelection()
                }
            }
            .onChange(of: filter) { _, _ in
                pruneSelectionToVisibleGroups()
            }
            .onChange(of: searchFilters) { _, _ in
                pruneSelectionToVisibleGroups()
            }
            .navigationTitle("Hangar")
            .sheet(isPresented: $isLogPresented) {
                HangarLogView(appModel: appModel)
            }
            .sheet(item: $presentedBulkAction) { request in
                NavigationStack {
                    switch request.action {
                    case .gift:
                        HangarBulkGiftConfirmationView(
                            appModel: appModel,
                            packageGroups: request.packageGroups,
                            onCompleted: completeBulkAction
                        )
                    case .reclaim:
                        HangarBulkMeltConfirmationView(
                            appModel: appModel,
                            packageGroups: request.packageGroups,
                            onCompleted: completeBulkAction
                        )
                    }
                }
            }
            .sheet(item: $sharePicturePayload) { payload in
                HangarShareSheet(activityItems: [payload.fileURL])
            }
            .alert(item: $sharePictureError) { error in
                Alert(
                    title: Text("Share Picture Failed"),
                    message: Text(error.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .alert(item: $photoSaveNotice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .overlay {
                if isGeneratingSharePicture {
                    HangarSharePictureProgressOverlay()
                }
            }
            .toolbar {
                if enablesBulkSelection {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(AppLocalizer.string(isSelectingPackages ? "Done" : "Select")) {
                            if isSelectingPackages {
                                endSelection()
                            } else {
                                isSelectingPackages = true
                            }
                        }
                        .disabled(appModel.isRefreshing)
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Log") {
                        isLogPresented = true
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
        }
    }

    private func hangarImagePrefetchID(for packageGroups: [GroupedHangarPackage]) -> String {
        [
            appModel.hangarFleetImageReloadToken.uuidString,
            showsUpgradedShipInHangar ? "upgraded" : "package",
            usesCompositeUpgradeThumbnails ? "composite" : "single",
            packageGroups.prefix(Self.hangarImagePrefetchLookaheadCount).map(\.id).joined(separator: ","),
            "\(packageGroups.count)"
        ].joined(separator: "|")
    }

    private func scheduleHangarImagePrefetch(
        startingAt startIndex: Int,
        in packageGroups: [GroupedHangarPackage]
    ) {
        hangarImagePrefetchTask?.cancel()
        let requests = hangarImagePrefetchRequests(startingAt: startIndex, in: packageGroups)
        hangarImagePrefetchTask = Task(priority: .utility) {
            await URLCachedImageStore.shared.prefetchCompositeImages(for: requests.composites)
            await URLCachedImageStore.shared.prefetchImages(for: requests.remotes)
        }
    }

    private func prefetchHangarImages(
        startingAt startIndex: Int,
        in packageGroups: [GroupedHangarPackage]
    ) async {
        let requests = hangarImagePrefetchRequests(startingAt: startIndex, in: packageGroups)
        await URLCachedImageStore.shared.prefetchCompositeImages(for: requests.composites)
        await URLCachedImageStore.shared.prefetchImages(for: requests.remotes)
    }

    private func hangarImagePrefetchRequests(
        startingAt startIndex: Int,
        in packageGroups: [GroupedHangarPackage]
    ) -> (remotes: [RemoteImagePrefetchRequest], composites: [UpgradeCompositeImagePrefetchRequest]) {
        guard startIndex < packageGroups.count else {
            return ([], [])
        }

        let thumbnailSize = Self.hangarThumbnailPointSize
        var remoteRequests: [RemoteImagePrefetchRequest] = []
        var compositeRequests: [UpgradeCompositeImagePrefetchRequest] = []
        let window = packageGroups
            .dropFirst(max(0, startIndex))
            .prefix(Self.hangarImagePrefetchLookaheadCount)

        for packageGroup in window {
            let package = packageGroup.representative
            if usesCompositeUpgradeThumbnails,
               let upgradePricing = compositeUpgradePricing(for: package),
               upgradePricing.sourceShipImageURL != nil || upgradePricing.targetShipImageURL != nil {
                compositeRequests.append(
                    UpgradeCompositeImagePrefetchRequest(
                        sourceURL: upgradePricing.sourceShipImageURL,
                        targetURL: upgradePricing.targetShipImageURL,
                        targetPointSize: thumbnailSize,
                        displayScale: displayScale
                    )
                )
            } else if let thumbnailURL = displayThumbnailURL(for: package) {
                remoteRequests.append(
                    RemoteImagePrefetchRequest(
                        url: thumbnailURL,
                        targetPointSize: thumbnailSize,
                        displayScale: displayScale
                    )
                )
            }
        }

        return (remoteRequests, compositeRequests)
    }

    private func compositeUpgradePricing(for package: HangarPackage) -> PackageItem.UpgradePricing? {
        guard package.isUpgradeOnlyPledge else {
            return nil
        }

        return package.contents.compactMap(\.upgradePricing).first
    }

    private func displayThumbnailURL(for package: HangarPackage) -> URL? {
        if showsUpgradedShipInHangar,
           let upgradedShipThumbnailURL = package.upgradedShipThumbnailURL {
            return upgradedShipThumbnailURL
        }

        return package.packageThumbnailURL
    }

    private var hasStoredCredentials: Bool {
        appModel.session?.hasStoredCredentials == true
    }

    private func selectionState(for visiblePackageGroups: [GroupedHangarPackage]) -> HangarBulkSelectionState {
        let packageGroups = visiblePackageGroups.filter { selectedPackageGroupIDs.contains($0.id) }
        let packages = packageGroups.flatMap(\.packages)
        let hasSelection = !packages.isEmpty
        let allPackagesCanGift = hasSelection && packages.allSatisfy(\.canGift)
        let allPackagesCanReclaim = hasSelection && packages.allSatisfy(\.canReclaim)
        let canGift = allPackagesCanGift
            && hasStoredCredentials
            && !appModel.isRefreshing
        let canReclaim = allPackagesCanReclaim
            && hasStoredCredentials
            && !appModel.isRefreshing

        return HangarBulkSelectionState(
            packageGroups: packageGroups,
            packages: packages,
            allPackagesCanGift: allPackagesCanGift,
            allPackagesCanReclaim: allPackagesCanReclaim,
            canGift: canGift,
            canReclaim: canReclaim
        )
    }

    private func selectionFooterText(for selection: HangarBulkSelectionState) -> String {
        if selection.packages.isEmpty {
            return AppLocalizer.string("Select one or more pledge rows to unlock bulk actions.")
        }

        if !hasStoredCredentials {
            if appModel.session?.isReadOnly == true {
                return AppLocalizer.string("Bulk gift and reclaim are disabled for this read-only account.")
            }
            return AppLocalizer.string("Bulk gift and reclaim need a fresh sign-in with saved credentials.")
        }

        if appModel.isRefreshing {
            return AppLocalizer.string("Bulk actions are unavailable while Hangar Express is refreshing.")
        }

        if !selection.allPackagesCanGift && !selection.allPackagesCanReclaim {
            return AppLocalizer.string("Gift and reclaim only unlock when every selected pledge is eligible for that action.")
        }

        if !selection.allPackagesCanGift {
            return AppLocalizer.string("Gift is disabled because at least one selected pledge cannot be gifted.")
        }

        if !selection.allPackagesCanReclaim {
            return AppLocalizer.string("Reclaim is disabled because at least one selected pledge cannot be melted.")
        }

        return AppLocalizer.string("Actions apply to every pledge represented by the selected rows.")
    }

    private var filteredPackageGroups: [GroupedHangarPackage] {
        let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let currentItemTranslator = itemTranslator
        let searchSignature = HangarPackageSearchHaystackCache.Signature(
            snapshotLastSyncedAt: snapshot.lastSyncedAt,
            languageRawValue: currentItemTranslator.language.rawValue,
            dictionaryLocale: currentItemTranslator.dictionary?.locale,
            dictionaryVersion: currentItemTranslator.dictionary?.version,
            translationCacheGeneration: translationService.cacheGeneration,
            showsUpgradedShipInHangar: showsUpgradedShipInHangar
        )

        return allPackageGroups.filter { packageGroup in
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

            guard !normalizedSearchText.isEmpty else {
                return true
            }

            let haystack = searchHaystackCache.haystack(
                for: packageGroup,
                signature: searchSignature,
                itemTranslator: currentItemTranslator,
                translationService: translationService
            )

            return haystack.contains(normalizedSearchText)
        }
    }

    private var itemTranslator: HangarItemTranslator {
        itemTranslationState.translator(for: hangarItemLanguageRawValue)
    }

    private func loadItemTranslationDictionary() async {
        await itemTranslationState.loadDictionary(for: hangarItemLanguageRawValue)
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

    private func toggleSelection(for packageGroup: GroupedHangarPackage) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            if selectedPackageGroupIDs.contains(packageGroup.id) {
                selectedPackageGroupIDs.remove(packageGroup.id)
            } else {
                selectedPackageGroupIDs.insert(packageGroup.id)
            }
        }
    }

    private func clearSelection() {
        selectedPackageGroupIDs.removeAll()
    }

    private func endSelection() {
        isSelectingPackages = false
        clearSelection()
    }

    private func pruneSelectionToVisibleGroups() {
        guard isSelectingPackages else {
            return
        }

        let visibleIDs = Set(filteredPackageGroups.map(\.id))
        selectedPackageGroupIDs = selectedPackageGroupIDs.intersection(visibleIDs)
    }

    private func presentBulkGift() {
        let packageGroups = selectionState(for: filteredPackageGroups).packageGroups
        guard !packageGroups.isEmpty else {
            return
        }

        presentedBulkAction = HangarBulkActionRequest(action: .gift, packageGroups: packageGroups)
    }

    private func presentBulkReclaim() {
        let packageGroups = selectionState(for: filteredPackageGroups).packageGroups
        guard !packageGroups.isEmpty else {
            return
        }

        presentedBulkAction = HangarBulkActionRequest(action: .reclaim, packageGroups: packageGroups)
    }

    @MainActor
    private func completeBulkAction() {
        presentedBulkAction = nil
        endSelection()
    }

    private func hangarCardDebugExport(for packageGroup: GroupedHangarPackage) -> String {
        HangarCardDebugExporter.string(
            for: packageGroup,
            showsUpgradedShipInHangar: appModel.showsUpgradedShipInHangar,
            compositeUpgradeThumbnailsEnabled: appModel.compositeUpgradeThumbnailsEnabled
        )
    }

    private func presentSharePicture(for packageGroup: GroupedHangarPackage) async {
        guard !isGeneratingSharePicture else {
            return
        }

        isGeneratingSharePicture = true
        defer {
            isGeneratingSharePicture = false
        }

        if autoCopiesSharePictureDebugLog {
            UIPasteboard.general.string = hangarCardDebugExport(for: packageGroup)
        }

        do {
            let fileURL = try await HangarSharePictureGenerator.makeJPEG(
                for: packageGroup,
                fleet: snapshot.fleet,
                itemTranslator: itemTranslator
            )
            sharePicturePayload = HangarSharePicturePayload(fileURL: fileURL)
        } catch {
            sharePictureError = HangarSharePictureError(message: error.localizedDescription)
        }
    }

    @MainActor
    private func savePictureToPhotos(for packageGroup: GroupedHangarPackage) async {
        guard !isGeneratingSharePicture else { return }
        isGeneratingSharePicture = true
        defer { isGeneratingSharePicture = false }

        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            photoSaveNotice = HangarPhotoSaveNotice(
                title: AppLocalizer.string("Unable to Save Image"),
                message: AppLocalizer.string("Photo access is required to save the hangar picture.")
            )
            return
        }

        do {
            let fileURL = try await HangarSharePictureGenerator.makeJPEG(
                for: packageGroup,
                fleet: snapshot.fleet,
                itemTranslator: itemTranslator
            )
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
            }
            photoSaveNotice = HangarPhotoSaveNotice(
                title: AppLocalizer.string("Saved to Photos"),
                message: AppLocalizer.string("The hangar picture was added to your photo library.")
            )
        } catch {
            photoSaveNotice = HangarPhotoSaveNotice(
                title: AppLocalizer.string("Unable to Save Image"),
                message: error.localizedDescription
            )
        }
    }

    @ViewBuilder
    private func hangarRowBackground(for package: HangarPackage, isSelected: Bool = false) -> some View {
        let baseColor = Color(uiColor: .secondarySystemGroupedBackground)

        ZStack {
            baseColor

            if isSelected {
                Color.accentColor.opacity(0.18)
            } else if highlightsGiftedHangarRows && package.status.localizedLowercase.contains("gifted") {
                Color.green.opacity(0.16)
            } else if highlightsUpgradedHangarRows && package.isUpgradedShipPledge {
                Color.accentColor.opacity(0.16)
            }
        }
    }
}

private struct HangarBulkActionRequest: Identifiable {
    enum Action {
        case gift
        case reclaim
    }

    let id = UUID()
    let action: Action
    let packageGroups: [GroupedHangarPackage]
}

private struct HangarBulkSelectionState {
    let packageGroups: [GroupedHangarPackage]
    let packages: [HangarPackage]
    let allPackagesCanGift: Bool
    let allPackagesCanReclaim: Bool
    let canGift: Bool
    let canReclaim: Bool

    var selectedRowCount: Int {
        packageGroups.count
    }

    var selectedPledgeCount: Int {
        packages.count
    }
}

private struct HangarBulkSelectionSummaryView: View {
    let selectedRowCount: Int
    let selectedPledgeCount: Int
    let canGift: Bool
    let canReclaim: Bool
    let onClear: () -> Void
    let onGift: () -> Void
    let onReclaim: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectionTitle)
                        .font(.headline)

                    Text(selectionSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button("Clear", action: onClear)
                    .disabled(selectedPledgeCount == 0)
            }

            HStack(spacing: 12) {
                Button(action: onGift) {
                    Label("Gift", systemImage: "gift.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!canGift)

                Button(role: .destructive, action: onReclaim) {
                    Label {
                        Text(AppLocalizer.string("Reclaim"))
                    } icon: {
                        Image(systemName: "arrow.3.trianglepath")
                    }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!canReclaim)
            }
        }
        .padding(.vertical, 4)
    }

    private var selectionTitle: String {
        if selectedPledgeCount == 0 {
            return AppLocalizer.string("No pledges selected")
        }

        return AppLocalizer.format("%lld pledge(s) selected", selectedPledgeCount)
    }

    private var selectionSubtitle: String {
        if selectedRowCount == selectedPledgeCount {
            return AppLocalizer.string("Tap pledge rows to include them.")
        }

        return AppLocalizer.format("%lld selected row(s), including grouped copies.", selectedRowCount)
    }
}

private struct HangarCardDebugExport: Codable {
    struct DisplaySettings: Codable {
        let showsUpgradedShipInHangar: Bool
        let compositeUpgradeThumbnailsEnabled: Bool
    }

    struct RepresentativeComputedDisplay: Codable {
        let displayTitle: String
        let displayThumbnailURL: String?
        let insuranceBadgeText: String?
        let isUpgradedShipPledge: Bool
        let upgradedShipDisplayTitle: String?
        let upgradedShipThumbnailURL: String?
    }

    let generatedAt: String
    let quantity: Int
    let containsMultipleCopies: Bool
    let displaySettings: DisplaySettings
    let representativeComputedDisplay: RepresentativeComputedDisplay
    let representative: HangarPackage
    let packages: [HangarPackage]
}

private enum HangarCardDebugExporter {
    static func string(
        for packageGroup: GroupedHangarPackage,
        showsUpgradedShipInHangar: Bool,
        compositeUpgradeThumbnailsEnabled: Bool
    ) -> String {
        let export = HangarCardDebugExport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            quantity: packageGroup.quantity,
            containsMultipleCopies: packageGroup.containsMultipleCopies,
            displaySettings: .init(
                showsUpgradedShipInHangar: showsUpgradedShipInHangar,
                compositeUpgradeThumbnailsEnabled: compositeUpgradeThumbnailsEnabled
            ),
            representativeComputedDisplay: .init(
                displayTitle: packageGroup.representative.debugDisplayTitle(showsUpgradedShipInHangar: showsUpgradedShipInHangar),
                displayThumbnailURL: packageGroup.representative.debugDisplayThumbnailURL(showsUpgradedShipInHangar: showsUpgradedShipInHangar)?.absoluteString,
                insuranceBadgeText: packageGroup.representative.displayedInsurance,
                isUpgradedShipPledge: packageGroup.representative.isUpgradedShipPledge,
                upgradedShipDisplayTitle: packageGroup.representative.upgradedShipDisplayTitle,
                upgradedShipThumbnailURL: packageGroup.representative.upgradedShipThumbnailURL?.absoluteString
            ),
            representative: packageGroup.representative,
            packages: packageGroup.packages
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(export),
              let string = String(data: data, encoding: .utf8) else {
            return """
            {
              "error" : "Failed to encode hangar card debug export",
              "representativePackageID" : \(packageGroup.representative.id),
              "quantity" : \(packageGroup.quantity)
            }
            """
        }

        return string
    }
}

private struct HangarCouponInfo: Equatable {
    let couponLabel: String
    let cardTitle: String
    let code: String?
}

private enum HangarCouponParser {
    private static let couponExpression = try? NSRegularExpression(
        pattern: #"\b([0-9]{1,3})\s*%\s*Coupon\b"#,
        options: [.caseInsensitive]
    )

    private static let delimiterExpression = try? NSRegularExpression(pattern: #"[:：]"#)

    static func info(from title: String) -> HangarCouponInfo? {
        let fullRange = NSRange(title.startIndex ..< title.endIndex, in: title)
        guard let couponExpression,
              let match = couponExpression.firstMatch(in: title, range: fullRange),
              let couponRange = Range(match.range, in: title) else {
            return nil
        }

        let couponLabel = String(title[couponRange])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let delimiterSearchRange = NSRange(
            location: match.range.location + match.range.length,
            length: max(0, fullRange.length - match.range.location - match.range.length)
        )
        let delimiterMatch = delimiterExpression?.firstMatch(in: title, range: delimiterSearchRange)
        let delimiterRange = delimiterMatch.flatMap { Range($0.range, in: title) }
        let rawCardTitle = delimiterRange
            .map { String(title[..<$0.lowerBound]) }
            ?? title
        let cardTitle = rawCardTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawCode = delimiterRange.map {
            String(title[$0.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let code = rawCode.flatMap { $0.isEmpty ? nil : $0 }

        return HangarCouponInfo(
            couponLabel: couponLabel,
            cardTitle: cardTitle.isEmpty ? couponLabel : cardTitle,
            code: code
        )
    }
}

struct HangarPackageGroupRow: View {
    @AppStorage(DisplayPreferences.hangarUpgradedShipDisplayModeKey) private var showsUpgradedShipInHangar = DisplayPreferences.hangarUpgradedShipDisplayEnabledByDefault
    let packageGroup: GroupedHangarPackage
    let itemTranslator: HangarItemTranslator
    let reloadToken: UUID?

    private var package: HangarPackage {
        packageGroup.representative
    }

    private var compositeUpgradePricing: PackageItem.UpgradePricing? {
        guard package.isUpgradeOnlyPledge else {
            return nil
        }

        return package.contents.compactMap(\.upgradePricing).first
    }

    private var displayThumbnailURL: URL? {
        if showsUpgradedShipInHangar,
           let upgradedShipThumbnailURL = package.upgradedShipThumbnailURL {
            return upgradedShipThumbnailURL
        }

        return package.packageThumbnailURL
    }

    private var displayTitleSource: String {
        let rawTitle: String
        if showsUpgradedShipInHangar,
           let upgradedShipDisplayTitle = package.upgradedShipDisplayTitle {
            rawTitle = upgradedShipDisplayTitle
        } else {
            rawTitle = package.title
        }

        return HangarCouponParser.info(from: rawTitle)?.cardTitle ?? rawTitle
    }

    private var insuranceBadgeText: String? {
        package.isOriginalConceptShip ? "OC" : visibleInsurance
    }

    private var insuranceBadgeStyle: HangarInsuranceBadge.Style {
        package.isOriginalConceptShip ? .originalConcept : .standard
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    RemoteThumbnailView(
                        url: displayThumbnailURL,
                        upgradeCompositePricing: compositeUpgradePricing,
                        reloadToken: reloadToken,
                        fallbackSystemImage: "shippingbox.fill",
                        size: 76
                    )

                    if let insuranceBadgeText {
                        HangarInsuranceBadge(
                            text: insuranceBadgeText,
                            style: insuranceBadgeStyle
                        )
                            .padding(6)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HangarTranslatedText(
                        source: displayTitleSource,
                        itemTranslator: itemTranslator
                    )
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, packageGroup.containsMultipleCopies ? 52 : 0)
                        .layoutPriority(1)

                    insuranceSummaryView

                    Spacer(minLength: 0)

                    HStack(alignment: .bottom, spacing: 12) {
                        PriceSummaryView(
                            currentValueUSD: package.currentValueUSD,
                            meltValueUSD: package.originalValueUSD
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(acquiredDateSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .center)

                        HStack(spacing: 12) {
                            RowCapabilityIcon(
                                systemImage: "gift.fill",
                                tint: .green,
                                isAvailable: package.canGift,
                                accessibilityLabel: package.canGift ? "Giftable" : "Locked"
                            )

                            RowCapabilityIcon(
                                systemImage: "arrow.3.trianglepath",
                                tint: .red,
                                isAvailable: package.canReclaim,
                                accessibilityLabel: package.canReclaim ? "Reclaimable" : "No Melt"
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 76, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if packageGroup.containsMultipleCopies {
                quantityBadge
                    .padding(.trailing, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var quantityBadge: some View {
        Text("x\(packageGroup.quantity)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            )
    }

    private var acquiredDateSummary: String {
        AppLocalizer.displayDate(package.acquiredAt)
    }

    private var visibleInsurance: String? {
        guard let displayedInsurance = package.displayedInsurance,
              !HangarPackage.isUnknownInsuranceLabel(displayedInsurance) else {
            return nil
        }

        return displayedInsurance
    }

    @ViewBuilder
    private var insuranceSummaryView: some View {
        let isGifted = package.status.localizedLowercase.contains("gifted")
        let isUpgraded = package.isUpgradedShipPledge

        if isGifted || isUpgraded {
            HStack(spacing: 0) {
                if isGifted {
                    Text("Gifted")
                        .foregroundStyle(.green)
                }

                if isGifted && isUpgraded {
                    Text(" • ")
                        .foregroundStyle(.secondary)
                }

                if isUpgraded {
                    Text("Upgraded")
                        .foregroundStyle(Color.accentColor)
                }
            }
                .font(.subheadline)
        }
    }

}

private struct HangarSelectablePackageGroupRow: View {
    let packageGroup: GroupedHangarPackage
    let itemTranslator: HangarItemTranslator
    let isSelected: Bool
    let reloadToken: UUID?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)

            HangarPackageGroupRow(
                packageGroup: packageGroup,
                itemTranslator: itemTranslator,
                reloadToken: reloadToken
            )
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isSelected
                ? Text("Selected \(itemTranslator.translated(packageGroup.representative.title))")
                : Text("Not selected \(itemTranslator.translated(packageGroup.representative.title))")
        )
    }
}

private struct HangarInsuranceBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    enum Style {
        case standard
        case originalConcept
    }

    let text: String
    let style: Style

    private var palette: HangarInsuranceBadgePalette {
        HangarInsuranceBadgePalette(colorScheme: colorScheme)
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(style == .originalConcept ? .heavy : .semibold))
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .modifier(
                HangarInsuranceBadgeGlassStyle(
                    palette: palette,
                    style: style
                )
            )
    }

    private var foregroundStyle: Color {
        switch style {
        case .standard:
            return palette.foregroundColor
        case .originalConcept:
            return Color(red: 0.92, green: 0.78, blue: 0.32)
        }
    }
}

private struct HangarInsuranceBadgePalette {
    let backgroundColor: Color
    let foregroundColor: Color
    let strokeColor: Color
    let shadowColor: Color

    init(colorScheme: ColorScheme) {
        let backgroundUIColor: UIColor
        switch colorScheme {
        case .light:
            backgroundUIColor = UIColor(red: 0.82, green: 0.88, blue: 0.93, alpha: 1)
        case .dark:
            backgroundUIColor = UIColor(red: 0.08, green: 0.20, blue: 0.27, alpha: 1)
        @unknown default:
            backgroundUIColor = UIColor(red: 0.82, green: 0.88, blue: 0.93, alpha: 1)
        }

        backgroundColor = Color(uiColor: backgroundUIColor)
        foregroundColor = backgroundUIColor.prefersDarkContrastText
            ? Color.black.opacity(0.86)
            : Color.white.opacity(0.94)
        strokeColor = backgroundUIColor.prefersDarkContrastText
            ? Color.white.opacity(0.82)
            : Color.white.opacity(0.20)
        shadowColor = Color.black.opacity(backgroundUIColor.prefersDarkContrastText ? 0.10 : 0.18)
    }
}

private struct HangarInsuranceBadgeGlassStyle: ViewModifier {
    let palette: HangarInsuranceBadgePalette
    let style: HangarInsuranceBadge.Style

    func body(content: Content) -> some View {
        content
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundStyle)
                    .shadow(
                        color: shadowColor,
                        radius: style == .originalConcept ? 8 : 3,
                        x: 0,
                        y: style == .originalConcept ? 3 : 1
                    )
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(strokeStyle, lineWidth: style == .originalConcept ? 1 : 0.8)
            }
    }

    private var backgroundStyle: AnyShapeStyle {
        switch style {
        case .standard:
            return AnyShapeStyle(palette.backgroundColor)
        case .originalConcept:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.72),
                        Color.black.opacity(0.46)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var strokeStyle: AnyShapeStyle {
        switch style {
        case .standard:
            return AnyShapeStyle(palette.strokeColor)
        case .originalConcept:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.92, green: 0.78, blue: 0.32).opacity(0.42),
                        Color(red: 0.92, green: 0.78, blue: 0.32).opacity(0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var shadowColor: Color {
        switch style {
        case .standard:
            return palette.shadowColor
        case .originalConcept:
            return Color.black.opacity(0.32)
        }
    }
}

private extension UIColor {
    var prefersDarkContrastText: Bool {
        let components = cgColor.converted(
            to: CGColorSpaceCreateDeviceRGB(),
            intent: .defaultIntent,
            options: nil
        )?.components

        guard let components, components.count >= 3 else {
            return true
        }

        let red = linearizedColorComponent(components[0])
        let green = linearizedColorComponent(components[1])
        let blue = linearizedColorComponent(components[2])
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let blackTextContrast = (luminance + 0.05) / 0.05
        let whiteTextContrast = 1.05 / (luminance + 0.05)
        return blackTextContrast >= whiteTextContrast
    }

    private func linearizedColorComponent(_ value: CGFloat) -> CGFloat {
        if value <= 0.03928 {
            return value / 12.92
        }

        return pow((value + 0.055) / 1.055, 2.4)
    }
}

private struct PriceSummaryView: View {
    let currentValueUSD: Decimal
    let meltValueUSD: Decimal

    private var showsBothValues: Bool {
        currentValueUSD != meltValueUSD
    }

    var body: some View {
        Group {
            if showsBothValues {
                VStack(alignment: .leading, spacing: 1) {
                    Text(meltValueUSD.usdString)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(currentValueUSD.usdString)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .monospacedDigit()
            } else {
                Text(currentValueUSD.usdString)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
    }
}

struct HangarPackageDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DisplayPreferences.sharePictureAutoCopiesDebugLogKey) private var autoCopiesSharePictureDebugLog = DisplayPreferences.sharePictureAutoCopiesDebugLogEnabledByDefault

    private enum PresentedActionSheet: String, Identifiable {
        case melt
        case gift
        case upgrade

        var id: String { rawValue }
    }

    let appModel: AppModel
    let packageGroup: GroupedHangarPackage
    let itemTranslator: HangarItemTranslator
    let reloadToken: UUID?

    @State private var presentedActionSheet: PresentedActionSheet?
    @State private var sharePicturePayload: HangarSharePicturePayload?
    @State private var sharePictureError: HangarSharePictureError?
    @State private var isGeneratingSharePicture = false
    @State private var copiedCouponCode = false

    private var package: HangarPackage {
        packageGroup.representative
    }

    private var hasStoredCredentials: Bool {
        appModel.session?.hasStoredCredentials == true
    }

    private var canUseGiftAction: Bool {
        package.canGift && hasStoredCredentials && !appModel.isRefreshing
    }

    private var canUseUpgradeAction: Bool {
        package.canApplyStoredUpgrade && hasStoredCredentials && !appModel.isRefreshing
    }

    private var canUseReclaimAction: Bool {
        package.canReclaim && hasStoredCredentials && !appModel.isRefreshing
    }

    private var hasAnySupportedLiveAction: Bool {
        package.canGift || package.canApplyStoredUpgrade || package.canReclaim
    }

    private var compositeUpgradePricing: PackageItem.UpgradePricing? {
        guard package.isUpgradeOnlyPledge else {
            return nil
        }

        return package.contents.compactMap(\.upgradePricing).first
    }

    private var couponInfo: HangarCouponInfo? {
        HangarCouponParser.info(from: package.title)
    }

    private var displayTitle: String {
        let title = couponInfo?.cardTitle ?? package.title
        return itemTranslator.translated(title)
    }

    private var displayThumbnailURL: URL? {
        package.packageThumbnailURL
    }

    private var displayedContents: [PackageItem] {
        package.contents.filter {
            HangarPledgeSummaryParser.shouldRenderContentTitle($0.title)
        }
    }

    private var primaryContents: [PackageItem] {
        displayedContents.filter { item in
            item.imageURL != nil || item.upgradePricing != nil
        }
    }

    private var alsoContainsContents: [PackageItem] {
        displayedContents.filter { item in
            item.imageURL == nil && item.upgradePricing == nil
        }
    }

    var body: some View {
        List {
            if let compositeUpgradePricing {
                Section {
                    UpgradeDetailHeaderView(
                        pricing: compositeUpgradePricing,
                        reloadToken: reloadToken
                    )
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            } else if let displayThumbnailURL {
                Section {
                    RemoteThumbnailView(
                        url: displayThumbnailURL,
                        reloadToken: reloadToken,
                        fallbackSystemImage: "shippingbox.fill",
                        size: 180
                    )
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                }
            }

            Section {
                CompactPackageSummaryView(packageGroup: packageGroup)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            } header: {
                Text("Package")
            }

            if let couponInfo {
                Section {
                    CouponDetailView(
                        couponInfo: couponInfo,
                        copiedCouponCode: copiedCouponCode,
                        onCopyCode: copyCouponCode
                    )
                } header: {
                    Text("Coupon")
                }
            }

            if !primaryContents.isEmpty {
                Section {
                    ForEach(primaryContents) { item in
                        PackageItemRow(
                            item: item,
                            itemTranslator: itemTranslator,
                            reloadToken: reloadToken
                        )
                    }
                } header: {
                    Text("Contents")
                }
            }

            if !alsoContainsContents.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(alsoContainsContents) { item in
                            PackageAlsoContainsRow(
                                item: item,
                                itemTranslator: itemTranslator
                            )
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(AppLocalizer.string("Also Contains"))
                }
            }

            Section {
                HStack(spacing: 12) {
                    Button {
                        presentedActionSheet = .gift
                    } label: {
                        HangarActionTile(
                            title: AppLocalizer.string("Gift"),
                            systemImage: "gift.fill",
                            accentColor: .green,
                            isEnabled: canUseGiftAction
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canUseGiftAction)

                    Button {
                        presentedActionSheet = .upgrade
                    } label: {
                        HangarActionTile(
                            title: AppLocalizer.string("Upgrade"),
                            systemImage: "chevron.up.2",
                            accentColor: .blue,
                            isEnabled: canUseUpgradeAction
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canUseUpgradeAction)

                    Button(role: .destructive) {
                        presentedActionSheet = .melt
                    } label: {
                        HangarActionTile(
                            title: AppLocalizer.string("Reclaim"),
                            systemImage: "arrow.3.trianglepath",
                            accentColor: .red,
                            isEnabled: canUseReclaimAction
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canUseReclaimAction)
                }
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                Text("Actions")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if hasAnySupportedLiveAction && !hasStoredCredentials {
                        if appModel.session?.isReadOnly == true {
                            Text("Gift, upgrade, and reclaim are disabled for this read-only account.")
                        } else {
                            Text("Grey actions need a fresh sign-in with saved credentials before Hangar Express can send live RSI requests.")
                        }
                    } else if hasAnySupportedLiveAction {
                        Text("Hangar Express will confirm with Face ID or your iPhone passcode before sending any live RSI action.")
                    } else {
                        Text("This pledge does not currently support gift, upgrade, or reclaim actions through RSI.")
                    }
                }
            }
        }
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await presentSharePicture()
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(isGeneratingSharePicture)
                .accessibilityLabel(Text("Share Picture"))
            }
        }
        .sheet(item: $presentedActionSheet) { actionSheet in
            NavigationStack {
                switch actionSheet {
                case .melt:
                    HangarMeltConfirmationView(
                        appModel: appModel,
                        packageGroup: packageGroup,
                        onCompleted: {
                            presentedActionSheet = nil
                            dismiss()
                        }
                    )
                case .upgrade:
                    HangarUpgradeTargetPickerView(
                        appModel: appModel,
                        packageGroup: packageGroup,
                        reloadToken: reloadToken,
                        completionHandler: HangarActionCompletionHandler {
                            presentedActionSheet = nil
                            dismiss()
                        }
                    )
                case .gift:
                    HangarGiftConfirmationView(
                        appModel: appModel,
                        packageGroup: packageGroup,
                        onCompleted: {
                            presentedActionSheet = nil
                            dismiss()
                        }
                    )
                }
            }
        }
        .sheet(item: $sharePicturePayload) { payload in
            HangarShareSheet(activityItems: [payload.fileURL])
        }
        .alert(item: $sharePictureError) { error in
            Alert(
                title: Text("Share Picture Failed"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .overlay {
            if isGeneratingSharePicture {
                HangarSharePictureProgressOverlay()
            }
        }
    }

    private func presentSharePicture() async {
        guard !isGeneratingSharePicture else {
            return
        }

        isGeneratingSharePicture = true
        defer {
            isGeneratingSharePicture = false
        }

        if autoCopiesSharePictureDebugLog {
            UIPasteboard.general.string = HangarCardDebugExporter.string(
                for: packageGroup,
                showsUpgradedShipInHangar: appModel.showsUpgradedShipInHangar,
                compositeUpgradeThumbnailsEnabled: appModel.compositeUpgradeThumbnailsEnabled
            )
        }

        do {
            let fileURL = try await HangarSharePictureGenerator.makeJPEG(
                for: packageGroup,
                fleet: appModel.snapshot?.fleet ?? [],
                itemTranslator: itemTranslator
            )
            sharePicturePayload = HangarSharePicturePayload(fileURL: fileURL)
        } catch {
            sharePictureError = HangarSharePictureError(message: error.localizedDescription)
        }
    }

    private func copyCouponCode(_ code: String) {
        UIPasteboard.general.string = code
        copiedCouponCode = true

        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                copiedCouponCode = false
            }
        }
    }
}

@MainActor
private final class HangarPackageSearchHaystackCache {
    struct Signature: Equatable {
        let snapshotLastSyncedAt: Date
        let languageRawValue: String
        let dictionaryLocale: String?
        let dictionaryVersion: Int?
        let translationCacheGeneration: Int
        let showsUpgradedShipInHangar: Bool
    }

    private var activeSignature: Signature?
    private var entries: [String: String] = [:]

    func haystack(
        for packageGroup: GroupedHangarPackage,
        signature: Signature,
        itemTranslator: HangarItemTranslator,
        translationService: OnDeviceHangarItemTranslationService
    ) -> String {
        if activeSignature != signature {
            activeSignature = signature
            entries.removeAll(keepingCapacity: true)
        }

        let package = packageGroup.representative
        if let haystack = entries[packageGroup.id] {
            return haystack
        }

        let itemTitleSources = package.contents.flatMap { item -> [String] in
            var titles = [item.title]
            if let pricing = item.upgradePricing {
                titles.append(pricing.sourceShipName)
                titles.append(pricing.targetShipName)
            }
            return titles
        }

        let haystack = [
            translationService.searchableText(for: package.title, using: itemTranslator),
            translationService.searchableText(
                for: package.debugDisplayTitle(showsUpgradedShipInHangar: signature.showsUpgradedShipInHangar),
                using: itemTranslator
            ),
            package.status,
            package.searchableInsuranceText,
            translationService.searchableText(for: itemTitleSources, using: itemTranslator)
        ].joined(separator: " ").localizedLowercase

        entries[packageGroup.id] = haystack
        return haystack
    }
}

private struct HangarSharePicturePayload: Identifiable {
    let id = UUID()
    let fileURL: URL
}

private struct HangarSharePictureError: Identifiable {
    let id = UUID()
    let message: String
}

private struct HangarPhotoSaveNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct HangarShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct HangarSharePictureProgressOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()

            ProgressView("Generating share picture...")
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.regularMaterial)
                )
        }
    }
}

@MainActor
private enum HangarSharePictureGenerator {
    private struct ShareImages {
        let primary: UIImage?
        let source: UIImage?
        let target: UIImage?
        let contentThumbnails: [String: UIImage]
    }

    private struct ShareVisualContentRow {
        let id: String
        let title: String
        let detail: String?
        let imageURL: URL?
        let fallbackSystemImage: String
    }

    private struct ShareContentRow {
        let title: String
        let detail: String?
    }

    private struct ShareContentSections {
        let visualRows: [ShareVisualContentRow]
        let otherRows: [ShareContentRow]

        var isEmpty: Bool {
            visualRows.isEmpty && otherRows.isEmpty
        }
    }

    private enum ShareImageContentMode {
        case fill
        case fit
    }

    private struct ShipValueLookup {
        let valuesByKey: [String: Decimal]

        func valueText(for item: PackageItem, in package: HangarPackage) -> String {
            valuesByKey[Self.key(packageID: package.id, title: item.title)]?.usdString
                ?? AppLocalizer.string("Unavailable")
        }

        static func key(packageID: Int, title: String) -> String {
            "\(packageID)|\(normalizedTitle(title))"
        }

        private static func normalizedTitle(_ title: String) -> String {
            title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedLowercase
        }
    }

    private enum SharePictureError: LocalizedError {
        case encodingFailed

        var errorDescription: String? {
            AppLocalizer.string("Unable to create the share picture.")
        }
    }

    private static let canvasWidth: CGFloat = 1080
    private static let margin: CGFloat = 72
    private static let imageHeight: CGFloat = 520
    private static let upgradeImageHeight: CGFloat = 430
    private static let upgradeHeroHeight: CGFloat = 650
    private static let cornerRadius: CGFloat = 34
    private static let footerTopSpacing: CGFloat = 52
    private static let footerHeight: CGFloat = 58
    private static let footerLogoSize: CGFloat = 42
    private static let visualContentThumbnailSize: CGFloat = 132
    private static let visualContentThumbnailCornerRadius: CGFloat = 24
    private static let visualContentTextGap: CGFloat = 24
    private static let heroImageDisplayScale: CGFloat = 2
    private static let upgradeImageOutwardShift: CGFloat = 0.14

    private static let backgroundColor = UIColor(red: 0.035, green: 0.047, blue: 0.058, alpha: 1)
    private static let surfaceColor = UIColor(red: 0.085, green: 0.105, blue: 0.125, alpha: 1)
    private static let secondarySurfaceColor = UIColor(red: 0.115, green: 0.140, blue: 0.165, alpha: 1)
    private static let primaryTextColor = UIColor.white
    private static let secondaryTextColor = UIColor(white: 0.72, alpha: 1)
    private static let tertiaryTextColor = UIColor(white: 0.58, alpha: 1)
    private static let accentColor = UIColor(red: 0.13, green: 0.63, blue: 1, alpha: 1)
    private static let separatorColor = UIColor.white.withAlphaComponent(0.12)

    static func makeJPEG(
        for packageGroup: GroupedHangarPackage,
        fleet: [FleetShip],
        itemTranslator: HangarItemTranslator
    ) async throws -> URL {
        let package = packageGroup.representative
        let upgradePricing = package.shareUpgradePricing
        let packageTitle = displayText(package.title, using: itemTranslator)
        let contentSections = contentSections(
            for: package,
            shipValues: shipValueLookup(from: fleet),
            itemTranslator: itemTranslator
        )
        let images = await loadImages(
            for: package,
            upgradePricing: upgradePricing,
            visualRows: contentSections.visualRows
        )
        let size = CGSize(
            width: canvasWidth,
            height: measuredHeight(
                package: package,
                packageTitle: packageTitle,
                upgradePricing: upgradePricing,
                contentSections: contentSections
            )
        )
        let image = render(
            package: package,
            packageTitle: packageTitle,
            upgradePricing: upgradePricing,
            contentSections: contentSections,
            images: images,
            size: size,
            itemTranslator: itemTranslator
        )

        guard let data = image.jpegData(compressionQuality: 0.92) else {
            throw SharePictureError.encodingFailed
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeFilename(package.title))-\(UUID().uuidString.prefix(8)).jpg")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func loadImages(
        for package: HangarPackage,
        upgradePricing: PackageItem.UpgradePricing?,
        visualRows: [ShareVisualContentRow]
    ) async -> ShareImages {
        async let contentThumbnails = loadContentThumbnails(for: visualRows)

        if let upgradePricing {
            let upgradeTargetSize = CGSize(
                width: canvasWidth - margin * 2,
                height: upgradeImageHeight
            )
            async let sourceImage = loadImage(
                from: upgradePricing.sourceShipImageURL,
                targetSize: upgradeTargetSize,
                displayScale: heroImageDisplayScale
            )
            async let targetImage = loadImage(
                from: upgradePricing.targetShipImageURL,
                targetSize: upgradeTargetSize,
                displayScale: heroImageDisplayScale
            )
            return await ShareImages(primary: nil, source: sourceImage, target: targetImage, contentThumbnails: contentThumbnails)
        }

        let imageURL = package.packageThumbnailURL ?? package.thumbnailURL
        async let primaryImage = loadImage(
            from: imageURL,
            targetSize: CGSize(width: canvasWidth - margin * 2, height: imageHeight),
            displayScale: heroImageDisplayScale
        )
        return await ShareImages(primary: primaryImage, source: nil, target: nil, contentThumbnails: contentThumbnails)
    }

    private static func loadContentThumbnails(for visualRows: [ShareVisualContentRow]) async -> [String: UIImage] {
        var thumbnails: [String: UIImage] = [:]

        for row in visualRows {
            guard let image = await loadImage(
                from: row.imageURL,
                targetSize: CGSize(width: visualContentThumbnailSize, height: visualContentThumbnailSize)
            ) else {
                continue
            }

            thumbnails[row.id] = image
        }

        return thumbnails
    }

    private static func loadImage(
        from url: URL?,
        targetSize: CGSize,
        displayScale: CGFloat = 1
    ) async -> UIImage? {
        guard let url else {
            return nil
        }

        return try? await URLCachedImageStore.shared.image(
            for: url,
            targetPointSize: targetSize,
            displayScale: displayScale,
            maxRetries: 2
        )
    }

    private static func shipValueLookup(from fleet: [FleetShip]) -> ShipValueLookup {
        let valuesByKey = fleet.reduce(into: [String: Decimal]()) { partialResult, ship in
            guard let msrpUSD = ship.msrpUSD else {
                return
            }

            partialResult[ShipValueLookup.key(packageID: ship.sourcePackageID, title: ship.displayName)] = msrpUSD
        }

        return ShipValueLookup(valuesByKey: valuesByKey)
    }

    private static func contentSections(
        for package: HangarPackage,
        shipValues: ShipValueLookup,
        itemTranslator: HangarItemTranslator
    ) -> ShareContentSections {
        let visibleItems = package.contents
            .filter { HangarPledgeSummaryParser.shouldRenderContentTitle($0.title) }

        let visualRows = visibleItems
            .filter(isVisualContentItem)
            .map { item in
                ShareVisualContentRow(
                    id: item.id,
                    title: displayText(item.title, using: itemTranslator),
                    detail: visualDetail(
                        for: item,
                        package: package,
                        shipValues: shipValues,
                        itemTranslator: itemTranslator
                    ),
                    imageURL: item.imageURL,
                    fallbackSystemImage: item.isShipLike ? "airplane" : "paintpalette.fill"
                )
            }

        let insuranceRows = insuranceRows(for: package, visibleItems: visibleItems)
        guard !package.isUpgradeOnlyPledge else {
            return ShareContentSections(
                visualRows: visualRows,
                otherRows: insuranceRows
            )
        }

        let otherRows = visibleItems
            .filter { !isVisualContentItem($0) && !isInsuranceItem($0) }
            .map { plainContentRow(for: $0, itemTranslator: itemTranslator) }

        return ShareContentSections(
            visualRows: visualRows,
            otherRows: insuranceRows + otherRows
        )
    }

    nonisolated private static func isVisualContentItem(_ item: PackageItem) -> Bool {
        item.isShipLike || isPaintItem(item)
    }

    nonisolated private static func isPaintItem(_ item: PackageItem) -> Bool {
        let haystack = [item.title, item.detail, item.category.rawValue]
            .joined(separator: " ")
            .localizedLowercase

        return haystack.contains("paint")
            || haystack.contains("skin")
            || haystack.contains("livery")
            || haystack.contains("camo")
    }

    nonisolated private static func isInsuranceItem(_ item: PackageItem) -> Bool {
        isInsuranceLabelCandidate(item.title) || isInsuranceLabelCandidate(item.detail)
    }

    nonisolated private static func isInsuranceLabelCandidate(_ value: String) -> Bool {
        let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !lowercased.isEmpty else {
            return false
        }

        return lowercased.contains("insurance")
            || HangarPackage.containsLifetimeInsuranceToken(lowercased)
            || lowercased.range(of: #"\d+\s*(month|months|mo|year|years|yr)\b"#, options: .regularExpression) != nil
    }

    private static func visualDetail(
        for item: PackageItem,
        package: HangarPackage,
        shipValues: ShipValueLookup,
        itemTranslator: HangarItemTranslator
    ) -> String? {
        if item.isShipLike {
            return shipValues.valueText(for: item, in: package)
        }

        let detailParts = [
            displayText(AppLocalizer.string(item.category.rawValue), using: itemTranslator),
            cleanedDetail(item.detail).map { displayText($0, using: itemTranslator) }
        ].compactMap { $0 }

        return detailParts.isEmpty ? nil : detailParts.joined(separator: " - ")
    }

    private static func insuranceRows(
        for package: HangarPackage,
        visibleItems: [PackageItem]
    ) -> [ShareContentRow] {
        var rawValues = package.insuranceOptions ?? []
        rawValues.append(package.insurance)

        for item in visibleItems where isInsuranceItem(item) {
            rawValues.append(item.title)

            if isInsuranceLabelCandidate(item.detail) {
                rawValues.append(item.detail)
            }
        }

        var seen = Set<String>()
        return HangarPackage.normalizedInsuranceLevels(rawValues).compactMap { value in
            let displayLabel = HangarPackage.localizedInsuranceDisplayLabel(from: value)
            let trimmedLabel = displayLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercasedLabel = trimmedLabel.localizedLowercase

            guard !trimmedLabel.isEmpty,
                  !HangarPackage.isUnknownInsuranceLabel(trimmedLabel),
                  lowercasedLabel != "insurance",
                  lowercasedLabel != "rsi pledge entitlement",
                  seen.insert(lowercasedLabel).inserted else {
                return nil
            }

            return ShareContentRow(
                title: trimmedLabel,
                detail: AppLocalizer.string("Insurance")
            )
        }
    }

    private static func plainContentRow(
        for item: PackageItem,
        itemTranslator: HangarItemTranslator
    ) -> ShareContentRow {
        let detailParts = [
            displayText(AppLocalizer.string(item.category.rawValue), using: itemTranslator),
            cleanedDetail(item.detail).map { displayText($0, using: itemTranslator) }
        ].compactMap { $0 }

        return ShareContentRow(
            title: displayText(item.title, using: itemTranslator),
            detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " - ")
        )
    }

    private static func measuredHeight(
        package: HangarPackage,
        packageTitle: String,
        upgradePricing: PackageItem.UpgradePricing?,
        contentSections: ShareContentSections
    ) -> CGFloat {
        let textWidth = canvasWidth - margin * 2
        var height = margin
        height += measuredTextHeight(packageTitle, font: titleFont, width: textWidth)
        height += 34

        if upgradePricing != nil {
            height += upgradeHeroHeight
            height += 34
        } else {
            height += imageHeight
            height += 34
            height += priceBlockHeight(for: package)
        }

        if !contentSections.isEmpty {
            height += 44
            height += measuredContentSectionsHeight(contentSections, textWidth: textWidth)
        }

        height += footerTopSpacing
        height += footerHeight
        height += margin
        return ceil(height)
    }

    private static func render(
        package: HangarPackage,
        packageTitle: String,
        upgradePricing: PackageItem.UpgradePricing?,
        contentSections: ShareContentSections,
        images: ShareImages,
        size: CGSize,
        itemTranslator: HangarItemTranslator
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cgContext = context.cgContext
            backgroundColor.setFill()
            cgContext.fill(CGRect(origin: .zero, size: size))

            var y = margin
            y += drawText(
                packageTitle,
                in: CGRect(x: margin, y: y, width: canvasWidth - margin * 2, height: 240),
                font: titleFont,
                color: primaryTextColor
            )
            y += 34

            if let upgradePricing {
                let heroRect = CGRect(x: margin, y: y, width: canvasWidth - margin * 2, height: upgradeHeroHeight)
                drawUpgradeHero(
                    in: heroRect,
                    package: package,
                    pricing: upgradePricing,
                    images: images,
                    context: cgContext,
                    itemTranslator: itemTranslator
                )
                y += upgradeHeroHeight + 34
            } else {
                let imageRect = CGRect(x: margin, y: y, width: canvasWidth - margin * 2, height: imageHeight)
                drawImageSection(
                    in: imageRect,
                    images: images,
                    context: cgContext
                )
                y += imageHeight + 34

                y += drawPriceBlock(for: package, at: y, context: cgContext)
            }

            if !contentSections.isEmpty {
                y += 44
                y += drawContentSections(contentSections, images: images, at: y, context: cgContext)
            }

            y += footerTopSpacing
            drawWatermark(at: y, language: itemTranslator.language)
        }
    }

    private static func measuredContentSectionsHeight(
        _ sections: ShareContentSections,
        textWidth: CGFloat
    ) -> CGFloat {
        var height: CGFloat = 0

        if !sections.visualRows.isEmpty {
            height += measuredContentSectionHeaderHeight(AppLocalizer.string("Items"), textWidth: textWidth)
            for row in sections.visualRows {
                height += measuredVisualContentRowHeight(row, textWidth: textWidth)
            }
        }

        if !sections.otherRows.isEmpty {
            if height > 0 {
                height += 44
            }

            height += measuredContentSectionHeaderHeight(AppLocalizer.string("Other Items"), textWidth: textWidth)
            for row in sections.otherRows {
                height += measuredPlainContentRowHeight(row, textWidth: textWidth)
            }
        }

        if sections.isEmpty {
            height += measuredContentSectionHeaderHeight(AppLocalizer.string("Items"), textWidth: textWidth)
            height += measuredTextHeight(AppLocalizer.string("No listed contents"), font: rowDetailFont, width: textWidth)
        }

        return height
    }

    private static func measuredContentSectionHeaderHeight(_ title: String, textWidth: CGFloat) -> CGFloat {
        measuredTextHeight(title, font: sectionHeaderFont, width: textWidth) + 20
    }

    private static func measuredVisualContentRowHeight(
        _ row: ShareVisualContentRow,
        textWidth: CGFloat
    ) -> CGFloat {
        let contentTextWidth = textWidth - visualContentThumbnailSize - visualContentTextGap
        var textHeight = measuredTextHeight(row.title, font: rowTitleFont, width: contentTextWidth)

        if let detail = row.detail {
            textHeight += 6 + measuredTextHeight(detail, font: rowDetailFont, width: contentTextWidth)
        }

        return max(visualContentThumbnailSize, textHeight + 10) + 28
    }

    private static func measuredPlainContentRowHeight(
        _ row: ShareContentRow,
        textWidth: CGFloat
    ) -> CGFloat {
        var textHeight = measuredTextHeight(row.title, font: rowTitleFont, width: textWidth - 34)

        if let detail = row.detail {
            textHeight += 6 + measuredTextHeight(detail, font: rowDetailFont, width: textWidth - 34)
        }

        return textHeight + 24
    }

    private static func drawContentSections(
        _ sections: ShareContentSections,
        images: ShareImages,
        at y: CGFloat,
        context: CGContext
    ) -> CGFloat {
        let textWidth = canvasWidth - margin * 2
        var currentY = y
        var hasRenderedSection = false

        if !sections.visualRows.isEmpty {
            currentY += drawContentSectionHeader(AppLocalizer.string("Items"), at: currentY)
            for row in sections.visualRows {
                currentY += drawVisualContentRow(row, image: images.contentThumbnails[row.id], at: currentY, context: context)
            }
            hasRenderedSection = true
        }

        if !sections.otherRows.isEmpty {
            if hasRenderedSection {
                currentY += 44
            }

            currentY += drawContentSectionHeader(AppLocalizer.string("Other Items"), at: currentY)
            for row in sections.otherRows {
                currentY += drawContentRow(row, at: currentY, context: context)
            }
            hasRenderedSection = true
        }

        if !hasRenderedSection {
            currentY += drawContentSectionHeader(AppLocalizer.string("Items"), at: currentY)
            currentY += drawText(
                AppLocalizer.string("No listed contents"),
                in: CGRect(x: margin, y: currentY, width: textWidth, height: 60),
                font: rowDetailFont,
                color: secondaryTextColor
            )
        }

        return currentY - y
    }

    private static func drawContentSectionHeader(_ title: String, at y: CGFloat) -> CGFloat {
        let height = drawText(
            title,
            in: CGRect(x: margin, y: y, width: canvasWidth - margin * 2, height: 52),
            font: sectionHeaderFont,
            color: primaryTextColor
        )
        return height + 20
    }

    private static func drawImageSection(
        in rect: CGRect,
        images: ShareImages,
        context: CGContext
    ) {
        drawImageOrFallback(
            images.primary,
            in: rect,
            fallbackSystemImage: "shippingbox.fill",
            contentMode: .fit,
            context: context
        )
    }

    private static func drawUpgradeHero(
        in rect: CGRect,
        package: HangarPackage,
        pricing: PackageItem.UpgradePricing,
        images: ShareImages,
        context: CGContext,
        itemTranslator: HangarItemTranslator
    ) {
        let imageRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: upgradeImageHeight)
        drawUpgradeStepFourBothMasksPanel(
            sourceImage: images.source,
            targetImage: images.target,
            in: imageRect,
            context: context
        )

        drawUpgradeCenterSummary(
            package: package,
            pricing: pricing,
            in: imageRect,
            context: context
        )

        let captionGap: CGFloat = 44
        let captionY = imageRect.maxY + 22
        let columnWidth = (rect.width - captionGap) / 2
        let sourceCaptionRect = CGRect(
            x: rect.minX,
            y: captionY,
            width: columnWidth,
            height: rect.maxY - captionY
        )
        let targetCaptionRect = CGRect(
            x: sourceCaptionRect.maxX + captionGap,
            y: captionY,
            width: columnWidth,
            height: rect.maxY - captionY
        )
        drawUpgradeShipCaption(
            title: displayText(pricing.sourceShipName, using: itemTranslator),
            label: AppLocalizer.string("From"),
            msrp: pricing.sourceShipMSRPUSD,
            in: sourceCaptionRect,
            alignment: .left
        )
        drawUpgradeShipCaption(
            title: displayText(pricing.targetShipName, using: itemTranslator),
            label: AppLocalizer.string("To"),
            msrp: pricing.targetShipMSRPUSD,
            in: targetCaptionRect,
            alignment: .right
        )
    }

    private static func drawUpgradeShipCaption(
        title: String,
        label: String,
        msrp: Decimal?,
        in rect: CGRect,
        alignment: NSTextAlignment
    ) {
        _ = drawText(
            label.uppercased(),
            in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 30),
            font: upgradeCaptionLabelFont,
            color: tertiaryTextColor,
            alignment: alignment
        )
        let titleY = rect.minY + 32
        let titleLimit: CGFloat = 108
        let titleHeight = drawText(
            title,
            in: CGRect(x: rect.minX, y: titleY, width: rect.width, height: titleLimit),
            font: upgradeShipNameFont,
            color: primaryTextColor,
            alignment: alignment
        )
        _ = drawText(
            msrp?.usdString ?? AppLocalizer.string("Unavailable"),
            in: CGRect(x: rect.minX, y: titleY + min(titleHeight, titleLimit), width: rect.width, height: 50),
            font: upgradeShipPriceFont,
            color: secondaryTextColor,
            alignment: alignment
        )
    }

    private static func drawUpgradeStepFourBothMasksPanel(
        sourceImage: UIImage?,
        targetImage: UIImage?,
        in rect: CGRect,
        context: CGContext
    ) {
        let panelPath = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
        let topSplitX = rect.midX - 72
        let bottomSplitX = rect.midX + 78
        let sourceClipPath = UIBezierPath()
        sourceClipPath.move(to: CGPoint(x: rect.minX, y: rect.minY))
        sourceClipPath.addLine(to: CGPoint(x: topSplitX, y: rect.minY))
        sourceClipPath.addLine(to: CGPoint(x: bottomSplitX, y: rect.maxY))
        sourceClipPath.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        sourceClipPath.close()

        let targetClipPath = UIBezierPath()
        targetClipPath.move(to: CGPoint(x: topSplitX, y: rect.minY))
        targetClipPath.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        targetClipPath.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        targetClipPath.addLine(to: CGPoint(x: bottomSplitX, y: rect.maxY))
        targetClipPath.close()

        let sourceLayer = renderUpgradeImageLayer(
            sourceImage,
            fallbackSystemImage: "arrow.uturn.backward.circle.fill",
            size: rect.size,
            horizontalAlignment: 0,
            outwardShift: upgradeImageOutwardShift
        )
        let targetLayer = renderUpgradeImageLayer(
            targetImage,
            fallbackSystemImage: "arrow.up.right.circle.fill",
            size: rect.size,
            horizontalAlignment: 1,
            outwardShift: upgradeImageOutwardShift
        )

        context.saveGState()
        panelPath.addClip()
        surfaceColor.setFill()
        UIRectFill(rect)
        drawUpgradeImageLayer(
            sourceLayer,
            clipPath: sourceClipPath,
            in: rect
        )
        drawUpgradeImageLayer(
            targetLayer,
            clipPath: targetClipPath,
            in: rect
        )
        context.restoreGState()

        let splitLine = UIBezierPath()
        splitLine.move(to: CGPoint(x: topSplitX, y: rect.minY))
        splitLine.addLine(to: CGPoint(x: bottomSplitX, y: rect.maxY))
        UIColor.white.withAlphaComponent(0.26).setStroke()
        splitLine.lineWidth = 3
        splitLine.stroke()

        separatorColor.setStroke()
        panelPath.lineWidth = 1
        panelPath.stroke()
    }

    private static func drawDiagonalUpgradeImagePanel(
        sourceImage: UIImage?,
        targetImage: UIImage?,
        in rect: CGRect,
        context: CGContext
    ) {
        let panelPath = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
        let topSplitX = rect.midX - 72
        let bottomSplitX = rect.midX + 78
        let sourceClipPath = UIBezierPath()
        sourceClipPath.move(to: CGPoint(x: rect.minX, y: rect.minY))
        sourceClipPath.addLine(to: CGPoint(x: topSplitX, y: rect.minY))
        sourceClipPath.addLine(to: CGPoint(x: bottomSplitX, y: rect.maxY))
        sourceClipPath.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        sourceClipPath.close()

        let targetClipPath = UIBezierPath()
        targetClipPath.move(to: CGPoint(x: topSplitX, y: rect.minY))
        targetClipPath.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        targetClipPath.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        targetClipPath.addLine(to: CGPoint(x: bottomSplitX, y: rect.maxY))
        targetClipPath.close()

        context.saveGState()
        panelPath.addClip()
        surfaceColor.setFill()
        UIRectFill(rect)

        let sourceLayer = renderUpgradeImageLayer(
            sourceImage,
            fallbackSystemImage: "arrow.uturn.backward.circle.fill",
            size: rect.size,
            horizontalAlignment: 0,
            outwardShift: upgradeImageOutwardShift
        )
        let targetLayer = renderUpgradeImageLayer(
            targetImage,
            fallbackSystemImage: "arrow.up.right.circle.fill",
            size: rect.size,
            horizontalAlignment: 1,
            outwardShift: upgradeImageOutwardShift
        )

        drawUpgradeImageLayer(
            sourceLayer,
            clipPath: sourceClipPath,
            in: rect
        )
        drawUpgradeImageLayer(
            targetLayer,
            clipPath: targetClipPath,
            in: rect
        )

        UIColor.black.withAlphaComponent(0.18).setFill()
        UIRectFill(rect)

        let splitLine = UIBezierPath()
        splitLine.move(to: CGPoint(x: topSplitX, y: rect.minY))
        splitLine.addLine(to: CGPoint(x: bottomSplitX, y: rect.maxY))
        UIColor.white.withAlphaComponent(0.26).setStroke()
        splitLine.lineWidth = 3
        splitLine.stroke()
        context.restoreGState()

        separatorColor.setStroke()
        panelPath.lineWidth = 1
        panelPath.stroke()
    }

    private static func renderUpgradeImageLayer(
        _ image: UIImage?,
        fallbackSystemImage: String,
        size: CGSize,
        horizontalAlignment: CGFloat,
        outwardShift: CGFloat
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: size)
            context.cgContext.clear(bounds)

            if let image {
                drawImage(
                    image,
                    fitting: bounds,
                    horizontalAlignment: horizontalAlignment,
                    outwardShift: outwardShift
                )
            } else {
                drawFallback(in: bounds, systemImage: fallbackSystemImage)
            }
        }
    }

    private static func drawUpgradeImageLayer(
        _ image: UIImage,
        clipPath: UIBezierPath,
        in rect: CGRect
    ) {
        guard let context = UIGraphicsGetCurrentContext() else {
            image.draw(in: rect)
            return
        }

        context.saveGState()
        clipPath.addClip()
        image.draw(in: rect)
        context.restoreGState()
    }

    private static func drawUpgradeCenterSummary(
        package: HangarPackage,
        pricing: PackageItem.UpgradePricing,
        in rect: CGRect,
        context: CGContext
    ) {
        let deltaRect = CGRect(x: rect.midX - 118, y: rect.midY - 78, width: 236, height: 156)
        let deltaPath = UIBezierPath(roundedRect: deltaRect, cornerRadius: 28)

        context.saveGState()
        context.setShadow(
            offset: .zero,
            blur: 34,
            color: UIColor.black.withAlphaComponent(0.48).cgColor
        )
        secondarySurfaceColor.setFill()
        deltaPath.fill()
        context.restoreGState()

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 14),
            blur: 26,
            color: UIColor.black.withAlphaComponent(0.42).cgColor
        )
        secondarySurfaceColor.setFill()
        deltaPath.fill()
        context.restoreGState()

        secondarySurfaceColor.setFill()
        deltaPath.fill()
        UIColor.white.withAlphaComponent(0.08).setStroke()
        deltaPath.lineWidth = 1
        deltaPath.stroke()

        _ = drawText(
            upgradeDifferenceText(for: pricing, fallbackPackage: package),
            in: CGRect(x: deltaRect.minX + 18, y: deltaRect.minY + 38, width: deltaRect.width - 36, height: 42),
            font: upgradeDifferenceFont,
            color: primaryTextColor,
            alignment: .center
        )

        _ = drawText(
            "\(AppLocalizer.string("Melt")) \(package.originalValueUSD.usdString)",
            in: CGRect(x: deltaRect.minX + 18, y: deltaRect.minY + 92, width: deltaRect.width - 36, height: 34),
            font: upgradePriceNoteFont,
            color: secondaryTextColor,
            alignment: .center
        )
    }

    private static func drawImageOrFallback(
        _ image: UIImage?,
        in rect: CGRect,
        fallbackSystemImage: String,
        contentMode: ShareImageContentMode = .fill,
        context: CGContext
    ) {
        if let image, contentMode == .fit, let fittedRect = aspectFitRect(for: image, in: rect) {
            let fittedCornerRadius = min(cornerRadius, min(fittedRect.width, fittedRect.height) / 2)
            let fittedPath = UIBezierPath(roundedRect: fittedRect, cornerRadius: fittedCornerRadius)

            context.saveGState()
            fittedPath.addClip()
            image.draw(in: fittedRect)
            context.restoreGState()

            separatorColor.setStroke()
            fittedPath.stroke()
            return
        }

        context.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).addClip()

        if let image {
            drawImage(image, filling: rect)
        } else {
            drawFallback(in: rect, systemImage: fallbackSystemImage)
        }

        context.restoreGState()
        separatorColor.setStroke()
        UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).stroke()
    }

    private static func aspectFitRect(for image: UIImage, in rect: CGRect) -> CGRect? {
        guard image.size.width > 0, image.size.height > 0 else {
            return nil
        }

        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
    }

    private static func drawImage(_ image: UIImage, filling rect: CGRect) {
        drawImage(image, filling: rect, horizontalBias: 0.5)
    }

    private static func drawImage(
        _ image: UIImage,
        fitting rect: CGRect,
        horizontalAlignment: CGFloat,
        outwardShift: CGFloat = 0
    ) {
        guard image.size.width > 0, image.size.height > 0 else {
            drawFallback(in: rect, systemImage: "shippingbox.fill")
            return
        }

        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let clampedHorizontalAlignment = min(max(horizontalAlignment, 0), 1)
        let outwardDirection: CGFloat = clampedHorizontalAlignment < 0.5 ? -1 : 1
        let blankX = max(0, rect.width - drawSize.width)
        let blankY = max(0, rect.height - drawSize.height)
        let drawRect = CGRect(
            x: rect.minX + blankX * clampedHorizontalAlignment + rect.width * outwardShift * outwardDirection,
            y: rect.minY + blankY / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(in: drawRect)
    }

    private static func drawImage(_ image: UIImage, filling rect: CGRect, horizontalBias: CGFloat) {
        guard image.size.width > 0, image.size.height > 0 else {
            drawFallback(in: rect, systemImage: "shippingbox.fill")
            return
        }

        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let clampedHorizontalBias = min(max(horizontalBias, 0), 1)
        let overflowX = max(0, drawSize.width - rect.width)
        let overflowY = max(0, drawSize.height - rect.height)
        let drawRect = CGRect(
            x: rect.minX - overflowX * clampedHorizontalBias,
            y: rect.minY - overflowY / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(in: drawRect)
    }

    private static func drawFallback(in rect: CGRect, systemImage: String) {
        let colors = [
            UIColor(red: 0.08, green: 0.16, blue: 0.22, alpha: 1).cgColor,
            UIColor(red: 0.04, green: 0.08, blue: 0.12, alpha: 1).cgColor
        ] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
        if let gradient, let context = UIGraphicsGetCurrentContext() {
            context.drawLinearGradient(gradient, start: rect.origin, end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        }

        let configuration = UIImage.SymbolConfiguration(pointSize: 96, weight: .semibold)
        let symbol = UIImage(systemName: systemImage, withConfiguration: configuration)?
            .withTintColor(UIColor.white.withAlphaComponent(0.72), renderingMode: .alwaysOriginal)
        let symbolSize = symbol?.size ?? CGSize(width: 96, height: 96)
        let symbolRect = CGRect(
            x: rect.midX - symbolSize.width / 2,
            y: rect.midY - symbolSize.height / 2,
            width: symbolSize.width,
            height: symbolSize.height
        )
        symbol?.draw(in: symbolRect)
    }

    private static func drawArrow(in rect: CGRect) {
        let configuration = UIImage.SymbolConfiguration(pointSize: 58, weight: .bold)
        let symbol = UIImage(systemName: "arrow.right", withConfiguration: configuration)?
            .withTintColor(accentColor, renderingMode: .alwaysOriginal)
        symbol?.draw(in: rect)
    }

    private static func drawPriceBlock(for package: HangarPackage, at y: CGFloat, context: CGContext) -> CGFloat {
        let rect = CGRect(x: margin, y: y, width: canvasWidth - margin * 2, height: priceBlockHeight(for: package))
        fillRoundedRect(rect, color: surfaceColor, cornerRadius: cornerRadius)

        _ = drawText(
            AppLocalizer.string("Price"),
            in: CGRect(x: rect.minX + 34, y: rect.minY + 26, width: rect.width - 68, height: 40),
            font: eyebrowFont,
            color: secondaryTextColor
        )

        if package.originalValueUSD == package.currentValueUSD {
            _ = drawText(
                package.currentValueUSD.usdString,
                in: CGRect(x: rect.minX + 34, y: rect.minY + 70, width: rect.width - 68, height: 72),
                font: priceFont,
                color: primaryTextColor
            )
        } else {
            let columnWidth = (rect.width - 90) / 2
            drawPriceColumn(
                label: AppLocalizer.string("Melt Value"),
                value: package.originalValueUSD.usdString,
                rect: CGRect(x: rect.minX + 34, y: rect.minY + 72, width: columnWidth, height: 80)
            )
            drawPriceColumn(
                label: AppLocalizer.string("Current Value"),
                value: package.currentValueUSD.usdString,
                rect: CGRect(x: rect.minX + 56 + columnWidth, y: rect.minY + 72, width: columnWidth, height: 80)
            )
        }

        return rect.height + 24
    }

    private static func drawPriceColumn(label: String, value: String, rect: CGRect) {
        _ = drawText(label, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 26), font: smallLabelFont, color: tertiaryTextColor)
        _ = drawText(value, in: CGRect(x: rect.minX, y: rect.minY + 28, width: rect.width, height: 58), font: priceColumnFont, color: primaryTextColor)
    }

    private static func drawVisualContentRow(
        _ row: ShareVisualContentRow,
        image: UIImage?,
        at y: CGFloat,
        context: CGContext
    ) -> CGFloat {
        let textX = margin + visualContentThumbnailSize + visualContentTextGap
        let textWidth = canvasWidth - margin * 2 - visualContentThumbnailSize - visualContentTextGap
        let thumbnailRect = CGRect(
            x: margin,
            y: y,
            width: visualContentThumbnailSize,
            height: visualContentThumbnailSize
        )

        drawContentThumbnail(
            image,
            in: thumbnailRect,
            fallbackSystemImage: row.fallbackSystemImage,
            context: context
        )

        var consumed = drawText(
            row.title,
            in: CGRect(x: textX, y: y + 10, width: textWidth, height: 92),
            font: rowTitleFont,
            color: primaryTextColor
        )

        if let detail = row.detail {
            consumed += 6
            consumed += drawText(
                detail,
                in: CGRect(x: textX, y: y + 10 + consumed, width: textWidth, height: 54),
                font: rowDetailFont,
                color: secondaryTextColor
            )
        }

        let rowHeight = max(visualContentThumbnailSize, consumed + 10) + 28
        separatorColor.setFill()
        UIBezierPath(
            rect: CGRect(x: textX, y: y + rowHeight - 1, width: textWidth, height: 1)
        ).fill()
        return rowHeight
    }

    private static func drawContentThumbnail(
        _ image: UIImage?,
        in rect: CGRect,
        fallbackSystemImage: String,
        context: CGContext
    ) {
        context.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: visualContentThumbnailCornerRadius).addClip()

        if let image {
            drawImage(image, filling: rect)
        } else {
            drawFallback(in: rect, systemImage: fallbackSystemImage)
        }

        context.restoreGState()
        separatorColor.setStroke()
        UIBezierPath(roundedRect: rect, cornerRadius: visualContentThumbnailCornerRadius).stroke()
    }

    private static func drawContentRow(
        _ row: ShareContentRow,
        at y: CGFloat,
        context: CGContext
    ) -> CGFloat {
        let textX = margin + 34
        let textWidth = canvasWidth - margin * 2 - 34
        let dotRect = CGRect(x: margin + 2, y: y + 13, width: 10, height: 10)
        accentColor.setFill()
        UIBezierPath(ovalIn: dotRect).fill()

        var consumed = drawText(
            row.title,
            in: CGRect(x: textX, y: y, width: textWidth, height: 140),
            font: rowTitleFont,
            color: primaryTextColor
        )

        if let detail = row.detail {
            consumed += 6
            consumed += drawText(
                detail,
                in: CGRect(x: textX, y: y + consumed, width: textWidth, height: 96),
                font: rowDetailFont,
                color: secondaryTextColor
            )
        }

        let rowHeight = consumed + 24
        separatorColor.setFill()
        let separatorY = y + rowHeight - 1
        UIBezierPath(
            rect: CGRect(x: textX, y: separatorY, width: textWidth, height: 1)
        ).fill()
        return rowHeight
    }

    private static func drawWatermark(at y: CGFloat, language: HangarItemLanguage) {
        let leadingText: String
        let brandText: String
        let trailingText: String?

        switch language {
        case .original:
            leadingText = AppLocalizer.string("Powered By")
            brandText = "Hangar Express"
            trailingText = nil
        case .simplifiedChinese:
            leadingText = "由"
            brandText = "机库通"
            trailingText = "生成"
        }

        let textHeight = measuredTextHeight(brandText, font: watermarkFont, width: canvasWidth)
        let leadingWidth = measuredTextWidth(leadingText, font: watermarkFont)
        let brandWidth = measuredTextWidth(brandText, font: watermarkBrandFont)
        let trailingWidth = trailingText.map { measuredTextWidth($0, font: watermarkFont) } ?? 0
        let gap: CGFloat = 12
        let trailingGap = trailingText == nil ? 0 : gap
        let totalWidth = leadingWidth + gap + footerLogoSize + gap + brandWidth + trailingGap + trailingWidth
        var x = (canvasWidth - totalWidth) / 2
        let textY = y + (footerHeight - textHeight) / 2
        let logoY = y + (footerHeight - footerLogoSize) / 2

        _ = drawText(
            leadingText,
            in: CGRect(x: x, y: textY, width: leadingWidth + 2, height: textHeight + 4),
            font: watermarkFont,
            color: tertiaryTextColor
        )
        x += leadingWidth + gap

        drawBrandLogo(in: CGRect(x: x, y: logoY, width: footerLogoSize, height: footerLogoSize))
        x += footerLogoSize + gap

        _ = drawText(
            brandText,
            in: CGRect(x: x, y: textY, width: brandWidth + 2, height: textHeight + 4),
            font: watermarkBrandFont,
            color: secondaryTextColor
        )

        if let trailingText {
            x += brandWidth + gap

            _ = drawText(
                trailingText,
                in: CGRect(x: x, y: textY, width: trailingWidth + 2, height: textHeight + 4),
                font: watermarkFont,
                color: tertiaryTextColor
            )
        }
    }

    private static func displayText(
        _ source: String,
        using itemTranslator: HangarItemTranslator
    ) -> String {
        OnDeviceHangarItemTranslationService.shared.displayText(
            for: source,
            using: itemTranslator
        )
    }

    private static func drawBrandLogo(in rect: CGRect) {
        if let image = appIconImage() {
            drawRoundedAppIcon(image, in: rect)
            return
        }

        accentColor.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: rect.width * 0.25).fill()
    }

    private static func appIconImage() -> UIImage? {
        let iconFiles = ((Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconFiles"] as? [String]

        if let image = iconFiles?.reversed().lazy.compactMap({ UIImage(named: $0) }).first {
            return image
        }

        return UIImage(named: "AppIcon") ?? UIImage(named: "Logo") ?? UIImage(named: "BrandMark")
    }

    private static func drawRoundedAppIcon(_ image: UIImage, in rect: CGRect) {
        let iconRect = rect.insetBy(dx: 1, dy: 1)
        let iconCornerRadius = iconRect.width * 0.2237
        let path = UIBezierPath(roundedRect: iconRect, cornerRadius: iconCornerRadius)

        if let context = UIGraphicsGetCurrentContext() {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 2), blur: 5, color: UIColor.black.withAlphaComponent(0.28).cgColor)
            UIColor.black.withAlphaComponent(0.08).setFill()
            path.fill()
            context.restoreGState()
        }

        if let context = UIGraphicsGetCurrentContext() {
            context.saveGState()
            path.addClip()
            drawImage(image, filling: iconRect)
            context.restoreGState()
        }

        UIColor.white.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private static func fillRoundedRect(_ rect: CGRect, color: UIColor, cornerRadius: CGFloat) {
        color.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).fill()
    }

    @discardableResult
    private static func drawText(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment = .left
    ) -> CGFloat {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = 2
        paragraphStyle.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        let height = measuredTextHeight(text, font: font, width: rect.width)
        NSString(string: text).draw(
            with: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(rect.height, height)),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        return height
    }

    private static func measuredTextHeight(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        let bounds = NSString(string: text).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        return ceil(bounds.height)
    }

    private static func measuredTextWidth(_ text: String, font: UIFont) -> CGFloat {
        ceil(NSString(string: text).size(withAttributes: [.font: font]).width)
    }

    private static func priceBlockHeight(for package: HangarPackage) -> CGFloat {
        package.originalValueUSD == package.currentValueUSD ? 162 : 178
    }

    private static func upgradeDifferenceText(
        for pricing: PackageItem.UpgradePricing,
        fallbackPackage package: HangarPackage
    ) -> String {
        if let sourceValue = pricing.sourceShipMSRPUSD,
           let targetValue = pricing.targetShipMSRPUSD {
            return differenceCurrency(targetValue - sourceValue)
        }

        if let actualValue = pricing.actualValueUSD {
            return differenceCurrency(actualValue)
        }

        return differenceCurrency(package.currentValueUSD)
    }

    private static func differenceCurrency(_ value: Decimal) -> String {
        value.usdString
    }

    private static func cleanedDetail(_ detail: String) -> String? {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.localizedCaseInsensitiveCompare("Unknown") != .orderedSame,
              trimmed.localizedCaseInsensitiveCompare("RSI pledge entitlement") != .orderedSame else {
            return nil
        }

        return trimmed
    }

    private static func safeFilename(_ value: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = value.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? String(scalar) : "-"
        }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return sanitized.isEmpty ? "Hangar-Express-Pledge" : String(sanitized.prefix(80))
    }

    private static let titleFont = UIFont.systemFont(ofSize: 54, weight: .bold)
    private static let sectionHeaderFont = UIFont.systemFont(ofSize: 36, weight: .bold)
    private static let eyebrowFont = UIFont.systemFont(ofSize: 22, weight: .bold)
    private static let smallLabelFont = UIFont.systemFont(ofSize: 24, weight: .semibold)
    private static let priceFont = UIFont.monospacedDigitSystemFont(ofSize: 62, weight: .bold)
    private static let priceColumnFont = UIFont.monospacedDigitSystemFont(ofSize: 48, weight: .bold)
    private static let upgradeCaptionLabelFont = UIFont.systemFont(ofSize: 23, weight: .bold)
    private static let upgradeShipNameFont = UIFont.systemFont(ofSize: 38, weight: .semibold)
    private static let upgradeShipPriceFont = UIFont.monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
    private static let upgradeDifferenceFont = UIFont.monospacedDigitSystemFont(ofSize: 36, weight: .bold)
    private static let upgradePriceNoteFont = UIFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
    private static let rowTitleFont = UIFont.systemFont(ofSize: 30, weight: .semibold)
    private static let rowDetailFont = UIFont.systemFont(ofSize: 26, weight: .regular)
    private static let watermarkFont = UIFont.systemFont(ofSize: 24, weight: .medium)
    private static let watermarkBrandFont = UIFont.systemFont(ofSize: 24, weight: .semibold)
}

private extension HangarPackage {
    var shareUpgradePricing: PackageItem.UpgradePricing? {
        guard isUpgradeOnlyPledge else {
            return nil
        }

        return contents.compactMap(\.upgradePricing).first
    }

    var displayInsuranceText: String {
        detailInsuranceText ?? Self.localizedInsuranceDisplayLabel(from: insurance)
    }
}

private extension UpgradeTargetCandidate {
    var displayInsuranceText: String? {
        guard let insurance else {
            return nil
        }

        let trimmedInsurance = insurance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInsurance.isEmpty else {
            return nil
        }

        return HangarPackage.localizedInsuranceDisplayLabel(from: trimmedInsurance)
    }
}

private struct CouponDetailView: View {
    let couponInfo: HangarCouponInfo
    let copiedCouponCode: Bool
    let onCopyCode: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Coupon", value: couponInfo.couponLabel)

            if let code = couponInfo.code {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Coupon Code")
                            .font(.caption2.weight(.bold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)

                        Text(code)
                            .font(.body.weight(.semibold))
                            .monospaced()
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        onCopyCode(code)
                    } label: {
                        Label(
                            copiedCouponCode ? "Copied" : "Copy Code",
                            systemImage: copiedCouponCode ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CompactPackageSummaryView: View {
    let packageGroup: GroupedHangarPackage

    private var package: HangarPackage {
        packageGroup.representative
    }

    private var columns: [GridItem] {
        [
            GridItem(.flexible(minimum: 112), spacing: 10),
            GridItem(.flexible(minimum: 112), spacing: 10)
        ]
    }

    private var acquiredDate: String {
        AppLocalizer.displayDate(package.acquiredAt)
    }

    private var originalValueLabel: String {
        AppLocalizer.string(packageGroup.containsMultipleCopies ? "Melt Value (Each)" : "Melt Value")
    }

    private var currentValueLabel: String {
        AppLocalizer.string(packageGroup.containsMultipleCopies ? "Current Value (Each)" : "Current Value")
    }

    private var insuranceText: String {
        package.displayInsuranceText
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            PackageSummaryTile(
                label: AppLocalizer.string("Status"),
                value: package.status,
                valueColor: statusColor(for: package.status)
            )
            PackageSummaryTile(
                label: AppLocalizer.string("Insurance"),
                value: insuranceText
            )
            PackageSummaryTile(
                label: AppLocalizer.string("Acquired"),
                value: acquiredDate
            )
            PackageSummaryTile(
                label: originalValueLabel,
                value: package.originalValueUSD.usdString,
                monospacedValue: true
            )
            PackageSummaryTile(
                label: currentValueLabel,
                value: package.currentValueUSD.usdString,
                monospacedValue: true
            )
            if packageGroup.containsMultipleCopies {
                PackageSummaryTile(
                    label: AppLocalizer.string("Copies"),
                    value: "\(packageGroup.quantity)",
                    monospacedValue: true
                )
            }
        }
        .padding(.vertical, 2)
    }

    private func statusColor(for status: String) -> Color {
        status.localizedLowercase.contains("gifted") ? .green : .primary
    }
}

private struct PackageSummaryTile: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var monospacedValue = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.82)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .modifier(MonospacedDigitModifier(isEnabled: monospacedValue))
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
    }
}

private struct MonospacedDigitModifier: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.monospacedDigit()
        } else {
            content
        }
    }
}

private struct HangarGiftConfirmationView: View {
    @Environment(\.dismiss) private var dismiss

    let appModel: AppModel
    let packageGroup: GroupedHangarPackage
    let onCompleted: @MainActor @Sendable () -> Void

    @State private var quantityToGift = 1
    @State private var recipientName = ""
    @State private var recipientEmail = ""
    @State private var isGifting = false
    @State private var errorMessage: String?

    private var package: HangarPackage {
        packageGroup.representative
    }

    private var maximumQuantity: Int {
        max(packageGroup.quantity, 1)
    }

    private var fallbackRecipientName: String {
        AppLocalizer.string("User")
    }

    private var recipientNamePreview: String {
        let trimmedValue = recipientName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? fallbackRecipientName : trimmedValue
    }

    var body: some View {
        List {
            Section {
                Text(package.title)
                    .font(.headline)

                if packageGroup.containsMultipleCopies {
                    LabeledContent("Copies Owned", value: "\(packageGroup.quantity)")
                }

                LabeledContent("Status", value: package.status)
                LabeledContent("Insurance", value: package.displayInsuranceText)
            } header: {
                Text("Selected Item")
            }

            Section {
                Stepper(value: $quantityToGift, in: 1 ... maximumQuantity) {
                    HStack {
                        Text("Amount to Gift")
                        Spacer()
                        Text("\(quantityToGift)")
                            .foregroundStyle(.secondary)
                    }
                }

                if maximumQuantity > 1 {
                    Text("Hangar Express will gift the selected number of identical copies one by one to the same recipient.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Quantity")
            }

            Section {
                GiftRecipientFields(
                    recipientName: $recipientName,
                    recipientEmail: $recipientEmail,
                    fallbackRecipientName: fallbackRecipientName
                )
            } header: {
                Text("Recipient")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("If the name is left blank, Hangar Express will use \(recipientNamePreview).")
                    Text("Hangar Express will reuse the saved RSI password for this account after Face ID or device passcode confirmation.")
                }
            }

            Section {
                Text("Double-check the recipient email before continuing. RSI will send the selected item(s) to that address through the live gifting flow.")
                    .foregroundStyle(.orange)
                    .font(.body.weight(.medium))
            } header: {
                Text("Warning")
            }

            Section {
                Button {
                    submitGift()
                } label: {
                    HStack {
                        Spacer()
                        if isGifting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                            Text("Gifting...")
                                .fontWeight(.semibold)
                        } else {
                            Text(quantityToGift == 1 ? "Gift Item" : "Gift \(quantityToGift) Items")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(isGifting || appModel.isRefreshing)
            }
        }
        .navigationTitle("Confirm Gift")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isGifting)
            }
        }
        .alert(
            "Unable to Gift Item",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func submitGift() {
        guard !isGifting else {
            return
        }

        errorMessage = nil
        isGifting = true

        Task {
            do {
                try await appModel.gift(
                    packageGroup: packageGroup,
                    quantity: quantityToGift,
                    recipientName: recipientName,
                    recipientEmail: recipientEmail
                )
                await MainActor.run {
                    isGifting = false
                    onCompleted()
                }
            } catch let error as SensitiveActionAuthorizationError where error.isCancellation {
                await MainActor.run {
                    isGifting = false
                }
            } catch {
                await MainActor.run {
                    isGifting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct HangarBulkGiftConfirmationView: View {
    @Environment(\.dismiss) private var dismiss

    let appModel: AppModel
    let packageGroups: [GroupedHangarPackage]
    let onCompleted: @MainActor @Sendable () -> Void

    @State private var recipientName = ""
    @State private var recipientEmail = ""
    @State private var isGifting = false
    @State private var errorMessage: String?

    private var selectedPackages: [HangarPackage] {
        packageGroups.flatMap(\.packages)
    }

    private var fallbackRecipientName: String {
        AppLocalizer.string("User")
    }

    private var recipientNamePreview: String {
        let trimmedValue = recipientName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? fallbackRecipientName : trimmedValue
    }

    var body: some View {
        List {
            Section {
                HangarBulkSelectedPledgesSummaryView(packageGroups: packageGroups)
            } header: {
                Text("Selected Pledges")
            } footer: {
                Text("Hangar Express will gift every pledge represented by these selected rows to the same recipient.")
            }

            Section {
                GiftRecipientFields(
                    recipientName: $recipientName,
                    recipientEmail: $recipientEmail,
                    fallbackRecipientName: fallbackRecipientName
                )
            } header: {
                Text("Recipient")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("If the name is left blank, Hangar Express will use \(recipientNamePreview).")
                    Text("Hangar Express will reuse the saved RSI password for this account after Face ID or device passcode confirmation.")
                }
            }

            Section {
                Text("Double-check the recipient email before continuing. RSI will send the selected item(s) to that address through the live gifting flow.")
                    .foregroundStyle(.orange)
                    .font(.body.weight(.medium))
            } header: {
                Text("Warning")
            }

            Section {
                Button {
                    submitGift()
                } label: {
                    HStack {
                        Spacer()
                        if isGifting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                            Text("Gifting...")
                                .fontWeight(.semibold)
                        } else {
                            Text("Gift \(selectedPackages.count) Pledges")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(isGifting || appModel.isRefreshing || selectedPackages.isEmpty)
            }
        }
        .navigationTitle("Confirm Gift")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isGifting)
            }
        }
        .alert(
            "Unable to Gift Items",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func submitGift() {
        guard !isGifting else {
            return
        }

        errorMessage = nil
        isGifting = true

        Task {
            do {
                try await appModel.gift(
                    packageGroups: packageGroups,
                    recipientName: recipientName,
                    recipientEmail: recipientEmail
                )
                await MainActor.run {
                    isGifting = false
                    onCompleted()
                }
            } catch let error as SensitiveActionAuthorizationError where error.isCancellation {
                await MainActor.run {
                    isGifting = false
                }
            } catch {
                await MainActor.run {
                    isGifting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct GiftRecipientFields: View {
    @Binding var recipientName: String
    @Binding var recipientEmail: String

    let fallbackRecipientName: String

    var body: some View {
        TextField(fallbackRecipientName, text: $recipientName)
            .textInputAutocapitalization(.words)
            .disableAutocorrection(true)

        HStack(spacing: 12) {
            TextField("Recipient email", text: $recipientEmail)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)

            PasteButton(payloadType: String.self) { values in
                guard let pastedValue = values.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !pastedValue.isEmpty else {
                    return
                }

                recipientEmail = pastedValue
            }
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .fixedSize()
        }
    }
}

private struct HangarBulkSelectedPledgesSummaryView: View {
    let packageGroups: [GroupedHangarPackage]

    private var selectedPledgeCount: Int {
        packageGroups.reduce(0) { partialResult, packageGroup in
            partialResult + packageGroup.quantity
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Total Pledges", value: "\(selectedPledgeCount)")
            LabeledContent("Selected Rows", value: "\(packageGroups.count)")

            Divider()

            ForEach(packageGroups) { packageGroup in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(packageGroup.representative.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)

                    Spacer(minLength: 8)

                    if packageGroup.containsMultipleCopies {
                        Text("x\(packageGroup.quantity)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }
}

private struct HangarActionTile: View {
    let title: String
    let systemImage: String
    let accentColor: Color
    let isEnabled: Bool

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    private var foregroundColor: Color {
        isEnabled ? accentColor : Color.secondary.opacity(0.9)
    }

    private var overlayTint: Color {
        isEnabled ? accentColor.opacity(0.14) : Color.secondary.opacity(0.06)
    }

    private var strokeColor: Color {
        isEnabled ? accentColor.opacity(0.35) : Color.white.opacity(0.12)
    }

    private var iconBackgroundColor: Color {
        isEnabled ? accentColor.opacity(0.14) : Color.white.opacity(0.05)
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline.weight(.bold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .fill(iconBackgroundColor)
                        )
                )

            Text(title)
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .foregroundStyle(foregroundColor)
        .background {
            ZStack {
                tileShape
                    .fill(.ultraThinMaterial)

                tileShape
                    .fill(overlayTint)
            }
        }
        .overlay {
            tileShape
                .strokeBorder(strokeColor, lineWidth: 1)
        }
        .contentShape(tileShape)
    }
}

private struct RowCapabilityIcon: View {
    let systemImage: String
    let tint: Color
    let isAvailable: Bool
    let accessibilityLabel: String

    private var foregroundColor: Color {
        isAvailable ? tint : .secondary
    }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(foregroundColor)
            .frame(width: 20, height: 20)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct HangarMeltConfirmationView: View {
    @Environment(\.dismiss) private var dismiss

    let appModel: AppModel
    let packageGroup: GroupedHangarPackage
    let onCompleted: @MainActor @Sendable () -> Void

    @State private var quantityToMelt = 1
    @State private var isMelting = false
    @State private var errorMessage: String?
    @State private var squadron42Acknowledgement = ""
    @State private var acknowledgesGiftableMelt = false

    private var package: HangarPackage {
        packageGroup.representative
    }

    private var maximumQuantity: Int {
        max(packageGroup.quantity, 1)
    }

    private var estimatedCreditValue: Decimal {
        package.originalValueUSD * Decimal(quantityToMelt)
    }

    private var selectedPackagesToMelt: [HangarPackage] {
        Array(packageGroup.packages.prefix(quantityToMelt))
    }

    private var requiresSquadron42Acknowledgement: Bool {
        selectedPackagesToMelt.contains { $0.containsSquadron42Content }
    }

    private var hasMetSquadron42Acknowledgement: Bool {
        squadron42Acknowledgement.trimmingCharacters(in: .whitespacesAndNewlines) == "I understand"
    }

    private var requiresGiftableMeltAcknowledgement: Bool {
        selectedPackagesToMelt.contains(where: \.canGift)
    }

    var body: some View {
        List {
            Section {
                Text(package.title)
                    .font(.headline)

                if packageGroup.containsMultipleCopies {
                    LabeledContent("Copies Owned", value: "\(packageGroup.quantity)")
                }

                LabeledContent("Per-Copy Melt Value", value: package.originalValueUSD.usdString)
                LabeledContent("Estimated Credit", value: estimatedCreditValue.usdString)
            } header: {
                Text("Selected Item")
            }

            Section {
                Stepper(value: $quantityToMelt, in: 1 ... maximumQuantity) {
                    HStack {
                        Text("Amount to Melt")
                        Spacer()
                        Text("\(quantityToMelt)")
                            .foregroundStyle(.secondary)
                    }
                }

                if maximumQuantity > 1 {
                    Text("Hangar Express will melt the selected number of identical copies one by one, up to the \(maximumQuantity) copies you currently own.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Quantity")
            }

            if requiresGiftableMeltAcknowledgement {
                Section {
                    Text("One or more selected pledges can still be gifted. Melting them permanently gives up the option to send those pledges to another account.")
                        .foregroundStyle(.orange)
                        .font(.body.weight(.semibold))

                    Toggle("I understand I am melting giftable pledge(s)", isOn: $acknowledgesGiftableMelt)
                } header: {
                    Text("Giftable Pledge Warning")
                } footer: {
                    Text("Confirm this warning before Hangar Express unlocks Face ID and sends the live RSI melt request.")
                }
            }

            if requiresSquadron42Acknowledgement {
                Section {
                    Text("This package contains Squadron 42. If you melt it, RSI does not allow this entitlement to be bought back later.")
                        .foregroundStyle(.orange)
                        .font(.body.weight(.semibold))

                    TextField("Type \"I understand\"", text: $squadron42Acknowledgement)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                } header: {
                    Text("Squadron 42 Warning")
                } footer: {
                    Text("Type I understand exactly before Hangar Express unlocks Face ID and sends the live RSI melt request.")
                }
            }

            Section {
                Text("This action cannot be undone. Once RSI confirms the melt, the selected item(s) are permanently converted into store credit.")
                    .foregroundStyle(.orange)
                    .font(.body.weight(.medium))
            } header: {
                Text("Warning")
            }

            Section {
                Button(role: .destructive) {
                    submitMelt()
                } label: {
                    HStack {
                        Spacer()
                        if isMelting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                            Text("Melting...")
                                .fontWeight(.semibold)
                        } else {
                            Text(quantityToMelt == 1 ? "Melt Item" : "Melt \(quantityToMelt) Items")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(
                    isMelting
                        || appModel.isRefreshing
                        || (requiresGiftableMeltAcknowledgement && !acknowledgesGiftableMelt)
                        || (requiresSquadron42Acknowledgement && !hasMetSquadron42Acknowledgement)
                )
            }
        }
        .navigationTitle("Confirm Melt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isMelting)
            }
        }
        .alert(
            "Unable to Melt Item",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func submitMelt() {
        guard !isMelting else {
            return
        }

        guard !requiresGiftableMeltAcknowledgement || acknowledgesGiftableMelt else {
            errorMessage = AppLocalizer.string("One or more selected pledges are giftable. Confirm that warning before Hangar Express can continue to Face ID and submit the melt request.")
            return
        }

        guard !requiresSquadron42Acknowledgement || hasMetSquadron42Acknowledgement else {
            errorMessage = AppLocalizer.string("This package contains Squadron 42. Type I understand before Hangar Express can continue to Face ID and submit the melt request.")
            return
        }

        errorMessage = nil
        isMelting = true

        Task {
            do {
                try await appModel.melt(packageGroup: packageGroup, quantity: quantityToMelt)
                await MainActor.run {
                    isMelting = false
                    onCompleted()
                }
            } catch let error as SensitiveActionAuthorizationError where error.isCancellation {
                await MainActor.run {
                    isMelting = false
                }
            } catch {
                await MainActor.run {
                    isMelting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct HangarBulkMeltConfirmationView: View {
    @Environment(\.dismiss) private var dismiss

    let appModel: AppModel
    let packageGroups: [GroupedHangarPackage]
    let onCompleted: @MainActor @Sendable () -> Void

    @State private var isMelting = false
    @State private var errorMessage: String?
    @State private var squadron42Acknowledgement = ""
    @State private var acknowledgesGiftableMelt = false

    private var selectedPackages: [HangarPackage] {
        packageGroups.flatMap(\.packages)
    }

    private var estimatedCreditValue: Decimal {
        selectedPackages.reduce(into: Decimal.zero) { partialResult, package in
            partialResult += package.originalValueUSD
        }
    }

    private var requiresGiftableMeltAcknowledgement: Bool {
        selectedPackages.contains(where: \.canGift)
    }

    private var requiresSquadron42Acknowledgement: Bool {
        selectedPackages.contains { $0.containsSquadron42Content }
    }

    private var hasMetSquadron42Acknowledgement: Bool {
        squadron42Acknowledgement.trimmingCharacters(in: .whitespacesAndNewlines) == "I understand"
    }

    var body: some View {
        List {
            Section {
                HangarBulkSelectedPledgesSummaryView(packageGroups: packageGroups)
                LabeledContent("Estimated Credit", value: estimatedCreditValue.usdString)
            } header: {
                Text("Selected Pledges")
            } footer: {
                Text("Hangar Express will reclaim every pledge represented by these selected rows.")
            }

            if requiresGiftableMeltAcknowledgement {
                Section {
                    Text("One or more selected pledges can still be gifted. Melting them permanently gives up the option to send those pledges to another account.")
                        .foregroundStyle(.orange)
                        .font(.body.weight(.semibold))

                    Toggle("I understand I am melting giftable pledge(s)", isOn: $acknowledgesGiftableMelt)
                } header: {
                    Text("Giftable Pledge Warning")
                } footer: {
                    Text("Confirm this warning before Hangar Express unlocks Face ID and sends the live RSI melt request.")
                }
            }

            if requiresSquadron42Acknowledgement {
                Section {
                    Text("One or more selected pledges contain Squadron 42. If you melt them, RSI does not allow this entitlement to be bought back later.")
                        .foregroundStyle(.orange)
                        .font(.body.weight(.semibold))

                    TextField("Type \"I understand\"", text: $squadron42Acknowledgement)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                } header: {
                    Text("Squadron 42 Warning")
                } footer: {
                    Text("Type I understand exactly before Hangar Express unlocks Face ID and sends the live RSI melt request.")
                }
            }

            Section {
                Text("This action cannot be undone. Once RSI confirms the melt, the selected item(s) are permanently converted into store credit.")
                    .foregroundStyle(.orange)
                    .font(.body.weight(.medium))
            } header: {
                Text("Warning")
            }

            Section {
                Button(role: .destructive) {
                    submitMelt()
                } label: {
                    HStack {
                        Spacer()
                        if isMelting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                            Text("Melting...")
                                .fontWeight(.semibold)
                        } else {
                            Text("Melt \(selectedPackages.count) Pledges")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(
                    isMelting
                        || appModel.isRefreshing
                        || selectedPackages.isEmpty
                        || (requiresGiftableMeltAcknowledgement && !acknowledgesGiftableMelt)
                        || (requiresSquadron42Acknowledgement && !hasMetSquadron42Acknowledgement)
                )
            }
        }
        .navigationTitle("Confirm Melt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isMelting)
            }
        }
        .alert(
            "Unable to Melt Items",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func submitMelt() {
        guard !isMelting else {
            return
        }

        guard !requiresGiftableMeltAcknowledgement || acknowledgesGiftableMelt else {
            errorMessage = AppLocalizer.string("One or more selected pledges are giftable. Confirm that warning before Hangar Express can continue to Face ID and submit the melt request.")
            return
        }

        guard !requiresSquadron42Acknowledgement || hasMetSquadron42Acknowledgement else {
            errorMessage = AppLocalizer.string("One or more selected pledges contain Squadron 42. Type I understand before Hangar Express can continue to Face ID and submit the melt request.")
            return
        }

        errorMessage = nil
        isMelting = true

        Task {
            do {
                try await appModel.melt(packageGroups: packageGroups)
                await MainActor.run {
                    isMelting = false
                    onCompleted()
                }
            } catch let error as SensitiveActionAuthorizationError where error.isCancellation {
                await MainActor.run {
                    isMelting = false
                }
            } catch {
                await MainActor.run {
                    isMelting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct HangarUpgradeTargetPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let appModel: AppModel
    let packageGroup: GroupedHangarPackage
    let reloadToken: UUID?
    let completionHandler: HangarActionCompletionHandler

    @State private var searchText = ""
    @State private var isLoading = true
    @State private var targets: [UpgradeTargetCandidate] = []
    @State private var errorMessage: String?

    private var package: HangarPackage {
        packageGroup.representative
    }

    private var filteredTargets: [UpgradeTargetCandidate] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return targets
        }

        let needle = searchText.localizedLowercase
        return targets.filter { target in
            [
                target.title,
                target.status ?? "",
                target.insurance ?? ""
            ]
            .joined(separator: " ")
            .localizedLowercase
            .contains(needle)
        }
    }

    var body: some View {
        List {
            Section {
                Text(package.title)
                    .font(.headline)

                if packageGroup.containsMultipleCopies {
                    Text("This grouped stack contains \(packageGroup.quantity) identical copies. Hangar Express will apply one copy in this first release.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Selected Upgrade")
            }

            if isLoading {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading eligible RSI target pledges...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
            } else if let errorMessage {
                Section {
                    ContentUnavailableView(
                        "Unable to Load Upgrade Targets",
                        systemImage: "exclamationmark.triangle.fill",
                        description: Text(errorMessage)
                    )

                    Button("Try Again") {
                        Task {
                            await loadTargets()
                        }
                    }
                }
            } else {
                Section {
                    ForEach(filteredTargets) { target in
                        NavigationLink {
                            HangarUpgradeConfirmationView(
                                appModel: appModel,
                                packageGroup: packageGroup,
                                target: target,
                                reloadToken: reloadToken,
                                completionHandler: completionHandler
                            )
                        } label: {
                            UpgradeTargetRow(target: target, reloadToken: reloadToken)
                        }
                    }
                } header: {
                    Text("Eligible Target Pledges")
                } footer: {
                    if filteredTargets.isEmpty {
                        Text("No target pledges match your search.")
                    } else {
                        Text("RSI decides which pledges are eligible. Hangar Express shows the live target list returned by RSI, then enriches it with your cached hangar data when available.")
                    }
                }
            }
        }
        .navigationTitle("Choose Target")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search target pledges")
        .task {
            guard targets.isEmpty, errorMessage == nil else {
                return
            }

            await loadTargets()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
        }
    }

    private func loadTargets() async {
        isLoading = true
        errorMessage = nil

        do {
            targets = try await appModel.fetchUpgradeTargets(for: packageGroup)
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

private struct UpgradeTargetRow: View {
    let target: UpgradeTargetCandidate
    let reloadToken: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteThumbnailView(
                url: target.thumbnailURL,
                reloadToken: reloadToken,
                fallbackSystemImage: "shippingbox.fill",
                size: 60
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(target.title)
                    .font(.headline)

                if let status = target.status,
                   !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let insurance = target.displayInsuranceText {
                    Text(insurance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

private final class HangarActionCompletionHandler: @unchecked Sendable {
    private let callback: @MainActor () -> Void

    init(callback: @escaping @MainActor () -> Void) {
        self.callback = callback
    }

    @MainActor
    func complete() {
        callback()
    }
}

private struct HangarUpgradeConfirmationView: View {
    @Environment(\.dismiss) private var dismiss

    let appModel: AppModel
    let packageGroup: GroupedHangarPackage
    let target: UpgradeTargetCandidate
    let reloadToken: UUID?
    let completionHandler: HangarActionCompletionHandler

    @State private var isApplying = false
    @State private var errorMessage: String?

    private var package: HangarPackage {
        packageGroup.representative
    }

    private var upgradePath: (from: String?, to: String?) {
        if let metadata = package.upgradeMetadata {
            let sourceName = metadata.matchItems.first?.name
            let targetName = metadata.targetItems.first?.name
            if sourceName != nil || targetName != nil {
                return (sourceName, targetName)
            }
        }

        if let pricing = package.contents.compactMap(\.upgradePricing).first {
            return (pricing.sourceShipName, pricing.targetShipName)
        }

        return (nil, nil)
    }

    var body: some View {
        List {
            Section {
                Text(package.title)
                    .font(.headline)

                if packageGroup.containsMultipleCopies {
                    Text("Hangar Express will consume one copy from this grouped stack of \(packageGroup.quantity) identical upgrades.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Upgrade Item")
            }

            Section {
                if let fromShip = upgradePath.from,
                   !fromShip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LabeledContent("From", value: fromShip)
                }

                if let toShip = upgradePath.to,
                   !toShip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LabeledContent("To", value: toShip)
                }
            } header: {
                Text("Upgrade Path")
            }

            Section {
                HStack(alignment: .top, spacing: 12) {
                    RemoteThumbnailView(
                        url: target.thumbnailURL,
                        reloadToken: reloadToken,
                        fallbackSystemImage: "shippingbox.fill",
                        size: 72
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text(target.title)
                            .font(.headline)

                        if let status = target.status,
                           !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(status)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        if let insurance = target.displayInsuranceText {
                            Text(insurance)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Selected Target")
            }

            Section {
                Text("This action cannot be undone. RSI will permanently consume the stored upgrade and apply it to the selected pledge.")
                    .foregroundStyle(.orange)
                    .font(.body.weight(.medium))

                Text("Hangar Express will reuse the saved RSI password for this account after Face ID or device passcode confirmation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Warning")
            }

            Section {
                Button {
                    submitUpgrade()
                } label: {
                    HStack {
                        Spacer()
                        if isApplying {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                            Text("Applying Upgrade...")
                                .fontWeight(.semibold)
                        } else {
                            Text("Apply Upgrade")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(isApplying || appModel.isRefreshing)
            }
        }
        .navigationTitle("Confirm Upgrade")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isApplying)
            }
        }
        .alert(
            "Unable to Apply Upgrade",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func submitUpgrade() {
        guard !isApplying else {
            return
        }

        errorMessage = nil
        isApplying = true

        Task {
            do {
                try await appModel.applyUpgrade(packageGroup: packageGroup, target: target)
                await MainActor.run {
                    isApplying = false
                    completionHandler.complete()
                }
            } catch let error as SensitiveActionAuthorizationError where error.isCancellation {
                await MainActor.run {
                    isApplying = false
                }
            } catch {
                await MainActor.run {
                    isApplying = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct PackageItemRow: View {
    let item: PackageItem
    let itemTranslator: HangarItemTranslator
    let reloadToken: UUID?

    var body: some View {
        if item.imageURL == nil {
            compactListRow
        } else {
            thumbnailRow
        }
    }

    private var thumbnailRow: some View {
        HStack(alignment: .top, spacing: 12) {
            PackageDetailItemThumbnailView(
                url: item.imageURL,
                reloadToken: reloadToken,
                fallbackSystemImage: fallbackSystemImage
            )

            VStack(alignment: .leading, spacing: 6) {
                HangarTranslatedText(
                    source: item.title,
                    itemTranslator: itemTranslator
                )
                    .font(.headline)

                HangarTranslatedText(
                    source: "\(item.category.rawValue) • \(item.detail)",
                    itemTranslator: itemTranslator
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let pricing = item.upgradePricing {
                    UpgradePricingSummary(
                        pricing: pricing,
                        itemTranslator: itemTranslator
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var compactListRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: fallbackSystemImage)
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HangarTranslatedText(
                    source: item.title,
                    itemTranslator: itemTranslator
                )
                    .font(.headline)

                HangarTranslatedText(
                    source: "\(item.category.rawValue) • \(item.detail)",
                    itemTranslator: itemTranslator
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let pricing = item.upgradePricing {
                    UpgradePricingSummary(
                        pricing: pricing,
                        itemTranslator: itemTranslator
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
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

private struct PackageDetailItemThumbnailView: View {
    let url: URL?
    let reloadToken: UUID?
    let fallbackSystemImage: String

    private let width: CGFloat = 112
    private let height: CGFloat = 76
    private let cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemBackground))

            if let url {
                CachedRemoteImage(
                    url: url,
                    targetSize: CGSize(width: width, height: height),
                    reloadToken: reloadToken
                ) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        ProgressView()
                    case .failure:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var fallback: some View {
        Image(systemName: fallbackSystemImage)
            .font(.title3)
            .foregroundStyle(.secondary)
    }
}

private struct PackageAlsoContainsRow: View {
    let item: PackageItem
    let itemTranslator: HangarItemTranslator

    private var detailText: String? {
        let detail = item.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty,
              detail.localizedCaseInsensitiveCompare("Unknown") != .orderedSame,
              detail.localizedCaseInsensitiveCompare("RSI pledge entitlement") != .orderedSame else {
            return nil
        }

        return "\(item.category.rawValue) • \(detail)"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.cyan)
                .frame(width: 9, height: 5)

            VStack(alignment: .leading, spacing: 3) {
                HangarTranslatedText(
                    source: item.title,
                    itemTranslator: itemTranslator
                )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                if let detailText {
                    HangarTranslatedText(
                        source: detailText,
                        itemTranslator: itemTranslator
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct UpgradePricingSummary: View {
    let pricing: PackageItem.UpgradePricing
    let itemTranslator: HangarItemTranslator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledValueRow(label: "Melt Value", value: pricing.meltValueUSD?.usdString ?? "Not separable from this package")
            LabeledValueRow(label: "Actual Value", value: pricing.actualValueUSD?.usdString ?? "Unavailable")
            LabeledValueRow(
                label: "From",
                value: "\(itemTranslator.translated(pricing.sourceShipName)) • MSRP \(pricing.sourceShipMSRPUSD?.usdString ?? "Unavailable")"
            )
            LabeledValueRow(
                label: "To",
                value: "\(itemTranslator.translated(pricing.targetShipName)) • MSRP \(pricing.targetShipMSRPUSD?.usdString ?? "Unavailable")"
            )
        }
        .padding(.top, 4)
    }
}

private struct LabeledValueRow: View {
    let label: LocalizedStringKey
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
    @AppStorage(DisplayPreferences.compositeUpgradeThumbnailModeKey) private var usesCompositeUpgradeThumbnails = DisplayPreferences.compositeUpgradeThumbnailsEnabledByDefault

    let url: URL?
    let upgradeCompositePricing: PackageItem.UpgradePricing?
    let reloadToken: UUID?
    let fallbackSystemImage: String
    let size: CGFloat

    init(
        url: URL?,
        upgradeCompositePricing: PackageItem.UpgradePricing? = nil,
        reloadToken: UUID? = nil,
        fallbackSystemImage: String,
        size: CGFloat
    ) {
        self.url = url
        self.upgradeCompositePricing = upgradeCompositePricing
        self.reloadToken = reloadToken
        self.fallbackSystemImage = fallbackSystemImage
        self.size = size
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))

            if shouldRenderCompositeThumbnail {
                compositeOrFallback
            } else if let url {
                CachedRemoteImage(
                    url: url,
                    targetSize: CGSize(width: size, height: size),
                    reloadToken: reloadToken
                ) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        compositeOrFallback
                    case .empty:
                        ProgressView()
                    }
                }
            } else {
                compositeOrFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var shouldRenderCompositeThumbnail: Bool {
        guard usesCompositeUpgradeThumbnails,
              let upgradeCompositePricing else {
            return false
        }

        return upgradeCompositePricing.sourceShipImageURL != nil
            || upgradeCompositePricing.targetShipImageURL != nil
    }

    @ViewBuilder
    private var compositeOrFallback: some View {
        if let upgradeCompositePricing, shouldRenderCompositeThumbnail {
            UpgradeCompositeThumbnailView(
                pricing: upgradeCompositePricing,
                reloadToken: reloadToken,
                size: size
            )
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Image(systemName: fallbackSystemImage)
            .font(.title2)
            .foregroundStyle(.secondary)
    }
}

private struct UpgradeCompositeThumbnailView: View {
    let pricing: PackageItem.UpgradePricing
    let reloadToken: UUID?
    let size: CGFloat

    var body: some View {
        CachedUpgradeCompositeImage(
            sourceURL: pricing.sourceShipImageURL,
            targetURL: pricing.targetShipImageURL,
            targetSize: CGSize(width: size, height: size),
            reloadToken: reloadToken
        ) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
            case .empty:
                ProgressView()
            case .failure:
                upgradeCompositeFallback
            }
        }
    }

    private var upgradeCompositeFallback: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemGray5), Color(.systemGray4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "square.2.layers.3d.top.filled")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct UpgradeDetailHeaderView: View {
    let pricing: PackageItem.UpgradePricing
    let reloadToken: UUID?

    var body: some View {
        UpgradeDetailDiagonalPictureView(
            pricing: pricing,
            reloadToken: reloadToken
        )
        .frame(height: 220)
        .padding(.horizontal, -8)
    }
}

private struct UpgradeDetailDiagonalPictureView: View {
    let pricing: PackageItem.UpgradePricing
    let reloadToken: UUID?

    private let cornerRadius: CGFloat = 24

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemBackground))

                UpgradeDetailDiagonalImageLayer(
                    url: pricing.sourceShipImageURL,
                    reloadToken: reloadToken,
                    targetSize: size,
                    alignment: .leading,
                    outwardDirection: -1,
                    fallbackSystemImage: "arrow.uturn.backward.circle.fill"
                )
                .clipShape(UpgradeSourceDiagonalClipShape())

                UpgradeDetailDiagonalImageLayer(
                    url: pricing.targetShipImageURL,
                    reloadToken: reloadToken,
                    targetSize: size,
                    alignment: .trailing,
                    outwardDirection: 1,
                    fallbackSystemImage: "arrow.up.right.circle.fill"
                )
                .clipShape(UpgradeTargetDiagonalClipShape())

                UpgradeDiagonalDividerShape()
                    .stroke(.white.opacity(0.26), lineWidth: 2)

                UpgradeDetailCenterSummaryCard(pricing: pricing)
            }
            .compositingGroup()
            .clipShape(panelShape, style: FillStyle(eoFill: false, antialiased: true))
            .overlay {
                panelShape
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
        }
    }
}

private struct UpgradeDetailDiagonalImageLayer: View {
    let url: URL?
    let reloadToken: UUID?
    let targetSize: CGSize
    let alignment: Alignment
    let outwardDirection: CGFloat
    let fallbackSystemImage: String

    private var outwardOffset: CGFloat {
        targetSize.width * 0.14 * outwardDirection
    }

    var body: some View {
        CachedRemoteImage(
            url: url,
            targetSize: targetSize,
            reloadToken: reloadToken
        ) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: targetSize.width, height: targetSize.height, alignment: alignment)
                    .offset(x: outwardOffset)
            case .empty:
                ProgressView()
                    .frame(width: targetSize.width, height: targetSize.height)
            case .failure:
                UpgradeDetailPictureFallback(systemImage: fallbackSystemImage)
                    .frame(width: targetSize.width, height: targetSize.height)
            }
        }
    }
}

private struct UpgradeDetailCenterSummaryCard: View {
    let pricing: PackageItem.UpgradePricing

    private var differenceText: String {
        if let sourceValue = pricing.sourceShipMSRPUSD,
           let targetValue = pricing.targetShipMSRPUSD {
            return (targetValue - sourceValue).usdString
        }

        if let actualValue = pricing.actualValueUSD {
            return actualValue.usdString
        }

        return "Unavailable"
    }

    private var meltText: String {
        pricing.meltValueUSD?.usdString ?? pricing.actualValueUSD?.usdString ?? "Unavailable"
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(differenceText)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.primary)

            Text("\(AppLocalizer.string("Melt")) \(meltText)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(width: 124, height: 84)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
                .shadow(color: .black.opacity(0.32), radius: 26, x: 0, y: 0)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct UpgradeDetailPictureFallback: View {
    let systemImage: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemGray5), Color(.systemGray4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct UpgradeSourceDiagonalClipShape: Shape {
    func path(in rect: CGRect) -> Path {
        let topSplitX = rect.width * 0.423
        let bottomSplitX = rect.width * 0.583

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + topSplitX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + bottomSplitX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct UpgradeTargetDiagonalClipShape: Shape {
    func path(in rect: CGRect) -> Path {
        let topSplitX = rect.width * 0.423
        let bottomSplitX = rect.width * 0.583

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topSplitX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + bottomSplitX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct UpgradeDiagonalDividerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let topSplitX = rect.width * 0.423
        let bottomSplitX = rect.width * 0.583

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topSplitX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + bottomSplitX, y: rect.maxY))
        return path
    }
}
