import Foundation

nonisolated struct NormalizedHangarInventory: Sendable {
    let packages: [HangarPackage]
    let fleet: [FleetShip]
}

/// One owner for formatter state and bulk CPU work. A genuine actor hop keeps
/// normalization/projection off the UI executor without unchecked shared state.
actor HangarInventoryNormalizer {
    private lazy var engine = HangarInventoryNormalizationEngine()
    func hangar(_ remote: [RemotePledge], catalog: RSIShipCatalog?, prefix: [HangarPackage] = []) throws -> NormalizedHangarInventory {
        assert(!Thread.isMainThread)
        return try engine.hangar(remote, catalog: catalog, prefix: prefix)
    }
    func buyback(_ remote: [RemoteBuybackPledge], catalog: RSIShipCatalog?) throws -> [BuybackPledge] {
        assert(!Thread.isMainThread)
        return try engine.buyback(remote, catalog: catalog)
    }
    func isMainThread() -> Bool { Thread.isMainThread }
}

/// Synchronous value transformation shared with the offline reference workload.
/// Production callers use the actor above; WebKit/UI objects never enter it.
nonisolated struct HangarInventoryNormalizationEngine {
    func hangar(_ remote: [RemotePledge], catalog: RSIShipCatalog?, prefix: [HangarPackage] = []) throws -> NormalizedHangarInventory {
        let packages = try PerformanceTrace.measure("NormalizeHangar") {
            var values = prefix
            values.reserveCapacity(prefix.count + remote.count)
            for (index, pledge) in remote.enumerated() {
                if index % 64 == 0 { try Task.checkCancellation() }
                values.append(normalize(package: pledge, shipCatalog: catalog))
            }
            return values
        }
        try Task.checkCancellation()
        var fleet: [FleetShip] = []
        for start in stride(from: 0, to: packages.count, by: 64) {
            try Task.checkCancellation()
            fleet += FleetProjector.project(packages: Array(packages[start..<min(start + 64, packages.count)]), shipCatalog: catalog)
        }
        return NormalizedHangarInventory(packages: packages, fleet: fleet)
    }
    func buyback(_ remote: [RemoteBuybackPledge], catalog: RSIShipCatalog?) throws -> [BuybackPledge] {
        try PerformanceTrace.measure("NormalizeBuyback") {
            var values: [BuybackPledge] = []
            values.reserveCapacity(remote.count)
            for (index, pledge) in remote.enumerated() {
                if index % 64 == 0 { try Task.checkCancellation() }
                values.append(normalize(buyback: pledge, shipCatalog: catalog))
            }
            return values
        }
    }

    private func normalize(package remote: RemotePledge, shipCatalog: RSIShipCatalog?) -> HangarPackage {
        let containsSummary = remote.containsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let packageValueUSD = parseMoney(remote.valueText)
        let packageThumbnailURL = mirroredCatalogImageURL(
            remote.thumbnailImageURL.flatMap(URL.init(string:)),
            shipCatalog: shipCatalog
        )
        let insuranceOptions = inferInsuranceOptions(
            from: remote.alsoContains,
            containsSummary: containsSummary,
            items: remote.items
        )
        let contents = normalizeContents(
            for: remote,
            containsSummary: containsSummary,
            packageValueUSD: packageValueUSD,
            shipCatalog: shipCatalog,
            packageThumbnailURL: packageThumbnailURL
        )

        return HangarPackage(
            id: remote.id ?? stableNumericID(from: remote.title),
            title: normalizePackageTitle(remote.title),
            status: remote.statusText.nilIfEmpty ?? "Unknown",
            insurance: insuranceOptions.first ?? "Unknown",
            insuranceOptions: insuranceOptions.isEmpty ? nil : insuranceOptions,
            acquiredAt: parseRSIDate(remote.dateText) ?? .now,
            originalValueUSD: packageValueUSD,
            currentValueUSD: inferredCurrentValueUSD(contents: contents, shipCatalog: shipCatalog, fallbackValueUSD: packageValueUSD),
            canGift: remote.canGift,
            canReclaim: remote.canReclaim,
            canUpgrade: remote.canUpgrade,
            isUpgradedStatusFlag: remote.isUpgradedStatusFlag,
            upgradeMetadata: remote.upgradeMetadata?.domainModel,
            sourcePage: remote.sourcePage,
            sourcePageIndex: remote.sourcePageIndex,
            packageThumbnailURL: packageThumbnailURL,
            contents: contents
        )
    }

    private func normalizeContents(
        for remote: RemotePledge,
        containsSummary: String,
        packageValueUSD: Decimal,
        shipCatalog: RSIShipCatalog?,
        packageThumbnailURL: URL?
    ) -> [PackageItem] {
        let renderableRemoteItems = remote.items.filter {
            HangarPledgeSummaryParser.shouldRenderContentTitle($0.title)
        }
        let upgradeMeltValueUSD = inferredUpgradeMeltValue(
            items: renderableRemoteItems,
            packageValueUSD: packageValueUSD
        )
        let shouldUsePackageThumbnailFallback = renderableRemoteItems.count <= 1

        let liveItems = renderableRemoteItems.enumerated().map { offset, item in
            let itemCategory = category(for: item.kind, title: item.title, detail: item.detail)
            let upgradePath = itemCategory == .upgrade ? UpgradeTitleParser.parse(item.title) : nil
            let sourceShip = upgradePath.flatMap { shipCatalog?.matchShip(named: $0.sourceShipName) }
            let targetShip = upgradePath.flatMap { shipCatalog?.matchShip(named: $0.targetShipName) }

            return PackageItem(
                id: "\(remote.id ?? stableNumericID(from: remote.title))-\(offset)",
                title: item.title.nilIfEmpty ?? "Untitled Item",
                detail: item.detail.nilIfEmpty ?? item.kind.nilIfEmpty ?? "Unknown",
                category: itemCategory,
                imageURL: itemImageURL(
                    for: item,
                    category: itemCategory,
                    shipCatalog: shipCatalog,
                    targetShip: targetShip,
                    packageThumbnailURL: packageThumbnailURL,
                    usePackageThumbnailFallback: shouldUsePackageThumbnailFallback
                ),
                upgradePricing: upgradePricing(
                    path: upgradePath,
                    sourceShip: sourceShip,
                    targetShip: targetShip,
                    meltValueUSD: upgradeMeltValueUSD
                )
            )
        }

        let supplementalTitles = HangarPledgeSummaryParser.supplementalTitles(
            from: containsSummary,
            alsoContains: remote.alsoContains,
            excluding: [remote.title, normalizePackageTitle(remote.title)] + liveItems.map(\.title)
        )
        let supplementalItems = supplementalTitles.enumerated().map { offset, title in
            let detail = supplementalDetail(for: title)
            return PackageItem(
                id: "\(remote.id ?? stableNumericID(from: remote.title))-\(liveItems.count + offset)",
                title: title,
                detail: detail,
                category: category(for: "", title: title, detail: detail),
                imageURL: liveItems.isEmpty && offset == 0 ? packageThumbnailURL : nil,
                upgradePricing: nil
            )
        }

        if !liveItems.isEmpty {
            return liveItems + supplementalItems
        }

        if !supplementalItems.isEmpty {
            return supplementalItems
        }

        guard !containsSummary.isEmpty else {
            return []
        }

        return [
            PackageItem(
                id: "\(remote.id ?? stableNumericID(from: remote.title))-0",
                title: containsSummary,
                detail: "Extracted from the RSI pledge summary",
                category: .perk,
                imageURL: packageThumbnailURL,
                upgradePricing: nil
            )
        ]
    }

    private func supplementalDetail(for title: String) -> String {
        let lowercasedTitle = title.localizedLowercase

        if lowercasedTitle.contains("hangar") {
            return "Hangar entitlement"
        }

        if lowercasedTitle.contains("insurance")
            || HangarPackage.containsLifetimeInsuranceToken(lowercasedTitle) {
            return "Insurance"
        }

        return "RSI pledge entitlement"
    }

    private func itemImageURL(
        for item: RemotePledgeItem,
        category: PackageItem.Category,
        shipCatalog: RSIShipCatalog?,
        targetShip: RSIShipCatalog.Ship?,
        packageThumbnailURL: URL?,
        usePackageThumbnailFallback: Bool
    ) -> URL? {
        if let directURL = item.imageURL.flatMap(URL.init(string:)) {
            return mirroredCatalogImageURL(directURL, shipCatalog: shipCatalog)
        }

        if let specialEditionURL = specialEditionImageURL(
            for: item.title,
            packageThumbnailURL: packageThumbnailURL
        ) {
            return specialEditionURL
        }

        switch category {
        case .upgrade:
            return nil
        case .ship, .vehicle:
            return shipCatalog?.matchShip(named: item.title)?.imageURL ?? (usePackageThumbnailFallback ? packageThumbnailURL : nil)
        case .gamePackage, .flair, .perk:
            return usePackageThumbnailFallback ? packageThumbnailURL : nil
        }
    }

    private func specialEditionImageURL(
        for itemTitle: String,
        packageThumbnailURL: URL?
    ) -> URL? {
        if itemTitle.localizedCaseInsensitiveContains("Dragonfly Star Kitten Edition") {
            return packageThumbnailURL
        }

        return nil
    }

    private func upgradePricing(
        path: ShipUpgradePath?,
        sourceShip: RSIShipCatalog.Ship?,
        targetShip: RSIShipCatalog.Ship?,
        meltValueUSD: Decimal?
    ) -> PackageItem.UpgradePricing? {
        guard let path else {
            return nil
        }

        let actualValueUSD: Decimal?
        if let sourceMSRP = sourceShip?.msrpUSD, let targetMSRP = targetShip?.msrpUSD {
            actualValueUSD = targetMSRP - sourceMSRP
        } else {
            actualValueUSD = nil
        }

        return PackageItem.UpgradePricing(
            sourceShipName: path.sourceShipName,
            sourceShipMSRPUSD: sourceShip?.msrpUSD,
            sourceShipImageURL: sourceShip?.imageURL,
            targetShipName: path.targetShipName,
            targetShipMSRPUSD: targetShip?.msrpUSD,
            targetShipImageURL: targetShip?.imageURL,
            actualValueUSD: actualValueUSD,
            meltValueUSD: meltValueUSD
        )
    }

    private func inferredCurrentValueUSD(
        contents: [PackageItem],
        shipCatalog: RSIShipCatalog?,
        fallbackValueUSD: Decimal
    ) -> Decimal {
        let shipLikeItems = contents.filter(\.isShipLike)
        let shipLikeValueUSD = shipLikeItems.reduce(into: Decimal.zero) { partialResult, item in
            partialResult += shipCatalog?.matchShip(named: item.title)?.msrpUSD ?? .zero
        }

        if !shipLikeItems.isEmpty, shipLikeValueUSD > 0 {
            return shipLikeValueUSD
        }

        let upgradeValueUSD = contents.reduce(into: Decimal.zero) { partialResult, item in
            partialResult += item.upgradePricing?.actualValueUSD ?? .zero
        }

        if upgradeValueUSD > 0 {
            return upgradeValueUSD
        }

        return fallbackValueUSD
    }

    private func inferredUpgradeMeltValue(items: [RemotePledgeItem], packageValueUSD: Decimal) -> Decimal? {
        guard packageValueUSD > 0 else {
            return nil
        }

        let upgradeItems = items.filter {
            category(for: $0.kind, title: $0.title, detail: $0.detail) == .upgrade
        }

        guard !upgradeItems.isEmpty else {
            return nil
        }

        let nonUpgradeCategories = items
            .map { category(for: $0.kind, title: $0.title, detail: $0.detail) }
            .filter { $0 != .upgrade && $0 != .perk && $0 != .flair }

        return nonUpgradeCategories.isEmpty ? packageValueUSD : nil
    }

    private func normalize(buyback remote: RemoteBuybackPledge, shipCatalog: RSIShipCatalog?) -> BuybackPledge {
        let title = remote.title.nilIfEmpty ?? "Untitled Buy Back"
        let notes = remote.containsText.nilIfEmpty ?? ""

        return BuybackPledge(
            id: remote.id ?? stableNumericID(from: title),
            title: title,
            recoveredValueUSD: parseMoney(remote.valueText),
            addedToBuybackAt: parseRSIDate(remote.dateText) ?? BuybackPledge.unknownAddedToBuybackDate,
            notes: notes,
            imageURL: mirroredCatalogImageURL(
                remote.imageURL.flatMap(URL.init(string:)),
                shipCatalog: shipCatalog
            ),
            upgradeContext: remote.upgradeContext,
            sourceRawInfo: remote.sourceRawInfo
        )
    }

    private func mirroredCatalogImageURL(_ originalURL: URL?, shipCatalog: RSIShipCatalog?) -> URL? {
        guard let originalURL else {
            return nil
        }

        return shipCatalog?.mirroredAssetURL(for: originalURL) ?? originalURL
    }

    private func normalizePackageTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.localizedCaseInsensitiveContains("contains"),
           trimmed.localizedCaseInsensitiveContains("nameable ship"),
           let prefix = trimmed.components(separatedBy: " Contains ").first {
            return prefix
        }

        return trimmed.isEmpty ? "Untitled Pledge" : trimmed
    }

    private func category(for kind: String, title: String, detail: String) -> PackageItem.Category {
        let haystack = [kind, title, detail]
            .joined(separator: " ")
            .localizedLowercase

        if haystack.contains("upgrade") || title.contains(" to ") {
            return .upgrade
        }

        if haystack.contains("game package") || haystack.contains("digital download") {
            return .gamePackage
        }

        if haystack.contains("vehicle") || haystack.contains("ground vehicle") || haystack.contains("bike") {
            return .vehicle
        }

        if haystack.contains("ship") || haystack.contains("gunboat") || haystack.contains("fighter") || haystack.contains("freighter") {
            return .ship
        }

        if haystack.contains("paint") || haystack.contains("skin") || haystack.contains("hangar") || haystack.contains("flair") {
            return .flair
        }

        if haystack.contains("perk") || haystack.contains("reward") || haystack.contains("token") || haystack.contains("coin") {
            return .perk
        }

        return .perk
    }

    private func inferInsuranceOptions(
        from alsoContains: [String],
        containsSummary: String,
        items: [RemotePledgeItem]
    ) -> [String] {
        let itemCandidates = items.flatMap { item in
            [item.title, item.kind, item.detail]
        }
        let candidates = alsoContains + containsSummary.components(separatedBy: "#") + itemCandidates
        let extractedOptions = candidates.flatMap(extractInsuranceOptions(from:))

        return HangarPackage.normalizedInsuranceLevels(extractedOptions)
    }

    private func extractInsuranceOptions(from rawValue: String) -> [String] {
        let value = rawValue
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty else {
            return []
        }

        var results: [String] = []
        let lowercased = value.localizedLowercase

        if HangarPackage.containsLifetimeInsuranceToken(lowercased) {
            results.append("LTI")
        }

        results.append(contentsOf: allMatches(in: lowercased, pattern: #"(\d+)\s*(month|months|mo)\b"#).map { "\($0) months" })
        results.append(contentsOf: allMatches(in: lowercased, pattern: #"(\d+)\s*(year|years|yr)\b"#).map { "\($0 * 12) months" })

        return results
    }

    private func parseMoney(_ value: String) -> Decimal {
        let normalized = value
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty, !normalized.localizedCaseInsensitiveContains("uec") else {
            return .zero
        }

        if let direct = Decimal(string: normalized.filter { $0.isNumber || $0 == "." || $0 == "-" }) {
            return direct
        }

        return .zero
    }

    private func parseRSIDate(_ value: String) -> Date? {
        let normalized = value
            .replacingOccurrences(
                of: #"(?i)\b(?:created|date|added|reclaimed|recovered)\s*:"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"\b(\d{1,2})(st|nd|rd|th)\b"#,
                with: "$1",
                options: [.regularExpression, .caseInsensitive]
            )

        guard !normalized.isEmpty else {
            return nil
        }

        for formatter in dateFormatters {
            if let date = formatter.date(from: normalized) {
                return date
            }
        }

        return nil
    }

    private func firstMatch(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return Int(text[captureRange])
    }

    private func allMatches(in text: String, pattern: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let captureRange = Range(match.range(at: 1), in: text) else {
                return nil
            }

            return Int(text[captureRange])
        }
    }

    private func stableNumericID(from text: String) -> Int {
        var value = 0
        for scalar in text.unicodeScalars {
            value = (value &* 31 &+ Int(scalar.value)) & 0x7fffffff
        }
        return max(value, 1)
    }

    private let dateFormatters: [DateFormatter] = {
        let formats = [
            "MMM d, yyyy",
            "MMM dd, yyyy",
            "MMMM d, yyyy",
            "MMMM dd, yyyy",
            "MMM d yyyy",
            "MMM dd yyyy",
            "MMMM d yyyy",
            "MMMM dd yyyy",
            "yyyy-MM-dd"
        ]

        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
    }()
}

private extension String {
    nonisolated var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
