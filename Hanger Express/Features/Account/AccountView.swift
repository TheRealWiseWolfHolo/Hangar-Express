import SwiftUI
import UIKit

struct AccountView: View {
    let appModel: AppModel
    let snapshot: HangarSnapshot

    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @AppStorage(DisplayPreferences.earlyAccessBadgeKey) private var showsEarlyAccessBadge = DisplayPreferences.earlyAccessBadgeEnabledByDefault
    @State private var isShowingSettings = false
    @State private var isShowingBackgroundPicker = false
    @State private var isShowingAccountTotalValueExplanation = false
    @State private var isShowingConciergeLevels = false
    @State private var selectedBackgroundSelectionKey: String?
    @State private var isOverviewEmailVisible = false
    @State private var isOverviewSavedLoginVisible = false
    @State private var presentedTool: FleetTool?
    @State private var limitedShipAccessPrompt: LimitedShipAccessPrompt?
    @State private var isCheckingLimitedShipAccess = false
    @State private var isLoadingReferralInviteCode = false
    @State private var copiedReferralInviteCode = false
    @State private var referralInviteCopyErrorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AccountProfileCard(
                        displayName: profileDisplayName,
                        organizationSummary: profileOrganizationSummary,
                        totalValueLabel: accountTotalValueLabel,
                        conciergeLevel: conciergeLevel,
                        proBadgeKind: proBadgeKind,
                        avatarURL: profileAvatarURL,
                        backgroundImageURL: profileBackgroundImageURL,
                        reloadToken: appModel.accountImageReloadToken,
                        onExplainTotalValue: {
                            isShowingAccountTotalValueExplanation = true
                        },
                        onShowConciergeLevels: {
                            isShowingConciergeLevels = true
                        },
                        onChangeBackground: profileBackgroundOptions.isEmpty ? nil : {
                            isShowingBackgroundPicker = true
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Profile")
                }

                Section {
                    LazyVGrid(columns: snapshotColumns, alignment: .leading, spacing: 12) {
                        MetricCard(
                            title: "Packages",
                            primaryValue: "\(snapshot.metrics.packageCount)",
                            secondaryValue: AppLocalizer.format("Ships %@", String(snapshot.metrics.shipCount))
                        )

                        MetricCard(
                            title: "Current Value",
                            primaryValue: snapshot.metrics.totalCurrentValue.usdString,
                            secondaryValue: AppLocalizer.format("Melt %@", snapshot.metrics.totalOriginalValue.usdString)
                        )

                        MetricCard(
                            title: "Credit",
                            primaryValue: snapshot.metrics.storeCreditUSD?.usdString ?? AppLocalizer.string("Unavailable"),
                            secondaryValue: AppLocalizer.format(
                                "Total Spend: %@",
                                snapshot.metrics.totalSpendUSD?.usdString ?? AppLocalizer.string("Unavailable")
                            )
                        )

                        MetricCard(
                            title: "Referrals",
                            primaryValue: snapshot.referralStats.currentSummary,
                            secondaryValue: snapshot.referralStats.legacySummary,
                            accessorySystemImage: referralMetricAccessorySystemImage,
                            accessoryColor: referralMetricAccessoryColor,
                            longPressAction: referralInviteCopyAction,
                            accessibilityActionName: "Copy Referral Code"
                        )
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Snapshot")
                }

                Section {
                    FleetToolsSection(showsHeader: false) { tool in
                        handleToolSelection(tool)
                    }
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Tools")
                }

                Section {
                    SensitiveOverviewFieldRow(
                        title: "Account Email",
                        value: profileEmail,
                        isVisible: $isOverviewEmailVisible,
                        hiddenText: "Email Hidden",
                        emptyText: "Unknown"
                    )
                    SensitiveOverviewFieldRow(
                        title: "Saved Login",
                        value: appModel.session?.credentials?.loginIdentifier,
                        isVisible: $isOverviewSavedLoginVisible,
                        hiddenText: "Saved Login Hidden",
                        emptyText: "None"
                    )
                    LabeledContent("Last Refresh", value: refreshLabel)
                } header: {
                    Text("Overview")
                }

                Section {
                    Button {
                        Task {
                            await appModel.refresh(scope: .account)
                        }
                    } label: {
                        Text(appModel.isRefreshing(.account) ? LocalizedStringKey("Refreshing Account...") : LocalizedStringKey("Refresh Account"))
                    }
                    .disabled(appModel.isRefreshing)

                    Button {
                        Task {
                            await appModel.refresh(scope: .full)
                        }
                    } label: {
                        Text(appModel.isRefreshing(.full) ? LocalizedStringKey("Refreshing Everything...") : LocalizedStringKey("Full Refresh"))
                    }
                    .disabled(appModel.isRefreshing)
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Refresh Account updates balances, referral data, and profile metadata. Full Refresh also reloads hangar, fleet, and buy-back data.")
                }
            }
            .id(appLanguageRawValue)
            .navigationTitle("Account")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Open Settings")
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView(appModel: appModel, snapshot: snapshot)
            }
            .sheet(isPresented: $isShowingBackgroundPicker) {
                ProfileBackgroundPickerView(
                    options: profileBackgroundOptions,
                    selectedSelectionKey: resolvedSelectedBackgroundSelectionKey
                ) { selectionKey in
                    updateProfileBackgroundSelection(selectionKey)
                }
            }
            .sheet(isPresented: $isShowingConciergeLevels) {
                ConciergeLevelsSheetView(
                    currentLevel: conciergeLevel,
                    totalSpendUSD: snapshot.metrics.totalSpendUSD
                )
            }
            .sheet(item: $limitedShipAccessPrompt) { _ in
                LimitedShipAccessCodePromptView(account: appModel.session) {
                    limitedShipAccessPrompt = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        presentedTool = .limitedShipPurchase
                    }
                }
                .presentationDetents([.large])
            }
            .sheet(item: $presentedTool) { tool in
                switch tool {
                case .allShips:
                    AllShipsBrowserView(reloadToken: appModel.hangarFleetImageReloadToken)
                case .limitedShipPurchase:
                    LimitedShipPurchaseView(
                        appModel: appModel,
                        snapshot: snapshot,
                        reloadToken: appModel.hangarFleetImageReloadToken
                    )
                case .ccuChainCalculator:
                    CCUUpgradeCalculatorView(
                        snapshot: snapshot,
                        reloadToken: appModel.hangarFleetImageReloadToken
                    )
                case .authorizedDevices:
                    AuthorizedDevicesView(appModel: appModel)
                case .resetCharacter:
                    EmptyView()
                }
            }
            .alert("Account Total Value", isPresented: $isShowingAccountTotalValueExplanation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(accountTotalValueExplanation)
            }
            .alert("Referral Code Unavailable", isPresented: referralInviteCopyErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(referralInviteCopyErrorMessage ?? "")
            }
            .overlay {
                if isCheckingLimitedShipAccess {
                    LimitedShipAccessCheckingOverlay()
                }
            }
            .task(id: backgroundSelectionLoadID) {
                loadSavedProfileBackgroundSelection()
            }
        }
    }

    private func handleToolSelection(_ tool: FleetTool) {
        guard tool.isAvailable else {
            return
        }

        guard tool == .limitedShipPurchase else {
            presentedTool = tool
            return
        }

        checkLimitedShipAccessAndPresent()
    }

    private func checkLimitedShipAccessAndPresent() {
        guard !isCheckingLimitedShipAccess else {
            return
        }

        isCheckingLimitedShipAccess = true
        let account = appModel.session

        Task {
            let entitlement = await LimitedShipAccessManager.shared.currentEntitlement(account: account)

            await MainActor.run {
                isCheckingLimitedShipAccess = false

                if entitlement != nil {
                    presentedTool = .limitedShipPurchase
                } else {
                    limitedShipAccessPrompt = LimitedShipAccessPrompt()
                }
            }
        }
    }

    private func copyReferralInviteCode() {
        if let referralInviteCode {
            copyReferralInviteCode(referralInviteCode)
            return
        }

        guard !appModel.isRefreshing, !isLoadingReferralInviteCode else {
            referralInviteCopyErrorMessage = AppLocalizer.string(
                "Referral code is still loading. Try again after the current refresh finishes."
            )
            return
        }

        isLoadingReferralInviteCode = true
        Task {
            await appModel.refresh(scope: .account)

            await MainActor.run {
                isLoadingReferralInviteCode = false

                if let refreshedInviteCode = currentReferralInviteCode {
                    copyReferralInviteCode(refreshedInviteCode)
                } else {
                    referralInviteCopyErrorMessage = AppLocalizer.string(
                        "Refresh Account did not find a referral code yet. Open the RSI referral page once, then refresh Account and try again."
                    )
                }
            }
        }
    }

    private func copyReferralInviteCode(_ inviteCode: String) {
        UIPasteboard.general.string = inviteCode
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copiedReferralInviteCode = true

        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                copiedReferralInviteCode = false
            }
        }
    }

    private var referralInviteCopyErrorBinding: Binding<Bool> {
        Binding {
            referralInviteCopyErrorMessage != nil
        } set: { isPresented in
            if !isPresented {
                referralInviteCopyErrorMessage = nil
            }
        }
    }

    private var refreshLabel: String {
        guard let lastRefreshAt = appModel.lastRefreshAt else {
            return AppLocalizer.string("Not yet synced")
        }

        return lastRefreshAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var snapshotColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }

    private var referralInviteCode: String? {
        sanitizedReferralInviteCode(from: snapshot)
    }

    private var currentReferralInviteCode: String? {
        if let snapshot = appModel.snapshot {
            return sanitizedReferralInviteCode(from: snapshot)
        }

        return referralInviteCode
    }

    private func sanitizedReferralInviteCode(from snapshot: HangarSnapshot) -> String? {
        let trimmedCode = snapshot.referralStats.inviteCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedCode.isEmpty ? nil : trimmedCode
    }

    private var referralMetricAccessorySystemImage: String? {
        if isLoadingReferralInviteCode {
            return "arrow.clockwise"
        }

        return copiedReferralInviteCode ? "checkmark.circle.fill" : "doc.on.doc"
    }

    private var referralMetricAccessoryColor: Color {
        if copiedReferralInviteCode {
            return .green
        }

        return isLoadingReferralInviteCode ? .blue : .secondary
    }

    private var referralInviteCopyAction: (() -> Void)? {
        return {
            copyReferralInviteCode()
        }
    }

    private var profileDisplayName: String {
        let candidates = [
            appModel.session?.displayName,
            appModel.session?.credentials?.loginIdentifier,
            appModel.session?.email
        ]

        for candidate in candidates {
            if let trimmedCandidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmedCandidate.isEmpty {
                return trimmedCandidate
            }
        }

        return AppLocalizer.string("Citizen")
    }

    private var profileEmail: String? {
        let trimmedEmail = appModel.session?.email.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedEmail.isEmpty ? nil : trimmedEmail
    }

    private var accountTotalValueUSD: Decimal? {
        guard let storeCreditUSD = snapshot.metrics.storeCreditUSD else {
            return nil
        }

        return snapshot.metrics.totalCurrentValue + storeCreditUSD
    }

    private var accountTotalValueLabel: String {
        accountTotalValueUSD?.usdString ?? AppLocalizer.string("Unavailable")
    }

    private var accountTotalValueExplanation: String {
        let currentValueText = snapshot.metrics.totalCurrentValue.usdString
        let availableCreditText = snapshot.metrics.storeCreditUSD?.usdString ?? AppLocalizer.string("Unavailable")
        let totalValueText = accountTotalValueUSD?.usdString ?? AppLocalizer.string("Unavailable")

        return AppLocalizer.format(
            "Account Current Value = %@\nCombined MSRP of all ships + current value of all upgrades + combined value of the rest of the items in your hangar.\n\nAvailable Credit = %@\n\nAccount Total Value = %@ + %@ = %@",
            currentValueText,
            availableCreditText,
            currentValueText,
            availableCreditText,
            totalValueText
        )
    }

    private var conciergeLevel: ConciergeLevel? {
        ConciergeLevel(totalSpendUSD: snapshot.metrics.totalSpendUSD)
    }

    private var proBadgeKind: AccountProBadgeKind? {
        guard showsEarlyAccessBadge else {
            return nil
        }

        if appModel.subscriptionStore.hasLifetimePro {
            return .proPlus
        }

        return appModel.isPro ? .pro : nil
    }

    private var profileOrganizationSummary: String {
        if let organization = snapshot.primaryOrganization {
            return organization.summaryText
        }

        return snapshot.didRefreshPrimaryOrganization
            ? AppLocalizer.string("No Organization")
            : AppLocalizer.string("Organization unavailable")
    }

    private var profileAvatarURL: URL? {
        snapshot.avatarURL ?? appModel.session?.avatarURL
    }

    private var profileBackgroundOptions: [ProfileBackgroundShipOption] {
        var orderedKeys: [String] = []
        var groupedShips: [String: [FleetShip]] = [:]

        for ship in snapshot.fleet {
            let selectionKey = ProfileBackgroundShipOption.selectionKey(for: ship)
            if groupedShips[selectionKey] == nil {
                orderedKeys.append(selectionKey)
            }

            groupedShips[selectionKey, default: []].append(ship)
        }

        let options = orderedKeys.compactMap { selectionKey -> ProfileBackgroundShipOption? in
            guard let ships = groupedShips[selectionKey], !ships.isEmpty else {
                return nil
            }

            let representative = ships.max { lhs, rhs in
                profileBackgroundRepresentativePriority(lhs) < profileBackgroundRepresentativePriority(rhs)
            } ?? ships[0]

            let msrpUSD = ships.compactMap(\.msrpUSD).max { lhs, rhs in
                NSDecimalNumber(decimal: lhs).compare(NSDecimalNumber(decimal: rhs)) == .orderedAscending
            }
            let msrpLabel = msrpUSD == nil ? representative.msrpLabel : nil

            return ProfileBackgroundShipOption(
                selectionKey: selectionKey,
                displayName: representative.displayName,
                manufacturer: representative.manufacturer,
                quantity: ships.count,
                msrpUSD: msrpUSD,
                msrpLabel: msrpLabel,
                imageURL: representative.imageURL
            )
        }

        return options.sorted { lhs, rhs in
            switch (lhs.msrpUSD, rhs.msrpUSD) {
            case let (lhsMSRP?, rhsMSRP?):
                let comparison = NSDecimalNumber(decimal: lhsMSRP).compare(NSDecimalNumber(decimal: rhsMSRP))
                if comparison != .orderedSame {
                    return comparison == .orderedDescending
                }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }

            if lhs.manufacturer != rhs.manufacturer {
                return lhs.manufacturer.localizedCaseInsensitiveCompare(rhs.manufacturer) == .orderedAscending
            }

            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private var resolvedSelectedBackgroundSelectionKey: String? {
        guard let selectedBackgroundSelectionKey,
              profileBackgroundOptions.contains(where: { $0.selectionKey == selectedBackgroundSelectionKey }) else {
            return nil
        }

        return selectedBackgroundSelectionKey
    }

    private var automaticProfileBackgroundOption: ProfileBackgroundShipOption? {
        profileBackgroundOptions
            .filter { option in
                guard let msrpUSD = option.msrpUSD else {
                    return false
                }

                return NSDecimalNumber(decimal: msrpUSD).compare(NSDecimalNumber.zero) == .orderedDescending
            }
            .max { lhs, rhs in
                let lhsMSRP = lhs.msrpUSD ?? .zero
                let rhsMSRP = rhs.msrpUSD ?? .zero
                return NSDecimalNumber(decimal: lhsMSRP).compare(NSDecimalNumber(decimal: rhsMSRP)) == .orderedAscending
            }
    }

    private var profileBackgroundImageURL: URL? {
        if let selectedOption = profileBackgroundOptions.first(where: { $0.selectionKey == resolvedSelectedBackgroundSelectionKey }) {
            return selectedOption.imageURL
        }

        return automaticProfileBackgroundOption?.imageURL
    }

    private var backgroundSelectionStorageKey: String {
        let accountKey = appModel.session?.accountKey ?? snapshot.accountHandle
        return ProfileBackgroundSelectionPersistence.storageKey(for: accountKey)
    }

    private var backgroundSelectionLoadID: String {
        let optionSignature = profileBackgroundOptions
            .map(\.selectionKey)
            .joined(separator: "|")

        return "\(backgroundSelectionStorageKey)::\(optionSignature)"
    }

    private func loadSavedProfileBackgroundSelection() {
        let savedSelectionKey = ProfileBackgroundSelectionPersistence.loadSelectionKey(storageKey: backgroundSelectionStorageKey)

        guard let savedSelectionKey else {
            selectedBackgroundSelectionKey = nil
            return
        }

        if profileBackgroundOptions.contains(where: { $0.selectionKey == savedSelectionKey }) {
            selectedBackgroundSelectionKey = savedSelectionKey
            return
        }

        selectedBackgroundSelectionKey = nil
        ProfileBackgroundSelectionPersistence.saveSelectionKey(nil, storageKey: backgroundSelectionStorageKey)
    }

    private func updateProfileBackgroundSelection(_ selectionKey: String?) {
        selectedBackgroundSelectionKey = selectionKey
        ProfileBackgroundSelectionPersistence.saveSelectionKey(selectionKey, storageKey: backgroundSelectionStorageKey)
    }

    private func profileBackgroundRepresentativePriority(_ ship: FleetShip) -> Int {
        var score = 0

        if ship.imageURL != nil {
            score += 8
        }

        if let msrpUSD = ship.msrpUSD,
           NSDecimalNumber(decimal: msrpUSD).compare(NSDecimalNumber.zero) == .orderedDescending {
            score += 4
        }

        if !ship.roleCategories.isEmpty {
            score += 2
        }

        if ship.manufacturer.localizedCaseInsensitiveCompare("Unknown") != .orderedSame {
            score += 1
        }

        return score
    }
}

private struct ConciergeLevel: Hashable {
    let title: String
    let minimumSpendUSD: Decimal
    let upperBoundSpendUSD: Decimal?
    let backgroundColor: Color
    let textColor: Color

    static let allLevels: [ConciergeLevel] = [
        ConciergeLevel(
            title: "High Admiral",
            minimumSpendUSD: 1000,
            upperBoundSpendUSD: 2500,
            backgroundColor: Color(red: 0.11, green: 0.32, blue: 0.56).opacity(0.30),
            textColor: Color(red: 0.77, green: 0.89, blue: 1.0)
        ),
        ConciergeLevel(
            title: "Grand Admiral",
            minimumSpendUSD: 2500,
            upperBoundSpendUSD: 5000,
            backgroundColor: Color(red: 0.23, green: 0.19, blue: 0.50).opacity(0.30),
            textColor: Color(red: 0.88, green: 0.84, blue: 1.0)
        ),
        ConciergeLevel(
            title: "Space Marshal",
            minimumSpendUSD: 5000,
            upperBoundSpendUSD: 10000,
            backgroundColor: Color(red: 0.07, green: 0.38, blue: 0.34).opacity(0.28),
            textColor: Color(red: 0.78, green: 0.97, blue: 0.88)
        ),
        ConciergeLevel(
            title: "Wing Commander",
            minimumSpendUSD: 10000,
            upperBoundSpendUSD: 15000,
            backgroundColor: Color(red: 0.42, green: 0.12, blue: 0.18).opacity(0.30),
            textColor: Color(red: 1.0, green: 0.84, blue: 0.78)
        ),
        ConciergeLevel(
            title: "Praetorian",
            minimumSpendUSD: 15000,
            upperBoundSpendUSD: 25000,
            backgroundColor: Color(red: 0.48, green: 0.28, blue: 0.08).opacity(0.30),
            textColor: Color(red: 1.0, green: 0.90, blue: 0.66)
        ),
        ConciergeLevel(
            title: "Legatus Navium",
            minimumSpendUSD: 25000,
            upperBoundSpendUSD: nil,
            backgroundColor: Color.black.opacity(0.46),
            textColor: Color(red: 0.92, green: 0.78, blue: 0.32)
        )
    ]

    init?(totalSpendUSD: Decimal?) {
        guard let totalSpendUSD else {
            return nil
        }

        guard let level = ConciergeLevel.allLevels.last(where: { level in
            NSDecimalNumber(decimal: totalSpendUSD).compare(NSDecimalNumber(decimal: level.minimumSpendUSD)) != .orderedAscending
        }) else {
            return nil
        }

        self = level
    }

    private init(
        title: String,
        minimumSpendUSD: Decimal,
        upperBoundSpendUSD: Decimal?,
        backgroundColor: Color,
        textColor: Color
    ) {
        self.title = title
        self.minimumSpendUSD = minimumSpendUSD
        self.upperBoundSpendUSD = upperBoundSpendUSD
        self.backgroundColor = backgroundColor
        self.textColor = textColor
    }

    var requirementSummary: String {
        if upperBoundSpendUSD == nil {
            return AppLocalizer.format("Requires %@+ total spend", minimumSpendUSD.usdString)
        }

        return AppLocalizer.format("Requires %@ total spend", minimumSpendUSD.usdString)
    }

    func isUnlocked(totalSpendUSD: Decimal?) -> Bool {
        guard let totalSpendUSD else {
            return false
        }

        return NSDecimalNumber(decimal: totalSpendUSD).compare(NSDecimalNumber(decimal: minimumSpendUSD)) != .orderedAscending
    }
}

private struct MetricCard: View {
    let title: LocalizedStringKey
    let primaryValue: String
    let secondaryValue: String
    let accessorySystemImage: String?
    let accessoryColor: Color
    let longPressAction: (() -> Void)?
    let accessibilityActionName: String?

    init(
        title: LocalizedStringKey,
        primaryValue: String,
        secondaryValue: String,
        accessorySystemImage: String? = nil,
        accessoryColor: Color = .secondary,
        longPressAction: (() -> Void)? = nil,
        accessibilityActionName: String? = nil
    ) {
        self.title = title
        self.primaryValue = primaryValue
        self.secondaryValue = secondaryValue
        self.accessorySystemImage = accessorySystemImage
        self.accessoryColor = accessoryColor
        self.longPressAction = longPressAction
        self.accessibilityActionName = accessibilityActionName
    }

    var body: some View {
        if let longPressAction {
            cardContent
                .contentShape(cardShape)
                .onLongPressGesture(minimumDuration: 0.45, perform: longPressAction)
                .accessibilityAction(named: Text(accessibilityActionName ?? "Copy")) {
                    longPressAction()
                }
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if let accessorySystemImage {
                    Image(systemName: accessorySystemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accessoryColor)
                        .frame(width: 16, height: 16)
                }
            }

            Text(primaryValue)
                .font(.headline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(secondaryValue)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }
}

private struct SensitiveOverviewFieldRow: View {
    let title: LocalizedStringKey
    let value: String?
    @Binding var isVisible: Bool
    let hiddenText: LocalizedStringKey
    let emptyText: LocalizedStringKey

    private var trimmedValue: String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        LabeledContent {
            if let trimmedValue {
                Button {
                    isVisible.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isVisible ? "eye.fill" : "eye.slash.fill")
                            .font(.caption.weight(.semibold))

                        if isVisible {
                            Text(trimmedValue)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(hiddenText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text(title)
        }
    }
}

private struct AccountProfileCard: View {
    let displayName: String
    let organizationSummary: String
    let totalValueLabel: String
    let conciergeLevel: ConciergeLevel?
    let proBadgeKind: AccountProBadgeKind?
    let avatarURL: URL?
    let backgroundImageURL: URL?
    let reloadToken: UUID?
    let onExplainTotalValue: () -> Void
    let onShowConciergeLevels: () -> Void
    let onChangeBackground: (() -> Void)?

    private let cardShape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    var body: some View {
        ZStack(alignment: .topLeading) {
            cardShape
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.32, blue: 0.46),
                            Color(red: 0.07, green: 0.16, blue: 0.26)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    if let backgroundImageURL {
                        CachedRemoteImage(url: backgroundImageURL, reloadToken: reloadToken) { phase in
                            switch phase {
                            case let .success(image):
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .clipped()
                            case .empty, .failure:
                                profileCardFallbackDecoration
                            }
                        }
                    } else {
                        profileCardFallbackDecoration
                    }
                }
                .overlay {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.84),
                            Color.black.opacity(0.72),
                            Color.black.opacity(0.4),
                            Color(red: 0.05, green: 0.12, blue: 0.2).opacity(0.22),
                            Color(red: 0.05, green: 0.12, blue: 0.2).opacity(0.08)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .overlay(alignment: .topTrailing) {
                    if let onChangeBackground {
                        ProfileCardActionButton(
                            systemName: "photo.on.rectangle.angled",
                            action: onChangeBackground
                        )
                        .padding(.top, 16)
                        .padding(.trailing, 16)
                    }
                }
                .clipShape(cardShape)

            VStack(alignment: .leading, spacing: 10) {
                Spacer(minLength: 52)

                HStack(alignment: .bottom, spacing: 8) {
                    Text(displayName)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    if let proBadgeKind {
                        AccountProBadge(kind: proBadgeKind)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                }

                Text(organizationSummary)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.76))
                    .lineLimit(2)

                AccountTotalValueTag(
                    totalValueLabel: totalValueLabel,
                    onExplain: onExplainTotalValue
                )
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .bottomLeading)
            .padding(18)
        }
        .overlay(alignment: .topLeading) {
            ProfileAvatarView(
                avatarURL: avatarURL,
                displayName: displayName,
                reloadToken: reloadToken
            )
            .offset(x: 18, y: -18)
        }
        .overlay {
            cardShape
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            if let conciergeLevel {
                Button(action: onShowConciergeLevels) {
                    ConciergeLevelTag(level: conciergeLevel)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 18)
                .padding(.bottom, 18)
            }
        }
        .padding(.top, 18)
        .padding(.vertical, 4)
    }

    private var profileCardFallbackDecoration: some View {
        Circle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 140, height: 140)
            .offset(x: 36, y: 46)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

private enum AccountProBadgeKind {
    case pro
    case proPlus

    var accessibilityLabel: String {
        switch self {
        case .pro:
            return AppLocalizer.string("Early Access account")
        case .proPlus:
            return AppLocalizer.string("Lifetime Early Access account")
        }
    }
}

private struct AccountProBadge: View {
    let kind: AccountProBadgeKind

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            VStack(alignment: .leading, spacing: -1) {
                Text(verbatim: "Early")
                Text(verbatim: "Access")
            }
            .font(.system(size: 8.5, weight: .heavy, design: .rounded))
            .lineLimit(1)

            if kind == .proPlus {
                Text("+")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .baselineOffset(0.5)
            }
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundGradient)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(borderGradient, lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: 8, y: 3)
            .accessibilityLabel(kind.accessibilityLabel)
    }

    private var textColor: Color {
        switch kind {
        case .pro:
            return Color(red: 0.96, green: 0.94, blue: 0.86)
        case .proPlus:
            return Color(red: 0.92, green: 0.78, blue: 0.32)
        }
    }

    private var backgroundGradient: LinearGradient {
        switch kind {
        case .pro:
            return LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.18, blue: 0.22).opacity(0.96),
                    Color(red: 0.38, green: 0.36, blue: 0.29).opacity(0.9)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .proPlus:
            return LinearGradient(
                colors: [
                    Color.black.opacity(0.72),
                    Color.black.opacity(0.46)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var borderGradient: LinearGradient {
        switch kind {
        case .pro:
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.34),
                    Color(red: 0.95, green: 0.78, blue: 0.38).opacity(0.24)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .proPlus:
            return LinearGradient(
                colors: [
                    Color(red: 0.92, green: 0.78, blue: 0.32).opacity(0.42),
                    Color(red: 0.92, green: 0.78, blue: 0.32).opacity(0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var shadowColor: Color {
        switch kind {
        case .pro:
            return Color.black.opacity(0.24)
        case .proPlus:
            return Color.black.opacity(0.32)
        }
    }
}

private struct AccountTotalValueTag: View {
    let totalValueLabel: String
    let onExplain: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(totalValueLabel)
                .font(.caption.weight(.medium))
                .lineLimit(1)

            Button(action: onExplain) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Explain account total value")
        }
        .foregroundStyle(Color.white.opacity(0.88))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct ConciergeLevelTag: View {
    let level: ConciergeLevel

    var body: some View {
        Text(level.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(level.textColor)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(level.backgroundColor)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(level.textColor.opacity(0.16), lineWidth: 1)
            )
    }
}

private struct ConciergeLevelsSheetView: View {
    let currentLevel: ConciergeLevel?
    let totalSpendUSD: Decimal?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Current Spend", value: totalSpendUSD?.usdString ?? "Unavailable")
                    LabeledContent("Current Tier", value: currentLevel?.title ?? "Below Concierge")
                }

                Section("Concierge Tiers") {
                    ForEach(ConciergeLevel.allLevels, id: \.title) { level in
                        ConciergeLevelRequirementRow(
                            level: level,
                            isCurrent: currentLevel?.title == level.title,
                            isUnlocked: level.isUnlocked(totalSpendUSD: totalSpendUSD)
                        )
                    }
                }
            }
            .navigationTitle("Concierge Levels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct ConciergeLevelRequirementRow: View {
    let level: ConciergeLevel
    let isCurrent: Bool
    let isUnlocked: Bool

    var body: some View {
        HStack(spacing: 12) {
            ConciergeLevelTag(level: level)

            VStack(alignment: .leading, spacing: 4) {
                Text(level.requirementSummary)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                Text(isCurrent ? "Current tier" : (isUnlocked ? "Unlocked" : "Not reached yet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ProfileCardActionButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.22))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Change profile background")
    }
}

private struct ProfileAvatarView: View {
    let avatarURL: URL?
    let displayName: String
    let reloadToken: UUID?

    private let size: CGFloat = 84

    var body: some View {
        Group {
            if let avatarURL {
                CachedRemoteImage(
                    url: avatarURL,
                    targetSize: CGSize(width: size, height: size),
                    reloadToken: reloadToken
                ) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure, .empty:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.42), lineWidth: 2)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 14, y: 10)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.9),
                        Color(red: 0.16, green: 0.48, blue: 0.78)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Text(initials)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
            }
    }

    private var initials: String {
        let words = displayName
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }

        if words.isEmpty {
            return "HE"
        }

        return words
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }
}

private struct ProfileBackgroundShipOption: Identifiable, Hashable {
    let selectionKey: String
    let displayName: String
    let manufacturer: String
    let quantity: Int
    let msrpUSD: Decimal?
    let msrpLabel: String?
    let imageURL: URL?

    var id: String {
        selectionKey
    }

    var subtitle: String {
        if quantity > 1 {
            return AppLocalizer.format("%@ • Owned %lld", manufacturer, quantity)
        }

        return manufacturer
    }

    var pricingSummary: String {
        if let msrpUSD {
            return AppLocalizer.format("MSRP %@", msrpUSD.usdString)
        }

        if let msrpLabel = msrpLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !msrpLabel.isEmpty {
            return msrpLabel
        }

        return AppLocalizer.string("MSRP unavailable")
    }

    static func selectionKey(for ship: FleetShip) -> String {
        [
            ship.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase,
            ship.displayName.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        ]
        .joined(separator: "|")
    }
}

private enum ProfileBackgroundSelectionPersistence {
    private static let keyPrefix = "account.profile.background.selection"

    static func storageKey(for accountKey: String) -> String {
        let normalizedAccountKey = accountKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase

        return "\(keyPrefix).\(normalizedAccountKey)"
    }

    static func loadSelectionKey(storageKey: String) -> String? {
        UserDefaults.standard.string(forKey: storageKey)
    }

    static func saveSelectionKey(_ selectionKey: String?, storageKey: String) {
        if let selectionKey {
            UserDefaults.standard.set(selectionKey, forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }
}

private struct LimitedShipAccessPrompt: Identifiable {
    let id = UUID()
}

private struct LimitedShipAccessCodePromptView: View {
    let account: UserSession?
    let onGranted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var accessCode = ""
    @State private var validationMessage: String?
    @State private var grantedEntitlement: LimitedShipAccessEntitlement?
    @State private var isRedeeming = false
    @State private var deviceID = LimitedShipAccessDeviceIdentity.currentID()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("Invite Only", systemImage: "lock.shield")
                            .font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Limited Ship Purchase is restricted while this alpha feature is being tested. Enter a lifetime or 24-hour access code to continue.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)

                        LimitedShipAccessWarningLabel()

                        VStack(alignment: .leading, spacing: 8) {
                            Label("Device ID", systemImage: "iphone.gen3")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(deviceID)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(.secondarySystemGroupedBackground))
                                )
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Access Code")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            TextField("HXLS1...", text: $accessCode, axis: .vertical)
                                .lineLimit(4...8)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .disabled(isRedeeming || grantedEntitlement != nil)
                        }

                        if let grantedEntitlement {
                            Label(grantedSummary(for: grantedEntitlement), systemImage: "checkmark.seal.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        } else if let validationMessage {
                            Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)

                Button {
                    redeemAccessCode()
                } label: {
                    HStack(spacing: 10) {
                        if isRedeeming {
                            ProgressView()
                        } else {
                            Image(systemName: "key.fill")
                        }

                        Text(isRedeeming ? "Verifying..." : "Unlock Limited Ship Purchase")
                            .fontWeight(.semibold)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(normalizedAccessCode.isEmpty || isRedeeming || grantedEntitlement != nil)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .background(.regularMaterial)
            }
            .navigationTitle("Access Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isRedeemingOrGranted)
                }
            }
            .onChange(of: accessCode) { _, _ in
                if validationMessage != nil {
                    validationMessage = nil
                }
            }
        }
    }

    private var normalizedAccessCode: String {
        accessCode
            .split(whereSeparator: \.isWhitespace)
            .joined()
    }

    private var isRedeemingOrGranted: Bool {
        isRedeeming || grantedEntitlement != nil
    }

    private func redeemAccessCode() {
        let code = normalizedAccessCode
        guard !code.isEmpty else {
            return
        }

        Task { @MainActor in
            isRedeeming = true
            validationMessage = nil

            do {
                let entitlement = try await LimitedShipAccessManager.shared.redeem(
                    code: code,
                    account: account
                )

                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    grantedEntitlement = entitlement
                }

                try? await Task.sleep(nanoseconds: 650_000_000)
                isRedeeming = false
                dismiss()
                onGranted()
            } catch {
                isRedeeming = false
                validationMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func grantedSummary(for entitlement: LimitedShipAccessEntitlement) -> String {
        switch entitlement.kind {
        case .lifetime:
            return "Lifetime access unlocked."
        case .timed24h:
            if let expiresAt = entitlement.expiresAt {
                return "24-hour access active until \(expiresAt.formatted(date: .abbreviated, time: .shortened))."
            }

            return "24-hour access unlocked."
        }
    }
}

private struct LimitedShipAccessWarningLabel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Experimental Feature Notice", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            Text("This alpha automation may interact with RSI checkout in ways that could result in account review, restriction, suspension, purchase errors, loss of access, or other consequences. Use is entirely at your own risk. The author and contributors assume no liability for any damage, account action, loss, purchase issue, or other outcome arising from use of this feature. By continuing, you acknowledge and accept full responsibility for all risks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.28), lineWidth: 1)
        }
    }
}

private struct LimitedShipAccessCheckingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            HStack(spacing: 12) {
                ProgressView()
                Text("Checking access...")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct LimitedShipPurchaseView: View {
    let appModel: AppModel
    let snapshot: HangarSnapshot
    let reloadToken: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var loadState: LimitedShipPurchaseLoadState = .idle
    @State private var now = Date()
    @State private var pendingConfirmation: LimitedShipPurchaseConfirmation?
    @State private var alert: LimitedShipPurchaseAlert?
    @State private var operation: LimitedShipPurchaseOperation?
    @State private var checkoutContext: RSICheckoutContext?
    @State private var purchaseSuccess: LimitedShipPurchaseSuccess?
    @State private var purchaseTask: Task<Void, Never>?
    @State private var accessEntitlement: LimitedShipAccessEntitlement?

    var body: some View {
        NavigationStack {
            Group {
                switch loadState {
                case .idle, .loading:
                    LimitedShipLoadingView()
                case let .loaded(ships):
                    if ships.isEmpty {
                        ContentUnavailableView(
                            "No Limited Ships",
                            systemImage: "cart.badge.questionmark",
                            description: Text("No limited ship sale data is available yet.")
                        )
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                LimitedShipAccessValidityCard(
                                    entitlement: accessEntitlement,
                                    now: now
                                )

                                Text("What ship do you want to buy?")
                                    .font(.title3.weight(.semibold))
                                    .padding(.horizontal, 4)

                                ForEach(ships) { ship in
                                    VStack(spacing: 8) {
                                        LimitedShipHeroCard(
                                            ship: ship,
                                            now: now,
                                            reloadToken: reloadToken,
                                            isDisabled: isOperationActive
                                        ) {
                                            prepare(ship)
                                        }

                                        Button {
                                            openShipPage(ship)
                                        } label: {
                                            Label("Open Browser", systemImage: "safari")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.large)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, operation == nil ? 24 : 340)
                        }
                    }
                case let .failed(message):
                    LimitedShipErrorView(message: message) {
                        Task {
                            await loadShips(force: true)
                        }
                    }
                }
            }
            .navigationTitle("Limited Ship Purchase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Refresh") {
                        Task {
                            await refreshAccessEntitlement()
                            await loadShips(force: true)
                        }
                    }
                    .disabled(isLoading || isOperationActive)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let operation {
                    LimitedShipOperationPanel(
                        operation: operation,
                        now: now,
                        onCancel: cancelOperation,
                        onOpenCheckout: openCheckout,
                        onDismiss: {
                            self.operation = nil
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial)
                }
            }
            .overlay {
                if let purchaseSuccess {
                    LimitedShipPurchaseSuccessOverlay(success: purchaseSuccess) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                            self.purchaseSuccess = nil
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.88).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .zIndex(10)
                }
            }
            .confirmationDialog(
                "Start Limited Ship Watch?",
                isPresented: Binding(
                    get: { pendingConfirmation != nil },
                    set: { isPresented in
                        if !isPresented {
                            pendingConfirmation = nil
                        }
                    }
                ),
                titleVisibility: .visible,
                presenting: pendingConfirmation
            ) { confirmation in
                Button("Start Cart Watch") {
                    startCartWatch(ship: confirmation.ship, slot: confirmation.slot)
                }

                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(
                    "Hangar Express will wait until one second before \(confirmation.ship.name)'s slot, then watch for an enabled Add to Cart button and click it once. Open checkout afterward to apply store credit and finish the RSI order."
                )
            }
            .alert(item: $alert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .sheet(item: $checkoutContext) { context in
                RSICheckoutBrowserView(
                    context: context,
                    onCancel: { cookies in
                        checkoutContext = nil
                        persistLimitedShipCheckoutCookies(cookies)
                    },
                    onFinished: { cookies in
                        checkoutContext = nil
                        persistLimitedShipCheckoutCookies(cookies)
                    },
                    onSucceeded: { cookies, confirmationURL in
                        checkoutContext = nil
                        handleCheckoutSucceeded(cookies: cookies, confirmationURL: confirmationURL)
                    }
                )
            }
            .task {
                await loadShips(force: false)
            }
            .task {
                await refreshAccessEntitlement()
            }
            .task {
                while !Task.isCancelled {
                    now = Date()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            .onDisappear {
                purchaseTask?.cancel()
            }
        }
    }

    private func refreshAccessEntitlement() async {
        accessEntitlement = await LimitedShipAccessManager.shared.currentEntitlement(account: appModel.session)
    }

    private var isLoading: Bool {
        if case .loading = loadState {
            return true
        }

        return false
    }

    private var isOperationActive: Bool {
        guard let operation else {
            return false
        }

        return operation.phase == .waiting || operation.phase == .adding
    }

    private func loadShips(force: Bool) async {
        if !force,
           case .loaded = loadState {
            return
        }

        loadState = .loading

        do {
            let ships = try await appModel.fetchLimitedShipSales()
            loadState = .loaded(ships)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func prepare(_ ship: LimitedShipSale) {
        guard !isOperationActive else {
            return
        }

        guard let storeCreditUSD = snapshot.metrics.storeCreditUSD else {
            alert = LimitedShipPurchaseAlert(
                title: "Credit Unavailable",
                message: "Refresh Account before starting a limited ship cart watch."
            )
            return
        }

        guard storeCreditUSD.isGreaterThanOrEqual(to: ship.priceUSD) else {
            let missingCredit = ship.priceUSD - storeCreditUSD
            alert = LimitedShipPurchaseAlert(
                title: "Not Enough Store Credit",
                message: "\(ship.name) costs \(ship.priceText). You are missing \(missingCredit.usdString)."
            )
            return
        }

        let currentDate = Date()
        guard let slot = ship.bestAvailabilitySlot(at: currentDate),
              slot.endsAt >= currentDate else {
            alert = LimitedShipPurchaseAlert(
                title: "No Upcoming Slot",
                message: "\(ship.name) does not have an upcoming dummy availability slot."
            )
            return
        }

        pendingConfirmation = LimitedShipPurchaseConfirmation(ship: ship, slot: slot)
    }

    private func startCartWatch(ship: LimitedShipSale, slot: LimitedShipAvailabilitySlot) {
        pendingConfirmation = nil
        purchaseTask?.cancel()

        let currentDate = Date()
        let fireDate = slot.fireDate(at: currentDate)
        let initialLogs = [
            Self.timestampedLog("Selected \(ship.name) at \(ship.priceText)."),
            Self.timestampedLog(
                "Availability slot: \(slot.startsAt.formatted(date: .abbreviated, time: .standard)) - \(slot.endsAt.formatted(date: .abbreviated, time: .standard))."
            ),
            Self.timestampedLog(
                fireDate > currentDate
                    ? "Watch armed. Add to Cart will start at \(fireDate.formatted(date: .abbreviated, time: .standard))."
                    : "Slot is active. Add to Cart will start immediately."
            )
        ]
        operation = LimitedShipPurchaseOperation(
            phase: fireDate > currentDate ? .waiting : .adding,
            shipName: ship.name,
            storeCreditAmountUSD: ship.priceUSD,
            detail: fireDate > currentDate
                ? "Waiting until \(fireDate.formatted(date: .omitted, time: .standard))"
                : "Waiting for an enabled Add to Cart button",
            fireDate: fireDate > currentDate ? fireDate : nil,
            cartURL: nil,
            attemptCount: nil,
            checkoutCookies: nil,
            logs: initialLogs
        )

        purchaseTask = Task {
            let delay = max(0, fireDate.timeIntervalSinceNow)
            if delay > 0 {
                let nanoseconds = UInt64(min(delay, 24 * 60 * 60) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                appendOperationLog("Reached fire time. Watching for an enabled Add to Cart button.")
                replaceOperation(
                    phase: .adding,
                    detail: "Watching for an enabled Add to Cart button",
                    fireDate: nil,
                    cartURL: nil,
                    attemptCount: nil
                )
            }

            do {
                let result = try await appModel.addLimitedShipToCart(ship) { message in
                    appendOperationLog(message)
                }
                guard !Task.isCancelled else {
                    return
                }

                await MainActor.run {
                    appendOperationLogs(result.debugLog)
                    appendOperationLog(result.debugSummary ?? "RSI confirmed the cart update.")
                    purchaseTask = nil
                    replaceOperation(
                        phase: .succeeded,
                        detail: result.debugSummary ?? "RSI confirmed the cart update.",
                        fireDate: nil,
                        cartURL: result.cartURL,
                        attemptCount: result.attemptCount,
                        checkoutCookies: result.updatedCookies.isEmpty ? appModel.session?.cookies : result.updatedCookies
                    )
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                await MainActor.run {
                    purchaseTask = nil
                    appendOperationLog("Add to Cart failed: \(error.localizedDescription)")
                    replaceOperation(
                        phase: .failed,
                        detail: error.localizedDescription,
                        fireDate: nil,
                        cartURL: nil,
                        attemptCount: nil,
                        checkoutCookies: nil
                    )
                    alert = LimitedShipPurchaseAlert(
                        title: "Add to Cart Failed",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func cancelOperation() {
        purchaseTask?.cancel()
        purchaseTask = nil
        operation = nil
    }

    private func openCheckout(_ cartURL: URL) {
        let shipName = operation?.shipName ?? "Limited Ship"
        let cookies = operation?.checkoutCookies ?? appModel.session?.cookies ?? []
        checkoutContext = RSICheckoutContext(
            itemTitle: shipName,
            checkoutURL: cartURL,
            cookies: cookies,
            navigationTitle: "RSI Checkout",
            automation: operation.map {
                RSICheckoutAutomation(storeCreditAmount: $0.storeCreditAmountUSD)
            }
        )
    }

    private func openShipPage(_ ship: LimitedShipSale) {
        let cookies = operation?.checkoutCookies ?? appModel.session?.cookies ?? []
        checkoutContext = RSICheckoutContext(
            itemTitle: ship.name,
            checkoutURL: ship.storeURL,
            cookies: cookies,
            navigationTitle: ship.name,
            completionButtonTitle: "Done"
        )
    }

    private func persistLimitedShipCheckoutCookies(_ cookies: [SessionCookie]) {
        Task {
            await appModel.persistBrowserCookies(cookies)
        }
    }

    private func handleCheckoutSucceeded(cookies: [SessionCookie], confirmationURL: URL?) {
        let shipName = operation?.shipName ?? checkoutContext?.itemTitle ?? "Limited Ship"
        persistLimitedShipCheckoutCookies(cookies)
        appendOperationLog(
            confirmationURL.map { "RSI checkout confirmation reached: \($0.absoluteString)" }
                ?? "RSI checkout confirmation reached."
        )
        replaceOperation(
            phase: .purchased,
            detail: "RSI confirmed the order. Check your hangar for delivery.",
            fireDate: nil,
            cartURL: nil,
            attemptCount: operation?.attemptCount,
            checkoutCookies: cookies
        )

        withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
            purchaseSuccess = LimitedShipPurchaseSuccess(
                shipName: shipName,
                confirmationURL: confirmationURL
            )
        }

        Task {
            await appModel.refresh(scope: .full)
        }
    }

    private func replaceOperation(
        phase: LimitedShipPurchaseOperation.Phase,
        detail: String,
        fireDate: Date?,
        cartURL: URL?,
        attemptCount: Int?,
        checkoutCookies: [SessionCookie]? = nil
    ) {
        guard let operation else {
            return
        }

        self.operation = LimitedShipPurchaseOperation(
            phase: phase,
            shipName: operation.shipName,
            storeCreditAmountUSD: operation.storeCreditAmountUSD,
            detail: detail,
            fireDate: fireDate,
            cartURL: cartURL,
            attemptCount: attemptCount,
            checkoutCookies: checkoutCookies ?? operation.checkoutCookies,
            logs: operation.logs
        )
    }

    private func appendOperationLog(_ message: String) {
        let line = Self.normalizedLogLine(message)
        guard let operation,
              !operation.logs.contains(line) else {
            return
        }

        self.operation = operation.appendingLog(line)
    }

    private func appendOperationLogs(_ messages: [String]) {
        for message in messages {
            appendOperationLog(message)
        }
    }

    private static func normalizedLogLine(_ message: String) -> String {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            return timestampedLog("Empty log message")
        }

        if trimmedMessage.hasPrefix("[") {
            return trimmedMessage
        }

        return timestampedLog(trimmedMessage)
    }

    private static func timestampedLog(_ message: String) -> String {
        "[\(Date().formatted(date: .omitted, time: .standard))] \(message)"
    }
}

private enum LimitedShipPurchaseLoadState {
    case idle
    case loading
    case loaded([LimitedShipSale])
    case failed(String)
}

private struct LimitedShipPurchaseConfirmation {
    let ship: LimitedShipSale
    let slot: LimitedShipAvailabilitySlot
}

private struct LimitedShipPurchaseAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct LimitedShipPurchaseSuccess: Identifiable, Equatable {
    let id = UUID()
    let shipName: String
    let confirmationURL: URL?
}

private struct LimitedShipPurchaseOperation: Equatable {
    enum Phase: Equatable {
        case waiting
        case adding
        case succeeded
        case purchased
        case failed
    }

    let phase: Phase
    let shipName: String
    let storeCreditAmountUSD: Decimal
    let detail: String
    let fireDate: Date?
    let cartURL: URL?
    let attemptCount: Int?
    let checkoutCookies: [SessionCookie]?
    let logs: [String]

    func appendingLog(_ line: String) -> LimitedShipPurchaseOperation {
        LimitedShipPurchaseOperation(
            phase: phase,
            shipName: shipName,
            storeCreditAmountUSD: storeCreditAmountUSD,
            detail: detail,
            fireDate: fireDate,
            cartURL: cartURL,
            attemptCount: attemptCount,
            checkoutCookies: checkoutCookies,
            logs: logs + [line]
        )
    }
}

private struct LimitedShipPurchaseSuccessOverlay: View {
    let success: LimitedShipPurchaseSuccess
    let onDismiss: () -> Void

    @State private var animate = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            ZStack {
                ForEach(0..<24, id: \.self) { index in
                    SuccessSpark(index: index, animate: animate)
                }

                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .stroke(
                                AngularGradient(
                                    colors: [.cyan, .blue, .purple, .cyan],
                                    center: .center
                                ),
                                lineWidth: 3
                            )
                            .frame(width: 128, height: 128)
                            .rotationEffect(.degrees(animate ? 360 : 0))
                            .scaleEffect(animate ? 1.08 : 0.76)
                            .opacity(animate ? 0.9 : 0.2)

                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 102, height: 102)
                            .overlay {
                                Circle()
                                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
                            }

                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 58, weight: .bold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .cyan)
                            .scaleEffect(animate ? 1 : 0.35)
                            .rotationEffect(.degrees(animate ? 0 : -18))
                    }

                    VStack(spacing: 8) {
                        Text("ORDER SECURED")
                            .font(.system(.title2, design: .rounded, weight: .black))
                            .tracking(1.8)

                        Text(success.shipName)
                            .font(.title.weight(.heavy))
                            .multilineTextAlignment(.center)

                        Text("RSI confirmed the checkout. The pledge is now headed to your hangar.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }

                    Button(action: onDismiss) {
                        Label("Continue", systemImage: "arrow.right.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.cyan)
                }
                .padding(24)
                .frame(maxWidth: 360)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.5),
                                    Color.cyan.opacity(0.45),
                                    Color.purple.opacity(0.28)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                }
                .shadow(color: .cyan.opacity(animate ? 0.45 : 0.1), radius: animate ? 34 : 8)
                .scaleEffect(animate ? 1 : 0.86)
                .opacity(animate ? 1 : 0)
            }
            .padding(24)
        }
        .onAppear {
            withAnimation(.spring(response: 0.62, dampingFraction: 0.72)) {
                animate = true
            }
        }
    }
}

private struct SuccessSpark: View {
    let index: Int
    let animate: Bool

    var body: some View {
        Image(systemName: index.isMultiple(of: 3) ? "sparkle" : "star.fill")
            .font(.system(size: CGFloat(8 + (index % 4) * 3), weight: .bold))
            .foregroundStyle(index.isMultiple(of: 2) ? Color.cyan : Color.purple)
            .opacity(animate ? 0.95 : 0)
            .scaleEffect(animate ? 1 : 0.2)
            .offset(
                x: cos(angle) * radius,
                y: sin(angle) * radius
            )
            .rotationEffect(.degrees(animate ? Double(index * 37 + 180) : Double(index * 11)))
            .animation(
                .easeInOut(duration: 1.35 + Double(index % 5) * 0.12)
                    .repeatForever(autoreverses: true)
                    .delay(Double(index) * 0.035),
                value: animate
            )
    }

    private var angle: CGFloat {
        CGFloat(index) / 24 * .pi * 2
    }

    private var radius: CGFloat {
        CGFloat(122 + (index % 5) * 22)
    }
}

private struct LimitedShipLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Loading limited ship sale data...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LimitedShipErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Unable to Load Limited Ships", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}

private struct LimitedShipAccessValidityCard: View {
    let entitlement: LimitedShipAccessEntitlement?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Access Validity")
                        .font(.headline)

                    Text(primaryText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(secondaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if let entitlement {
                HStack(spacing: 8) {
                    validityChip(icon: "envelope", text: emailScope(for: entitlement))
                    validityChip(icon: "iphone.gen3", text: "Device-bound")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(statusColor.opacity(0.26), lineWidth: 1)
        }
    }

    private var statusIcon: String {
        guard let entitlement else {
            return "hourglass"
        }

        if entitlement.kind == .timed24h,
           let expiresAt = entitlement.expiresAt,
           expiresAt <= now {
            return "exclamationmark.triangle.fill"
        }

        return "checkmark.shield.fill"
    }

    private var statusColor: Color {
        guard let entitlement else {
            return .secondary
        }

        if entitlement.kind == .timed24h,
           let expiresAt = entitlement.expiresAt,
           expiresAt <= now {
            return .orange
        }

        return .green
    }

    private var primaryText: String {
        guard let entitlement else {
            return "Checking access..."
        }

        switch entitlement.kind {
        case .lifetime:
            return "Lifetime access active"
        case .timed24h:
            guard let expiresAt = entitlement.expiresAt else {
                return "24-hour access active"
            }

            if expiresAt <= now {
                return "24-hour access expired"
            }

            return "24-hour access active"
        }
    }

    private var secondaryText: String {
        guard let entitlement else {
            return "The app is verifying the signed access entitlement for this device."
        }

        switch entitlement.kind {
        case .lifetime:
            return "This invite does not expire while it remains valid for this install."
        case .timed24h:
            guard let expiresAt = entitlement.expiresAt else {
                return "This invite is time-limited for this install."
            }

            if expiresAt <= now {
                return "Expired at \(expiresAt.formatted(date: .abbreviated, time: .shortened))."
            }

            return "Expires \(expiresAt.formatted(date: .abbreviated, time: .shortened)). \(Self.remainingText(from: now, to: expiresAt)) remaining."
        }
    }

    private func emailScope(for entitlement: LimitedShipAccessEntitlement) -> String {
        guard let audience = entitlement.audience?.trimmingCharacters(in: .whitespacesAndNewlines),
              !audience.isEmpty else {
            return "Any email"
        }

        return audience
    }

    private func validityChip(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(.tertiarySystemGroupedBackground))
            )
    }

    private static func remainingText(from now: Date, to expiresAt: Date) -> String {
        let remainingSeconds = max(0, Int(expiresAt.timeIntervalSince(now).rounded(.down)))
        let hours = remainingSeconds / 3600
        let minutes = (remainingSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
    }
}

private struct LimitedShipHeroCard: View {
    let ship: LimitedShipSale
    let now: Date
    let reloadToken: UUID?
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    heroCardBase(size: proxy.size)

                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Standalone Ships", systemImage: "shippingbox.fill")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.white.opacity(0.78))

                            Text(ship.name)
                                .font(.title.weight(.heavy))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .minimumScaleFactor(0.72)

                            Text(ship.manufacturer)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.white.opacity(0.76))
                        }
                        .padding(.trailing, 148)

                        Spacer(minLength: 12)

                        HStack(alignment: .bottom, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(ship.priceText)
                                    .font(.title3.weight(.heavy))
                                    .foregroundStyle(.white)

                                Text(availabilitySummary)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.white.opacity(0.74))
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 0)

                            Label("ADD TO CART", systemImage: "cart.badge.plus")
                                .font(.headline.weight(.heavy))
                                .foregroundStyle(.black)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 13)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color(red: 1.0, green: 0.83, blue: 0.66))
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 18)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 236, alignment: .bottomLeading)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .opacity(isDisabled ? 0.62 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var availabilitySummary: String {
        guard let slot = ship.bestAvailabilitySlot(at: now) else {
            return "Availability unavailable"
        }

        if slot.contains(now) {
            return "Available until \(slot.endsAt.formatted(date: .omitted, time: .shortened))"
        }

        return "Next slot \(slot.startsAt.formatted(date: .abbreviated, time: .shortened))"
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
}

private struct LimitedShipOperationPanel: View {
    let operation: LimitedShipPurchaseOperation
    let now: Date
    let onCancel: () -> Void
    let onOpenCheckout: (URL) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                statusIcon

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)

                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if operation.phase == .waiting {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .buttonStyle(.bordered)
                } else if operation.phase == .succeeded || operation.phase == .purchased || operation.phase == .failed {
                    if operation.phase == .succeeded,
                       let cartURL = operation.cartURL {
                        Button {
                            onOpenCheckout(cartURL)
                        } label: {
                            Label("Open Checkout", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button("Dismiss", action: onDismiss)
                        .buttonStyle(.bordered)
                }
            }

            if !operation.logs.isEmpty {
                Divider()
                logView
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch operation.phase {
        case .waiting:
            Image(systemName: "clock")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        case .adding:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
        case .purchased:
            Image(systemName: "sparkles")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.cyan)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(operation.logs.indices, id: \.self) { index in
                        Text(operation.logs[index])
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .id(index)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 180)
            .onAppear {
                scrollToLatestLog(using: proxy)
            }
            .onChange(of: operation.logs) { _, _ in
                scrollToLatestLog(using: proxy)
            }
        }
    }

    private func scrollToLatestLog(using proxy: ScrollViewProxy) {
        guard let lastIndex = operation.logs.indices.last else {
            return
        }

        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(lastIndex, anchor: .bottom)
        }
    }

    private var title: String {
        switch operation.phase {
        case .waiting:
            return "Watching \(operation.shipName)"
        case .adding:
            return "Adding \(operation.shipName)"
        case .succeeded:
            return "\(operation.shipName) Added to Cart"
        case .purchased:
            return "\(operation.shipName) Secured"
        case .failed:
            return "\(operation.shipName) Failed"
        }
    }

    private var detail: String {
        switch operation.phase {
        case .waiting:
            if let fireDate = operation.fireDate,
               fireDate > now {
                return "Starts in \(Self.durationText(fireDate.timeIntervalSince(now)))"
            }

            return operation.detail
        case .adding:
            return operation.detail
        case .succeeded:
            if let attemptCount = operation.attemptCount {
                return "Confirmed after \(attemptCount) attempt(s). Open checkout to complete with store credit."
            }

            return "Open checkout to complete with store credit."
        case .purchased:
            return "RSI confirmed the order. Check your hangar for delivery."
        case .failed:
            return operation.detail
        }
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        if seconds < 60 {
            return "\(seconds)s"
        }

        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return "\(minutes)m \(remainingSeconds)s"
    }
}

private extension Decimal {
    func isGreaterThanOrEqual(to other: Decimal) -> Bool {
        NSDecimalNumber(decimal: self).compare(NSDecimalNumber(decimal: other)) != .orderedAscending
    }
}

private struct AuthorizedDevicesView: View {
    let appModel: AppModel

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @State private var devices: [AuthorizedDevice] = []
    @State private var isLoading = false
    @State private var isRemoving = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var pendingRemoval: AuthorizedDevice?
    @State private var isShowingRemoveAllConfirmation = false

