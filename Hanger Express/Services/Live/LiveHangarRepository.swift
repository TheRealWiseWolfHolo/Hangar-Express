import Foundation
import WebKit

@MainActor
final class LiveHangarRepository: HangarRepository {
    private let browser = RSIAccountPageBrowser()
    private let shipCatalogClient = HostedShipCatalogClient()
    private let previewRepository = PreviewHangarRepository()
    private let pledgePageSize = 50
    private let buybackPageSize = 100
    private let maxPledgePages = 200
    private let maxBuybackPages = 100

    func fetchSnapshot(
        for session: UserSession,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        if session.authMode == .developerPreview {
            return try await previewRepository.fetchSnapshot(for: session, progress: progress)
        }

        try validate(session: session)
        progress(preparationProgress(for: session, stepNumber: 1, stepCount: 4))

        let remotePledges = try await fetchRemotePledges(
            using: session.cookies,
            progress: progress,
            stepNumber: 2,
            stepCount: 4
        )
        let remoteBuyback = try await fetchRemoteBuyback(
            using: session.cookies,
            progress: progress,
            stepNumber: 3,
            stepCount: 4
        )
        let shipCatalog = await fetchHostedShipCatalog(
            progress: progress,
            stepNumber: 4,
            stepCount: 4
        )
        let accountContext = try await fetchAccountContext(
            for: session,
            progress: progress,
            stepNumber: 4,
            stepCount: 4
        )

        let packages = remotePledges.map { normalize(package: $0, shipCatalog: shipCatalog) }
        let fleet = FleetProjector.project(packages: packages, shipCatalog: shipCatalog)
        let buyback = remoteBuyback.map(normalize(buyback:))

        progress(
            makeProgress(
                stage: .finalizing,
                stepNumber: 4,
                stepCount: 4,
                detail: "Organized \(remotePledges.count) pledges and \(remoteBuyback.count) buy-back items.",
                completedUnitCount: 3,
                totalUnitCount: 3
            )
        )

        return HangarSnapshot(
            accountHandle: session.handle,
            lastSyncedAt: .now,
            avatarURL: accountContext.avatarURL ?? session.avatarURL,
            primaryOrganization: accountContext.primaryOrganization,
            storeCreditUSD: accountContext.storeCreditUSD,
            totalSpendUSD: accountContext.totalSpendUSD,
            packages: packages,
            fleet: fleet,
            buyback: buyback,
            referralStats: accountContext.referralStats
        )
    }

    func refreshHangarData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        if session.authMode == .developerPreview {
            return try await previewRepository.refreshHangarData(
                for: session,
                from: snapshot,
                progress: progress
            )
        }

        try validate(session: session)
        progress(preparationProgress(for: session, stepNumber: 1, stepCount: 3))

        let remotePledges = try await fetchRemotePledges(
            using: session.cookies,
            progress: progress,
            stepNumber: 2,
            stepCount: 3
        )
        let shipCatalog = await fetchHostedShipCatalog(
            progress: progress,
            stepNumber: 3,
            stepCount: 3
        )
        let packages = remotePledges.map { normalize(package: $0, shipCatalog: shipCatalog) }
        let fleet = FleetProjector.project(packages: packages, shipCatalog: shipCatalog)

        progress(
            makeProgress(
                stage: .finalizing,
                stepNumber: 3,
                stepCount: 3,
                detail: "Organized \(remotePledges.count) pledges into the hangar and fleet views.",
                completedUnitCount: 2,
                totalUnitCount: 2
            )
        )

