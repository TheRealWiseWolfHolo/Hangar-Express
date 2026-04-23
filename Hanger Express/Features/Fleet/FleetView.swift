import SwiftUI

struct FleetView: View {
    enum SortMode: String, CaseIterable, Identifiable {
        case manufacturer = "Manufacturer"
        case msrp = "MSRP"
        case function = "Function"

        var id: Self { self }

        var title: String {
            rawValue
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
                return "Switch to two-column cards"
            case .twoColumn:
                return "Switch to one-column cards"
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
    @State private var presentedPledgeSheet: FleetShipPledgeSheetContext?
    @Namespace private var shipCardTransitionNamespace
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
                                    .foregroundStyle(Color.white.opacity(0.72))
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

                    Button(appModel.isRefreshing(.hangar) ? "Refreshing..." : "Refresh") {
                        Task {
                            await appModel.refresh(scope: .hangar)
                        }
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
                    ?? "Unknown Manufacturer"
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
                let title = normalizedHeaderTitle(category) ?? "Other Ships"
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
                return "MSRP \(msrpUSD.usdString) each"
            }

            return "MSRP \(msrpUSD.usdString)"
        }

        if let msrpLabel = shipGroup.representative.msrpLabel?.nilIfBlank {
            return msrpLabel
        }

        return "MSRP unavailable"
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
            return "1 pledge includes this ship"
        }