    private var removableDevices: [AuthorizedDevice] {
        let hasCurrentDeviceMarker = devices.contains(where: \.isCurrent)
        let hasHangarExpressFallback = devices.contains(where: \.matchesHangarExpressDeviceName)
        guard hasCurrentDeviceMarker || hasHangarExpressFallback else {
            return []
        }

        return devices.filter { device in
            hasCurrentDeviceMarker
                ? !device.isCurrent
                : !device.matchesHangarExpressDeviceName
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && devices.isEmpty {
                    AuthorizedDevicesLoadingView()
                } else if let errorMessage, devices.isEmpty {
                    AuthorizedDevicesErrorView(message: errorMessage) {
                        Task {
                            await loadDevices()
                        }
                    }
                } else if devices.isEmpty {
                    AuthorizedDevicesEmptyView()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            Text("Logged-in devices are trusted RSI sign-in sessions. Removing a device signs that session out.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)

                            ForEach(devices) { device in
                                AuthorizedDeviceRow(
                                    device: device,
                                    isRemoving: isRemoving
                                ) {
                                    pendingRemoval = device
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, removableDevices.isEmpty ? 24 : 112)
                    }
                    .refreshable {
                        await loadDevices()
                    }
                }
            }
            .id(appLanguageRawValue)
            .navigationTitle(AppLocalizer.string("Logged In Devices"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Refresh") {
                        Task {
                            await loadDevices()
                        }
                    }
                    .disabled(isLoading || isRemoving)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !removableDevices.isEmpty {
                    Button(role: .destructive) {
                        isShowingRemoveAllConfirmation = true
                    } label: {
                        HStack {
                            if isRemoving {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Text("Remove All Other Devices")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isLoading || isRemoving)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial)
                }
            }
            .task {
                await loadDevices()
            }
            .alert(
                AppLocalizer.string("Remove Device?"),
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { isPresented in
                        if !isPresented {
                            pendingRemoval = nil
                        }
                    }
                ),
                presenting: pendingRemoval
            ) { device in
                Button("Cancel", role: .cancel) {
                    pendingRemoval = nil
                }

                Button("Remove", role: .destructive) {
                    Task {
                        await remove(device)
                    }
                }
            } message: { device in
                Text(AppLocalizer.format("Remove %@ from your authorized RSI devices?", device.displayName))
            }
            .alert("Unable to Manage Devices", isPresented: Binding(
                get: { errorMessage != nil && !devices.isEmpty },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Logged In Devices Updated", isPresented: Binding(
                get: { successMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        successMessage = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(successMessage ?? "")
            }
            .confirmationDialog(
                AppLocalizer.string("Remove All Other Devices?"),
                isPresented: $isShowingRemoveAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove All Other Devices", role: .destructive) {
                    Task {
                        await removeAllOtherDevices()
                    }
                }

                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    AppLocalizer.format(
                        "Remove %lld authorized RSI devices and keep the current Hangar Express session?",
                        removableDevices.count
                    )
                )
            }
        }
    }

