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

    let appModel: AppModel
    let snapshot: HangarSnapshot
    @State private var searchText = ""
    @State private var sortMode: SortMode = .manufacturer

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

                            LazyVStack(spacing: 16) {
                                ForEach(section.shipGroups) { shipGroup in
                                    FleetShipHeroCard(
                                        shipGroup: shipGroup,
                                        subtitle: cardSubtitle(for: shipGroup),
                                        msrpSummary: msrpSummary(for: shipGroup),
                                        reloadToken: appModel.imageReloadToken
                                    )
                                }
                            }
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
        }
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

        return "MSRP unavailable"
    }
}

private struct FleetShipHeroCard: View {
    let shipGroup: GroupedFleetShip
    let subtitle: String?
    let msrpSummary: String
    let reloadToken: UUID?

    private var ship: FleetShip {
        shipGroup.representative
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
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
    }

    private var backdropImage: some View {
        GeometryReader { proxy in
            ZStack {
                backdropPlaceholder

                CachedRemoteImage(
                    url: ship.imageURL,
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