        return "\(context.packageGroups.count) pledges include this ship"
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
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.12, blue: 0.17),
                            Color(red: 0.08, green: 0.19, blue: 0.27),
                            Color(red: 0.05, green: 0.28, blue: 0.32)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.cyan.opacity(0.12))
                        .frame(width: 180, height: 180)
                        .blur(radius: 10)
                        .offset(x: 48, y: -28)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.cyan.opacity(0.18), lineWidth: 1)
                }

            backdropImage

            LinearGradient(
                colors: [
                    Color.black.opacity(0.72),
                    Color.black.opacity(0.48),
                    Color.black.opacity(0.08)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(FleetPresentationFormatter.manufacturerDisplayName(ship.manufacturer).uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(3)
                        .foregroundStyle(Color.cyan.opacity(0.92))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 1)

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
        .frame(maxWidth: .infinity)
        .frame(height: 212, alignment: .bottomLeading)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .alert("Ship Info Incomplete", isPresented: $showsCatalogWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ship.catalogWarning ?? "Ship info incomplete. Please send the dev a screenshot so it can be patched.")
        }
    }

    private var backdropImage: some View {
        GeometryReader { proxy in
            ZStack {
                backdropPlaceholder

                CachedRemoteImage(
                    url: ship.imageURL,
                    targetSize: proxy.size,
                    reloadToken: reloadToken,
                    maxRetryCount: 5
                ) { phase in
                    switch phase {
                    case let .success(image):
                        standardizedBackdropImage(
                            image,
                            size: proxy.size
                        )
                    case .empty:
                        Color.clear
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .overlay {
                                ProgressView()
                                    .tint(.white.opacity(0.7))
                            }
                    case .failure:
                        Color.clear
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.12)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .mask(
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.42),
                    Color.black
                ],
                startPoint: .leading,
                endPoint: UnitPoint(x: 0.78, y: 0.5)
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func standardizedBackdropImage(_ image: Image, size: CGSize) -> some View {
        image
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    private var backdropPlaceholder: some View {
        HStack {
            Spacer(minLength: 0)
            Image(systemName: "airplane")
                .font(.system(size: 58, weight: .light))
                .foregroundStyle(Color.white.opacity(0.16))
                .padding(.trailing, 24)
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
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.09, green: 0.11, blue: 0.16),
                            Color(red: 0.07, green: 0.17, blue: 0.24),
                            Color(red: 0.05, green: 0.24, blue: 0.29)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.cyan.opacity(0.16), lineWidth: 1)
                }

            compactBackdropImage

            LinearGradient(
                colors: [
                    Color.black.opacity(0.82),
                    Color.black.opacity(0.64),
                    Color.black.opacity(0.34)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    Text(FleetPresentationFormatter.manufacturerDisplayName(ship.manufacturer).uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(2.5)
                        .foregroundStyle(Color.cyan.opacity(0.92))
                        .lineLimit(2)

                    Spacer(minLength: 0)

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

                VStack(alignment: .leading, spacing: 6) {
                    Text(ship.displayName)
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.82)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.82))
                            .lineLimit(2)
                    }
                }
                .padding(.top, 10)

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
        .frame(maxWidth: .infinity)
        .frame(height: 232, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .alert("Ship Info Incomplete", isPresented: $showsCatalogWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ship.catalogWarning ?? "Ship info incomplete. Please send the dev a screenshot so it can be patched.")
        }
    }

    private var compactBackdropImage: some View {
        GeometryReader { proxy in
            ZStack {
                compactBackdropPlaceholder

                CachedRemoteImage(
                    url: ship.imageURL,
                    targetSize: proxy.size,
                    reloadToken: reloadToken,
                    maxRetryCount: 5
                ) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    case .empty:
                        Color.clear
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .overlay {
                                ProgressView()
                                    .tint(.white.opacity(0.7))
                            }
                    case .failure:
                        Color.clear
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.2)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var compactBackdropPlaceholder: some View {
        VStack {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                Image(systemName: "airplane")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.16))
                    .padding(.trailing, 18)
                    .padding(.bottom, 20)
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
        ScrollView {
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

                    FleetShipDescriptionCard(description: detail.description)

                    FleetShipTechnicalSpecsCard(detail: detail)

                    if let pageURL = detail.pageURL {
                        Link(destination: pageURL) {
                            Label("Open Source Page", systemImage: "arrow.up.right.square")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.cyan.opacity(0.22))
                    }

                case let .unavailable(message):
                    FleetShipUnavailableCard(message: message)

                case let .failed(message):
                    FleetShipUnavailableCard(message: message)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .contentMargins(.top, 0, for: .scrollContent)
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
                loadState = .unavailable("Ship info unavailable for this variant.")
                return
            }

            if detail.isUnavailable {
                loadState = .unavailable(
                    detail.unavailableReason ?? "Ship info unavailable for this variant."
                )
                return
            }

            loadState = .loaded(detail)
        } catch {
            loadState = .failed(
                "Unable to load ship info right now. \(error.localizedDescription)"
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
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(FleetPresentationFormatter.manufacturerDisplayName(ship.manufacturer).uppercased())
                            .font(.caption.weight(.semibold))
                            .tracking(3)
                            .foregroundStyle(Color.cyan.opacity(0.94))

                        Text(detail?.name ?? ship.displayName)
                            .font(.system(size: 34, weight: .heavy, design: .default))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .minimumScaleFactor(0.72)

                    }

                    Spacer(minLength: 0)

                    if let status = detail?.inGameStatus?.nilIfBlank {
                        FleetShipDetailPill(
                            title: status,
                            tint: Color.cyan.opacity(0.24)
                        )
                    }
                }

                Spacer(minLength: 18)

                VStack(alignment: .leading, spacing: 14) {
                    if let roleSummary, !roleSummary.isEmpty {
                        Text(roleSummary)
                            .font(.headline.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.84))
                            .lineLimit(2)
                    }

                    HStack(spacing: 10) {
                        FleetShipDetailPill(
                            title: "Crew \(detail?.crewSummary ?? "Unavailable")",
                            tint: Color.white.opacity(0.10)
                        )

                        FleetShipDetailPill(
                            title: detail?.size?.nilIfBlank ?? "Size unavailable",
                            tint: Color.white.opacity(0.10)
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
        FleetShipDetailPanel(title: "SHIP OVERVIEW", subtitle: "Variant-specific ship profile") {
            VStack(spacing: 0) {
                FleetShipOverviewRow(label: "Role", value: detail.role?.nilIfBlank ?? "Unavailable")
                FleetShipOverviewRow(label: "Function", value: detail.career?.nilIfBlank ?? "Unavailable")
                FleetShipOverviewRow(label: "Max Crew", value: detail.maxCrew.map(String.init) ?? detail.crewSummary ?? "Unavailable")
                FleetShipOverviewRow(label: "Size", value: detail.size?.nilIfBlank ?? "Unavailable")
                FleetShipOverviewRow(label: "In Game Status", value: detail.inGameStatus?.nilIfBlank ?? "Unavailable")
                FleetShipOverviewRow(
                    label: "Pledge Availability",
                    value: detail.pledgeAvailability?.nilIfBlank ?? "Unavailable",
                    showsDivider: false
                )
            }
        }
    }
}

private struct FleetShipDescriptionCard: View {
    let description: String?

    var body: some View {
        FleetShipDetailPanel(title: "DESCRIPTION", subtitle: "Directly sourced from the ship page") {
            Text(description?.nilIfBlank ?? "Description unavailable.")
                .font(.body)
                .foregroundStyle(Color.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            subtitle: "These specs are sourced from the ship page and may change over time."
        ) {
            VStack(alignment: .leading, spacing: 20) {
                if !detail.technicalSpecs.isEmpty {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(detail.technicalSpecs, id: \.self) { item in
                            FleetShipSpecTile(item: item)
                        }
                    }
                }

                if !detail.technicalSections.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(detail.technicalSections, id: \.self) { section in
                            FleetShipTechnicalSectionCard(section: section)
                        }
                    }
                }

                if detail.technicalSpecs.isEmpty, detail.technicalSections.isEmpty {
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
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
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
    let label: String
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
                ForEach(section.items, id: \.self) { item in
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
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