    private func loadDevices(showLoading: Bool = true, reportsErrors: Bool = true) async {
        guard !isRemoving else {
            return
        }

        if showLoading {
            isLoading = true
        }
        defer {
            if showLoading {
                isLoading = false
            }
        }

        do {
            devices = try await appModel.fetchAuthorizedDevices()
                .sorted(by: sortAuthorizedDevices)
            errorMessage = nil
        } catch {
            if reportsErrors {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func remove(_ device: AuthorizedDevice) async {
        pendingRemoval = nil
        isRemoving = true

        do {
            try await appModel.removeAuthorizedDevice(device)
            devices.removeAll { $0.id == device.id }
            successMessage = AppLocalizer.format("Removed %@ from logged-in devices.", device.displayName)
            isRemoving = false
            await loadDevices(showLoading: false, reportsErrors: false)
        } catch {
            isRemoving = false
            errorMessage = error.localizedDescription
        }
    }

    private func removeAllOtherDevices() async {
        let targetDevices = removableDevices
        guard !targetDevices.isEmpty else {
            return
        }

        isRemoving = true

        do {
            try await appModel.removeAuthorizedDevicesExceptCurrent(targetDevices)
            let removedDeviceIDs = Set(targetDevices.map(\.id))
            devices.removeAll { removedDeviceIDs.contains($0.id) }
            successMessage = AppLocalizer.format(
                "Removed %lld logged-in device(s).",
                targetDevices.count
            )
            isRemoving = false
            await loadDevices(showLoading: false, reportsErrors: false)
        } catch {
            isRemoving = false
            errorMessage = error.localizedDescription
        }
    }

    private func sortAuthorizedDevices(lhs: AuthorizedDevice, rhs: AuthorizedDevice) -> Bool {
        if lhs.isCurrent != rhs.isCurrent {
            return lhs.isCurrent
        }

        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
}

private struct AuthorizedDeviceRow: View {
    let device: AuthorizedDevice
    let isRemoving: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: iconName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(device.isCurrent ? Color.accentColor : .secondary)
                .frame(width: 42, height: 42)
                .background(
                    Circle()
                        .fill((device.isCurrent ? Color.accentColor : Color.secondary).opacity(0.13))
                )

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(device.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if device.isCurrent {
                        Text("This App")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.14))
                            )
                    }
                }

                Text(device.displayType)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    if let createdAtLabel = device.createdAtLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !createdAtLabel.isEmpty {
                        Label(createdAtLabel, systemImage: "calendar")
                    }

                    Label(device.durationLabel, systemImage: "timer")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if device.shouldProtectFromBulkRemoval {
                Image(systemName: "lock.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                        .font(.headline)
                }
                .buttonStyle(.borderless)
                .disabled(isRemoving)
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var iconName: String {
        switch device.type?.localizedLowercase {
        case "mobile":
            return "iphone"
        case "tablet":
            return "ipad"
        case "desktop":
            return "desktopcomputer"
        default:
            return "iphone"
        }
    }
}

private struct AuthorizedDevicesLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Loading authorized devices")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AuthorizedDevicesEmptyView: View {
    var body: some View {
        ContentUnavailableView(
            AppLocalizer.string("No Logged In Devices"),
            systemImage: "iphone",
            description: Text("No logged-in devices were returned by RSI.")
        )
    }
}

private struct AuthorizedDevicesErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Unable to Load Devices", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct ProfileBackgroundPickerView: View {
    let options: [ProfileBackgroundShipOption]
    let selectedSelectionKey: String?
    let onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onSelect(nil)
                        dismiss()
                    } label: {
                        AutomaticBackgroundOptionRow(
                            isSelected: selectedSelectionKey == nil
                        )
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("Automatic uses the owned ship with the highest known MSRP as the profile background.")
                }

