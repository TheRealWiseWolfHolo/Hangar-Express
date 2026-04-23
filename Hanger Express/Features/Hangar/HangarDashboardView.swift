import SwiftUI
import UIKit

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

    @AppStorage(DisplayPreferences.hangarGiftedHighlightKey) private var highlightsGiftedHangarRows = DisplayPreferences.hangarGiftedHighlightEnabledByDefault
    @AppStorage(DisplayPreferences.hangarUpgradedHighlightKey) private var highlightsUpgradedHangarRows = DisplayPreferences.hangarUpgradedHighlightEnabledByDefault
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
                                appModel: appModel,
                                packageGroup: packageGroup,
                                reloadToken: appModel.hangarFleetImageReloadToken
                            )
                        } label: {
                            HangarPackageGroupRow(
                                packageGroup: packageGroup,
                                reloadToken: appModel.hangarFleetImageReloadToken
                            )
                        }
                        .contextMenu {
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
                        .listRowBackground(hangarRowBackground(for: packageGroup.representative))
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

    private func hangarCardDebugExport(for packageGroup: GroupedHangarPackage) -> String {
        let export = HangarCardDebugExport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            quantity: packageGroup.quantity,
            containsMultipleCopies: packageGroup.containsMultipleCopies,
            displaySettings: .init(
                showsUpgradedShipInHangar: appModel.showsUpgradedShipInHangar,
                compositeUpgradeThumbnailsEnabled: appModel.compositeUpgradeThumbnailsEnabled
            ),
            representativeComputedDisplay: .init(
                displayTitle: packageGroup.representative.debugDisplayTitle(showsUpgradedShipInHangar: appModel.showsUpgradedShipInHangar),
                displayThumbnailURL: packageGroup.representative.debugDisplayThumbnailURL(showsUpgradedShipInHangar: appModel.showsUpgradedShipInHangar)?.absoluteString,
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

    @ViewBuilder
    private func hangarRowBackground(for package: HangarPackage) -> some View {
        let baseColor = Color(uiColor: .secondarySystemGroupedBackground)

        ZStack {
            baseColor

            if highlightsGiftedHangarRows && package.status.localizedLowercase.contains("gifted") {
                Color.green.opacity(0.16)
            } else if highlightsUpgradedHangarRows && package.isUpgradedShipPledge {
                Color.accentColor.opacity(0.16)
            }
        }
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

struct HangarPackageGroupRow: View {
    @AppStorage(DisplayPreferences.hangarUpgradedShipDisplayModeKey) private var showsUpgradedShipInHangar = DisplayPreferences.hangarUpgradedShipDisplayEnabledByDefault
    let packageGroup: GroupedHangarPackage
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

    private var displayTitle: String {
        if showsUpgradedShipInHangar,
           let upgradedShipDisplayTitle = package.upgradedShipDisplayTitle {
            return upgradedShipDisplayTitle
        }

        return package.title
    }

    private var insuranceBadgeText: String? {
        visibleInsurance
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
                        Text(insuranceBadgeText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor.opacity(0.14))
                            )
                            .padding(6)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(displayTitle)
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
        Self.acquiredDateFormatter.string(from: package.acquiredAt)
    }

    private var visibleInsurance: String? {
        guard let displayedInsurance = package.displayedInsurance,
              displayedInsurance.localizedCaseInsensitiveCompare("Unknown") != .orderedSame else {
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

    private static let acquiredDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter
    }()
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

    private enum PresentedActionSheet: String, Identifiable {
        case melt
        case gift
        case upgrade

        var id: String { rawValue }
    }

    let appModel: AppModel
    let packageGroup: GroupedHangarPackage
    let reloadToken: UUID?

    @State private var presentedActionSheet: PresentedActionSheet?

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

    private var displayThumbnailURL: URL? {
        package.packageThumbnailURL
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
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
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
                LabeledContent {
                    Text(package.status)
                        .foregroundStyle(statusColor(for: package.status))
                } label: {
                    Text("Status")
                }
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

            Section {
                HStack(spacing: 12) {
                    Button {
                        presentedActionSheet = .gift
                    } label: {
                        HangarActionTile(
                            title: "Gift",
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
                            title: "Upgrade",
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
                            title: "Reclaim",
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
                        Text("Grey actions need a fresh sign-in with saved credentials before Hangar Express can send live RSI requests.")
                    } else if hasAnySupportedLiveAction {
                        Text("Hangar Express will confirm with Face ID or your iPhone passcode before sending any live RSI action.")
                    } else {
                        Text("This pledge does not currently support gift, upgrade, or reclaim actions through RSI.")
                    }
                }
            }
        }
        .navigationTitle(package.title)
        .navigationBarTitleDisplayMode(.inline)
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
    }

    private var originalValueLabel: String {
        packageGroup.containsMultipleCopies ? "Melt Value (Each)" : "Melt Value"
    }

    private var currentValueLabel: String {
        packageGroup.containsMultipleCopies ? "Current Value (Each)" : "Current Value"
    }

    private func statusColor(for status: String) -> Color {
        status.localizedLowercase.contains("gifted") ? .green : .secondary
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
        let displayName = appModel.session?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return displayName.isEmpty ? "Hangar Express User" : displayName
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
                LabeledContent("Insurance", value: package.insurance)
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
                TextField("Recipient name (optional)", text: $recipientName)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)

                TextField("Recipient email", text: $recipientEmail)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
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

    private var package: HangarPackage {
        packageGroup.representative
    }

    private var maximumQuantity: Int {
        max(packageGroup.quantity, 1)
    }

    private var estimatedCreditValue: Decimal {
        package.originalValueUSD * Decimal(quantityToMelt)
    }

    private var requiresSquadron42Acknowledgement: Bool {
        packageGroup.containsSquadron42Content
    }

    private var hasMetSquadron42Acknowledgement: Bool {
        squadron42Acknowledgement.trimmingCharacters(in: .whitespacesAndNewlines) == "I understand"
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

        guard !requiresSquadron42Acknowledgement || hasMetSquadron42Acknowledgement else {
            errorMessage = "This package contains Squadron 42. Type I understand before Hangar Express can continue to Face ID and submit the melt request."
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

                if let insurance = target.insurance,
                   !insurance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

                        if let insurance = target.insurance,
                           !insurance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
    let reloadToken: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteThumbnailView(
                url: item.imageURL,
                reloadToken: reloadToken,
                fallbackSystemImage: fallbackSystemImage,
                size: 76
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
        HStack(spacing: 18) {
            RemoteThumbnailView(
                url: pricing.sourceShipImageURL,
                reloadToken: reloadToken,
                fallbackSystemImage: "arrow.uturn.backward.circle.fill",
                size: 132
            )

            Image(systemName: "arrow.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)

            RemoteThumbnailView(
                url: pricing.targetShipImageURL,
                reloadToken: reloadToken,
                fallbackSystemImage: "arrow.up.right.circle.fill",
                size: 132
            )
        }
        .padding(.vertical, 8)
    }
}
