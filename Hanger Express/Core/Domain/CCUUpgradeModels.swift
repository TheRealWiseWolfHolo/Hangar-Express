import Foundation

nonisolated struct CCUUpgradeCatalogShip: Identifiable, Hashable, Sendable {
    private static let maximumUpgradeableMSRPUSD: Decimal = 1000
    private static let pioneerKey = UpgradeTitleParser.normalizedShipKey("Pioneer")

    let numericID: Int
    let key: String
    let name: String
    let manufacturer: String
    let msrpUSD: Decimal
    let msrpLabel: String?
    let storeAvailability: String?
    let storeAvailable: Bool?
    let imageURL: URL?
    let aliases: [String]

    var id: String {
        key
    }

    var displayPrice: String {
        msrpLabel?.nilIfBlankForCCU ?? msrpUSD.ccuUSDString
    }

    var displayAvailability: String {
        if let storeAvailability = storeAvailability?.nilIfBlankForCCU {
            switch storeAvailability.localizedLowercase {
            case "available":
                return AppLocalizer.string("Available")
            case "unavailable", "not available":
                return AppLocalizer.string("Unavailable")
            default:
                return storeAvailability
            }
        }

        return AppLocalizer.string(isStoreUpgradeAvailable ? "Available" : "Unavailable")
    }

    var isStoreUpgradeAvailable: Bool {
        if let storeAvailable {
            return storeAvailable
        }

        guard let availability = storeAvailability?.nilIfBlankForCCU?.localizedLowercase else {
            return false
        }

        if availability.contains("no longer")
            || availability.contains("not available")
            || availability.contains("unavailable")
            || availability.contains("not for sale") {
            return false
        }

        return availability.contains("available")
            || availability.contains("always")
            || availability.contains("limited")
            || availability.contains("sale")
    }

    var searchHaystack: String {
        [
            name,
            manufacturer,
            displayPrice,
            storeAvailability ?? "",
            aliases.joined(separator: " ")
        ]
        .joined(separator: " ")
        .localizedLowercase
    }

    static func makeShips(from catalog: RSIShipCatalog) -> [CCUUpgradeCatalogShip] {
        var shipsByKey: [String: CCUUpgradeCatalogShip] = [:]

        for ship in catalog.ships {
            guard let msrpUSD = ship.msrpUSD,
                  msrpUSD.isGreaterThan(.zero) else {
                continue
            }

            let key = UpgradeTitleParser.normalizedShipKey(ship.name)
            guard !key.isEmpty else {
                continue
            }

            guard msrpUSD.isLessThanOrEqual(to: Self.maximumUpgradeableMSRPUSD),
                  !Self.isPioneerShip(name: ship.name, key: key) else {
                continue
            }

            let candidate = CCUUpgradeCatalogShip(
                numericID: ship.id,
                key: key,
                name: ship.name,
                manufacturer: ship.manufacturer?.nilIfBlankForCCU ?? "Unknown",
                msrpUSD: msrpUSD,
                msrpLabel: ship.msrpLabel,
                storeAvailability: ship.storeAvailability,
                storeAvailable: ship.storeAvailable,
                imageURL: ship.imageURL,
                aliases: ship.aliases
            )

            if let existing = shipsByKey[key] {
                if candidate.isPreferredCatalogEntry(over: existing) {
                    shipsByKey[key] = candidate
                }
            } else {
                shipsByKey[key] = candidate
            }
        }

        return shipsByKey.values.sorted { lhs, rhs in
            let priceComparison = lhs.msrpUSD.compare(to: rhs.msrpUSD)
            if priceComparison != .orderedSame {
                return priceComparison == .orderedAscending
            }

            if lhs.manufacturer != rhs.manufacturer {
                return lhs.manufacturer.localizedCaseInsensitiveCompare(rhs.manufacturer) == .orderedAscending
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func isPioneerShip(name: String, key: String) -> Bool {
        key == pioneerKey
            || UpgradeTitleParser.normalizedShipKey(
                UpgradeTitleParser.stripManufacturerPrefix(from: name)
            ) == pioneerKey
    }

    private func isPreferredCatalogEntry(over other: CCUUpgradeCatalogShip) -> Bool {
        if isStoreUpgradeAvailable != other.isStoreUpgradeAvailable {
            return isStoreUpgradeAvailable
        }

        if imageURL != nil, other.imageURL == nil {
            return true
        }

        if manufacturer.localizedCaseInsensitiveCompare("Unknown") != .orderedSame,
           other.manufacturer.localizedCaseInsensitiveCompare("Unknown") == .orderedSame {
            return true
        }

        return name.count < other.name.count
    }
}

nonisolated enum CCUUpgradeSourceKind: Int, Hashable, Sendable, CaseIterable {
    case hangarWarbond
    case hangarStandardMeltAboveCurrent
    case hangarStandardMeltMatchesCurrent
    case buyback
    case storeWarbond
    case store
    case unavailableStore

    var title: String {
        switch self {
        case .hangarWarbond:
            return AppLocalizer.string("WB CCU in Hangar")
        case .hangarStandardMeltAboveCurrent:
            return AppLocalizer.string("Standard CCU in Hangar")
        case .hangarStandardMeltMatchesCurrent:
            return AppLocalizer.string("Standard CCU in Hangar")
        case .buyback:
            return AppLocalizer.string("CCU in Buy Back")
        case .storeWarbond:
            return AppLocalizer.string("WB CCU in Store")
        case .store:
            return AppLocalizer.string("CCU in Store")
        case .unavailableStore:
            return AppLocalizer.string("CCU Not in Store")
        }
    }

    var detail: String {
        switch self {
        case .hangarWarbond:
            return AppLocalizer.string("Best owned saving")
        case .hangarStandardMeltAboveCurrent:
            return AppLocalizer.string("Melt above current value")
        case .hangarStandardMeltMatchesCurrent:
            return AppLocalizer.string("Melt equals current value")
        case .buyback:
            return AppLocalizer.string("Recoverable from buy back")
        case .storeWarbond:
            return AppLocalizer.string("Purchasable now, new money only")
        case .store:
            return AppLocalizer.string("Purchasable now")
        case .unavailableStore:
            return AppLocalizer.string("Cannot be purchased right now")
        }
    }

    var priority: Int {
        switch self {
        case .hangarWarbond:
            return 0
        case .hangarStandardMeltAboveCurrent:
            return 1
        case .hangarStandardMeltMatchesCurrent:
            return 2
        case .buyback:
            return 3
        case .storeWarbond:
            return 4
        case .store:
            return 5
        case .unavailableStore:
            return 6
        }
    }

    var requiresNewPurchase: Bool {
        switch self {
        case .hangarWarbond, .hangarStandardMeltAboveCurrent, .hangarStandardMeltMatchesCurrent:
            return false
        case .buyback, .storeWarbond, .store, .unavailableStore:
            return true
        }
    }

    var allowsStoreCredit: Bool {
        switch self {
        case .store, .unavailableStore:
            return true
        case .hangarWarbond, .hangarStandardMeltAboveCurrent, .hangarStandardMeltMatchesCurrent, .buyback, .storeWarbond:
            return false
        }
    }

    var isUnavailableStoreStep: Bool {
        self == .unavailableStore
    }
}

nonisolated struct CCUUpgradeCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let sourceShip: CCUUpgradeCatalogShip
    let targetShip: CCUUpgradeCatalogShip
    let title: String
    let kind: CCUUpgradeSourceKind
    let currentValueUSD: Decimal
    let effectiveCostUSD: Decimal
    let newPurchaseCostUSD: Decimal
    let referenceID: String?

    var savingsUSD: Decimal {
        currentValueUSD - effectiveCostUSD
    }

    var routeValueText: String {
        "\(sourceShip.name) -> \(targetShip.name)"
    }
}

nonisolated struct CCUUpgradePaymentRequirement: Hashable, Sendable {
    let candidateID: String
    let purchaseCostUSD: Decimal
    let storeCreditUSD: Decimal
    let newMoneyUSD: Decimal
}

private nonisolated struct CCUUpgradeStorePath: Hashable, Sendable {
    let sourceKey: String
    let targetKey: String

    init(sourceShip: CCUUpgradeCatalogShip, targetShip: CCUUpgradeCatalogShip) {
        sourceKey = sourceShip.key
        targetKey = targetShip.key
    }
}

nonisolated struct CCUUpgradeRoute: Hashable, Sendable {
    let sourceShip: CCUUpgradeCatalogShip
    let destinationShip: CCUUpgradeCatalogShip
    let sourceShipValueUSD: Decimal
    let steps: [CCUUpgradeCandidate]
    let standardUpgradeValueUSD: Decimal
    let totalEffectiveCostUSD: Decimal
    let totalNewPurchaseCostUSD: Decimal
    let availableStoreCreditUSD: Decimal
    let paymentRequirements: [String: CCUUpgradePaymentRequirement]

    var totalSavingsUSD: Decimal {
        standardUpgradeValueUSD - totalEffectiveCostUSD
    }

    var totalStoreCreditNeededUSD: Decimal {
        paymentRequirements.values.reduce(into: Decimal.zero) { partialResult, requirement in
            partialResult += requirement.storeCreditUSD
        }
    }

    var totalNewMoneyNeededUSD: Decimal {
        paymentRequirements.values.reduce(into: Decimal.zero) { partialResult, requirement in
            partialResult += requirement.newMoneyUSD
        }
    }

    var hasUnavailableStoreStep: Bool {
        steps.contains { $0.kind.isUnavailableStoreStep }
    }

    func paymentRequirement(for step: CCUUpgradeCandidate) -> CCUUpgradePaymentRequirement? {
        paymentRequirements[step.id]
    }
}

nonisolated enum CCUUpgradePlanner {
    static func bestRoute(
        from sourceShip: CCUUpgradeCatalogShip,
        to destinationShip: CCUUpgradeCatalogShip,
        snapshot: HangarSnapshot,
        catalogShips: [CCUUpgradeCatalogShip],
        storeUpgradeOffers: [RSIShipCatalog.StoreUpgradeOffer] = [],
        selectedSourceMeltValueUSD: Decimal? = nil,
        excludedCandidateIDs: Set<String> = []
    ) -> CCUUpgradeRoute? {
        guard sourceShip.msrpUSD.isLessThan(destinationShip.msrpUSD) else {
            return nil
        }

        let shipIndex = CCUUpgradeShipIndex(ships: catalogShips)
        guard shipIndex.ship(forKey: sourceShip.key) != nil,
              shipIndex.ship(forKey: destinationShip.key) != nil else {
            return nil
        }

        let ownedSourceMeltValues = sourceShipMeltValues(
            for: sourceShip,
            snapshot: snapshot,
            shipIndex: shipIndex
        )
        let sourceShipValueUSD: Decimal
        if ownedSourceMeltValues.isEmpty {
            sourceShipValueUSD = sourceShip.msrpUSD
        } else if let selectedSourceMeltValueUSD,
                  ownedSourceMeltValues.contains(selectedSourceMeltValueUSD) {
            sourceShipValueUSD = selectedSourceMeltValueUSD
        } else if ownedSourceMeltValues.count == 1,
                  let soleMeltValue = ownedSourceMeltValues.first {
            sourceShipValueUSD = soleMeltValue
        } else {
            // The caller must ask which owned copy to use when melt values differ.
            return nil
        }

        let candidates = allCandidates(
            snapshot: snapshot,
            shipIndex: shipIndex,
            storeUpgradeOffers: storeUpgradeOffers
        )
            .filter { !excludedCandidateIDs.contains($0.id) }
            .filter { candidate in
                candidate.sourceShip.msrpUSD.isGreaterThanOrEqual(to: sourceShip.msrpUSD)
                    && candidate.targetShip.msrpUSD.isLessThanOrEqual(to: destinationShip.msrpUSD)
                    && candidate.sourceShip.msrpUSD.isLessThan(candidate.targetShip.msrpUSD)
            }

        let adjacency = Dictionary(grouping: candidates, by: \.sourceShip.key)
        let sortedShips = catalogShips
            .filter { ship in
                ship.msrpUSD.isGreaterThanOrEqual(to: sourceShip.msrpUSD)
                    && ship.msrpUSD.isLessThanOrEqual(to: destinationShip.msrpUSD)
            }
            .sorted { lhs, rhs in
                let priceComparison = lhs.msrpUSD.compare(to: rhs.msrpUSD)
                if priceComparison != .orderedSame {
                    return priceComparison == .orderedAscending
                }

                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

        var bestStates: [String: CCUUpgradeRouteState] = [
            sourceShip.key: CCUUpgradeRouteState.empty
        ]

        for ship in sortedShips {
            guard let state = bestStates[ship.key] else {
                continue
            }

            for candidate in adjacency[ship.key] ?? [] {
                let nextState = state.appending(candidate)
                if let existingState = bestStates[candidate.targetShip.key] {
                    if nextState.isBetter(than: existingState) {
                        bestStates[candidate.targetShip.key] = nextState
                    }
                } else {
                    bestStates[candidate.targetShip.key] = nextState
                }
            }
        }

        guard let destinationState = bestStates[destinationShip.key],
              !destinationState.steps.isEmpty else {
            return nil
        }

        let availableStoreCreditUSD = (snapshot.storeCreditUSD ?? .zero).nonNegative
        let paymentRequirements = makePaymentRequirements(
            for: destinationState.steps,
            availableStoreCreditUSD: availableStoreCreditUSD
        )

        return CCUUpgradeRoute(
            sourceShip: sourceShip,
            destinationShip: destinationShip,
            sourceShipValueUSD: sourceShipValueUSD,
            steps: destinationState.steps,
            standardUpgradeValueUSD: destinationShip.msrpUSD,
            totalEffectiveCostUSD: sourceShipValueUSD + destinationState.totalEffectiveCostUSD,
            totalNewPurchaseCostUSD: destinationState.totalNewPurchaseCostUSD,
            availableStoreCreditUSD: availableStoreCreditUSD,
            paymentRequirements: paymentRequirements
        )
    }

    static func sourceShipMeltValues(
        for sourceShip: CCUUpgradeCatalogShip,
        snapshot: HangarSnapshot,
        catalogShips: [CCUUpgradeCatalogShip]
    ) -> [Decimal] {
        sourceShipMeltValues(
            for: sourceShip,
            snapshot: snapshot,
            shipIndex: CCUUpgradeShipIndex(ships: catalogShips)
        )
    }

    private static func sourceShipMeltValues(
        for sourceShip: CCUUpgradeCatalogShip,
        snapshot: HangarSnapshot,
        shipIndex: CCUUpgradeShipIndex
    ) -> [Decimal] {
        Array(Set(snapshot.fleet.compactMap { ownedShip -> Decimal? in
            guard shipIndex.matchShip(named: ownedShip.displayName)?.key == sourceShip.key else {
                return nil
            }
            return ownedShip.meltValueUSD
        }))
        .sorted { $0.compare(to: $1) == .orderedAscending }
    }

    static func allCandidates(
        snapshot: HangarSnapshot,
        shipIndex: CCUUpgradeShipIndex,
        storeUpgradeOffers: [RSIShipCatalog.StoreUpgradeOffer] = []
    ) -> [CCUUpgradeCandidate] {
        let storeWarbondCandidates = storeWarbondCandidates(
            shipIndex: shipIndex,
            storeUpgradeOffers: storeUpgradeOffers
        )
        let storeWarbondPaths = Set(storeWarbondCandidates.map { candidate in
            CCUUpgradeStorePath(
                sourceShip: candidate.sourceShip,
                targetShip: candidate.targetShip
            )
        })

        var candidates: [CCUUpgradeCandidate] = []
        candidates.append(contentsOf: hangarCandidates(snapshot: snapshot, shipIndex: shipIndex))
        candidates.append(contentsOf: buybackCandidates(snapshot: snapshot, shipIndex: shipIndex))
        candidates.append(contentsOf: storeWarbondCandidates)
        candidates.append(contentsOf: storeCandidates(
            shipIndex: shipIndex,
            excludingStoreWarbondPaths: storeWarbondPaths
        ))
        return candidates
    }

    private static func hangarCandidates(
        snapshot: HangarSnapshot,
        shipIndex: CCUUpgradeShipIndex
    ) -> [CCUUpgradeCandidate] {
        snapshot.packages.flatMap { package -> [CCUUpgradeCandidate] in
            guard package.canApplyStoredUpgrade || package.isUpgradeOnlyPledge else {
                return []
            }

            var candidates = package.contents.compactMap { item -> CCUUpgradeCandidate? in
                guard item.category == .upgrade,
                      let pricing = item.upgradePricing else {
                    return nil
                }

                let fallbackMeltValue = package.isUpgradeOnlyPledge ? package.originalValueUSD : nil
                return makeHangarCandidate(
                    id: "hangar-\(package.id)-\(item.id)",
                    title: item.title,
                    detailText: [package.title, item.title, item.detail].joined(separator: " "),
                    sourceName: pricing.sourceShipName,
                    targetName: pricing.targetShipName,
                    actualValueUSD: pricing.actualValueUSD,
                    meltValueUSD: pricing.meltValueUSD ?? fallbackMeltValue,
                    packageID: package.id,
                    shipIndex: shipIndex
                )
            }

            if candidates.isEmpty,
               let parsedPath = UpgradeTitleParser.parse(package.title) {
                if let fallbackCandidate = makeHangarCandidate(
                    id: "hangar-\(package.id)",
                    title: package.title,
                    detailText: package.title,
                    sourceName: parsedPath.sourceShipName,
                    targetName: parsedPath.targetShipName,
                    actualValueUSD: nil,
                    meltValueUSD: package.originalValueUSD,
                    packageID: package.id,
                    shipIndex: shipIndex
                ) {
                    candidates.append(fallbackCandidate)
                }
            }

            return candidates
        }
    }

    private static func makeHangarCandidate(
        id: String,
        title: String,
        detailText: String,
        sourceName: String,
        targetName: String,
        actualValueUSD: Decimal?,
        meltValueUSD: Decimal?,
        packageID: Int,
        shipIndex: CCUUpgradeShipIndex
    ) -> CCUUpgradeCandidate? {
        guard let sourceShip = shipIndex.matchShip(named: sourceName),
              let targetShip = shipIndex.matchShip(named: targetName) else {
            return nil
        }

        let currentValueUSD = actualValueUSD ?? targetShip.msrpUSD - sourceShip.msrpUSD
        guard currentValueUSD.isGreaterThan(.zero) else {
            return nil
        }

        let effectiveCostUSD = meltValueUSD ?? currentValueUSD
        let kind = hangarKind(
            detailText: detailText,
            effectiveCostUSD: effectiveCostUSD,
            currentValueUSD: currentValueUSD
        )

        return CCUUpgradeCandidate(
            id: id,
            sourceShip: sourceShip,
            targetShip: targetShip,
            title: title,
            kind: kind,
            currentValueUSD: currentValueUSD,
            effectiveCostUSD: effectiveCostUSD,
            newPurchaseCostUSD: .zero,
            referenceID: "#\(packageID)"
        )
    }

    private static func hangarKind(
        detailText: String,
        effectiveCostUSD: Decimal,
        currentValueUSD: Decimal
    ) -> CCUUpgradeSourceKind {
        let normalizedDetail = detailText.localizedLowercase
        if normalizedDetail.contains("warbond")
            || effectiveCostUSD.isLessThan(currentValueUSD) {
            return .hangarWarbond
        }

        if effectiveCostUSD.isGreaterThan(currentValueUSD) {
            return .hangarStandardMeltAboveCurrent
        }

        return .hangarStandardMeltMatchesCurrent
    }

    private static func buybackCandidates(
        snapshot: HangarSnapshot,
        shipIndex: CCUUpgradeShipIndex
    ) -> [CCUUpgradeCandidate] {
        snapshot.buyback.compactMap { pledge -> CCUUpgradeCandidate? in
            guard pledge.isUpgrade else {
                return nil
            }

            let parsedPath = UpgradeTitleParser.parse(pledge.title)
                ?? pledge.displayedNotes.flatMap(UpgradeTitleParser.parse)
            let sourceShip = parsedPath.flatMap { shipIndex.matchShip(named: $0.sourceShipName) }
                ?? pledge.upgradeContext.flatMap { shipIndex.ship(forNumericID: $0.fromShipID) }
            let targetShip = parsedPath.flatMap { shipIndex.matchShip(named: $0.targetShipName) }
                ?? pledge.upgradeContext.flatMap { shipIndex.ship(forNumericID: $0.toShipID) }

            guard let sourceShip,
                  let targetShip else {
                return nil
            }

            let currentValueUSD = targetShip.msrpUSD - sourceShip.msrpUSD
            guard currentValueUSD.isGreaterThan(.zero) else {
                return nil
            }

            if targetShip.isStoreUpgradeAvailable {
                return nil
            }

            return CCUUpgradeCandidate(
                id: "buyback-\(pledge.id)",
                sourceShip: sourceShip,
                targetShip: targetShip,
                title: pledge.title,
                kind: .buyback,
                currentValueUSD: currentValueUSD,
                effectiveCostUSD: currentValueUSD,
                newPurchaseCostUSD: currentValueUSD,
                referenceID: "#\(pledge.id)"
            )
        }
    }

    private static func storeCandidates(
        shipIndex: CCUUpgradeShipIndex,
        excludingStoreWarbondPaths storeWarbondPaths: Set<CCUUpgradeStorePath> = []
    ) -> [CCUUpgradeCandidate] {
        let ships = shipIndex.ships
        var candidates: [CCUUpgradeCandidate] = []
        candidates.reserveCapacity(ships.count * max(ships.count - 1, 0) / 2)

        for sourceShip in ships {
            for targetShip in ships where sourceShip.msrpUSD.isLessThan(targetShip.msrpUSD) {
                guard !storeWarbondPaths.contains(
                    CCUUpgradeStorePath(sourceShip: sourceShip, targetShip: targetShip)
                ) else {
                    continue
                }

                let currentValueUSD = targetShip.msrpUSD - sourceShip.msrpUSD
                let kind: CCUUpgradeSourceKind = targetShip.isStoreUpgradeAvailable ? .store : .unavailableStore

                candidates.append(
                    CCUUpgradeCandidate(
                        id: "\(kind)-\(sourceShip.key)-\(targetShip.key)",
                        sourceShip: sourceShip,
                        targetShip: targetShip,
                        title: "\(sourceShip.name) to \(targetShip.name)",
                        kind: kind,
                        currentValueUSD: currentValueUSD,
                        effectiveCostUSD: currentValueUSD,
                        newPurchaseCostUSD: currentValueUSD,
                        referenceID: nil
                    )
                )
            }
        }

        return candidates
    }

    private static func storeWarbondCandidates(
        shipIndex: CCUUpgradeShipIndex,
        storeUpgradeOffers: [RSIShipCatalog.StoreUpgradeOffer]
    ) -> [CCUUpgradeCandidate] {
        var candidates: [CCUUpgradeCandidate] = []

        for offer in storeUpgradeOffers where offer.available {
            guard let targetShip = storeWarbondTargetShip(for: offer, shipIndex: shipIndex),
                  targetShip.msrpUSD.isGreaterThan(offer.priceUSD) else {
                continue
            }

            for sourceShip in shipIndex.ships where sourceShip.msrpUSD.isLessThan(offer.priceUSD) {
                let currentValueUSD = targetShip.msrpUSD - sourceShip.msrpUSD
                let effectiveCostUSD = offer.priceUSD - sourceShip.msrpUSD

                guard currentValueUSD.isGreaterThan(.zero),
                      effectiveCostUSD.isGreaterThan(.zero) else {
                    continue
                }

                let referenceID = offer.skuID.map { "SKU #\($0)" }
                candidates.append(
                    CCUUpgradeCandidate(
                        id: "store-warbond-\(offer.id)-\(sourceShip.key)-\(targetShip.key)",
                        sourceShip: sourceShip,
                        targetShip: targetShip,
                        title: "\(sourceShip.name) to \(targetShip.name) - \(offer.title)",
                        kind: .storeWarbond,
                        currentValueUSD: currentValueUSD,
                        effectiveCostUSD: effectiveCostUSD,
                        newPurchaseCostUSD: effectiveCostUSD,
                        referenceID: referenceID
                    )
                )
            }
        }

        return candidates
    }

    private static func storeWarbondTargetShip(
        for offer: RSIShipCatalog.StoreUpgradeOffer,
        shipIndex: CCUUpgradeShipIndex
    ) -> CCUUpgradeCatalogShip? {
        let nameMatch = shipIndex.matchShip(named: offer.targetShipName)
        let idMatch = offer.targetShipID.flatMap(shipIndex.ship(forNumericID:))

        guard let idMatch else {
            return nameMatch
        }

        guard let nameMatch else {
            return idMatch
        }

        return idMatch.key == nameMatch.key ? idMatch : nameMatch
    }

    private static func makePaymentRequirements(
        for steps: [CCUUpgradeCandidate],
        availableStoreCreditUSD: Decimal
    ) -> [String: CCUUpgradePaymentRequirement] {
        var remainingCreditUSD = availableStoreCreditUSD.nonNegative
        var requirements: [String: CCUUpgradePaymentRequirement] = [:]

        for step in steps where step.kind.requiresNewPurchase {
            let purchaseCostUSD = step.newPurchaseCostUSD.nonNegative
            let storeCreditUSD = step.kind.allowsStoreCredit ? purchaseCostUSD.minimum(remainingCreditUSD) : .zero
            let newMoneyUSD = purchaseCostUSD - storeCreditUSD

            requirements[step.id] = CCUUpgradePaymentRequirement(
                candidateID: step.id,
                purchaseCostUSD: purchaseCostUSD,
                storeCreditUSD: storeCreditUSD,
                newMoneyUSD: newMoneyUSD
            )

            remainingCreditUSD -= storeCreditUSD
        }

        return requirements
    }
}

nonisolated struct CCUUpgradeShipIndex: Sendable {
    let ships: [CCUUpgradeCatalogShip]

    private let shipsByKey: [String: CCUUpgradeCatalogShip]
    private let shipsByNumericID: [Int: CCUUpgradeCatalogShip]

    init(ships: [CCUUpgradeCatalogShip]) {
        self.ships = ships

        var keyedShips: [String: CCUUpgradeCatalogShip] = [:]
        var numericShips: [Int: CCUUpgradeCatalogShip] = [:]

        for ship in ships {
            numericShips[ship.numericID] = numericShips[ship.numericID] ?? ship
            keyedShips[ship.key] = keyedShips[ship.key] ?? ship
            keyedShips[UpgradeTitleParser.normalizedShipKey(ship.name)] = keyedShips[ship.key] ?? ship
            keyedShips[
                UpgradeTitleParser.normalizedShipKey(
                    UpgradeTitleParser.stripManufacturerPrefix(from: ship.name)
                )
            ] = keyedShips[ship.key] ?? ship

            for alias in ship.aliases {
                let aliasKey = UpgradeTitleParser.normalizedShipKey(alias)
                if !aliasKey.isEmpty {
                    keyedShips[aliasKey] = keyedShips[aliasKey] ?? ship
                }
            }
        }

        shipsByKey = keyedShips
        shipsByNumericID = numericShips
    }

    func ship(forKey key: String) -> CCUUpgradeCatalogShip? {
        shipsByKey[key]
    }

    func ship(forNumericID numericID: Int) -> CCUUpgradeCatalogShip? {
        shipsByNumericID[numericID]
    }

    func matchShip(named rawName: String) -> CCUUpgradeCatalogShip? {
        let directKey = UpgradeTitleParser.normalizedShipKey(rawName)
        if let directMatch = shipsByKey[directKey] {
            return directMatch
        }

        let strippedKey = UpgradeTitleParser.normalizedShipKey(
            UpgradeTitleParser.stripManufacturerPrefix(from: rawName)
        )
        return shipsByKey[strippedKey]
    }
}

private nonisolated struct CCUUpgradeRouteState: Hashable, Sendable {
    let steps: [CCUUpgradeCandidate]
    let totalEffectiveCostUSD: Decimal
    let totalNewPurchaseCostUSD: Decimal
    let unavailableStepCount: Int
    let priorityPenalty: Int

    static let empty = CCUUpgradeRouteState(
        steps: [],
        totalEffectiveCostUSD: .zero,
        totalNewPurchaseCostUSD: .zero,
        unavailableStepCount: 0,
        priorityPenalty: 0
    )

    func appending(_ candidate: CCUUpgradeCandidate) -> CCUUpgradeRouteState {
        CCUUpgradeRouteState(
            steps: steps + [candidate],
            totalEffectiveCostUSD: totalEffectiveCostUSD + candidate.effectiveCostUSD,
            totalNewPurchaseCostUSD: totalNewPurchaseCostUSD + candidate.newPurchaseCostUSD,
            unavailableStepCount: unavailableStepCount + (candidate.kind.isUnavailableStoreStep ? 1 : 0),
            priorityPenalty: priorityPenalty + candidate.kind.priority
        )
    }

    func isBetter(than other: CCUUpgradeRouteState) -> Bool {
        let newPurchaseComparison = totalNewPurchaseCostUSD.compare(to: other.totalNewPurchaseCostUSD)
        if newPurchaseComparison != .orderedSame {
            return newPurchaseComparison == .orderedAscending
        }

        let effectiveCostComparison = totalEffectiveCostUSD.compare(to: other.totalEffectiveCostUSD)
        if effectiveCostComparison != .orderedSame {
            return effectiveCostComparison == .orderedAscending
        }

        if unavailableStepCount != other.unavailableStepCount {
            return unavailableStepCount < other.unavailableStepCount
        }

        if priorityPenalty != other.priorityPenalty {
            return priorityPenalty < other.priorityPenalty
        }

        return steps.count < other.steps.count
    }
}

private extension Decimal {
    nonisolated func compare(to other: Decimal) -> ComparisonResult {
        NSDecimalNumber(decimal: self).compare(NSDecimalNumber(decimal: other))
    }

    nonisolated func isLessThan(_ other: Decimal) -> Bool {
        compare(to: other) == .orderedAscending
    }

    nonisolated func isLessThanOrEqual(to other: Decimal) -> Bool {
        compare(to: other) != .orderedDescending
    }

    nonisolated func isGreaterThan(_ other: Decimal) -> Bool {
        compare(to: other) == .orderedDescending
    }

    nonisolated func isGreaterThanOrEqual(to other: Decimal) -> Bool {
        compare(to: other) != .orderedAscending
    }

    nonisolated var nonNegative: Decimal {
        isLessThan(.zero) ? .zero : self
    }

    nonisolated func minimum(_ other: Decimal) -> Decimal {
        isLessThan(other) ? self : other
    }

    nonisolated var ccuUSDString: String {
        let number = NSDecimalNumber(decimal: self)
        let rounded = number.rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            )
        )
        return "$\(rounded)"
    }
}

private extension String {
    nonisolated var nilIfBlankForCCU: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