        return snapshot.updatingHangar(
            packages: packages,
            fleet: fleet
        )
    }

    func refreshBuybackData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        if session.authMode == .developerPreview {
            return try await previewRepository.refreshBuybackData(
                for: session,
                from: snapshot,
                progress: progress
            )
        }

        try validate(session: session)
        progress(preparationProgress(for: session, stepNumber: 1, stepCount: 2))

        let remoteBuyback = try await fetchRemoteBuyback(
            using: session.cookies,
            progress: progress,
            stepNumber: 2,
            stepCount: 2
        )
        let buyback = remoteBuyback.map(normalize(buyback:))

        return snapshot.updatingBuyback(
            buyback: buyback
        )
    }

    func refreshAccountData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        if session.authMode == .developerPreview {
            return try await previewRepository.refreshAccountData(
                for: session,
                from: snapshot,
                progress: progress
            )
        }

        try validate(session: session)
        progress(preparationProgress(for: session, stepNumber: 1, stepCount: 2))

        let accountContext = try await fetchAccountContext(
            for: session,
            progress: progress,
            stepNumber: 2,
            stepCount: 2
        )

        return snapshot.updatingAccount(
            accountHandle: session.handle,
            avatarURL: accountContext.didRefreshAccountOverview ? accountContext.avatarURL : snapshot.avatarURL,
            primaryOrganization: accountContext.didRefreshPrimaryOrganization ? accountContext.primaryOrganization : snapshot.primaryOrganization,
            storeCreditUSD: accountContext.didRefreshAccountOverview ? accountContext.storeCreditUSD : snapshot.storeCreditUSD,
            totalSpendUSD: accountContext.didRefreshAccountOverview ? accountContext.totalSpendUSD : snapshot.totalSpendUSD,
            referralStats: accountContext.didRefreshReferralStats ? accountContext.referralStats : snapshot.referralStats,
            lastSyncedAt: (accountContext.didRefreshAccountOverview || accountContext.didRefreshReferralStats) ? .now : snapshot.lastSyncedAt
        )
    }

    private func validate(session: UserSession) throws {
        guard !session.cookies.isEmpty else {
            throw LiveHangarRepositoryError.sessionUnavailable
        }
    }

    private func preparationProgress(
        for session: UserSession,
        stepNumber: Int,
        stepCount: Int
    ) -> RefreshProgress {
        makeProgress(
            stage: .preparingSession,
            stepNumber: stepNumber,
            stepCount: stepCount,
            detail: "Restoring \(session.cookies.count) saved RSI cookies.",
            completedUnitCount: 1,
            totalUnitCount: 1
        )
    }

    private func fetchRemotePledges(
        using cookies: [SessionCookie],
        progress: @escaping RefreshProgressHandler,
        stepNumber: Int,
        stepCount: Int
    ) async throws -> [RemotePledge] {
        var remotePledges: [RemotePledge] = []
        var pledgeTotalPages: Int?
        var previousPledgePageSignature: String?
        var didReachEndOfPledges = false

        for page in 1 ... maxPledgePages {
            progress(
                makeProgress(
                    stage: .pledges,
                    stepNumber: stepNumber,
                    stepCount: stepCount,
                    detail: pageDetail(
                        for: "pledges",
                        page: page,
                        totalPages: pledgeTotalPages,
                        loadedCount: remotePledges.count,
                        isLoading: true
                    ),
                    completedUnitCount: max(page - 1, 0),
                    totalUnitCount: pledgeTotalPages
                )
            )

            let result = try await browser.extractPledges(
                using: cookies,
                page: page,
                pageSize: pledgePageSize
            )

            if result.accessDenied {
                throw LiveHangarRepositoryError.sessionExpired
            }

            remotePledges.append(contentsOf: result.items)

            pledgeTotalPages = mergedTotalPages(
                known: pledgeTotalPages,
                discovered: inferredTotalPages(
                    reportedByPage: result.totalPages,
                    page: page,
                    pageItemCount: result.items.count,
                    hasNextPage: result.hasNextPage
                )
            )

            progress(
                makeProgress(
                    stage: .pledges,
                    stepNumber: stepNumber,
                    stepCount: stepCount,
                    detail: pageDetail(
                        for: "pledges",
                        page: page,
                        totalPages: pledgeTotalPages,
                        loadedCount: remotePledges.count,
                        isLoading: false
                    ),
                    completedUnitCount: page,
                    totalUnitCount: pledgeTotalPages
                )
            )

            if shouldStopFetching(
                after: page,
                pageItemCount: result.items.count,
                knownTotalPages: pledgeTotalPages,
                hasNextPage: result.hasNextPage,
                pageSignature: result.pageSignature,
                previousPageSignature: previousPledgePageSignature
            ) {
                didReachEndOfPledges = true
                break
            }

            previousPledgePageSignature = result.pageSignature
        }

        guard didReachEndOfPledges else {
            throw LiveHangarRepositoryError.pageLimitReached(
                itemLabel: "hangar pledges",
                limit: maxPledgePages
            )
        }

        return remotePledges
    }

    private func fetchRemoteBuyback(
        using cookies: [SessionCookie],
        progress: @escaping RefreshProgressHandler,
        stepNumber: Int,
        stepCount: Int
    ) async throws -> [RemoteBuybackPledge] {
        var remoteBuyback: [RemoteBuybackPledge] = []
        var buybackTotalPages: Int?
        var previousBuybackPageSignature: String?
        var didReachEndOfBuyback = false

        for page in 1 ... maxBuybackPages {
            progress(
                makeProgress(
                    stage: .buyback,
                    stepNumber: stepNumber,
                    stepCount: stepCount,
                    detail: pageDetail(
                        for: "buy-back items",
                        page: page,
                        totalPages: buybackTotalPages,
                        loadedCount: remoteBuyback.count,
                        isLoading: true
                    ),
                    completedUnitCount: max(page - 1, 0),
                    totalUnitCount: buybackTotalPages
                )
            )

            let result = try await browser.extractBuybackPledges(
                using: cookies,
                page: page,
                pageSize: buybackPageSize
            )

            if result.accessDenied {
                throw LiveHangarRepositoryError.sessionExpired
            }

            remoteBuyback.append(contentsOf: result.items)

            buybackTotalPages = mergedTotalPages(
                known: buybackTotalPages,
                discovered: inferredTotalPages(
                    reportedByPage: result.totalPages,
                    page: page,
                    pageItemCount: result.items.count,
                    hasNextPage: result.hasNextPage
                )
            )

            progress(
                makeProgress(
                    stage: .buyback,
                    stepNumber: stepNumber,
                    stepCount: stepCount,
                    detail: pageDetail(
                        for: "buy-back items",
                        page: page,
                        totalPages: buybackTotalPages,
                        loadedCount: remoteBuyback.count,
                        isLoading: false
                    ),
                    completedUnitCount: page,
                    totalUnitCount: buybackTotalPages
                )
            )

            if shouldStopFetching(
                after: page,
                pageItemCount: result.items.count,
                knownTotalPages: buybackTotalPages,
                hasNextPage: result.hasNextPage,
                pageSignature: result.pageSignature,
                previousPageSignature: previousBuybackPageSignature
            ) {
                didReachEndOfBuyback = true
                break
            }

            previousBuybackPageSignature = result.pageSignature
        }

        guard didReachEndOfBuyback else {
            throw LiveHangarRepositoryError.pageLimitReached(
                itemLabel: "buy-back pledges",
                limit: maxBuybackPages
            )
        }

        return remoteBuyback
    }

    private func fetchHostedShipCatalog(
        progress: @escaping RefreshProgressHandler,
        stepNumber: Int,
        stepCount: Int
    ) async -> RSIShipCatalog? {
        progress(
            makeProgress(
                stage: .finalizing,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: "Loading hosted ship MSRP and thumbnail data for upgrade valuation.",
                completedUnitCount: 0,
                totalUnitCount: 2
            )
        )

        let shipCatalog: RSIShipCatalog?
        do {
            shipCatalog = try await shipCatalogClient.fetchCatalog()
        } catch {
            shipCatalog = nil
        }

        progress(
            makeProgress(
                stage: .finalizing,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: shipCatalog == nil
                    ? "Hosted ship valuation data was unavailable. Continuing with hangar media only."
                    : "Loaded \(shipCatalog?.ships.count ?? 0) hosted ships for MSRP and image enrichment.",
                completedUnitCount: 1,
                totalUnitCount: 2
            )
        )

        return shipCatalog
    }

    private func fetchAccountContext(
        for session: UserSession,
        progress: @escaping RefreshProgressHandler,
        stepNumber: Int,
        stepCount: Int
    ) async throws -> AccountRefreshContext {
        progress(
            makeProgress(
                stage: .account,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: "Loading account balances and profile details.",
                completedUnitCount: 0,
                totalUnitCount: 3
            )
        )

        let accountOverview = try await optionalAccountFetch {
            try await browser.fetchAccountOverview(
                using: session.cookies,
                profileName: session.displayName
            )
        }
        let didRefreshAccountOverview = accountOverview != nil

        progress(
            makeProgress(
                stage: .account,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: accountOverview == nil
                    ? "Account balances were unavailable. Continuing with saved account metadata."
                    : "Loaded \(accountOverview?.storeCreditUSD?.usdString ?? "an unavailable") store credit balance and \(accountOverview?.totalSpendUSD?.usdString ?? "an unavailable total spend").",
                completedUnitCount: 1,
                totalUnitCount: 3
            )
        )

        let refreshedReferralStats = try await optionalAccountFetch {
            try await browser.fetchReferralStats(using: session.cookies)
        }
        let didRefreshReferralStats = refreshedReferralStats != nil
        let referralStats = refreshedReferralStats ?? .unavailable
        let currentReferralDetail = referralStats.currentLadderCount.map { "\($0) current referrals" } ?? "unavailable current referrals"
        let legacyReferralDetail = referralStats.hasLegacyLadder
            ? referralStats.legacyLadderCount.map { "\($0) legacy referrals" } ?? "unavailable legacy referrals"
            : "no legacy referral ladder"

        progress(
            makeProgress(
                stage: .account,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: "Loaded \(currentReferralDetail) and \(legacyReferralDetail).",
                completedUnitCount: 2,
                totalUnitCount: 3
            )
        )

        progress(
            makeProgress(
                stage: .account,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: "Account overview sync complete.",
                completedUnitCount: 3,
                totalUnitCount: 3
            )
        )

        return AccountRefreshContext(
            avatarURL: accountOverview?.avatarURL,
            primaryOrganization: accountOverview?.primaryOrganization,
            storeCreditUSD: accountOverview?.storeCreditUSD,
            totalSpendUSD: accountOverview?.totalSpendUSD,
            referralStats: referralStats,
            didRefreshAccountOverview: didRefreshAccountOverview,
            didRefreshPrimaryOrganization: accountOverview?.didRefreshPrimaryOrganization ?? false,
            didRefreshReferralStats: didRefreshReferralStats
        )
    }

    private func optionalAccountFetch<T>(
        _ operation: () async throws -> T
    ) async throws -> T? {
        do {
            return try await operation()
        } catch let error as LiveHangarRepositoryError where error.requiresReauthentication {
            throw error
        } catch {
            return nil
        }
    }

    private func makeProgress(
        stage: RefreshStage,
        stepNumber: Int,
        stepCount: Int,
        detail: String,
        completedUnitCount: Int,
        totalUnitCount: Int?
    ) -> RefreshProgress {
        RefreshProgress(
            stage: stage,
            stepNumber: stepNumber,
            stepCount: stepCount,
            detail: detail,
            completedUnitCount: completedUnitCount,
            totalUnitCount: totalUnitCount
        )
    }

    private func inferredTotalPages(
        reportedByPage: Int?,
        page: Int,
        pageItemCount: Int,
        hasNextPage: Bool?
    ) -> Int? {
        if let reportedByPage, reportedByPage > 0 {
            return reportedByPage
        }

        if hasNextPage == false {
            return page
        }

        if pageItemCount == 0 {
            return max(page - 1, 1)
        }

        return nil
    }

    private func mergedTotalPages(known: Int?, discovered: Int?) -> Int? {
        switch (known, discovered) {
        case let (known?, discovered?):
            return max(known, discovered)
        case let (known?, nil):
            return known
        case let (nil, discovered?):
            return discovered
        case (nil, nil):
            return nil
        }
    }

    private func shouldStopFetching(
        after page: Int,
        pageItemCount: Int,
        knownTotalPages: Int?,
        hasNextPage: Bool?,
        pageSignature: String?,
        previousPageSignature: String?
    ) -> Bool {
        if let knownTotalPages, page >= knownTotalPages {
            return true
        }

        if let hasNextPage {
            return !hasNextPage
        }

        if pageItemCount == 0 {
            return true
        }

        if let pageSignature, let previousPageSignature, pageSignature == previousPageSignature {
            return true
        }

        return false
    }

    private func pageDetail(
        for itemLabel: String,
        page: Int,
        totalPages: Int?,
        loadedCount: Int,
        isLoading: Bool
    ) -> String {
        let pageLabel: String
        if let totalPages, totalPages > 0 {
            pageLabel = "page \(page) of \(totalPages)"
        } else {
            pageLabel = "page \(page)"
        }

        let countLabel = loadedCount == 1 ? "1 \(itemLabel.dropLast())" : "\(loadedCount) \(itemLabel)"

        if isLoading {
            if loadedCount > 0 {
                return "Loading \(pageLabel). \(countLabel) already synced."
            }

            return "Loading \(pageLabel)."
        }

        return "Finished \(pageLabel). \(countLabel) synced so far."
    }

    private func normalize(package remote: RemotePledge, shipCatalog: RSIShipCatalog?) -> HangarPackage {
        let containsSummary = remote.containsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let packageValueUSD = parseMoney(remote.valueText)
        let packageThumbnailURL = remote.thumbnailImageURL.flatMap(URL.init(string:))
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
        let upgradeMeltValueUSD = inferredUpgradeMeltValue(
            package: remote,
            packageValueUSD: packageValueUSD
        )
        let shouldUsePackageThumbnailFallback = remote.items.count <= 1

        let liveItems = remote.items.enumerated().map { offset, item in
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

        if !liveItems.isEmpty {
            return liveItems
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

    private func itemImageURL(
        for item: RemotePledgeItem,
        category: PackageItem.Category,
        shipCatalog: RSIShipCatalog?,
        targetShip: RSIShipCatalog.Ship?,
        packageThumbnailURL: URL?,
        usePackageThumbnailFallback: Bool
    ) -> URL? {
        if let directURL = item.imageURL.flatMap(URL.init(string:)) {
            return directURL
        }

        switch category {
        case .upgrade:
            return targetShip?.imageURL ?? (usePackageThumbnailFallback ? packageThumbnailURL : nil)
        case .ship, .vehicle:
            return shipCatalog?.matchShip(named: item.title)?.imageURL ?? (usePackageThumbnailFallback ? packageThumbnailURL : nil)
        case .gamePackage, .flair, .perk:
            return usePackageThumbnailFallback ? packageThumbnailURL : nil
        }
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
            targetShipName: path.targetShipName,
            targetShipMSRPUSD: targetShip?.msrpUSD,
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

    private func inferredUpgradeMeltValue(package remote: RemotePledge, packageValueUSD: Decimal) -> Decimal? {
        guard packageValueUSD > 0 else {
            return nil
        }

        let upgradeItems = remote.items.filter {
            category(for: $0.kind, title: $0.title, detail: $0.detail) == .upgrade
        }

        guard !upgradeItems.isEmpty else {
            return nil
        }

        let nonUpgradeCategories = remote.items
            .map { category(for: $0.kind, title: $0.title, detail: $0.detail) }
            .filter { $0 != .upgrade && $0 != .perk && $0 != .flair }

        return nonUpgradeCategories.isEmpty ? packageValueUSD : nil
    }

    private func normalize(buyback remote: RemoteBuybackPledge) -> BuybackPledge {
        let title = remote.title.nilIfEmpty ?? "Untitled Buy Back"
        let notes = remote.containsText.nilIfEmpty ?? ""

        return BuybackPledge(
            id: remote.id ?? stableNumericID(from: title),
            title: title,
            recoveredValueUSD: parseMoney(remote.valueText),
            addedToBuybackAt: parseRSIDate(remote.dateText) ?? .now,
            notes: notes,
            imageURL: remote.imageURL.flatMap(URL.init(string:))
        )
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

        if lowercased.contains("lti") || lowercased.contains("lifetime") {
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
            .replacingOccurrences(of: "Created:", with: "")
            .replacingOccurrences(of: "Date:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return nil
        }

        for formatter in Self.dateFormatters {
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

    private static let dateFormatters: [DateFormatter] = {
        let formats = [
            "MMM d, yyyy",
            "MMM dd, yyyy",
            "MMMM d, yyyy",
            "MMMM dd, yyyy",
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

enum LiveHangarRepositoryError: Error, LocalizedError, Equatable {
    case sessionUnavailable
    case sessionExpired
    case unexpectedMarkup(String)
    case pageLimitReached(itemLabel: String, limit: Int)

    var requiresReauthentication: Bool {
        switch self {
        case .sessionUnavailable, .sessionExpired:
            return true
        case .unexpectedMarkup, .pageLimitReached:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            return "No saved RSI session cookies were available for a live hangar refresh."
        case .sessionExpired:
            return "The saved RSI session expired. Sign in again to refresh the live hangar."
        case let .unexpectedMarkup(message):
            return message
        case let .pageLimitReached(itemLabel, limit):
            return "Live RSI refresh hit the safety limit after \(limit) pages while loading \(itemLabel)."
        }
    }
}

enum FleetProjector {
    static func project(packages: [HangarPackage], shipCatalog: RSIShipCatalog?) -> [FleetShip] {
        packages.flatMap { package in
            let fleetEntries = package.contents.compactMap { item -> (PackageItem, RSIShipCatalog.Ship?)? in
                guard item.category == .ship || item.category == .vehicle else {
                    return nil
                }

                let matchedShip = shipCatalog?.matchShip(named: item.title)

                if matchedShip == nil, isObviousEquipmentItem(item) {
                    return nil
                }

                return (item, matchedShip)
            }

            return fleetEntries.enumerated().map { offset, entry in
                let meltValue = fleetEntries.count == 1 ? package.originalValueUSD : .zero
                let item = entry.0
                let matchedShip = entry.1

                return FleetShip(
                    id: package.id * 100 + offset,
                    displayName: item.title,
                    manufacturer: manufacturer(for: item, matchedShip: matchedShip),
                    role: role(for: item, matchedShip: matchedShip),
                    roleCategories: roleCategories(for: item, matchedShip: matchedShip),
                    msrpUSD: hostedMSRP(for: matchedShip),
                    insurance: package.insurance,
                    sourcePackageID: package.id,
                    sourcePackageName: package.title,
                    meltValueUSD: meltValue,
                    canGift: package.canGift,
                    canReclaim: package.canReclaim,
                    imageURL: matchedShip?.imageURL ?? item.imageURL
                )
            }
        }
    }

    private static func manufacturer(for item: PackageItem, matchedShip: RSIShipCatalog.Ship?) -> String {
        if let manufacturer = matchedShip?.manufacturer?.nilIfEmpty {
            return manufacturer
        }

        let candidates = [item.detail, item.title]
        let manufacturers: [(match: String, display: String)] = [
            ("Grey's Market", "Grey's Market"),
            ("GREY", "Grey's Market"),
            ("Aegis", "Aegis"),
            ("Anvil", "Anvil"),
            ("ARGO", "ARGO"),
            ("Banu", "Banu"),
            ("Consolidated Outland", "Consolidated Outland"),
            ("Crusader", "Crusader"),
            ("Drake", "Drake"),
            ("Esperia", "Esperia"),
            ("Gatac", "Gatac"),
            ("Greycat", "Greycat"),
            ("Kruger", "Kruger"),
            ("MISC", "MISC"),
            ("Mirai", "Mirai"),
            ("Origin", "Origin"),
            ("RSI", "RSI"),
            ("Tumbril", "Tumbril")
        ]

        for manufacturer in manufacturers {
            if candidates.contains(where: { $0.localizedCaseInsensitiveContains(manufacturer.match) }) {
                return manufacturer.display
            }
        }

        return "Unknown"
    }

    private static func role(for item: PackageItem, matchedShip: RSIShipCatalog.Ship?) -> String {
        if let hostedSummary = matchedShip?.roleSummary?.nilIfEmpty {
            return hostedSummary
        }

        let detail = item.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty, detail.caseInsensitiveCompare(item.category.rawValue) != .orderedSame {
            return detail
        }

        return item.category.rawValue
    }

    private static func roleCategories(for item: PackageItem, matchedShip: RSIShipCatalog.Ship?) -> [String] {
        let hostedCategories = matchedShip?.roleCategories ?? []
        if !hostedCategories.isEmpty {
            return hostedCategories
        }

        let fallbackRole = role(for: item, matchedShip: matchedShip)
        let fallbackCategories = fallbackRole
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return fallbackCategories.isEmpty ? [fallbackRole] : fallbackCategories
    }

    private static func hostedMSRP(for matchedShip: RSIShipCatalog.Ship?) -> Decimal? {
        matchedShip?.msrpUSD
    }

    private static func isObviousEquipmentItem(_ item: PackageItem) -> Bool {
        let haystack = [item.title, item.detail]
            .joined(separator: " ")
            .localizedLowercase

        let equipmentKeywords = [
            "armor",
            "armour",
            "attachment",
            "ammo",
            "backpack",
            "grenade",
            "helmet",
            "knife",
            "magazine",
            "medgun",
            "medpen",
            "multi-tool",
            "multitool",
            "pistol",
            "rifle",
            "shotgun",
            "smg",
            "sniper",
            "undersuit",
            "weapon"
        ]

        return equipmentKeywords.contains(where: haystack.contains)
    }
}

@MainActor
private final class RSIAccountPageBrowser: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func extractPledges(
        using cookies: [SessionCookie],
        page: Int,
        pageSize: Int
    ) async throws -> RemotePledgePage {
        let url = try pageURL(path: "/en/account/pledges", page: page, pageSize: pageSize)
        try await prepareWebView(with: cookies)
        try await load(url: url)
        return try await evaluate(script: Self.pledgesExtractionScript, as: RemotePledgePage.self)
    }

    func extractBuybackPledges(
        using cookies: [SessionCookie],
        page: Int,
        pageSize: Int
    ) async throws -> RemoteBuybackPage {
        let url = try pageURL(path: "/en/account/buy-back-pledges", page: page, pageSize: pageSize)
        try await prepareWebView(with: cookies)
        try await load(url: url)
        return try await evaluate(script: Self.buybackExtractionScript, as: RemoteBuybackPage.self)
    }

    func fetchShipCatalog(using cookies: [SessionCookie]) async throws -> RSIShipCatalog {
        let url = try storefrontURL(path: "/pledge-store/ship-upgrades")
        try await prepareWebView(with: cookies)
        try await load(url: url)

        let payload = try await evaluate(script: Self.shipCatalogExtractionScript, as: RemoteShipCatalogPayload.self)

        if payload.accessDenied {
            throw LiveHangarRepositoryError.sessionExpired
        }

        guard payload.status == "ok" else {
            throw LiveHangarRepositoryError.unexpectedMarkup(
                payload.failureMessage ?? "RSI store valuation data could not be loaded."
            )
        }

        guard (200 ..< 300).contains(payload.graphQLStatus) else {
            throw LiveHangarRepositoryError.unexpectedMarkup(
                "RSI store catalog returned HTTP \(payload.graphQLStatus)."
            )
        }

        guard payload.errors.isEmpty else {
            throw LiveHangarRepositoryError.unexpectedMarkup(
                "RSI store catalog returned GraphQL errors: \(payload.errors.joined(separator: ", "))."
            )
        }

        return RSIShipCatalog(
            ships: payload.ships.map { ship in
                RSIShipCatalog.Ship(
                    id: ship.id,
                    name: ship.name,
                    msrpUSD: ship.msrpUSD,
                    imageURL: ship.imageURL.flatMap(URL.init(string:))
                )
            }
        )
    }

    func fetchAccountOverview(
        using cookies: [SessionCookie],
        profileName: String
    ) async throws -> AccountOverview {
        let url = try storefrontURL(path: "/en/")
        try await prepareWebView(with: cookies)
        try await load(url: url)

        let payload = try await evaluate(script: Self.accountBalancesExtractionScript, as: RemoteAccountBalances.self)

        if payload.accessDenied {
            throw LiveHangarRepositoryError.sessionExpired
        }

        let storeCreditUSD: Decimal?
        if let graphQLStoreCreditValue = payload.graphQLStoreCreditValue?.nilIfEmpty,
           let parsedStoreCredit = RSIStoreCreditParser.parseStructuredMinorUnits(graphQLStoreCreditValue)
        {
            storeCreditUSD = parsedStoreCredit
        } else if let storeCreditText = payload.storeCreditText?.nilIfEmpty {
            storeCreditUSD = RSIStoreCreditParser.parseCurrencyText(storeCreditText)
        } else {
            storeCreditUSD = nil
        }

        let billingURL = try storefrontURL(path: "/en/account/billing")
        try await load(url: billingURL)

        let billingPayload = try await evaluate(script: Self.billingSummaryExtractionScript, as: RemoteBillingSummary.self)

        if billingPayload.accessDenied {
            throw LiveHangarRepositoryError.sessionExpired
        }

        let primaryOrganizationOverview = try? await fetchPrimaryOrganization(profileName: profileName)

        return AccountOverview(
            storeCreditUSD: storeCreditUSD,
            totalSpendUSD: billingPayload.totalSpendText.flatMap(RSIStoreCreditParser.parseCurrencyText),
            avatarURL: normalizedRSIURL(from: payload.avatarURL),
            primaryOrganization: primaryOrganizationOverview?.organization,
            didRefreshPrimaryOrganization: primaryOrganizationOverview?.didRefreshPrimaryOrganization ?? false
        )
    }

    func fetchReferralStats(using cookies: [SessionCookie]) async throws -> ReferralStats {
        let referralURL = try storefrontURL(path: "/en/referral")
        try await prepareWebView(with: cookies)
        try await load(url: referralURL)

        let currentPayload = try await evaluate(script: Self.referralCurrentExtractionScript, as: RemoteReferralOverview.self)

        if currentPayload.accessDenied {
            throw LiveHangarRepositoryError.sessionExpired
        }

        let legacyURL = try storefrontURL(path: "/en/referral-legacy")
        try await load(url: legacyURL)

        let legacyPayload = try await evaluate(script: Self.legacyReferralExtractionScript, as: RemoteLegacyReferralPage.self)

        if legacyPayload.accessDenied {
            throw LiveHangarRepositoryError.sessionExpired
        }

        return ReferralStatsResolver.resolve(
            currentLadderCount: currentPayload.currentLadderCount,
            legacyGraphQLCount: legacyPayload.graphQLCount,
            legacyParsedCount: legacyPayload.legacyLadderCount,
            legacyPageUnavailable: legacyPayload.pageUnavailable
        )
    }

    private func fetchPrimaryOrganization(profileName: String) async throws -> PrimaryOrganizationOverview {
        let trimmedProfileName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProfileName.isEmpty else {
            return PrimaryOrganizationOverview(
                organization: nil,
                didRefreshPrimaryOrganization: false
            )
        }

        let dossierURL = try citizenDossierURL(profileName: trimmedProfileName)
        try await load(url: dossierURL)

        let payload = try await evaluate(script: Self.primaryOrganizationExtractionScript, as: RemotePrimaryOrganization.self)

        if payload.accessDenied {
            throw LiveHangarRepositoryError.sessionExpired
        }

        return PrimaryOrganizationOverview(
            organization: payload.organization,
            didRefreshPrimaryOrganization: !payload.pageUnavailable
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    private func prepareWebView(with cookies: [SessionCookie]) async throws {
        try await replaceCookies(cookies)
    }

    private func replaceCookies(_ cookies: [SessionCookie]) async throws {
        let store = webView.configuration.websiteDataStore.httpCookieStore

        let existingCookies = await allCookies(from: store)
        for cookie in existingCookies where cookie.domain.contains("robertsspaceindustries.com") {
            await withCheckedContinuation { continuation in
                store.delete(cookie) {
                    continuation.resume()
                }
            }
        }

        for cookie in cookies {
            guard let httpCookie = cookie.httpCookie else {
                continue
            }

            await withCheckedContinuation { continuation in
                store.setCookie(httpCookie) {
                    continuation.resume()
                }
            }
        }
    }

    private func allCookies(from store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func load(url: URL) async throws {
        if loadContinuation != nil {
            throw LiveHangarRepositoryError.unexpectedMarkup("The RSI page loader is already busy.")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    private func evaluate<Value: Decodable>(script: String, as type: Value.Type) async throws -> Value {
        let result = try await webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )

        guard let result else {
            throw LiveHangarRepositoryError.unexpectedMarkup("RSI returned an empty page payload.")
        }

        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func pageURL(path: String, page: Int, pageSize: Int) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "robertsspaceindustries.com"
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pagesize", value: String(pageSize))
        ]

        guard let url = components.url else {
            throw LiveHangarRepositoryError.unexpectedMarkup("Unable to build the RSI page URL.")
        }

        return url
    }

    private func storefrontURL(path: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "robertsspaceindustries.com"
        components.path = path

        guard let url = components.url else {
            throw LiveHangarRepositoryError.unexpectedMarkup("Unable to build the RSI storefront URL.")
        }

        return url
    }

    private func citizenDossierURL(profileName: String) throws -> URL {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encodedProfileName = profileName.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            throw LiveHangarRepositoryError.unexpectedMarkup("Unable to build the RSI citizen dossier URL.")
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "robertsspaceindustries.com"
        components.percentEncodedPath = "/en/citizens/\(encodedProfileName)"

        guard let url = components.url else {
            throw LiveHangarRepositoryError.unexpectedMarkup("Unable to build the RSI citizen dossier URL.")
        }

        return url
    }

    private func normalizedRSIURL(from rawValue: String?) -> URL? {
        guard let trimmedValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedValue.isEmpty else {
            return nil
        }

        if trimmedValue.hasPrefix("//") {
            return URL(string: "https:\(trimmedValue)")
        }

        if trimmedValue.hasPrefix("/") {
            return URL(string: "https://robertsspaceindustries.com\(trimmedValue)")
        }

        return URL(string: trimmedValue)
    }

    private static let pledgesExtractionScript = """
    await new Promise(resolve => setTimeout(resolve, 150));

    const firstText = (node, selectors) => {
      for (const selector of selectors) {
        const found = node.querySelector(selector);
        const value = found?.textContent?.trim();
        if (value) {
          return value;
        }
      }
      return "";
    };

    const firstImageURL = (node) => {
      const candidates = [];
      const directImage =
        node?.matches?.('img') ? node :
        node?.matches?.('picture') ? node.querySelector('img') :
        null;
      const image = directImage || node.querySelector('img, picture img');
      if (image) {
        candidates.push(
          image.currentSrc,
          image.getAttribute('src'),
          image.getAttribute('data-src'),
          image.getAttribute('data-original'),
          image.getAttribute('data-lazy'),
          image.getAttribute('srcset')?.split(',')[0]?.trim()?.split(' ')[0]
        );
      }

      const styledNode =
        node?.matches?.('[style*="background-image"]') ? node :
        node.querySelector('[style*="background-image"]');
      if (styledNode) {
        const style = styledNode.getAttribute('style') || '';
        const match = style.match(/url\\((['"]?)(.*?)\\1\\)/i);
        if (match?.[2]) {
          candidates.push(match[2]);
        }
      }

      for (const candidate of candidates) {
        if (!candidate) {
          continue;
        }

        try {
          return new URL(candidate, window.location.href).toString();
        } catch {
          continue;
        }
      }

      return "";
    };

    const firstValue = (node, selectors) => {
      for (const selector of selectors) {
        const found = node.querySelector(selector);
        const value = found?.value?.trim() || found?.getAttribute?.('value')?.trim() || found?.getAttribute?.('content')?.trim();
        if (value) {
          return value;
        }
      }
      return "";
    };

    const currentPage = (() => {
      const parsed = Number.parseInt(new URL(window.location.href).searchParams.get('page') || '1', 10);
      return Number.isFinite(parsed) && parsed > 0 ? parsed : 1;
    })();

    const isDisabled = (node) => {
      const nodeIsDisabled = node?.matches?.('[disabled], [aria-disabled="true"]') || false;
      if (nodeIsDisabled) {
        return true;
      }

      return Boolean(node?.classList?.contains('disabled') || node?.closest?.('.disabled'));
    };

    const paginationTargets = Array.from(document.querySelectorAll('a[href*="page="], button[data-page], [data-page], a[rel="next"], button[rel="next"]'))
      .map((node) => {
        const candidates = [
          node.getAttribute?.('data-page'),
          node.textContent,
          (() => {
            const href = node.getAttribute?.('href');
            if (!href) {
              return null;
            }
            try {
              return new URL(href, window.location.href).searchParams.get('page');
            } catch {
              return null;
            }
          })()
        ];

        for (const candidate of candidates) {
          const match = String(candidate || '').match(/\\b(\\d+)\\b/);
          if (!match) {
            continue;
          }

          const parsed = Number.parseInt(match[1], 10);
          if (Number.isFinite(parsed) && parsed > 0) {
            return {
              page: parsed,
              isNextControl: false,
              disabled: isDisabled(node)
            };
          }
        }

        const label = [
          node.getAttribute?.('aria-label'),
          node.getAttribute?.('title'),
          node.textContent,
          node.getAttribute?.('rel')
        ]
          .map((value) => String(value || '').toLowerCase())
          .join(' ');

        return {
          page: null,
          isNextControl: label.includes('next'),
          disabled: isDisabled(node)
        };
      })
      .filter((value) => value !== null);

    const pageNumbers = paginationTargets
      .map((target) => target.page)
      .filter((value) => Number.isFinite(value));

    const accessDenied = document.title.toLowerCase().includes('access denied') || document.body.innerText.includes('Access denied');
    const rows = Array.from(document.querySelectorAll('.list-items .row'));
    const hasNextPage = paginationTargets.some((target) => {
      if (target.disabled) {
        return false;
      }

      if (Number.isFinite(target.page)) {
        return target.page > currentPage;
      }

      return target.isNextControl;
    });

    return {
      accessDenied,
      title: document.title,
      totalPages: pageNumbers.length ? Math.max(...pageNumbers) : null,
      hasNextPage,
      items: rows.map((row) => {
        const titles = Array.from(row.querySelectorAll('.title'))
          .map((node) => node.textContent.trim())
          .filter(Boolean);
        const packageThumbnailNode =
          row.querySelector('.image-col, .image, .thumb, .thumbnail, picture, img') || row;
        const items = Array.from(row.querySelectorAll('.with-images .item')).map((item) => ({
          title: firstText(item, ['.title']),
          kind: firstText(item, ['.kind']),
          detail: firstText(item, ['.liner', '.subtitle']),
          imageURL: firstImageURL(item)
        }));

        return {
          id: (() => {
            const value = Number.parseInt(firstValue(row, ['.js-pledge-id']), 10);
            return Number.isFinite(value) ? value : null;
          })(),
          title: firstValue(row, ['.js-pledge-name']) || firstText(row, ['h1', 'h2', '.title']),
          statusText: firstText(row, ['.availability', '.status']),
          dateText: firstText(row, ['.date-col', '.date']),
          valueText: firstValue(row, ['.js-pledge-value']) || firstText(row, ['.value', '.price']),
          containsText: firstText(row, ['.items-col', '.contains']),
          thumbnailImageURL: firstImageURL(packageThumbnailNode),
          alsoContains: titles,
          canGift: row.querySelector('.shadow-button.js-gift, .js-gift') !== null,
          canReclaim: row.querySelector('.shadow-button.js-reclaim, .js-reclaim') !== null,
          canUpgrade: row.querySelector('.shadow-button.js-apply-upgrade, .js-apply-upgrade') !== null,
          items
        };
      })
    };
    """

    private static let shipCatalogExtractionScript = """
    await new Promise(resolve => setTimeout(resolve, 300));

    const hasAccessDeniedMarkup = document.title.toLowerCase().includes('access denied') || document.body.innerText.includes('Access denied');
    if (hasAccessDeniedMarkup) {
      return {
        accessDenied: true,
        status: 'access-denied',
        graphQLStatus: 0,
        errors: [],
        failureMessage: 'The RSI storefront rejected the current session.',
        ships: []
      };
    }

    const cookieValue = (name) => {
      const pattern = new RegExp('(?:^|; )' + name.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&') + '=([^;]*)');
      const match = document.cookie.match(pattern);
      return match ? decodeURIComponent(match[1]) : '';
    };

    const tokenCookieName = (() => {
      const host = window.location.host;
      const parts = host.split('.');
      const subdomain = parts.length > 2 ? parts.slice(0, -2).join('.') : '';
      if (subdomain && !host.includes('local')) {
        return subdomain.includes('.') ? `rsi-review-${subdomain.split('.')[0]}-token` : `rsi-${subdomain}-token`;
      }
      return 'rsi-token';
    })();

    const tokenValue = cookieValue(tokenCookieName);
    if (!tokenValue) {
      return {
        accessDenied: false,
        status: 'token-missing',
        graphQLStatus: 0,
        errors: [],
        failureMessage: `RSI storefront token cookie (${tokenCookieName}) was not available.`,
        ships: []
      };
    }

    const baseHeaders = {
      'Content-Type': 'application/json;charset=UTF-8',
      'Accept': 'application/json',
      ['x-' + tokenCookieName]: tokenValue
    };

    const authResponse = await fetch('/api/account/v2/setAuthToken', {
      method: 'POST',
      credentials: 'include',
      headers: baseHeaders,
      body: JSON.stringify({})
    });

    const contextResponse = await fetch('/api/ship-upgrades/setContextToken', {
      method: 'POST',
      credentials: 'include',
      headers: baseHeaders,
      body: JSON.stringify({
        fromShipId: null,
        toShipId: null,
        toSkuId: null,
        pledgeId: null
      })
    });

    if (!authResponse.ok || !contextResponse.ok) {
      return {
        accessDenied: false,
        status: 'token-renewal-failed',
        graphQLStatus: 0,
        errors: [],
        failureMessage: `RSI storefront token renewal failed (auth ${authResponse.status}, context ${contextResponse.status}).`,
        ships: []
      };
    }

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '';
    const language = document.documentElement.getAttribute('lang') || 'en';
    const query = `query initShipUpgrade {
      ships {
        id
        name
        msrp
        medias {
          productThumbMediumAndSmall
          slideShow
        }
      }
    }`;

    const graphQLResponse = await fetch('/pledge-store/api/graphql', {
      method: 'POST',
      credentials: 'include',
      headers: {
        'Content-Type': 'application/json;charset=UTF-8',
        'Accept': 'application/json',
        'X-CSRF-TOKEN': csrfToken,
        'Accept-Language': language
      },
      body: JSON.stringify([
        {
          operationName: 'initShipUpgrade',
          query,
          variables: {}
        }
      ])
    });

    const rawBody = await graphQLResponse.text();
    let parsedBody = null;
    try {
      parsedBody = JSON.parse(rawBody);
    } catch {}

    const payload = Array.isArray(parsedBody) ? parsedBody[0] : parsedBody;
    const responseErrors = Array.isArray(payload?.errors)
      ? payload.errors.map((entry) => entry?.message || 'Unknown GraphQL error')
      : [];

    const normalizeImageURL = (value) => {
      if (!value) {
        return '';
      }

      const candidate = Array.isArray(value) ? value[0] : value;
      if (!candidate) {
        return '';
      }

      try {
        return new URL(candidate, window.location.origin).toString();
      } catch {
        return '';
      }
    };

    const normalizeMSRP = (value) => {
      if (typeof value === 'number' && Number.isFinite(value)) {
        return Math.abs(value) >= 1000 ? value / 100 : value;
      }

      if (typeof value === 'string' && value.trim()) {
        const parsed = Number.parseFloat(value);
        return Number.isFinite(parsed) ? (Math.abs(parsed) >= 1000 ? parsed / 100 : parsed) : null;
      }

      return null;
    };

    const ships = Array.isArray(payload?.data?.ships)
      ? payload.data.ships.map((ship) => ({
          id: Number.parseInt(String(ship?.id ?? ''), 10),
          name: ship?.name || '',
          msrpUSD: normalizeMSRP(ship?.msrp),
          imageURL: normalizeImageURL(
            ship?.medias?.productThumbMediumAndSmall || ship?.medias?.slideShow
          )
        }))
        .filter((ship) => Number.isFinite(ship.id) && ship.id > 0 && ship.name)
      : [];

    return {
      accessDenied: false,
      status: 'ok',
      graphQLStatus: graphQLResponse.status,
      errors: responseErrors,
      failureMessage: responseErrors.length ? rawBody.slice(0, 500) : '',
      ships
    };
    """

    private static let accountBalancesExtractionScript = """
    const normalizeText = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
    const isVisible = (node) => {
      if (!node || !(node instanceof Element)) {
        return false;
      }

      const style = window.getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden' || Number.parseFloat(style.opacity || '1') === 0) {
        return false;
      }

      const rect = node.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };

    const findVisibleAccountPanel = () => {
      const stablePanel = document.querySelector('[data-cy-id="account-sidepanel"]');
      if (stablePanel && isVisible(stablePanel)) {
        return stablePanel;
      }

      const panels = Array.from(document.querySelectorAll('body *'))
        .filter((node) => {
          if (!isVisible(node)) {
            return false;
          }

          const text = normalizeText(node.textContent).toLowerCase();
          if (!text.includes('store credit')) {
            return false;
          }

          return text.includes('credits') || text.includes('my hangar') || text.includes('account dashboard');
        })
        .sort((lhs, rhs) => rhs.getBoundingClientRect().height - lhs.getBoundingClientRect().height);

      return panels[0] || null;
    };

    const findAvatarTrigger = () => {
      const labeledCandidates = Array.from(document.querySelectorAll('button, a, [role="button"], summary'))
        .filter((node) => {
          if (!isVisible(node)) {
            return false;
          }

          const haystack = [
            node.textContent,
            node.getAttribute?.('aria-label'),
            node.getAttribute?.('title'),
            node.className
          ]
            .map(normalizeText)
            .join(' ')
            .toLowerCase();

          return ['account', 'my rsi', 'my account', 'profile', 'avatar', 'user'].some((label) => haystack.includes(label));
        });

      const imageCandidates = Array.from(document.querySelectorAll('header img, nav img, button img, a img, [role="button"] img, img'))
        .map((image) => image.closest('button, a, [role="button"], summary') || image)
        .filter((node) => {
          if (!isVisible(node)) {
            return false;
          }

          const rect = node.getBoundingClientRect();
          if (rect.top > window.innerHeight * 0.35 || rect.left < window.innerWidth * 0.55) {
            return false;
          }

          const haystack = [
            node.getAttribute?.('aria-label'),
            node.getAttribute?.('title'),
            node.className,
            node.querySelector?.('img')?.getAttribute?.('alt')
          ]
            .map(normalizeText)
            .join(' ')
            .toLowerCase();

          return haystack.includes('avatar')
            || haystack.includes('profile')
            || haystack.includes('account')
            || haystack.includes('user')
            || node.querySelector?.('img') !== null;
        });

      const candidates = [...labeledCandidates, ...imageCandidates];
      candidates.sort((lhs, rhs) => {
        const lhsRect = lhs.getBoundingClientRect();
        const rhsRect = rhs.getBoundingClientRect();
        if (lhsRect.right !== rhsRect.right) {
          return rhsRect.right - lhsRect.right;
        }

        return lhsRect.top - rhsRect.top;
      });

      return candidates[0] || null;
    };

    const waitForAccountPanel = async (timeoutMs = 1500) => {
      const startedAt = Date.now();
      while (Date.now() - startedAt < timeoutMs) {
        const panel = findVisibleAccountPanel();
        if (panel) {
          return panel;
        }

        await new Promise(resolve => setTimeout(resolve, 100));
      }

      return findVisibleAccountPanel();
    };

    const openAccountPanelIfNeeded = async () => {
      if (findVisibleAccountPanel()) {
        return;
      }

      document.dispatchEvent(
        new CustomEvent('plt-client.sidePanel.toggle', {
          detail: {
            type: 'account',
            open: true
          }
        })
      );

      if (await waitForAccountPanel(1200)) {
        return;
      }

      const trigger = findAvatarTrigger();
      if (!trigger) {
        return;
      }

      trigger.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true, cancelable: true, view: window }));
      trigger.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, cancelable: true, view: window }));
      trigger.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window }));
      trigger.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window }));
      trigger.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
      trigger.click?.();
      await waitForAccountPanel(1200);
    };

    const fetchStructuredStoreCreditValue = async () => {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '';
      if (!csrfToken) {
        return '';
      }

      const query = `query AccountDashboardForCredits {
        accountDashboard {
          account {
            creditsData {
              label
              currency
              symbol
              value
              variant
            }
          }
        }
      }`;

      try {
        const response = await fetch('/graphql', {
          method: 'POST',
          credentials: 'include',
          headers: {
            'Content-Type': 'application/json;charset=UTF-8',
            'Accept': 'application/json',
            'X-CSRF-TOKEN': csrfToken
          },
          body: JSON.stringify({
            operationName: 'AccountDashboardForCredits',
            query,
            variables: {}
          })
        });

        const rawBody = await response.text();
        let payload = null;
        try {
          payload = JSON.parse(rawBody);
        } catch {
          return '';
        }

        const credits = payload?.data?.accountDashboard?.account?.creditsData;
        if (!Array.isArray(credits)) {
          return '';
        }

        const storeCredit = credits.find((credit) => {
          const label = normalizeText(credit?.label).toLowerCase();
          const variant = normalizeText(credit?.variant).toLowerCase();
          return label.includes('store credit') || variant.includes('store');
        }) || credits.find((credit) => normalizeText(credit?.currency).toUpperCase() === 'USD');

        if (!storeCredit) {
          return '';
        }

        const value = typeof storeCredit.value === 'number'
          ? storeCredit.value
          : Number.parseFloat(String(storeCredit.value || ''));

        return Number.isFinite(value) ? String(value) : '';
      } catch {
        return '';
      }
    };

    const extractStoreCreditText = (sourceNode) => {
      const snippets = [];
      const collectSnippet = (value) => {
        const normalized = normalizeText(value);
        if (normalized) {
          snippets.push(normalized);
        }
      };

      if (sourceNode) {
        collectSnippet(sourceNode.textContent);

        Array.from(sourceNode.querySelectorAll('*')).forEach((node) => {
          const haystack = [
            node.textContent,
            node.parentElement?.textContent,
            node.previousElementSibling?.textContent,
            node.nextElementSibling?.textContent
          ];

          haystack.forEach(collectSnippet);
        });
      }

      collectSnippet(document.body.innerText);

      for (const snippet of snippets) {
        const match =
          snippet.match(/store credit[^$\\d-]{0,80}(\\$?\\d[\\d,]*(?:\\.\\d{1,2})?)/i) ||
          snippet.match(/(\\$?\\d[\\d,]*(?:\\.\\d{1,2})?)[^$\\d-]{0,40}store credit/i);

        if (match?.[1]) {
          return match[1];
        }
      }

      return '';
    };

    const extractAvatarURL = (sourceNode, triggerNode) => {
      const candidates = [];
      const collectFrom = (root, priority) => {
        if (!root || !(root instanceof Element)) {
          return;
        }

        const imageNodes = root.matches('img')
          ? [root]
          : Array.from(root.querySelectorAll('img'));

        imageNodes.forEach((imageNode) => {
          if (!(imageNode instanceof HTMLImageElement) || !isVisible(imageNode)) {
            return;
          }

          const rect = imageNode.getBoundingClientRect();
          if (rect.width < 24 || rect.height < 24) {
            return;
          }

          const url = normalizeText(imageNode.currentSrc || imageNode.src || imageNode.getAttribute('src'));
          if (!url) {
            return;
          }

          candidates.push({
            url,
            priority,
            area: rect.width * rect.height,
            squareness: Math.abs(rect.width - rect.height)
          });
        });
      };

      collectFrom(sourceNode, 2);
      collectFrom(triggerNode, 1);
      collectFrom(document.querySelector('header'), 0);
      collectFrom(document.querySelector('nav'), 0);

      candidates.sort((lhs, rhs) => {
        if (lhs.priority !== rhs.priority) {
          return rhs.priority - lhs.priority;
        }

        if (lhs.area !== rhs.area) {
          return rhs.area - lhs.area;
        }

        return lhs.squareness - rhs.squareness;
      });

      const bestCandidate = candidates[0];
      if (!bestCandidate) {
        return '';
      }

      try {
        return new URL(bestCandidate.url, window.location.href).href;
      } catch {
        return bestCandidate.url;
      }
    };

    await new Promise(resolve => setTimeout(resolve, 200));
    const graphQLStoreCreditValue = await fetchStructuredStoreCreditValue();
    const avatarTrigger = findAvatarTrigger();
    await openAccountPanelIfNeeded();

    const accessDenied = document.title.toLowerCase().includes('access denied') || document.body.innerText.includes('Access denied');
    const accountPanel = findVisibleAccountPanel();
    const storeCreditText = extractStoreCreditText(accountPanel);
    const avatarURL = extractAvatarURL(accountPanel, avatarTrigger);

    return {
      accessDenied,
      graphQLStoreCreditValue: graphQLStoreCreditValue || null,
      storeCreditText: storeCreditText || null,
      avatarURL: avatarURL || null
    };
    """

    private static let primaryOrganizationExtractionScript = """
    const normalizeText = (value) => String(value || '').replace(/\\s+/g, ' ').trim();

    const accessDenied =
      document.title.toLowerCase().includes('access denied') ||
      document.body.innerText.includes('Access denied');

    const mainOrganizationRoot =
      document.querySelector('.main-org .info') ||
      document.querySelector('.box-content.org.main .info');

    if (!mainOrganizationRoot) {
      return {
        accessDenied,
        pageUnavailable: true,
        organizationName: null,
        organizationRank: null
      };
    }

    let organization = {
      name: '',
      rank: ''
    };

    Array.from(mainOrganizationRoot.querySelectorAll('.entry')).forEach((entry) => {
      const label = normalizeText(entry.querySelector('.label')?.textContent).toLowerCase();
      const value = normalizeText(entry.querySelector('.value')?.textContent);

      if (!value) {
        return;
      }

      if (!label && !organization.name) {
        organization.name = value;
        return;
      }

      if (label.includes('organization rank') && !organization.rank) {
        organization.rank = value;
      }
    });

    return {
      accessDenied,
      pageUnavailable: false,
      organizationName: organization.name || null,
      organizationRank: organization.rank || null
    };
    """

    private static let referralCurrentExtractionScript = """
    const normalizeText = (value) => String(value || '').replace(/\\s+/g, ' ').trim();

    const waitFor = async (predicate, timeoutMs = 1600) => {
      const startedAt = Date.now();
      while (Date.now() - startedAt < timeoutMs) {
        const result = predicate();
        if (result) {
          return result;
        }

        await new Promise(resolve => setTimeout(resolve, 100));
      }

      return predicate();
    };

    const parseCount = (value) => {
      const match = normalizeText(value).match(/\\d[\\d,]*/);
      if (!match) {
        return null;
      }

      const parsed = Number.parseInt(match[0].replace(/,/g, ''), 10);
      return Number.isFinite(parsed) ? parsed : null;
    };

    const decodeHTML = (value) => {
      const textarea = document.createElement('textarea');
      textarea.innerHTML = value;
      return textarea.value;
    };

    const extractCampaignId = () => {
      const components = Array.from(document.querySelectorAll('g-platform-client-component'));
      for (const component of components) {
        const rawValue = component.getAttribute(':properties') || component.getAttribute('properties');
        if (!rawValue) {
          continue;
        }

        const decoded = decodeHTML(rawValue);
        if (!decoded.includes('Account.ReferralPage.Ladder')) {
          continue;
        }

        const match =
          decoded.match(/"referralCampaign"\\s*:\\s*\\{[^}]*"id"\\s*:\\s*"([^"]+)"/) ||
          decoded.match(/"componentId"\\s*:\\s*"Account\\.ReferralPage\\.Ladder"[\\s\\S]*?"id"\\s*:\\s*"([^"]+)"/);

        if (match?.[1]) {
          return match[1];
        }
      }

      return '2';
    };

    const fetchReferralCount = async (campaignId) => {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '';
      if (!csrfToken) {
        return null;
      }

      const query = `query ReferralCountByCampaign($campaignId: ID!) {
        referralCountByCampaign(campaignId: $campaignId)
      }`;

      try {
        const response = await fetch('/graphql', {
          method: 'POST',
          credentials: 'include',
          headers: {
            'Content-Type': 'application/json;charset=UTF-8',
            'Accept': 'application/json',
            'X-CSRF-TOKEN': csrfToken,
            'Accept-Language': document.documentElement.getAttribute('lang') || 'en'
          },
          body: JSON.stringify({
            operationName: 'ReferralCountByCampaign',
            query,
            variables: {
              campaignId
            }
          })
        });

        const rawBody = await response.text();
        let payload = null;
        try {
          payload = JSON.parse(rawBody);
        } catch {
          return null;
        }

        const value = payload?.data?.referralCountByCampaign;
        if (typeof value === 'number' && Number.isFinite(value)) {
          return value;
        }

        const parsed = Number.parseInt(String(value ?? ''), 10);
        return Number.isFinite(parsed) ? parsed : null;
      } catch {
        return null;
      }
    };

    await waitFor(() => document.querySelector('.accountReferralHeroBanner, .accountReferralRecruitsCount__text, g-platform-client-component'), 1200);

    const accessDenied = document.title.toLowerCase().includes('access denied') || document.body.innerText.includes('Access denied');
    const campaignId = extractCampaignId();
    const graphQLCount = await fetchReferralCount(campaignId);
    const counterText = normalizeText(document.querySelector('.accountReferralRecruitsCount__text')?.textContent);

    return {
      accessDenied,
      campaignId,
      currentLadderCount: graphQLCount ?? parseCount(counterText),
      counterText: counterText || null
    };
    """

    private static let billingSummaryExtractionScript = """
    const normalizeText = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
    const isVisible = (node) => {
      if (!node || !(node instanceof Element)) {
        return false;
      }

      const style = window.getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden' || Number.parseFloat(style.opacity || '1') === 0) {
        return false;
      }

      const rect = node.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };

    const waitForBodyText = async (timeoutMs = 1600) => {
      const startedAt = Date.now();
      while (Date.now() - startedAt < timeoutMs) {
        if (normalizeText(document.body?.innerText).length > 0) {
          return;
        }

        await new Promise(resolve => setTimeout(resolve, 100));
      }
    };

    const pushUnique = (collection, value) => {
      const normalized = normalizeText(value);
      if (!normalized || collection.includes(normalized)) {
        return;
      }

      collection.push(normalized);
    };

    const buildSnippets = (node) => {
      if (!node) {
        return [];
      }

      const snippets = [];
      pushUnique(snippets, node.textContent);

      if (!(node instanceof Element)) {
        return snippets;
      }

      pushUnique(snippets, node.getAttribute('aria-label'));
      pushUnique(snippets, node.getAttribute('title'));
      pushUnique(snippets, node.parentElement?.textContent);
      pushUnique(snippets, node.previousElementSibling?.textContent);
      pushUnique(snippets, node.nextElementSibling?.textContent);

      Array.from(node.querySelectorAll('*'))
        .slice(0, 60)
        .forEach((child) => {
          pushUnique(snippets, child.textContent);
          pushUnique(snippets, child.getAttribute?.('aria-label'));
          pushUnique(snippets, child.getAttribute?.('title'));
        });

      return snippets;
    };

    const parseTotalSpendText = (snippet) => {
      const normalized = normalizeText(snippet);
      if (!normalized) {
        return '';
      }

      const patterns = [
        /total\\s+spen[dt][^$\\d-]{0,80}(\\$?\\d[\\d,]*(?:\\.\\d{1,2})?)/i,
        /(\\$?\\d[\\d,]*(?:\\.\\d{1,2})?)[^$\\d-]{0,40}total\\s+spen[dt]/i
      ];

      for (const pattern of patterns) {
        const match = normalized.match(pattern);
        if (match?.[1]) {
          return match[1];
        }
      }

      return '';
    };

    await waitForBodyText();

    const accessDenied = document.title.toLowerCase().includes('access denied') || document.body.innerText.includes('Access denied');
    const candidates = Array.from(document.querySelectorAll('body *'))
      .filter((node) => isVisible(node) && /total\\s+spen[dt]/i.test(normalizeText(node.textContent)));

    const snippets = candidates.flatMap((node) => buildSnippets(node));
    pushUnique(snippets, document.body?.innerText);

    let totalSpendText = '';
    let matchedSnippet = '';

    for (const snippet of snippets) {
      const parsed = parseTotalSpendText(snippet);
      if (!parsed) {
        continue;
      }

      totalSpendText = parsed;
      matchedSnippet = snippet;
      break;
    }

    return {
      accessDenied,
      totalSpendText: totalSpendText || null,
      matchedSnippet: matchedSnippet || null
    };
    """

    private static let legacyReferralExtractionScript = """
    const normalizeText = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
    const isVisible = (node) => {
      if (!(node instanceof Element)) {
        return false;
      }

      const style = window.getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden' || Number.parseFloat(style.opacity || '1') === 0) {
        return false;
      }

      const rect = node.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };

    const waitFor = async (timeoutMs = 1600) => {
      const startedAt = Date.now();
      while (Date.now() - startedAt < timeoutMs) {
        const hasText = normalizeText(document.body?.innerText).length > 0;
        if (hasText) {
          return;
        }

        await new Promise(resolve => setTimeout(resolve, 100));
      }
    };

    const fetchReferralCount = async (campaignId) => {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '';
      if (!csrfToken) {
        return null;
      }

      const query = `query ReferralCountByCampaign($campaignId: ID!) {
        referralCountByCampaign(campaignId: $campaignId)
      }`;

      try {
        const response = await fetch('/graphql', {
          method: 'POST',
          credentials: 'include',
          headers: {
            'Content-Type': 'application/json;charset=UTF-8',
            'Accept': 'application/json',
            'X-CSRF-TOKEN': csrfToken,
            'Accept-Language': document.documentElement.getAttribute('lang') || 'en'
          },
          body: JSON.stringify({
            operationName: 'ReferralCountByCampaign',
            query,
            variables: {
              campaignId
            }
          })
        });

        const rawBody = await response.text();
        let payload = null;
        try {
          payload = JSON.parse(rawBody);
        } catch {
          return null;
        }

        const value = payload?.data?.referralCountByCampaign;
        if (typeof value === 'number' && Number.isFinite(value)) {
          return value;
        }

        const parsed = Number.parseInt(String(value ?? ''), 10);
        return Number.isFinite(parsed) ? parsed : null;
      } catch {
        return null;
      }
    };

    const pushUnique = (collection, value) => {
      const normalized = normalizeText(value);
      if (!normalized || collection.includes(normalized)) {
        return;
      }

      collection.push(normalized);
    };

    const buildSnippets = (node) => {
      if (!node) {
        return [];
      }

      const snippets = [];
      pushUnique(snippets, node.textContent);

      if (!(node instanceof Element)) {
        return snippets;
      }

      pushUnique(snippets, node.getAttribute('aria-label'));
      pushUnique(snippets, node.getAttribute('title'));
      pushUnique(snippets, node.parentElement?.textContent);

      Array.from(node.querySelectorAll('*'))
        .slice(0, 40)
        .forEach((child) => {
          pushUnique(snippets, child.textContent);
          pushUnique(snippets, child.getAttribute?.('aria-label'));
          pushUnique(snippets, child.getAttribute?.('title'));
        });

      return snippets;
    };

    const parseLabeledLegacyCount = (snippet) => {
      const normalized = normalizeText(snippet);
      if (!normalized) {
        return null;
      }

      const patterns = [
        /(\\d{1,9}(?:,\\d{3})*)\\D{0,40}citizens?\\s+recruited/i,
        /citizens?\\s+recruited\\D{0,40}(\\d{1,9}(?:,\\d{3})*)/i
      ];

      for (const pattern of patterns) {
        const match = normalized.match(pattern);
        if (!match?.[1]) {
          continue;
        }

        const parsed = Number.parseInt(match[1].replace(/,/g, ''), 10);
        if (Number.isFinite(parsed)) {
          return parsed;
        }
      }

      return null;
    };

    const parseCountFromSnippet = (snippet) => {
      const patterns = [
        /(\\d{1,9}(?:,\\d{3})*)\\s+(?:citizens?|recruits?|referrals?)\\s+(?:recruited|referred|earned)?/i,
        /(?:legacy\\s+)?(?:citizens?|recruits?|referrals?|recruitment points?|reward points?)\\D{0,30}(\\d{1,9}(?:,\\d{3})*)/i,
        /(\\d{1,9}(?:,\\d{3})*)\\D{0,20}(?:legacy\\s+)?(?:recruits?|referrals?|recruitment points?|reward points?)/i
      ];

      for (const pattern of patterns) {
        const match = normalizeText(snippet).match(pattern);
        if (!match?.[1]) {
          continue;
        }

        const parsed = Number.parseInt(match[1].replace(/,/g, ''), 10);
        if (Number.isFinite(parsed)) {
          return parsed;
        }
      }

      return null;
    };

    const visibleLabelNodes = Array.from(document.querySelectorAll('body *'))
      .filter((node) => isVisible(node) && /citizens?\\s+recruited/i.test(normalizeText(node.textContent)));

    const targetedContainers = visibleLabelNodes.flatMap((node) => [
      node,
      node.parentElement,
      node.parentElement?.parentElement,
      node.closest?.('[class*="recruit"], [id*="recruit"], [class*="citizen"], [id*="citizen"], [class*="count"], [id*="count"]')
    ]).filter(Boolean);

    const targetedSnippets = targetedContainers.flatMap((node) => buildSnippets(node));

    let legacyLadderCount = null;
    let matchedSnippet = '';

    for (const snippet of targetedSnippets) {
      const parsed = parseLabeledLegacyCount(snippet);
      if (parsed === null) {
        continue;
      }

      legacyLadderCount = parsed;
      matchedSnippet = snippet;
      break;
    }

    if (legacyLadderCount === null && visibleLabelNodes.length > 0) {
      for (const labelNode of visibleLabelNodes) {
        const labelRect = labelNode.getBoundingClientRect();
        const numericCandidates = Array.from(document.querySelectorAll('body *'))
          .filter((node) => {
            if (!isVisible(node)) {
              return false;
            }

            const text = normalizeText(node.textContent);
            return /^\\d{1,9}(?:,\\d{3})*$/.test(text);
          })
          .map((node) => ({ node, rect: node.getBoundingClientRect(), text: normalizeText(node.textContent) }))
          .filter((candidate) => {
            const horizontalCenter = candidate.rect.left + (candidate.rect.width / 2);
            return horizontalCenter >= labelRect.left - 120 && horizontalCenter <= labelRect.right + 120;
          })
          .sort((lhs, rhs) => {
            const lhsVerticalDistance = Math.abs((lhs.rect.bottom) - labelRect.top);
            const rhsVerticalDistance = Math.abs((rhs.rect.bottom) - labelRect.top);
            return lhsVerticalDistance - rhsVerticalDistance;
          });

        const bestCandidate = numericCandidates[0];
        if (!bestCandidate) {
          continue;
        }

        const parsed = Number.parseInt(bestCandidate.text.replace(/,/g, ''), 10);
        if (!Number.isFinite(parsed)) {
          continue;
        }

        legacyLadderCount = parsed;
        matchedSnippet = `${bestCandidate.text} CITIZENS RECRUITED`;
        break;
      }
    }

    await waitFor();

    const accessDenied = document.title.toLowerCase().includes('access denied') || document.body.innerText.includes('Access denied');
    const bodyText = normalizeText(document.body?.innerText);
    const title = normalizeText(document.title);
    const pageUnavailable = /(^|\\b)404(\\b|$)/.test(title) || /page not found/i.test(bodyText);
    const graphQLCount = pageUnavailable ? null : await fetchReferralCount('1');
    const candidateNodes = [
      document.querySelector('.accountReferralRecruitsCount__text'),
      ...Array.from(document.querySelectorAll('[class*="recruit"], [id*="recruit"], [class*="referral"], [id*="referral"], [class*="count"], [id*="count"]')).slice(0, 120),
      document.body
    ];

    if (legacyLadderCount === null) {
      for (const node of candidateNodes) {
        for (const snippet of buildSnippets(node)) {
          const parsed = parseCountFromSnippet(snippet);
          if (parsed === null) {
            continue;
          }

          legacyLadderCount = parsed;
          matchedSnippet = snippet;
          break;
        }

        if (legacyLadderCount !== null) {
          break;
        }
      }
    }

    return {
      accessDenied,
      pageUnavailable,
      title: title || null,
      graphQLCount,
      legacyLadderCount,
      matchedSnippet: matchedSnippet || null
    };
    """

    private static let buybackExtractionScript = """
    await new Promise(resolve => setTimeout(resolve, 150));

    const firstText = (node, selectors) => {
      for (const selector of selectors) {
        const found = node.querySelector(selector);
        const value = found?.textContent?.trim();
        if (value) {
          return value;
        }
      }
      return "";
    };

    const firstImageURL = (node) => {
      const candidates = [];
      const directImage =
        node?.matches?.('img') ? node :
        node?.matches?.('picture') ? node.querySelector('img') :
        null;
      const image = directImage || node?.querySelector?.('img, picture img');
      if (image) {
        candidates.push(
          image.currentSrc,
          image.getAttribute('src'),
          image.getAttribute('data-src'),
          image.getAttribute('data-original'),
          image.getAttribute('data-lazy'),
          image.getAttribute('srcset')?.split(',')[0]?.trim()?.split(' ')[0]
        );
      }

      const styledNode =
        node?.matches?.('[style*="background-image"]') ? node :
        node?.querySelector?.('[style*="background-image"]');
      if (styledNode) {
        const style = styledNode.getAttribute('style') || '';
        const match = style.match(/url\\((['"]?)(.*?)\\1\\)/i);
        if (match?.[2]) {
          candidates.push(match[2]);
        }
      }

      for (const candidate of candidates) {
        if (!candidate) {
          continue;
        }

        try {
          return new URL(candidate, window.location.href).toString();
        } catch {
          continue;
        }
      }

      return "";
    };

    const currentPage = (() => {
      const parsed = Number.parseInt(new URL(window.location.href).searchParams.get('page') || '1', 10);
      return Number.isFinite(parsed) && parsed > 0 ? parsed : 1;
    })();

    const isDisabled = (node) => {
      const nodeIsDisabled = node?.matches?.('[disabled], [aria-disabled="true"]') || false;
      if (nodeIsDisabled) {
        return true;
      }

      return Boolean(node?.classList?.contains('disabled') || node?.closest?.('.disabled'));
    };

    const paginationTargets = Array.from(document.querySelectorAll('a[href*="page="], button[data-page], [data-page], a[rel="next"], button[rel="next"]'))
      .map((node) => {
        const candidates = [
          node.getAttribute?.('data-page'),
          node.textContent,
          (() => {
            const href = node.getAttribute?.('href');
            if (!href) {
              return null;
            }
            try {
              return new URL(href, window.location.href).searchParams.get('page');
            } catch {
              return null;
            }
          })()
        ];

        for (const candidate of candidates) {
          const match = String(candidate || '').match(/\\b(\\d+)\\b/);
          if (!match) {
            continue;
          }

          const parsed = Number.parseInt(match[1], 10);
          if (Number.isFinite(parsed) && parsed > 0) {
            return {
              page: parsed,
              isNextControl: false,
              disabled: isDisabled(node)
            };
          }
        }

        const label = [
          node.getAttribute?.('aria-label'),
          node.getAttribute?.('title'),
          node.textContent,
          node.getAttribute?.('rel')
        ]
          .map((value) => String(value || '').toLowerCase())
          .join(' ');

        return {
          page: null,
          isNextControl: label.includes('next'),
          disabled: isDisabled(node)
        };
      })
      .filter((value) => value !== null);

    const pageNumbers = paginationTargets
      .map((target) => target.page)
      .filter((value) => Number.isFinite(value));

    const accessDenied = document.title.toLowerCase().includes('access denied') || document.body.innerText.includes('Access denied');
    const articles = Array.from(document.querySelectorAll('article.pledge'));
    const hasNextPage = paginationTargets.some((target) => {
      if (target.disabled) {
        return false;
      }

      if (Number.isFinite(target.page)) {
        return target.page > currentPage;
      }

      return target.isNextControl;
    });

    return {
      accessDenied,
      title: document.title,
      totalPages: pageNumbers.length ? Math.max(...pageNumbers) : null,
      hasNextPage,
      items: articles.map((article) => {
        const button = article.querySelector('.holosmallbtn, a[href*="/pledge/buyback/"]');
        const href = button?.getAttribute('href') || '';
        const hrefId = Number(href.split('/').filter(Boolean).pop());
        const dataId = Number(button?.getAttribute('data-pledgeid'));
        const definitionValues = Array.from(article.querySelectorAll('dl dd'))
          .map((node) => node.textContent.trim())
          .filter(Boolean);

        return {
          id: Number.isFinite(hrefId) && hrefId > 0 ? hrefId : (Number.isFinite(dataId) && dataId > 0 ? dataId : null),
          title: firstText(article, ['.information h1', 'h1', 'h2']),
          dateText: definitionValues[0] || '',
          containsText: definitionValues[2] || firstText(article, ['.information .contains']),
          valueText: firstText(article, ['.price', '.value', '.cost']),
          imageURL: firstImageURL(article.querySelector('.image, .thumb, .thumbnail, picture, img') || article)
        };
      })
    };
    """
}

enum RSIStoreCreditParser {
    static func parseStructuredMinorUnits(_ rawValue: String) -> Decimal? {
        guard let value = parseDecimal(rawValue) else {
            return nil
        }

        return value / 100
    }

    static func parseCurrencyText(_ rawValue: String) -> Decimal? {
        parseDecimal(rawValue)
    }

    private static func parseDecimal(_ rawValue: String) -> Decimal? {
        let sanitized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"[^0-9\.-]"#,
                with: "",
                options: .regularExpression
            )

        guard !sanitized.isEmpty else {
            return nil
        }

        return Decimal(string: sanitized, locale: Locale(identifier: "en_US_POSIX"))
    }
}

private struct AccountOverview {
    let storeCreditUSD: Decimal?
    let totalSpendUSD: Decimal?
    let avatarURL: URL?
    let primaryOrganization: AccountOrganization?
    let didRefreshPrimaryOrganization: Bool
}

private nonisolated struct RemotePledgePage: Decodable {
    let accessDenied: Bool
    let title: String
    let totalPages: Int?
    let hasNextPage: Bool?
    let items: [RemotePledge]

    var pageSignature: String {
        items
            .map(\.pageSignature)
            .joined(separator: "|")
    }
}

private nonisolated struct RemotePledge: Decodable {
    let id: Int?
    let title: String
    let statusText: String
    let dateText: String
    let valueText: String
    let containsText: String
    let thumbnailImageURL: String?
    let alsoContains: [String]
    let canGift: Bool
    let canReclaim: Bool
    let canUpgrade: Bool
    let items: [RemotePledgeItem]

    var pageSignature: String {
        [
            id.map(String.init) ?? "nil",
            title,
            statusText,
            dateText,
            valueText,
            containsText,
            alsoContains.joined(separator: ","),
            canGift ? "gift" : "locked",
            canReclaim ? "reclaim" : "keep",
            canUpgrade ? "upgrade" : "fixed"
        ].joined(separator: "•")
    }
}

private nonisolated struct RemotePledgeItem: Decodable {
    let title: String
    let kind: String
    let detail: String
    let imageURL: String?
}

private nonisolated struct RemoteShipCatalogPayload: Decodable {
    let accessDenied: Bool
    let status: String
    let graphQLStatus: Int
    let errors: [String]
    let failureMessage: String?
    let ships: [RemoteStoreShip]
}

private nonisolated struct RemoteAccountBalances: Decodable {
    let accessDenied: Bool
    let graphQLStoreCreditValue: String?
    let storeCreditText: String?
    let avatarURL: String?
}

private nonisolated struct RemotePrimaryOrganization: Decodable {
    let accessDenied: Bool
    let pageUnavailable: Bool
    let organizationName: String?
    let organizationRank: String?

    var organization: AccountOrganization? {
        guard let organizationName = organizationName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !organizationName.isEmpty else {
            return nil
        }

        let normalizedRank = organizationRank?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AccountOrganization(
            name: organizationName,
            rank: normalizedRank?.isEmpty == false ? normalizedRank : nil
        )
    }
}

private nonisolated struct RemoteBillingSummary: Decodable {
    let accessDenied: Bool
    let totalSpendText: String?
    let matchedSnippet: String?
}

private nonisolated struct RemoteReferralOverview: Decodable {
    let accessDenied: Bool
    let campaignId: String
    let currentLadderCount: Int?
    let counterText: String?
}

private nonisolated struct RemoteLegacyReferralPage: Decodable {
    let accessDenied: Bool
    let pageUnavailable: Bool
    let title: String?
    let graphQLCount: Int?
    let legacyLadderCount: Int?
    let matchedSnippet: String?
}

private nonisolated struct AccountRefreshContext {
    let avatarURL: URL?
    let primaryOrganization: AccountOrganization?
    let storeCreditUSD: Decimal?
    let totalSpendUSD: Decimal?
    let referralStats: ReferralStats
    let didRefreshAccountOverview: Bool
    let didRefreshPrimaryOrganization: Bool
    let didRefreshReferralStats: Bool
}

private nonisolated struct PrimaryOrganizationOverview {
    let organization: AccountOrganization?
    let didRefreshPrimaryOrganization: Bool
}

enum ReferralStatsResolver {
    static func resolve(
        currentLadderCount: Int?,
        legacyGraphQLCount: Int?,
        legacyParsedCount: Int?,
        legacyPageUnavailable: Bool
    ) -> ReferralStats {
        ReferralStats(
            currentLadderCount: currentLadderCount,
            legacyLadderCount: legacyPageUnavailable ? nil : (legacyGraphQLCount ?? legacyParsedCount),
            hasLegacyLadder: !legacyPageUnavailable
        )
    }
}

private nonisolated struct RemoteStoreShip: Decodable {
    let id: Int
    let name: String
    let msrpUSD: Decimal?
    let imageURL: String?
}

private nonisolated struct RemoteBuybackPage: Decodable {
    let accessDenied: Bool
    let title: String
    let totalPages: Int?
    let hasNextPage: Bool?
    let items: [RemoteBuybackPledge]

    var pageSignature: String {
        items
            .map(\.pageSignature)
            .joined(separator: "|")
    }
}

private nonisolated struct RemoteBuybackPledge: Decodable {
    let id: Int?
    let title: String
    let dateText: String
    let containsText: String
    let valueText: String
    let imageURL: String?

    var pageSignature: String {
        [
            id.map(String.init) ?? "nil",
            title,
            dateText,
            containsText,
            valueText,
            imageURL ?? ""
        ].joined(separator: "•")
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
