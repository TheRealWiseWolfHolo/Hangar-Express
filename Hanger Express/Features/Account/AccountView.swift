import SwiftUI

struct AccountView: View {
    let appModel: AppModel
    let snapshot: HangarSnapshot

    @State private var isShowingSettings = false
    @State private var isShowingBackgroundPicker = false
    @State private var isShowingAccountTotalValueExplanation = false
    @State private var isShowingConciergeLevels = false
    @State private var selectedBackgroundSelectionKey: String?
    @State private var isOverviewEmailVisible = false
    @State private var isOverviewSavedLoginVisible = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AccountProfileCard(
                        displayName: profileDisplayName,
                        organizationSummary: profileOrganizationSummary,
                        totalValueLabel: accountTotalValueLabel,
                        conciergeLevel: conciergeLevel,
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
                            secondaryValue: "Ships \(snapshot.metrics.shipCount)"
                        )

                        MetricCard(
                            title: "Current Value",
                            primaryValue: snapshot.metrics.totalCurrentValue.usdString,
                            secondaryValue: "Melt \(snapshot.metrics.totalOriginalValue.usdString)"
                        )

                        MetricCard(
                            title: "Credit",
                            primaryValue: snapshot.metrics.storeCreditUSD?.usdString ?? "Unavailable",
                            secondaryValue: "Total Spend: \(snapshot.metrics.totalSpendUSD?.usdString ?? "Unavailable")"
                        )

                        MetricCard(
                            title: "Referrals",
                            primaryValue: snapshot.referralStats.currentSummary,
                            secondaryValue: snapshot.referralStats.legacySummary
                        )
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Snapshot")
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
                    Button(appModel.isRefreshing(.account) ? "Refreshing Account..." : "Refresh Account") {
                        Task {
                            await appModel.refresh(scope: .account)
                        }
                    }
                    .disabled(appModel.isRefreshing)

                    Button(appModel.isRefreshing(.full) ? "Refreshing Everything..." : "Full Refresh") {
                        Task {
                            await appModel.refresh(scope: .full)
                        }
                    }
                    .disabled(appModel.isRefreshing)
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Refresh Account updates balances, referral data, and profile metadata. Full Refresh also reloads hangar, fleet, and buy-back data.")
                }
            }
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
            .alert("Account Total Value", isPresented: $isShowingAccountTotalValueExplanation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(accountTotalValueExplanation)
            }
            .task(id: backgroundSelectionLoadID) {
                loadSavedProfileBackgroundSelection()
            }
        }
    }

    private var refreshLabel: String {
        guard let lastRefreshAt = appModel.lastRefreshAt else {
            return "Not yet synced"
        }

        return lastRefreshAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var snapshotColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
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

        return "Citizen"
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
        accountTotalValueUSD?.usdString ?? "Unavailable"
    }

    private var accountTotalValueExplanation: String {
        let currentValueText = snapshot.metrics.totalCurrentValue.usdString
        let availableCreditText = snapshot.metrics.storeCreditUSD?.usdString ?? "Unavailable"
        let totalValueText = accountTotalValueUSD?.usdString ?? "Unavailable"

        return """
        Account Current Value = \(currentValueText)
        Combined MSRP of all ships + current value of all upgrades + combined value of the rest of the items in your hangar.

        Available Credit = \(availableCreditText)

        Account Total Value = \(currentValueText) + \(availableCreditText) = \(totalValueText)
        """
    }

    private var conciergeLevel: ConciergeLevel? {
        ConciergeLevel(totalSpendUSD: snapshot.metrics.totalSpendUSD)
    }

    private var profileOrganizationSummary: String {
        if let organization = snapshot.primaryOrganization {
            return organization.summaryText
        }

        return snapshot.didRefreshPrimaryOrganization ? "No Organization" : "Organization unavailable"
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
            return "Requires \(minimumSpendUSD.usdString)+ total spend"
        }

        return "Requires \(minimumSpendUSD.usdString) total spend"
    }

    func isUnlocked(totalSpendUSD: Decimal?) -> Bool {
        guard let totalSpendUSD else {
            return false
        }

        return NSDecimalNumber(decimal: totalSpendUSD).compare(NSDecimalNumber(decimal: minimumSpendUSD)) != .orderedAscending
    }
}

private struct MetricCard: View {
    let title: String
    let primaryValue: String
    let secondaryValue: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SensitiveOverviewFieldRow: View {
    let title: String
    let value: String?
    @Binding var isVisible: Bool
    let hiddenText: String
    let emptyText: String

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

                        Text(isVisible ? trimmedValue : hiddenText)
                            .lineLimit(1)
                            .truncationMode(.middle)
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

                Text(displayName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)

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
            return "\(manufacturer) • Owned \(quantity)"
        }

        return manufacturer
    }

    var pricingSummary: String {
        if let msrpUSD {
            return "MSRP \(msrpUSD.usdString)"
        }

        if let msrpLabel = msrpLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !msrpLabel.isEmpty {
            return msrpLabel
        }

        return "MSRP unavailable"
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