                Section("Owned Ships") {
                    ForEach(options) { option in
                        Button {
                            onSelect(option.selectionKey)
                            dismiss()
                        } label: {
                            ProfileBackgroundOptionRow(
                                option: option,
                                isSelected: selectedSelectionKey == option.selectionKey
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Choose Background")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct AutomaticBackgroundOptionRow: View {
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.32, blue: 0.46),
                            Color(red: 0.07, green: 0.16, blue: 0.26)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 84, height: 56)
                .overlay {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.82))
                }

            VStack(alignment: .leading, spacing: 4) {
                Text("Automatic")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("Use the most expensive owned ship")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.title3)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct ProfileBackgroundOptionRow: View {
    let option: ProfileBackgroundShipOption
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ProfileBackgroundOptionThumbnail(imageURL: option.imageURL)

            VStack(alignment: .leading, spacing: 4) {
                Text(option.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(option.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(option.pricingSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.title3)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct ProfileBackgroundOptionThumbnail: View {
    let imageURL: URL?
    let reloadToken: UUID? = nil

    var body: some View {
        Group {
            if let imageURL {
                CachedRemoteImage(
                    url: imageURL,
                    targetSize: CGSize(width: 84, height: 56),
                    reloadToken: reloadToken
                ) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure, .empty:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 84, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.32, blue: 0.46),
                        Color(red: 0.07, green: 0.16, blue: 0.26)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "airplane")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.72))
            }
    }
}
