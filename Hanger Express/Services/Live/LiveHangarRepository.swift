import Foundation
import WebKit

@MainActor
final class LiveHangarRepository: HangarRepository {
    private let browser = RSIAccountPageBrowser()
    private let shipCatalogClient = HostedShipCatalogClient()
    private let limitedShipSaleClient = HostedLimitedShipSaleClient()
    private let previewRepository = PreviewHangarRepository()
    private let refreshDiagnostics: RefreshDiagnosticsStore
    private let pledgePageSize = 50
    private let buybackPageSize = 100
    private let maxPledgePages = 200
    private let maxBuybackPages = 100

    init(diagnostics: RefreshDiagnosticsStore) {
        refreshDiagnostics = diagnostics
    }

    private var syncWorkerCount: Int {
        let configuredValue = UserDefaults.standard.integer(forKey: SyncPreferences.workerCountKey)
        let fallbackValue = configuredValue == 0 ? SyncPreferences.defaultWorkerCount : configuredValue
        return SyncPreferences.constrainedWorkerCount(
            fallbackValue,
            isPro: ProSubscriptionConfiguration.storedIsPro
        )
    }

    private enum FullRefreshTracker {
        static let hangar = "hangar"
        static let buyback = "buyback"
        static let account = "account"
    }

    private enum DisplayProgressRange {
        static let preparing = (start: 0.0, end: 0.1)
        static let pages = (start: 0.1, end: 0.9)
        static let finalizing = (start: 0.9, end: 1.0)
    }

    private struct FullHangarRefreshPayload {
        let packages: [HangarPackage]
        let fleet: [FleetShip]
    }

    private struct FullAccountRefreshPayload {
        let avatarURL: URL?
        let primaryOrganization: AccountOrganization?
        let didRefreshPrimaryOrganization: Bool
        let storeCreditUSD: Decimal?
        let totalSpendUSD: Decimal?
        let hangarLogs: [HangarLogEntry]
        let referralStats: ReferralStats
    }

    func fetchSnapshot(
        for session: UserSession,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        if session.authMode == .developerPreview {
            return try await previewRepository.fetchSnapshot(for: session, progress: progress)
        }

        try validate(session: session)
        let hangarBrowser = RSIAccountPageBrowser()
        let buybackBrowser = RSIAccountPageBrowser()
        let accountBrowser = RSIAccountPageBrowser()

        async let hangarPayload = fetchFullHangarRefreshPayload(
            using: session.cookies,
            browser: hangarBrowser,
            progress: progress
        )
        async let buybackPayload = fetchFullBuybackRefreshPayload(
            using: session.cookies,
            browser: buybackBrowser,
            progress: progress
        )
        async let accountPayload = fetchFullAccountRefreshPayload(
            for: session,
            browser: accountBrowser,
            progress: progress
        )

        let resolvedHangarPayload = try await hangarPayload
        let resolvedBuyback = try await buybackPayload
        let resolvedAccountPayload = try await accountPayload

        return HangarSnapshot(
            accountHandle: session.handle,
            lastSyncedAt: .now,
            avatarURL: resolvedAccountPayload.avatarURL ?? session.avatarURL,
            primaryOrganization: resolvedAccountPayload.primaryOrganization,
            didRefreshPrimaryOrganization: resolvedAccountPayload.didRefreshPrimaryOrganization,
            storeCreditUSD: resolvedAccountPayload.storeCreditUSD,
            totalSpendUSD: resolvedAccountPayload.totalSpendUSD,
            packages: resolvedHangarPayload.packages,
            fleet: resolvedHangarPayload.fleet,
            buyback: resolvedBuyback,
            hangarLogs: resolvedAccountPayload.hangarLogs,
            referralStats: resolvedAccountPayload.referralStats
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
                detail: AppLocalizer.format(
                    "Organized %lld pledges into the hangar and fleet views.",
                    remotePledges.count
                ),
                completedUnitCount: 2,
                totalUnitCount: 2,
                displayRange: DisplayProgressRange.finalizing
            )
        )

        return snapshot.updatingHangar(
            packages: packages,
            fleet: fleet
        )
    }

    func refreshHangarData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        affectedPledgeIDs: [Int],
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        if session.authMode == .developerPreview {
            return try await previewRepository.refreshHangarData(
                for: session,
                from: snapshot,
                affectedPledgeIDs: affectedPledgeIDs,
                progress: progress
            )
        }

        let normalizedAffectedPledgeIDs = Array(Set(affectedPledgeIDs))
        guard let partialRefreshStartPage = partialHangarRefreshStartPage(
            from: snapshot,
            affectedPledgeIDs: normalizedAffectedPledgeIDs
        ) else {
            return try await refreshHangarData(
                for: session,
                from: snapshot,
                progress: progress
            )
        }

        try validate(session: session)
        progress(preparationProgress(for: session, stepNumber: 1, stepCount: 3))

        async let remotePledgeTail = fetchRemotePledges(
            using: session.cookies,
            startingAtPage: partialRefreshStartPage,
            progress: progress,
            stepNumber: 2,
            stepCount: 3
        )
        async let shipCatalog = fetchHostedShipCatalog(
            progress: { _ in },
            stepNumber: 3,
            stepCount: 3
        )

        let refreshedRemotePledgeTail = try await remotePledgeTail
        let resolvedShipCatalog = await shipCatalog
        let unaffectedPrefix = snapshot.packages.filter { package in
            guard let sourcePage = package.sourcePage else {
                return false
            }

            return sourcePage < partialRefreshStartPage
        }
        let refreshedPackages = unaffectedPrefix + refreshedRemotePledgeTail.map {
            normalize(package: $0, shipCatalog: resolvedShipCatalog)
        }
        let fleet = FleetProjector.project(
            packages: refreshedPackages,
            shipCatalog: resolvedShipCatalog
        )

        progress(
            makeProgress(
                stage: .finalizing,
                stepNumber: 3,
                stepCount: 3,
                detail: "Rebuilt the hangar from cached pages 1-\(partialRefreshStartPage - 1) and refreshed pages \(partialRefreshStartPage)+.",
                completedUnitCount: 2,
                totalUnitCount: 2,
                displayRange: DisplayProgressRange.finalizing
            )
        )

        return snapshot.updatingHangar(
            packages: refreshedPackages,
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

        async let remoteBuyback = fetchRemoteBuyback(
            using: session.cookies,
            progress: progress,
            stepNumber: 2,
            stepCount: 2
        )
        async let shipCatalog = fetchHostedShipCatalog(
            progress: { _ in },
            stepNumber: 2,
            stepCount: 2
        )

        let resolvedRemoteBuyback = try await remoteBuyback
        let resolvedShipCatalog = await shipCatalog
        let buyback = resolvedRemoteBuyback.map { normalize(buyback: $0, shipCatalog: resolvedShipCatalog) }
        progress(
            makeProgress(
                stage: .finalizing,
                stepNumber: 2,
                stepCount: 2,
                detail: AppLocalizer.format("Organized %lld buy-back pledges.", buyback.count),
                completedUnitCount: 1,
                totalUnitCount: 1,
                displayRange: DisplayProgressRange.finalizing
            )
        )

        return snapshot.updatingBuyback(
            buyback: buyback
        )
    }

    func refreshHangarLogData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        mode: HangarLogFetchMode,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        if session.authMode == .developerPreview {
            return try await previewRepository.refreshHangarLogData(
                for: session,
                from: snapshot,
                mode: mode,
                progress: progress
            )
        }

        try validate(session: session)
        progress(preparationProgress(for: session, stepNumber: 1, stepCount: 2))

        let hangarLogs = try await fetchRemoteHangarLogs(
            using: session.cookies,
            existingLogs: snapshot.hangarLogs,
            mode: mode,
            progress: progress,
            stepNumber: 2,
            stepCount: 2
        )
        progress(
            makeProgress(
                stage: .finalizing,
                stepNumber: 2,
                stepCount: 2,
                detail: AppLocalizer.format("Loaded %lld hangar log entries.", hangarLogs.count),
                completedUnitCount: 1,
                totalUnitCount: 1,
                displayRange: DisplayProgressRange.finalizing
            )
        )

        return snapshot.updatingHangarLogs(
            hangarLogs: hangarLogs
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
            didRefreshPrimaryOrganization: accountContext.didRefreshPrimaryOrganization || snapshot.didRefreshPrimaryOrganization,
            storeCreditUSD: accountContext.didRefreshAccountOverview ? accountContext.storeCreditUSD : snapshot.storeCreditUSD,
            totalSpendUSD: accountContext.didRefreshAccountOverview ? accountContext.totalSpendUSD : snapshot.totalSpendUSD,
            referralStats: accountContext.didRefreshReferralStats ? accountContext.referralStats : snapshot.referralStats,
            lastSyncedAt: (accountContext.didRefreshAccountOverview || accountContext.didRefreshReferralStats) ? .now : snapshot.lastSyncedAt
        )
    }

    private func fetchFullHangarRefreshPayload(
        using cookies: [SessionCookie],
        browser: RSIAccountPageBrowser,
        progress: @escaping RefreshProgressHandler
    ) async throws -> FullHangarRefreshPayload {
        let remotePledges = try await fetchRemotePledges(
            using: cookies,
            browser: browser,
            progress: progress,
            stepNumber: 1,
            stepCount: 2,
            trackerID: FullRefreshTracker.hangar,
            trackerTitle: "Hangar"
        )
        let shipCatalog = await fetchHostedShipCatalog(
            progress: progress,
            stepNumber: 2,
            stepCount: 2,
            trackerID: FullRefreshTracker.hangar,
            trackerTitle: "Hangar"
        )
        let packages = remotePledges.map { normalize(package: $0, shipCatalog: shipCatalog) }
        let fleet = FleetProjector.project(packages: packages, shipCatalog: shipCatalog)
        emitFullRefreshCompletion(
            progress: progress,
            trackerID: FullRefreshTracker.hangar,
            trackerTitle: "Hangar",
            stepNumber: 2,
            stepCount: 2,
            detail: AppLocalizer.string("Hangar sync is ready.")
        )

        return FullHangarRefreshPayload(
            packages: packages,
            fleet: fleet
        )
    }

    private func fetchFullBuybackRefreshPayload(
        using cookies: [SessionCookie],
        browser: RSIAccountPageBrowser,
        progress: @escaping RefreshProgressHandler
    ) async throws -> [BuybackPledge] {
        async let remoteBuyback = fetchRemoteBuyback(
            using: cookies,
            browser: browser,
            progress: progress,
            stepNumber: 1,
            stepCount: 1,
            trackerID: FullRefreshTracker.buyback,
            trackerTitle: "Buy Back"
        )
        async let shipCatalog = fetchHostedShipCatalog(
            progress: { _ in },
            stepNumber: 1,
            stepCount: 1,
            trackerID: FullRefreshTracker.buyback,
            trackerTitle: "Buy Back"
        )

        let resolvedRemoteBuyback = try await remoteBuyback
        let resolvedShipCatalog = await shipCatalog
        let buyback = resolvedRemoteBuyback.map { normalize(buyback: $0, shipCatalog: resolvedShipCatalog) }
        emitFullRefreshCompletion(
            progress: progress,
            trackerID: FullRefreshTracker.buyback,
            trackerTitle: "Buy Back",
            stepNumber: 1,
            stepCount: 1,
            detail: AppLocalizer.string("Buyback sync is ready.")
        )
        return buyback
    }

    private func fetchFullAccountRefreshPayload(
        for session: UserSession,
        browser: RSIAccountPageBrowser,
        progress: @escaping RefreshProgressHandler
    ) async throws -> FullAccountRefreshPayload {
        let accountContext = try await fetchAccountContext(
            for: session,
            browser: browser,
            progress: progress,
            stepNumber: 1,
            stepCount: 1,
            trackerID: FullRefreshTracker.account,
            trackerTitle: "Account"
        )
        emitFullRefreshCompletion(
            progress: progress,
            trackerID: FullRefreshTracker.account,
            trackerTitle: "Account",
            stepNumber: 1,
            stepCount: 1,
            detail: AppLocalizer.string("Account sync is ready.")
        )

        return FullAccountRefreshPayload(
            avatarURL: accountContext.avatarURL,
            primaryOrganization: accountContext.primaryOrganization,
            didRefreshPrimaryOrganization: accountContext.didRefreshPrimaryOrganization,
            storeCreditUSD: accountContext.storeCreditUSD,
            totalSpendUSD: accountContext.totalSpendUSD,
            hangarLogs: [],
            referralStats: accountContext.referralStats
        )
    }

    private func emitFullRefreshCompletion(
        progress: @escaping RefreshProgressHandler,
        trackerID: String,
        trackerTitle: String,
        stepNumber: Int,
        stepCount: Int,
        detail: String
    ) {
        progress(
            makeProgress(
                stage: .finalizing,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: detail,
                completedUnitCount: 1,
                totalUnitCount: 1,
                trackerID: trackerID,
                trackerTitle: trackerTitle,
                displayRange: DisplayProgressRange.finalizing
            )
        )
    }

    func meltPackages(
        for session: UserSession,
        pledgeIDs: [Int],
        password: String
    ) async throws -> MeltPackagesResult {
        if session.authMode == .developerPreview {
            return try await previewRepository.meltPackages(
                for: session,
                pledgeIDs: pledgeIDs,
                password: password
            )
        }

        try validate(session: session)
        return try await browser.reclaimPledges(
            using: session.cookies,
            pledgeIDs: pledgeIDs,
            password: password
        )
    }

    func giftPackages(
        for session: UserSession,
        pledgeIDs: [Int],
        password: String,
        recipientEmail: String,
        recipientName: String
    ) async throws -> GiftPackagesResult {
        if session.authMode == .developerPreview {
            return try await previewRepository.giftPackages(
                for: session,
                pledgeIDs: pledgeIDs,
                password: password,
                recipientEmail: recipientEmail,
                recipientName: recipientName
            )
        }

        try validate(session: session)
        return try await browser.giftPledges(
            using: session.cookies,
            pledgeIDs: pledgeIDs,
            password: password,
            recipientEmail: recipientEmail,
            recipientName: recipientName
        )
    }

    func fetchUpgradeTargets(
        for session: UserSession,
        upgradeItemPledgeID: Int
    ) async throws -> [UpgradeTargetCandidate] {
        if session.authMode == .developerPreview {
            return try await previewRepository.fetchUpgradeTargets(
                for: session,
                upgradeItemPledgeID: upgradeItemPledgeID
            )
        }

        try validate(session: session)
        return try await browser.fetchUpgradeTargets(
            using: session.cookies,
            upgradeItemPledgeID: upgradeItemPledgeID
        )
    }

    func applyUpgrade(
        for session: UserSession,
        upgradeItemPledgeID: Int,
        targetPledgeID: Int,
        password: String
    ) async throws -> ApplyUpgradeResult {
        if session.authMode == .developerPreview {
            return try await previewRepository.applyUpgrade(
                for: session,
                upgradeItemPledgeID: upgradeItemPledgeID,
                targetPledgeID: targetPledgeID,
                password: password
            )
        }

        try validate(session: session)
        return try await browser.applyUpgrade(
            using: session.cookies,
            upgradeItemPledgeID: upgradeItemPledgeID,
            targetPledgeID: targetPledgeID,
            password: password
        )
    }

    func requestCharacterRepair(
        for session: UserSession,
        password: String
    ) async throws -> CharacterRepairResult {
        if session.authMode == .developerPreview {
            return try await previewRepository.requestCharacterRepair(
                for: session,
                password: password
            )
        }

        try validate(session: session)
        return try await browser.requestCharacterRepair(
            using: session.cookies,
            password: password
        )
    }

    func prepareBuybackCheckout(
        for session: UserSession,
        pledge: BuybackPledge
    ) async throws -> BuybackCheckoutPreparation {
        if session.authMode == .developerPreview {
            return try await previewRepository.prepareBuybackCheckout(
                for: session,
                pledge: pledge
            )
        }

        try validate(session: session)
        return try await browser.prepareBuybackCheckout(
            using: session.cookies,
            pledge: pledge
        )
    }

    func fetchLimitedShipSales() async throws -> [LimitedShipSale] {
        let sales = try await limitedShipSaleClient.fetchSales()
        guard let shipCatalog = try? await HostedShipCatalogStore.shared.catalog(using: shipCatalogClient) else {
            return sales
        }

        return sales.map { sale in
            guard let ship = shipCatalog.matchShip(named: sale.name) else {
                return sale
            }

            return sale.replacingHostedAssets(
                imageURL: ship.imageURL,
                manufacturerLogoURL: ship.manufacturerLogoURL
            )
        }
    }

    func addLimitedShipToCart(
        for session: UserSession,
        ship: LimitedShipSale,
        log: @escaping LimitedShipCartLogHandler
    ) async throws -> LimitedShipCartInsertionResult {
        if session.authMode == .developerPreview {
            return try await previewRepository.addLimitedShipToCart(
                for: session,
                ship: ship,
                log: log
            )
        }

        try validate(session: session)
        return try await addLimitedShipToCartUsingSingleSession(
            using: session.cookies,
            ship: ship,
            log: log
        )
    }

    private func addLimitedShipToCartUsingSingleSession(
        using cookies: [SessionCookie],
        ship: LimitedShipSale,
        log: @escaping LimitedShipCartLogHandler
    ) async throws -> LimitedShipCartInsertionResult {
        log("Starting one isolated RSI cart session. Overlapping sessions are disabled so one successful RSI response cannot create duplicate cart items.")
        let attemptBrowser = RSIAccountPageBrowser()
        return try await attemptBrowser.addLimitedShipToCart(
            using: cookies,
            ship: ship,
            log: log,
            maxAttemptCount: 1
        )
    }

    func fetchAuthorizedDevices(
        for session: UserSession,
        password: String?
    ) async throws -> [AuthorizedDevice] {
        if session.authMode == .developerPreview {
            return try await previewRepository.fetchAuthorizedDevices(for: session, password: password)
        }

        try validate(session: session)
        return try await browser.fetchAuthorizedDevices(using: session.cookies, password: password)
    }

    func removeAuthorizedDevice(
        for session: UserSession,
        device: AuthorizedDevice,
        password: String?
    ) async throws {
        if session.authMode == .developerPreview {
            return try await previewRepository.removeAuthorizedDevice(for: session, device: device, password: password)
        }

        try validate(session: session)
        try await browser.removeAuthorizedDevice(using: session.cookies, device: device, password: password)
    }

    func removeAuthorizedDevices(
        for session: UserSession,
        devices: [AuthorizedDevice],
        password: String?
    ) async throws {
        if session.authMode == .developerPreview {
            return try await previewRepository.removeAuthorizedDevices(for: session, devices: devices, password: password)
        }

        try validate(session: session)
        try await browser.removeAuthorizedDevices(using: session.cookies, devices: devices, password: password)
    }

    private func validate(session: UserSession) throws {
        guard !session.cookies.isEmpty else {
            throw LiveHangarRepositoryError.sessionUnavailable
        }
    }

    private func partialHangarRefreshStartPage(
        from snapshot: HangarSnapshot,
        affectedPledgeIDs: [Int]
    ) -> Int? {
        guard !affectedPledgeIDs.isEmpty else {
            return nil
        }

        // Older cached snapshots do not know which RSI page each pledge came from.
        // In that case we fall back to the existing full hangar refresh path.
        guard !snapshot.packages.isEmpty,
              !snapshot.packages.contains(where: { $0.sourcePage == nil }) else {
            return nil
        }

        let affectedPages = snapshot.packages.compactMap { package -> Int? in
            guard affectedPledgeIDs.contains(package.id) else {
                return nil
            }

            return package.sourcePage
        }

        guard let earliestAffectedPage = affectedPages.min(),
              earliestAffectedPage > 1 else {
            return nil
        }

        // A successful melt removes rows and only causes later RSI pages to shift upward.
        // Pages before the earliest affected pledge stay stable, so the smallest safe refresh
        // range is that earliest affected page through the end of the hangar.
        return earliestAffectedPage
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
            detail: AppLocalizer.format("Restoring %lld saved RSI cookies.", session.cookies.count),
            completedUnitCount: 1,
            totalUnitCount: 1,
            displayRange: DisplayProgressRange.preparing
        )
    }

    private func fetchRemotePledges(
        using cookies: [SessionCookie],
        browser activeBrowser: RSIAccountPageBrowser? = nil,
        progress: @escaping RefreshProgressHandler,
        stepNumber: Int,
        stepCount: Int,
        trackerID: String? = nil,
        trackerTitle: String? = nil
    ) async throws -> [RemotePledge] {
        recordRefreshDiagnostics(
            stage: "hangar.connect",
            summary: "Connecting to RSI hangar pledge pages.",
            detail: connectionDetail(
                path: "/en/account/pledges",
                page: 1,
                pageSize: pledgePageSize,
                workerCount: syncWorkerCount,
                cookies: cookies
            )
        )
        progress(
            makeProgress(
                stage: .pledges,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: pageDetail(
                    for: .pledge,
                    page: 1,
                    totalPages: nil,
                    loadedCount: 0,
                    isLoading: true
                ),
                completedUnitCount: 0,
                totalUnitCount: nil,
                trackerID: trackerID,
                trackerTitle: trackerTitle,
                displayRange: DisplayProgressRange.pages
            )
        )

        let directClient = RSIAccountHTTPPageClient(cookies: cookies)
        let firstPage: RemotePledgePage
        do {
            firstPage = try await directClient.fetchPledgePage(
                page: 1,
                pageSize: pledgePageSize
            )
        } catch {
            recordRefreshDiagnostics(
                stage: "hangar.connect",
                summary: "Hangar Express could not load RSI hangar page 1.",
                detail: "errorType=\(String(reflecting: type(of: error))), localizedDescription=\(error.localizedDescription)",
                level: .error
            )
            throw error
        }

        if firstPage.accessDenied {
            recordRefreshDiagnostics(
                stage: "hangar.response",
                summary: "RSI rejected the saved session while opening hangar page 1.",
                detail: "accessDenied=true",
                level: .warning
            )
            throw LiveHangarRepositoryError.sessionExpired
        }

        var remotePledges = firstPage.items.enumerated().map { itemOffset, pledge in
            pledge.withSourcePage(1, index: itemOffset)
        }
        let inferredTotalPages = inferredTotalPages(
            reportedByPage: firstPage.totalPages,
            page: 1,
            pageItemCount: firstPage.items.count,
            hasNextPage: firstPage.hasNextPage
        )
        let workerCount = syncWorkerCount
        recordRefreshDiagnostics(
            stage: "hangar.response",
            summary: "Loaded RSI hangar page 1.",
            detail: [
                "itemCount=\(firstPage.items.count)",
                "reportedTotalPages=\(firstPage.totalPages.map(String.init) ?? "unknown")",
                "inferredTotalPages=\(inferredTotalPages.map(String.init) ?? "unknown")",
                "hasNextPage=\(firstPage.hasNextPage.map { $0 ? "yes" : "no" } ?? "unknown")"
            ].joined(separator: ", ")
        )

        progress(
            makeProgress(
                stage: .pledges,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: pageDetail(
                    for: .pledge,
                    page: 1,
                    totalPages: inferredTotalPages,
                    loadedCount: remotePledges.count,
                    isLoading: false
                ),
                completedUnitCount: 1,
                totalUnitCount: inferredTotalPages,
                trackerID: trackerID,
                trackerTitle: trackerTitle,
                displayRange: DisplayProgressRange.pages
            )
        )

        guard let totalPages = inferredTotalPages else {
            return try await fetchRemotePledgesSequentially(
                using: cookies,
                startingFrom: 2,
                initialItems: remotePledges,
                knownTotalPages: nil,
                previousPageSignature: firstPage.pageSignature,
                browser: activeBrowser,
                progress: progress,
                stepNumber: stepNumber,
                stepCount: stepCount,
                trackerID: trackerID,
                trackerTitle: trackerTitle
            )
        }

        if totalPages > maxPledgePages {
            throw LiveHangarRepositoryError.pageLimitReached(
                itemLabel: "hangar pledges",
                limit: maxPledgePages
            )
        }

        guard totalPages > 1 else {
            return remotePledges
        }

        if workerCount <= 1 {
            return try await fetchRemotePledgesSequentially(
                using: cookies,
                startingFrom: 2,
                initialItems: remotePledges,
                knownTotalPages: totalPages,
                previousPageSignature: firstPage.pageSignature,
                browser: activeBrowser,
                progress: progress,
                stepNumber: stepNumber,
                stepCount: stepCount,
                trackerID: trackerID,
                trackerTitle: trackerTitle
            )
        }

        let warmedCookies = directClient.currentCookies
        let remainingPages = Array(2 ... totalPages)
        let orderedResults: [RemotePledgePage]
        do {
            orderedResults = try await fetchPledgePagesConcurrently(
                using: warmedCookies.isEmpty ? cookies : warmedCookies,
                pages: remainingPages,
                workerCount: workerCount,
                initialLoadedCount: remotePledges.count
            ) { completedPages, loadedCount in
                progress(
                    self.makeProgress(
                        stage: .pledges,
                        stepNumber: stepNumber,
                        stepCount: stepCount,
                        detail: self.parallelPageDetail(
                            for: .pledge,
                            completedPages: completedPages,
                            totalPages: totalPages,
                            loadedCount: loadedCount,
                            workerCount: workerCount
                        ),
                        completedUnitCount: completedPages,
                        totalUnitCount: totalPages,
                        trackerID: trackerID,
                        trackerTitle: trackerTitle,
                        displayRange: DisplayProgressRange.pages
                    )
                )
            }
        } catch {
            recordRefreshDiagnostics(
                stage: "hangar.parallel-fallback",
                summary: "Parallel hangar page loading failed, so Hangar Express is retrying sequentially.",
                detail: "errorType=\(String(reflecting: type(of: error))), localizedDescription=\(error.localizedDescription)",
                level: .warning
            )
            return try await fetchRemotePledgesSequentially(
                using: cookies,
                startingFrom: 2,
                initialItems: remotePledges,
                knownTotalPages: totalPages,
                previousPageSignature: firstPage.pageSignature,
                browser: activeBrowser,
                progress: progress,
                stepNumber: stepNumber,
                stepCount: stepCount,
                trackerID: trackerID,
                trackerTitle: trackerTitle
            )
        }

        for (pageOffset, result) in orderedResults.enumerated() {
            if result.accessDenied {
                throw LiveHangarRepositoryError.sessionExpired
            }

            let pageNumber = pageOffset + 2
            remotePledges.append(
                contentsOf: result.items.enumerated().map { itemOffset, pledge in
                    pledge.withSourcePage(pageNumber, index: itemOffset)
                }
            )
        }

        return remotePledges
    }

    private func fetchRemotePledges(
        using cookies: [SessionCookie],
        startingAtPage startPage: Int,
        browser activeBrowser: RSIAccountPageBrowser? = nil,
        progress: @escaping RefreshProgressHandler,
        stepNumber: Int,
        stepCount: Int,
        trackerID: String? = nil,
        trackerTitle: String? = nil
    ) async throws -> [RemotePledge] {
        guard startPage > 1 else {
            return try await fetchRemotePledges(
                using: cookies,
                browser: activeBrowser,
                progress: progress,
                stepNumber: stepNumber,
                stepCount: stepCount,
                trackerID: trackerID,
                trackerTitle: trackerTitle
            )
        }

        recordRefreshDiagnostics(
            stage: "hangar.connect",
            summary: "Connecting to the affected RSI hangar pages for a partial refresh.",
            detail: connectionDetail(
                path: "/en/account/pledges",
                page: startPage,
                pageSize: pledgePageSize,
                workerCount: syncWorkerCount,
                cookies: cookies,
                extra: ["partialRefresh=yes"]
            )
        )
        progress(
            makeProgress(
                stage: .pledges,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: AppLocalizer.format(
                    "Refreshing the affected hangar tail beginning with page %lld.",
                    startPage
                ),
                completedUnitCount: 0,
                totalUnitCount: nil,
                trackerID: trackerID,
                trackerTitle: trackerTitle,
                displayRange: DisplayProgressRange.pages
            )
        )

        let directClient = RSIAccountHTTPPageClient(cookies: cookies)
        let firstPage: RemotePledgePage
        do {
            firstPage = try await directClient.fetchPledgePage(
                page: startPage,
                pageSize: pledgePageSize
            )
        } catch {
            recordRefreshDiagnostics(
                stage: "hangar.connect",
                summary: "Hangar Express could not load the first affected RSI hangar page.",
                detail: "page=\(startPage), errorType=\(String(reflecting: type(of: error))), localizedDescription=\(error.localizedDescription)",
                level: .error
            )
            throw error
        }

        if firstPage.accessDenied {
            recordRefreshDiagnostics(
                stage: "hangar.response",
                summary: "RSI rejected the saved session while opening the first affected hangar page.",
                detail: "page=\(startPage), accessDenied=true",
                level: .warning
            )
            throw LiveHangarRepositoryError.sessionExpired
        }

        var remotePledges = firstPage.items.enumerated().map { itemOffset, pledge in
            pledge.withSourcePage(startPage, index: itemOffset)
        }
        let inferredTotalPages = inferredTotalPages(
            reportedByPage: firstPage.totalPages,
            page: startPage,
            pageItemCount: firstPage.items.count,
            hasNextPage: firstPage.hasNextPage
        )
        let workerCount = syncWorkerCount
        recordRefreshDiagnostics(
            stage: "hangar.response",
            summary: "Loaded the first affected RSI hangar page.",
            detail: [
                "page=\(startPage)",
                "itemCount=\(firstPage.items.count)",
                "reportedTotalPages=\(firstPage.totalPages.map(String.init) ?? "unknown")",
                "inferredTotalPages=\(inferredTotalPages.map(String.init) ?? "unknown")",
                "hasNextPage=\(firstPage.hasNextPage.map { $0 ? "yes" : "no" } ?? "unknown")"
            ].joined(separator: ", ")
        )

        progress(
            makeProgress(
                stage: .pledges,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: pageDetail(
                    for: .pledge,
                    page: startPage,
                    totalPages: inferredTotalPages,
                    loadedCount: remotePledges.count,
                    isLoading: false
                ),
                completedUnitCount: 1,
                totalUnitCount: inferredTotalPages.map { max($0 - startPage + 1, 1) },
                trackerID: trackerID,
                trackerTitle: trackerTitle,
                displayRange: DisplayProgressRange.pages
            )
        )

        guard let totalPages = inferredTotalPages else {
            return try await fetchRemotePledgesSequentially(
                using: cookies,
                startingFrom: startPage + 1,
                initialItems: remotePledges,
                knownTotalPages: nil,
                previousPageSignature: firstPage.pageSignature,
                browser: activeBrowser,
                progress: progress,
                stepNumber: stepNumber,
                stepCount: stepCount,
                trackerID: trackerID,
                trackerTitle: trackerTitle
            )
        }

        if totalPages > maxPledgePages {
            throw LiveHangarRepositoryError.pageLimitReached(
                itemLabel: "hangar pledges",
                limit: maxPledgePages
            )
        }

        guard totalPages > startPage else {
            return remotePledges
        }

        if workerCount <= 1 {
            return try await fetchRemotePledgesSequentially(
                using: cookies,
                startingFrom: startPage + 1,
                initialItems: remotePledges,
                knownTotalPages: totalPages,
                previousPageSignature: firstPage.pageSignature,
                browser: activeBrowser,
                progress: progress,
                stepNumber: stepNumber,
                stepCount: stepCount,
                trackerID: trackerID,
                trackerTitle: trackerTitle
            )
        }

        let warmedCookies = directClient.currentCookies
        let remainingPages = Array((startPage + 1) ... totalPages)
        let orderedResults: [RemotePledgePage]
        do {
            orderedResults = try await fetchPledgePagesConcurrently(
                using: warmedCookies.isEmpty ? cookies : warmedCookies,
                pages: remainingPages,
                workerCount: workerCount,
                initialLoadedCount: remotePledges.count
            ) { completedPages, loadedCount in
                progress(
                    self.makeProgress(
                        stage: .pledges,
                        stepNumber: stepNumber,
                        stepCount: stepCount,
                        detail: self.parallelPageDetail(
                            for: .pledge,
                            completedPages: completedPages,
                            totalPages: max(totalPages - startPage + 1, 1),
                            loadedCount: loadedCount,
                            workerCount: workerCount
                        ),
                        completedUnitCount: completedPages,
                        totalUnitCount: max(totalPages - startPage + 1, 1),
                        trackerID: trackerID,
                        trackerTitle: trackerTitle,
                        displayRange: DisplayProgressRange.pages
                    )
                )
            }
        } catch {
            recordRefreshDiagnostics(
                stage: "hangar.parallel-fallback",
                summary: "Parallel partial hangar loading failed, so Hangar Express is retrying sequentially.",
                detail: "errorType=\(String(reflecting: type(of: error))), localizedDescription=\(error.localizedDescription)",
                level: .warning
            )
            return try await fetchRemotePledgesSequentially(
                using: cookies,
                startingFrom: startPage + 1,
                initialItems: remotePledges,
                knownTotalPages: totalPages,
                previousPageSignature: firstPage.pageSignature,
                browser: activeBrowser,
                progress: progress,
                stepNumber: stepNumber,
                stepCount: stepCount,
                trackerID: trackerID,
                trackerTitle: trackerTitle
            )
        }

        for (pageOffset, result) in orderedResults.enumerated() {
            if result.accessDenied {
                throw LiveHangarRepositoryError.sessionExpired
            }

            let pageNumber = startPage + pageOffset + 1
            remotePledges.append(
                contentsOf: result.items.enumerated().map { itemOffset, pledge in
                    pledge.withSourcePage(pageNumber, index: itemOffset)
                }
            )
        }

        return remotePledges
    }

    private func fetchRemoteBuyback(
        using cookies: [SessionCookie],
        browser activeBrowser: RSIAccountPageBrowser? = nil,
        progress: @escaping RefreshProgressHandler,
        stepNumber: Int,
        stepCount: Int,
        trackerID: String? = nil,
        trackerTitle: String? = nil
    ) async throws -> [RemoteBuybackPledge] {
        recordRefreshDiagnostics(
            stage: "buyback.connect",
            summary: "Connecting to RSI buy-back pages.",
            detail: connectionDetail(
                path: "/en/account/buy-back-pledges",
                page: 1,
                pageSize: buybackPageSize,
                workerCount: syncWorkerCount,
                cookies: cookies
            )
        )
        progress(
            makeProgress(
                stage: .buyback,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: pageDetail(
                    for: .buybackItem,
                    page: 1,
                    totalPages: nil,
                    loadedCount: 0,
                    isLoading: true
                ),
                completedUnitCount: 0,
                totalUnitCount: nil,
                trackerID: trackerID,
                trackerTitle: trackerTitle,
                displayRange: DisplayProgressRange.pages
            )
        )

        let directClient = RSIAccountHTTPPageClient(cookies: cookies)
        let firstPage: RemoteBuybackPage
        do {
            firstPage = try await directClient.fetchBuybackPage(
                page: 1,
                pageSize: buybackPageSize
            )
        } catch {
            recordRefreshDiagnostics(
                stage: "buyback.connect",
                summary: "Hangar Express could not load RSI buy-back page 1.",
                detail: "errorType=\(String(reflecting: type(of: error))), localizedDescription=\(error.localizedDescription)",
                level: .error
            )
            throw error
        }

        if firstPage.accessDenied {
            recordRefreshDiagnostics(
                stage: "buyback.response",
                summary: "RSI rejected the saved session while opening buy-back page 1.",
                detail: "accessDenied=true",
                level: .warning
            )
            throw LiveHangarRepositoryError.sessionExpired
        }

        var remoteBuyback = firstPage.items
        let inferredTotalPages = inferredTotalPages(
            reportedByPage: firstPage.totalPages,
            page: 1,
            pageItemCount: firstPage.items.count,
            hasNextPage: firstPage.hasNextPage
        )
        let workerCount = syncWorkerCount
        recordRefreshDiagnostics(
            stage: "buyback.response",
            summary: "Loaded RSI buy-back page 1.",
            detail: [
                "itemCount=\(firstPage.items.count)",
                "reportedTotalPages=\(firstPage.totalPages.map(String.init) ?? "unknown")",
                "inferredTotalPages=\(inferredTotalPages.map(String.init) ?? "unknown")",
                "hasNextPage=\(firstPage.hasNextPage.map { $0 ? "yes" : "no" } ?? "unknown")"
            ].joined(separator: ", ")
        )

        progress(
            makeProgress(
                stage: .buyback,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: pageDetail(
                    for: .buybackItem,
                    page: 1,
                    totalPages: inferredTotalPages,
                    loadedCount: remoteBuyback.count,
                    isLoading: false
                ),
                completedUnitCount: 1,
                totalUnitCount: inferredTotalPages,
                trackerID: trackerID,
                trackerTitle: trackerTitle,
                displayRange: DisplayProgressRange.pages
            )
        )

        guard let totalPages = inferredTotalPages else {
            return try await fetchRemoteBuybackSequentially(
                using: cookies,
                startingFrom: 2,
                initialItems: remoteBuyback,
                knownTotalPages: nil,
                previousPageSignature: firstPage.pageSignature,
                browser: activeBrowser,
                progress: progress,
                stepNumber: stepNumber,
                stepCount: stepCount,
                trackerID: trackerID,
                trackerTitle: trackerTitle
            )
        }

        if totalPages > maxBuybackPages {
            throw LiveHangarRepositoryError.pageLimitReached(
                itemLabel: "buy-back pledges",
                limit: maxBuybackPages
            )
        }

        guard totalPages > 1 else {
            return remoteBuyback
        }

        if workerCount <= 1 {
            return try await fetchRemoteBuybackSequentially(
                using: cookies,
                startingFrom: 2,
                initialItems: remoteBuyback,
                knownTotalPages: totalPages,
                previousPageSignature: firstPage.pageSignature,
                browser: activeBrowser,
                progress: progress,
                stepNumber: stepNumber,
                stepCount: stepCount,
                trackerID: trackerID,
                trackerTitle: trackerTitle
            )
        }

        let warmedCookies = directClient.currentCookies
        let remainingPages = Array(2 ... totalPages)
        let orderedResults: [RemoteBuybackPage]
        do {
            orderedResults = try await fetchBuybackPagesConcurrently(
                using: warmedCookies.isEmpty ? cookies : warmedCookies,
                pages: remainingPages,
                workerCount: workerCount,
                initialLoadedCount: remoteBuyback.count
            ) { completedPages, loadedCount in
                progress(
                    self.makeProgress(
                        stage: .buyback,
                        stepNumber: stepNumber,
                        stepCount: stepCount,
                        detail: self.parallelPageDetail(
                            for: .buybackItem,
                            completedPages: completedPages,
                            totalPages: totalPages,
                            loadedCount: loadedCount,
                            workerCount: workerCount
                        ),
                        completedUnitCount: completedPages,
                        totalUnitCount: totalPages,
                        trackerID: trackerID,
                        trackerTitle: trackerTitle,
                        displayRange: DisplayProgressRange.pages
                    )
                )
            }
        } catch {
            recordRefreshDiagnostics(
                stage: "buyback.parallel-fallback",
                summary: "Parallel buy-back page loading failed, so Hangar Express is retrying sequentially.",
                detail: "errorType=\(String(reflecting: type(of: error))), localizedDescription=\(error.localizedDescription)",
                level: .warning
            )
            return try await fetchRemoteBuybackSequentially(
                using: cookies,
                startingFrom: 2,
                initialItems: remoteBuyback,
                knownTotalPages: totalPages,
                previousPageSignature: firstPage.pageSignature,
                browser: activeBrowser,
                progress: progress,
                stepNumber: stepNumber,
                stepCount: stepCount,
                trackerID: trackerID,
                trackerTitle: trackerTitle
            )
        }

        for result in orderedResults {
            if result.accessDenied {
                throw LiveHangarRepositoryError.sessionExpired
            }

            remoteBuyback.append(contentsOf: result.items)
        }

        return remoteBuyback
    }

    private func fetchRemotePledgesSequentially(
        using cookies: [SessionCookie],
        startingFrom startPage: Int,
        initialItems: [RemotePledge],
        knownTotalPages: Int?,
        previousPageSignature: String?,
        browser activeBrowser: RSIAccountPageBrowser? = nil,
        progress: @escaping RefreshProgressHandler,
        stepNumber: Int,
        stepCount: Int,
        trackerID: String? = nil,
        trackerTitle: String? = nil
    ) async throws -> [RemotePledge] {
        var remotePledges = initialItems
        var pledgeTotalPages = knownTotalPages
        var previousSignature = previousPageSignature
        var didReachEndOfPledges = false
        let directClient = RSIAccountHTTPPageClient(cookies: cookies)

        for page in startPage ... maxPledgePages {
            progress(
                makeProgress(
                    stage: .pledges,
                    stepNumber: stepNumber,
                    stepCount: stepCount,
                    detail: pageDetail(
                        for: .pledge,
                        page: page,
                        totalPages: pledgeTotalPages,
                        loadedCount: remotePledges.count,
                        isLoading: true
                    ),
                    completedUnitCount: max(page - 1, 0),
                    totalUnitCount: pledgeTotalPages,
                    trackerID: trackerID,
                    trackerTitle: trackerTitle,
                    displayRange: DisplayProgressRange.pages
                )
            )

            let result = try await directClient.fetchPledgePage(
                page: page,
                pageSize: pledgePageSize
            )

            if result.accessDenied {
                throw LiveHangarRepositoryError.sessionExpired
            }

            remotePledges.append(
                contentsOf: result.items.enumerated().map { itemOffset, pledge in
                    pledge.withSourcePage(page, index: itemOffset)
                }
            )

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
                        for: .pledge,
                        page: page,
                        totalPages: pledgeTotalPages,
                        loadedCount: remotePledges.count,
                        isLoading: false
                    ),
                    completedUnitCount: page,
                    totalUnitCount: pledgeTotalPages,
                    trackerID: trackerID,
                    trackerTitle: trackerTitle,
                    displayRange: DisplayProgressRange.pages
                )
            )

            if shouldStopFetching(
                after: page,
                pageItemCount: result.items.count,
                knownTotalPages: pledgeTotalPages,
                hasNextPage: result.hasNextPage,
                pageSignature: result.pageSignature,
                previousPageSignature: previousSignature
            ) {
                didReachEndOfPledges = true
                break
            }

            previousSignature = result.pageSignature
        }

        guard didReachEndOfPledges else {
            throw LiveHangarRepositoryError.pageLimitReached(
                itemLabel: "hangar pledges",
                limit: maxPledgePages
            )
        }

        return remotePledges
    }

    private func fetchRemoteBuybackSequentially(
        using cookies: [SessionCookie],
        startingFrom startPage: Int,
        initialItems: [RemoteBuybackPledge],
        knownTotalPages: Int?,
        previousPageSignature: String?,
        browser activeBrowser: RSIAccountPageBrowser? = nil,
        progress: @escaping RefreshProgressHandler,
        stepNumber: Int,
        stepCount: Int,
        trackerID: String? = nil,
        trackerTitle: String? = nil
    ) async throws -> [RemoteBuybackPledge] {
        var remoteBuyback = initialItems
        var buybackTotalPages = knownTotalPages
        var previousSignature = previousPageSignature
        var didReachEndOfBuyback = false
        let directClient = RSIAccountHTTPPageClient(cookies: cookies)

        for page in startPage ... maxBuybackPages {
            progress(
                makeProgress(
                    stage: .buyback,
                    stepNumber: stepNumber,
                    stepCount: stepCount,
                    detail: pageDetail(
                        for: .buybackItem,
                        page: page,
                        totalPages: buybackTotalPages,
                        loadedCount: remoteBuyback.count,
                        isLoading: true
                    ),
                    completedUnitCount: max(page - 1, 0),
                    totalUnitCount: buybackTotalPages,
                    trackerID: trackerID,
                    trackerTitle: trackerTitle,
                    displayRange: DisplayProgressRange.pages
                )
            )

            let result = try await directClient.fetchBuybackPage(
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
                        for: .buybackItem,
                        page: page,
                        totalPages: buybackTotalPages,
                        loadedCount: remoteBuyback.count,
                        isLoading: false
                    ),
                    completedUnitCount: page,
                    totalUnitCount: buybackTotalPages,
                    trackerID: trackerID,
                    trackerTitle: trackerTitle,
                    displayRange: DisplayProgressRange.pages
                )
            )

            if shouldStopFetching(
                after: page,
                pageItemCount: result.items.count,
                knownTotalPages: buybackTotalPages,
                hasNextPage: result.hasNextPage,
                pageSignature: result.pageSignature,
                previousPageSignature: previousSignature
            ) {
                didReachEndOfBuyback = true
                break
            }

            previousSignature = result.pageSignature
        }

        guard didReachEndOfBuyback else {
            throw LiveHangarRepositoryError.pageLimitReached(
                itemLabel: "buy-back pledges",
                limit: maxBuybackPages
            )
        }

        return remoteBuyback
    }

    private func fetchPledgePagesConcurrently(
        using cookies: [SessionCookie],
        pages: [Int],
        workerCount: Int,
        initialLoadedCount: Int,
        progress: @escaping (_ completedPages: Int, _ loadedCount: Int) -> Void
    ) async throws -> [RemotePledgePage] {
        let chunks = makePageChunks(
            pages: pages,
            preferredWorkerCount: workerCount
        )
        let pageSize = pledgePageSize
        let totalPageCount = pages.count + 1
        let progressTracker = ConcurrentPageProgress(
            completedPages: 1,
            loadedCount: initialLoadedCount
        )
        var resultsByPage: [Int: RemotePledgePage] = [:]

        try await withThrowingTaskGroup(of: [(Int, RemotePledgePage)].self) { group in
            for chunk in chunks {
                group.addTask {
                    try await RSIAccountHTTPPageClient.loadPledgeChunk(
                        using: cookies,
                        pages: chunk,
                        pageSize: pageSize
                    ) { _, itemCount in
                        let totals = await progressTracker.record(
                            completedPages: 1,
                            loadedCount: itemCount,
                            totalPageCount: totalPageCount
                        )
                        guard totals.shouldEmit else {
                            return
                        }

                        Task { @MainActor in
                            progress(totals.completedPages, totals.loadedCount)
                        }
                    }
                }
            }

            while let chunkResults = try await group.next() {
                for (page, result) in chunkResults {
                    resultsByPage[page] = result
                }
            }
        }

        guard resultsByPage.count == pages.count else {
            throw LiveHangarRepositoryError.unexpectedMarkup(
                "Parallel pledge sync did not return every requested page."
            )
        }

        return try pages.map { page in
            guard let result = resultsByPage[page] else {
                throw LiveHangarRepositoryError.unexpectedMarkup(
                    "Parallel pledge sync missed page \(page)."
                )
            }
            return result
        }
    }

    private func fetchBuybackPagesConcurrently(
        using cookies: [SessionCookie],
        pages: [Int],
        workerCount: Int,
        initialLoadedCount: Int,
        progress: @escaping (_ completedPages: Int, _ loadedCount: Int) -> Void
    ) async throws -> [RemoteBuybackPage] {
        let chunks = makePageChunks(
            pages: pages,
            preferredWorkerCount: workerCount
        )
        let pageSize = buybackPageSize
        let totalPageCount = pages.count + 1
        let progressTracker = ConcurrentPageProgress(
            completedPages: 1,
            loadedCount: initialLoadedCount
        )
        var resultsByPage: [Int: RemoteBuybackPage] = [:]

        try await withThrowingTaskGroup(of: [(Int, RemoteBuybackPage)].self) { group in
            for chunk in chunks {
                group.addTask {
                    try await RSIAccountHTTPPageClient.loadBuybackChunk(
                        using: cookies,
                        pages: chunk,
                        pageSize: pageSize
                    ) { _, itemCount in
                        let totals = await progressTracker.record(
                            completedPages: 1,
                            loadedCount: itemCount,
                            totalPageCount: totalPageCount
                        )
                        guard totals.shouldEmit else {
                            return
                        }

                        Task { @MainActor in
                            progress(totals.completedPages, totals.loadedCount)
                        }
                    }
                }
            }

            while let chunkResults = try await group.next() {
                for (page, result) in chunkResults {
                    resultsByPage[page] = result
                }
            }
        }

        guard resultsByPage.count == pages.count else {
            throw LiveHangarRepositoryError.unexpectedMarkup(
                "Parallel buy-back sync did not return every requested page."
            )
        }

        return try pages.map { page in
            guard let result = resultsByPage[page] else {
                throw LiveHangarRepositoryError.unexpectedMarkup(
                    "Parallel buy-back sync missed page \(page)."
                )
            }
            return result
        }
    }

    private func makePageChunks(
        pages: [Int],
        preferredWorkerCount: Int
    ) -> [[Int]] {
        guard !pages.isEmpty else {
            return []
        }

        let workerCount = min(max(preferredWorkerCount, 1), pages.count)
        let baseChunkSize = max(pages.count / workerCount, 1)
        let remainder = pages.count % workerCount

        var chunks: [[Int]] = []
        var index = 0

        for workerIndex in 0 ..< workerCount {
            var chunkSize = baseChunkSize
            if workerIndex == workerCount - 1 {
                chunkSize += remainder
            }

            let endIndex = min(index + chunkSize, pages.count)
            if index < endIndex {
                chunks.append(Array(pages[index ..< endIndex]))
            }
            index = endIndex
        }

        if index < pages.count {
            chunks.append(Array(pages[index...]))
        }

        return chunks
    }

    private func fetchRemoteHangarLogs(
        using cookies: [SessionCookie],
        existingLogs: [HangarLogEntry],
        mode: HangarLogFetchMode = .initial,
        browser activeBrowser: RSIAccountPageBrowser? = nil,
        progress: @escaping RefreshProgressHandler,
        stepNumber: Int,
        stepCount: Int,
        trackerID: String? = nil,
        trackerTitle: String? = nil
    ) async throws -> [HangarLogEntry] {
        recordRefreshDiagnostics(
            stage: "hangar-log.connect",
            summary: "Opening RSI's hangar log window.",
            detail: connectionDetail(
                path: "/en/account/pledges",
                page: 1,
                cookies: cookies,
                transport: "WKWebView.nonPersistent",
                extra: ["knownMarkerCount=\(existingLogs.prefix(50).count)"]
            )
        )
        progress(
            makeProgress(
                stage: .hangarLog,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: AppLocalizer.string("Opening RSI's hangar log window and loading the current entries."),
                completedUnitCount: 0,
                totalUnitCount: 1,
                trackerID: trackerID,
                trackerTitle: trackerTitle,
                displayRange: DisplayProgressRange.pages
            )
        )

        let activeBrowser = activeBrowser ?? browser
        let result: RemoteHangarLogPage
        do {
            result = try await activeBrowser.fetchHangarLogPage(
                using: cookies,
                page: 1,
                maxEntries: mode.entryLimit,
                knownRawTexts: hangarLogStopMarkers(from: existingLogs)
            )
        } catch {
            recordRefreshDiagnostics(
                stage: "hangar-log.connect",
                summary: "Hangar Express could not load the RSI hangar log page.",
                detail: "errorType=\(String(reflecting: type(of: error))), localizedDescription=\(error.localizedDescription)",
                level: .error
            )
            throw error
        }

        if result.accessDenied {
            recordRefreshDiagnostics(
                stage: "hangar-log.response",
                summary: "RSI rejected the saved session while opening the hangar log window.",
                detail: "statusCode=\(result.statusCode), accessDenied=true",
                level: .warning
            )
            throw LiveHangarRepositoryError.sessionExpired
        }

        if !(200 ..< 300).contains(result.statusCode) {
            recordRefreshDiagnostics(
                stage: "hangar-log.response",
                summary: "RSI returned a non-success HTTP status while loading the hangar log.",
                detail: [
                    "statusCode=\(result.statusCode)",
                    "failureMessage=\(result.failureMessage ?? "none")",
                    "debugSummary=\(result.debugSummary ?? "none")"
                ].joined(separator: "\n"),
                level: .error
            )
            throw LiveHangarRepositoryError.unexpectedMarkup(
                result.failureMessage
                ?? "RSI hangar log returned HTTP \(result.statusCode)."
            )
        }

        if let failureMessage = result.failureMessage {
            recordRefreshDiagnostics(
                stage: "hangar-log.response",
                summary: "RSI opened the hangar log window but did not finish returning usable log data.",
                detail: [
                    "statusCode=\(result.statusCode)",
                    "failureMessage=\(failureMessage)",
                    "debugSummary=\(result.debugSummary ?? "none")"
                ].joined(separator: "\n"),
                level: .error
            )
            throw LiveHangarRepositoryError.unexpectedMarkup(failureMessage)
        }

        let fetchedLogs = Array(HangarLogParser.parse(result.items).prefix(mode.entryLimit))
        let hangarLogs = mergedHangarLogs(
            fetchedLogs: fetchedLogs,
            existingLogs: existingLogs,
            entryLimit: mode.entryLimit
        )

        if hangarLogs.isEmpty {
            recordRefreshDiagnostics(
                stage: "hangar-log.response",
                summary: "RSI returned an empty hangar log payload.",
                detail: [
                    "statusCode=\(result.statusCode)",
                    "returnedItems=\(result.items.count)",
                    "debugSummary=\(result.debugSummary ?? "none")"
                ].joined(separator: "\n"),
                level: .error
            )
            throw LiveHangarRepositoryError.unexpectedMarkup(
                result.debugSummary
                ?? "RSI opened the hangar log window, but no log entries were discovered."
            )
        }

        let addedEntryCount = max(hangarLogs.count - existingLogs.count, 0)
        let detail: String
        if existingLogs.isEmpty {
            detail = hangarLogs.count >= mode.entryLimit
                ? AppLocalizer.format(
                    "Loaded %lld hangar log entries from RSI (cap %lld).",
                    hangarLogs.count,
                    mode.entryLimit
                )
                : AppLocalizer.format("Loaded %lld hangar log entries from RSI.", hangarLogs.count)
        } else if addedEntryCount > 0 {
            detail = addedEntryCount == 1
                ? AppLocalizer.format("Added %lld new hangar log entry from RSI. %lld cached total.", addedEntryCount, hangarLogs.count)
                : AppLocalizer.format("Added %lld new hangar log entries from RSI. %lld cached total.", addedEntryCount, hangarLogs.count)
        } else {
            detail = AppLocalizer.string("Your cached hangar log is already up to date.")
        }

        progress(
            makeProgress(
                stage: .hangarLog,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: detail,
                completedUnitCount: 1,
                totalUnitCount: 1,
                trackerID: trackerID,
                trackerTitle: trackerTitle,
                displayRange: DisplayProgressRange.pages
            )
        )
        recordRefreshDiagnostics(
            stage: "hangar-log.response",
            summary: "Loaded hangar log entries from RSI.",
            detail: [
                "fetchedEntries=\(fetchedLogs.count)",
                "mergedEntries=\(hangarLogs.count)",
                "addedEntries=\(addedEntryCount)",
                "statusCode=\(result.statusCode)"
            ].joined(separator: ", ")
        )

        return hangarLogs.sorted { lhs, rhs in
            lhs.occurredAt > rhs.occurredAt
        }
    }

    private func hangarLogStopMarkers(from existingLogs: [HangarLogEntry]) -> [String] {
        Array(
            existingLogs
                .prefix(50)
                .map(\.rawText)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
    }

    private func mergedHangarLogs(
        fetchedLogs: [HangarLogEntry],
        existingLogs: [HangarLogEntry],
        entryLimit: Int
    ) -> [HangarLogEntry] {
        var seenEntryIDs = Set<String>()
        let sortedEntries = (fetchedLogs + existingLogs).sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt {
                return lhs.occurredAt > rhs.occurredAt
            }

            return lhs.id > rhs.id
        }

        var mergedEntries: [HangarLogEntry] = []
        mergedEntries.reserveCapacity(min(sortedEntries.count, entryLimit))

        for entry in sortedEntries {
            guard seenEntryIDs.insert(entry.id).inserted else {
                continue
            }

            mergedEntries.append(entry)

            if mergedEntries.count >= entryLimit {
                break
            }
        }

        return mergedEntries
    }

    private func fetchHostedShipCatalog(
        progress: @escaping RefreshProgressHandler,
        stepNumber: Int,
        stepCount: Int,
        trackerID: String? = nil,
        trackerTitle: String? = nil
    ) async -> RSIShipCatalog? {
        progress(
            makeProgress(
                stage: .finalizing,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: AppLocalizer.string("Loading hosted ship MSRP and thumbnail data for upgrade valuation."),
                completedUnitCount: 0,
                totalUnitCount: 2,
                trackerID: trackerID,
                trackerTitle: trackerTitle,
                displayRange: DisplayProgressRange.finalizing
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
                    ? AppLocalizer.string("Hosted ship valuation data was unavailable. Continuing with hangar media only.")
                    : AppLocalizer.format(
                        "Loaded %lld hosted ships for MSRP and image enrichment.",
                        shipCatalog?.ships.count ?? 0
                    ),
                completedUnitCount: 1,
                totalUnitCount: 2,
                trackerID: trackerID,
                trackerTitle: trackerTitle,
                displayRange: DisplayProgressRange.finalizing
            )
        )

        return shipCatalog
    }

    private func fetchAccountContext(
        for session: UserSession,
        browser activeBrowser: RSIAccountPageBrowser? = nil,
        progress: @escaping RefreshProgressHandler,
        stepNumber: Int,
        stepCount: Int,
        trackerID: String? = nil,
        trackerTitle: String? = nil
    ) async throws -> AccountRefreshContext {
        progress(
            makeProgress(
                stage: .account,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: AppLocalizer.string("Loading account balances and profile details."),
                completedUnitCount: 0,
                totalUnitCount: 3,
                trackerID: trackerID,
                trackerTitle: trackerTitle
            )
        )

        let activeBrowser = activeBrowser ?? browser
        let accountOverview = try await optionalAccountFetch {
            try await activeBrowser.fetchAccountOverview(
                using: session.cookies,
                accountHandle: session.handle,
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
                    ? AppLocalizer.string("Account balances were unavailable. Continuing with saved account metadata.")
                    : AppLocalizer.format(
                        "Loaded %@ store credit balance and %@.",
                        accountOverview?.storeCreditUSD?.usdString ?? AppLocalizer.string("an unavailable"),
                        accountOverview?.totalSpendUSD?.usdString ?? AppLocalizer.string("an unavailable total spend")
                    ),
                completedUnitCount: 1,
                totalUnitCount: 3,
                trackerID: trackerID,
                trackerTitle: trackerTitle
            )
        )

        let refreshedReferralStats = try await optionalAccountFetch {
            try await activeBrowser.fetchReferralStats(using: session.cookies)
        }
        let didRefreshReferralStats = refreshedReferralStats != nil
        let referralStats = refreshedReferralStats ?? .unavailable
        let currentReferralDetail = referralStats.currentLadderCount.map {
            AppLocalizer.format("%lld current referrals", $0)
        } ?? AppLocalizer.string("unavailable current referrals")
        let legacyReferralDetail = referralStats.hasLegacyLadder
            ? referralStats.legacyLadderCount.map { AppLocalizer.format("%lld legacy referrals", $0) } ?? AppLocalizer.string("unavailable legacy referrals")
            : AppLocalizer.string("no legacy referral ladder")

        progress(
            makeProgress(
                stage: .account,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: AppLocalizer.format("Loaded %@ and %@.", currentReferralDetail, legacyReferralDetail),
                completedUnitCount: 2,
                totalUnitCount: 3,
                trackerID: trackerID,
                trackerTitle: trackerTitle
            )
        )

        progress(
            makeProgress(
                stage: .account,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: AppLocalizer.string("Account overview sync complete."),
                completedUnitCount: 3,
                totalUnitCount: 3,
                trackerID: trackerID,
                trackerTitle: trackerTitle
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

    private func recordRefreshDiagnostics(
        stage: String,
        summary: String,
        detail: String? = nil,
        level: RefreshDiagnosticsStore.Entry.Level = .info
    ) {
        refreshDiagnostics.record(
            stage: stage,
            summary: summary,
            detail: detail,
            level: level
        )
    }

    private func connectionDetail(
        path: String,
        page: Int? = nil,
        pageSize: Int? = nil,
        workerCount: Int? = nil,
        cookies: [SessionCookie],
        transport: String = "URLSession.directHTML",
        extra: [String] = []
    ) -> String {
        var details: [String] = [
            "path=\(path)",
            "transport=\(transport)",
            "cookieCount=\(cookies.count)",
            "cookieNames=\(cookieNamePreview(cookies))",
            "authCookies=\(authCookieSummary(cookies))",
            "cookieDomains=\(cookieDomainSummary(cookies))"
        ]

        if let page {
            details.append("page=\(page)")
        }

        if let pageSize {
            details.append("pageSize=\(pageSize)")
        }

        if let workerCount {
            details.append("workerCount=\(workerCount)")
        }

        details.append(contentsOf: extra)
        return details.joined(separator: ", ")
    }

    private func cookieNamePreview(_ cookies: [SessionCookie]) -> String {
        let names = Array(Set(cookies.map(\.name))).sorted()
        guard !names.isEmpty else {
            return "none"
        }

        let preview = names.prefix(12).joined(separator: ",")
        return names.count > 12 ? "\(preview),..." : preview
    }

    private func cookieDomainSummary(_ cookies: [SessionCookie]) -> String {
        let domains = Array(Set(cookies.map(\.domain))).sorted()
        guard !domains.isEmpty else {
            return "none"
        }

        let preview = domains.prefix(6).joined(separator: ",")
        return domains.count > 6 ? "\(preview),..." : preview
    }

    private func authCookieSummary(_ cookies: [SessionCookie]) -> String {
        let authCookieNames = Set([
            "rsi-token",
            "_rsi_device",
            "rsi-account-auth"
        ])
        let matches = Array(
            Set(
                cookies.compactMap { cookie in
                    let normalizedName = cookie.name.lowercased()
                    return authCookieNames.contains(normalizedName) ? cookie.name : nil
                }
            )
        )
        .sorted()

        return matches.isEmpty ? "none" : matches.joined(separator: ",")
    }

    private func makeProgress(
        stage: RefreshStage,
        stepNumber: Int,
        stepCount: Int,
        detail: String,
        completedUnitCount: Int,
        totalUnitCount: Int?,
        trackerID: String? = nil,
        trackerTitle: String? = nil,
        displayRange: (start: Double, end: Double)? = nil
    ) -> RefreshProgress {
        RefreshProgress(
            stage: stage,
            stepNumber: stepNumber,
            stepCount: stepCount,
            detail: detail,
            completedUnitCount: completedUnitCount,
            totalUnitCount: totalUnitCount,
            trackerID: trackerID,
            trackerTitle: trackerTitle,
            displayStartFraction: displayRange?.start,
            displayEndFraction: displayRange?.end
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

    private enum RefreshItemKind {
        case pledge
        case buybackItem

        func countLabel(_ count: Int) -> String {
            switch self {
            case .pledge:
                return count == 1
                    ? AppLocalizer.format("%lld pledge", count)
                    : AppLocalizer.format("%lld pledges", count)
            case .buybackItem:
                return count == 1
                    ? AppLocalizer.format("%lld buy-back item", count)
                    : AppLocalizer.format("%lld buy-back items", count)
            }
        }
    }

    private func pageDetail(
        for itemKind: RefreshItemKind,
        page: Int,
        totalPages: Int?,
        loadedCount: Int,
        isLoading: Bool
    ) -> String {
        let pageLabel: String
        if let totalPages, totalPages > 0 {
            pageLabel = AppLocalizer.format("page %lld of %lld", page, totalPages)
        } else {
            pageLabel = AppLocalizer.format("page %lld", page)
        }

        let countLabel = itemKind.countLabel(loadedCount)

        if isLoading {
            if loadedCount > 0 {
                return AppLocalizer.format("Loading %@. %@ already synced.", pageLabel, countLabel)
            }

            return AppLocalizer.format("Loading %@.", pageLabel)
        }

        return AppLocalizer.format("Finished %@. %@ synced so far.", pageLabel, countLabel)
    }

    private func parallelPageDetail(
        for itemKind: RefreshItemKind,
        completedPages: Int,
        totalPages: Int,
        loadedCount: Int,
        workerCount: Int
    ) -> String {
        let countLabel = itemKind.countLabel(loadedCount)
        return AppLocalizer.format(
            "Loaded %lld of %lld pages across %lld workers. %@ synced so far.",
            completedPages,
            totalPages,
            workerCount,
            countLabel
        )
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

nonisolated enum LiveHangarRepositoryError: Error, LocalizedError, Equatable {
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

nonisolated enum FleetProjector {
    private static let notForSaleShipNames: Set<String> = [
        "f7a hornet mk ii",
        "dragonfly star kitten edition",
        "mustang omega",
        "mustang omega : amd edition",
        "600i executive edition"
    ]

    static func project(packages: [HangarPackage], shipCatalog: RSIShipCatalog?) -> [FleetShip] {
        packages.flatMap { package in
            let fleetEntries = package.contents.compactMap { item -> (PackageItem, RSIShipCatalog.Ship?)? in
                guard HangarPledgeSummaryParser.shouldRenderContentTitle(item.title) else {
                    return nil
                }

                guard item.category == .ship || item.category == .vehicle else {
                    return nil
                }

                let matchedShip = shipCatalog?.matchShip(named: item.title)

                if matchedShip == nil, isObviousEquipmentItem(item) {
                    return nil
                }

                if matchedShip == nil, !hasShipLikeInsurance(package.insurance) {
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
                    manufacturerLogoURL: matchedShip?.manufacturerLogoURL,
                    role: role(for: item, matchedShip: matchedShip),
                    roleCategories: roleCategories(for: item, matchedShip: matchedShip),
                    msrpUSD: hostedMSRP(for: item, matchedShip: matchedShip),
                    msrpLabel: hostedMSRPLabel(for: item, matchedShip: matchedShip),
                    catalogWarning: catalogWarning(for: item, matchedShip: matchedShip),
                    insurance: package.detailInsuranceText ?? HangarPackage.localizedInsuranceDisplayLabel(from: package.insurance),
                    sourcePackageID: package.id,
                    sourcePackageName: package.title,
                    meltValueUSD: meltValue,
                    canGift: package.canGift,
                    canReclaim: package.canReclaim,
                    imageURL: preferredImageURL(for: item, matchedShip: matchedShip)
                )
            }
        }
    }

    private static func preferredImageURL(for item: PackageItem, matchedShip: RSIShipCatalog.Ship?) -> URL? {
        if item.title.localizedCaseInsensitiveContains("Dragonfly Star Kitten Edition"),
           let itemImageURL = item.imageURL {
            return itemImageURL
        }

        return matchedShip?.imageURL ?? item.imageURL
    }

    private static func manufacturer(for item: PackageItem, matchedShip: RSIShipCatalog.Ship?) -> String {
        if let manufacturer = matchedShip?.manufacturer?.nilIfEmpty {
            return manufacturer
        }

        let candidates = [item.detail, item.title]
        let manufacturers: [(match: String, display: String)] = [
            ("Grey's Market", "Grey's Market"),
            ("GREY", "Grey's Market"),
            ("Aegis", "Aegis Dynamics"),
            ("Anvil", "Anvil Aerospace"),
            ("Aopoa", "Aopoa"),
            ("ARGO", "Argo Astronautics"),
            ("Banu", "Banu"),
            ("Consolidated Outland", "Consolidated Outland"),
            ("Crusader", "Crusader Industries"),
            ("Drake", "Drake Interplanetary"),
            ("Esperia", "Esperia"),
            ("Gatac", "Gatac Manufacture"),
            ("Greycat", "Greycat Industrial"),
            ("Kruger", "Kruger Intergalactic"),
            ("MISC", "MISC"),
            ("Mirai", "Mirai"),
            ("Origin", "Origin Jumpworks"),
            ("RSI", "Roberts Space Industries"),
            ("Tumbril", "Tumbril"),
            ("Vanduul", "Vanduul")
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

    private static func hostedMSRP(for item: PackageItem, matchedShip: RSIShipCatalog.Ship?) -> Decimal? {
        if isKnownNotForSaleShip(item: item, matchedShip: matchedShip) {
            return nil
        }

        return matchedShip?.msrpUSD
    }

    private static func hostedMSRPLabel(for item: PackageItem, matchedShip: RSIShipCatalog.Ship?) -> String? {
        if let hostedLabel = matchedShip?.msrpLabel?.nilIfEmpty {
            return hostedLabel
        }

        if isKnownNotForSaleShip(item: item, matchedShip: matchedShip) {
            return "Not For Sale"
        }

        return nil
    }

    private static func isKnownNotForSaleShip(item: PackageItem, matchedShip: RSIShipCatalog.Ship?) -> Bool {
        let candidateNames = [
            item.title,
            matchedShip?.name,
            UpgradeTitleParser.stripManufacturerPrefix(from: item.title),
            matchedShip.map { UpgradeTitleParser.stripManufacturerPrefix(from: $0.name) }
        ]

        return candidateNames
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase }
            .contains(where: { notForSaleShipNames.contains($0) })
    }

    private static func catalogWarning(for item: PackageItem, matchedShip: RSIShipCatalog.Ship?) -> String? {
        let warningMessage = "Ship info incomplete. Please send the dev a screenshot so it can be patched."

        guard let matchedShip else {
            return warningMessage
        }

        let hasManufacturer = matchedShip.manufacturer?.nilIfEmpty != nil
        let hasRole = matchedShip.roleSummary?.nilIfEmpty != nil
        let hasPricingState = hostedMSRP(for: item, matchedShip: matchedShip) != nil
            || hostedMSRPLabel(for: item, matchedShip: matchedShip) != nil

        return hasManufacturer && hasRole && hasPricingState ? nil : warningMessage
    }

    private static func hasShipLikeInsurance(_ insurance: String) -> Bool {
        let normalized = insurance.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !normalized.isEmpty else {
            return false
        }

        return normalized != "unknown"
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
            "banner",
            "coin",
            "decoration",
            "decor",
            "die",
            "flag",
            "grenade",
            "helmet",
            "knife",
            "magazine",
            "medgun",
            "medpen",
            "multi-tool",
            "multitool",
            "painting",
            "pennant",
            "plush",
            "poster",
            "pistol",
            "rifle",
            "shotgun",
            "smg",
            "sniper",
            "statue",
            "undersuit",
            "weapon",
            "trophy"
        ]

        return equipmentKeywords.contains(where: haystack.contains)
    }
}

private actor ConcurrentPageProgress {
    private static let emissionInterval: TimeInterval = 0.5

    private var completedPages: Int
    private var loadedCount: Int
    private var lastEmissionDate = Date.distantPast

    init(completedPages: Int, loadedCount: Int) {
        self.completedPages = completedPages
        self.loadedCount = loadedCount
    }

    func record(
        completedPages additionalPages: Int,
        loadedCount additionalItems: Int,
        totalPageCount: Int
    ) -> (completedPages: Int, loadedCount: Int, shouldEmit: Bool) {
        completedPages += additionalPages
        loadedCount += additionalItems

        let isComplete = completedPages >= totalPageCount
        let now = Date()
        let shouldEmit = isComplete || now.timeIntervalSince(lastEmissionDate) >= Self.emissionInterval
        if shouldEmit {
            lastEmissionDate = now
        }

        return (completedPages, loadedCount, shouldEmit)
    }
}

private struct RemoteReclaimExecution: Decodable {
    let accessDenied: Bool
    let status: String
    let completedPledgeIDs: [Int]
    let failedPledgeID: Int?
    let failureMessage: String?
    let debugSummary: String?
}

private struct RemoteGiftExecution: Decodable {
    let accessDenied: Bool
    let status: String
    let completedPledgeIDs: [Int]
    let failedPledgeID: Int?
    let failureMessage: String?
    let debugSummary: String?
}

private struct RemoteUpgradeTargetLookup: Decodable {
    let accessDenied: Bool
    let status: String
    let candidates: [RemoteUpgradeTargetCandidate]
    let failureMessage: String?
    let debugSummary: String?
}

private struct RemoteUpgradeTargetCandidate: Decodable {
    let pledgeID: Int
    let title: String

    var domainModel: UpgradeTargetCandidate {
        UpgradeTargetCandidate(
            pledgeID: pledgeID,
            title: title
        )
    }
}

private struct RemoteApplyUpgradeExecution: Decodable {
    let accessDenied: Bool
    let status: String
    let failureMessage: String?
    let debugSummary: String?
}

private struct RemoteCharacterRepairExecution: Decodable {
    let accessDenied: Bool
    let status: String
    let failureMessage: String?
    let debugSummary: String?
}

private struct RemoteAuthorizedDevicesLookup: Decodable {
    let accessDenied: Bool
    let status: String
    let devices: [RemoteAuthorizedDevice]
    let failureMessage: String?
    let debugSummary: String?
}

private struct RemoteAuthorizedDevice: Decodable {
    let id: String
    let name: String
    let type: String?
    let createdAtLabel: String?
    let duration: String?
    let isCurrent: Bool

    var domainModel: AuthorizedDevice {
        AuthorizedDevice(
            id: id,
            name: name,
            type: type,
            createdAtLabel: createdAtLabel,
            duration: duration,
            isCurrent: isCurrent
        )
    }
}

private struct RemoteAuthorizedDeviceRemoval: Decodable {
    let accessDenied: Bool
    let status: String
    let failureMessage: String?
    let debugSummary: String?
}

private struct RemoteAuthorizedDeviceBulkRemoval: Decodable {
    let accessDenied: Bool
    let status: String
    let completedDeviceIDs: [String]
    let failedDeviceID: String?
    let failureMessage: String?
    let debugSummary: String?
}

private nonisolated final class RSIAccountHTTPPageClient: @unchecked Sendable {
    private var cookies: [SessionCookie]
    private let session: URLSession
    private let timeoutSeconds: TimeInterval = 25

    var currentCookies: [SessionCookie] {
        cookies
    }

    init(cookies: [SessionCookie]) {
        self.cookies = cookies

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = max(timeoutSeconds * 2, 45)
        session = URLSession(configuration: configuration)
    }

    func fetchPledgePage(page: Int, pageSize: Int) async throws -> RemotePledgePage {
        let payload = try await fetchHTML(path: "/en/account/pledges", page: page, pageSize: pageSize)
        return try RSIAccountHTMLParser.parsePledgePage(
            html: payload.html,
            pageURL: payload.finalURL,
            requestedURL: payload.requestedURL,
            statusCode: payload.statusCode,
            cookieCount: cookies.count
        )
    }

    func fetchBuybackPage(page: Int, pageSize: Int) async throws -> RemoteBuybackPage {
        let payload = try await fetchHTML(path: "/en/account/buy-back-pledges", page: page, pageSize: pageSize)
        return try RSIAccountHTMLParser.parseBuybackPage(
            html: payload.html,
            pageURL: payload.finalURL,
            requestedURL: payload.requestedURL,
            statusCode: payload.statusCode,
            cookieCount: cookies.count
        )
    }

    static func loadPledgeChunk(
        using cookies: [SessionCookie],
        pages: [Int],
        pageSize: Int,
        onPageLoaded: @escaping @Sendable (_ page: Int, _ itemCount: Int) async -> Void
    ) async throws -> [(Int, RemotePledgePage)] {
        guard !pages.isEmpty else {
            return []
        }

        let client = RSIAccountHTTPPageClient(cookies: cookies)
        var results: [(Int, RemotePledgePage)] = []
        var previousSignature: String?

        for page in pages {
            let result = try await client.fetchPledgePage(page: page, pageSize: pageSize)

            if result.accessDenied {
                throw LiveHangarRepositoryError.sessionExpired
            }

            if result.items.isEmpty {
                throw LiveHangarRepositoryError.unexpectedMarkup(
                    "RSI returned an empty hangar page for page \(page) during direct HTTP sync."
                )
            }

            if let previousSignature,
               previousSignature == result.pageSignature
            {
                throw LiveHangarRepositoryError.unexpectedMarkup(
                    "RSI repeated the same hangar page content while loading page \(page) over direct HTTP."
                )
            }

            results.append((page, result))
            previousSignature = result.pageSignature
            await onPageLoaded(page, result.items.count)
        }

        return results
    }

    static func loadBuybackChunk(
        using cookies: [SessionCookie],
        pages: [Int],
        pageSize: Int,
        onPageLoaded: @escaping @Sendable (_ page: Int, _ itemCount: Int) async -> Void
    ) async throws -> [(Int, RemoteBuybackPage)] {
        guard !pages.isEmpty else {
            return []
        }

        let client = RSIAccountHTTPPageClient(cookies: cookies)
        var results: [(Int, RemoteBuybackPage)] = []
        var previousSignature: String?

        for page in pages {
            let result = try await client.fetchBuybackPage(page: page, pageSize: pageSize)

            if result.accessDenied {
                throw LiveHangarRepositoryError.sessionExpired
            }

            if result.items.isEmpty {
                throw LiveHangarRepositoryError.unexpectedMarkup(
                    "RSI returned an empty buy-back page for page \(page) during direct HTTP sync."
                )
            }

            if let previousSignature,
               previousSignature == result.pageSignature
            {
                throw LiveHangarRepositoryError.unexpectedMarkup(
                    "RSI repeated the same buy-back page content while loading page \(page) over direct HTTP."
                )
            }

            results.append((page, result))
            previousSignature = result.pageSignature
            await onPageLoaded(page, result.items.count)
        }

        return results
    }

    private func fetchHTML(path: String, page: Int, pageSize: Int) async throws -> HTTPPagePayload {
        let requestedURL = try pageURL(path: path, page: page, pageSize: pageSize)
        var request = URLRequest(url: requestedURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://robertsspaceindustries.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        if let cookieHeader = cookieHeader(), !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        if let rsiToken = cookieValue(named: "Rsi-Token") ?? cookieValue(named: "rsi-token") {
            request.setValue(rsiToken, forHTTPHeaderField: "x-rsi-token")
        }

        if let rsiDevice = cookieValue(named: "_rsi_device") {
            request.setValue(rsiDevice, forHTTPHeaderField: "x-rsi-device")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LiveHangarRepositoryError.unexpectedMarkup(
                directHTTPDiagnostics(
                    summary: "Direct RSI HTTP page load failed.",
                    requestedURL: requestedURL,
                    response: nil,
                    data: nil,
                    underlyingError: error
                )
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveHangarRepositoryError.unexpectedMarkup(
                directHTTPDiagnostics(
                    summary: "RSI returned a non-HTTP response for the direct page request.",
                    requestedURL: requestedURL,
                    response: response,
                    data: data,
                    underlyingError: nil
                )
            )
        }

        mergeCookies(from: httpResponse, url: requestedURL)

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw LiveHangarRepositoryError.unexpectedMarkup(
                directHTTPDiagnostics(
                    summary: "RSI returned HTTP \(httpResponse.statusCode) for the direct page request.",
                    requestedURL: requestedURL,
                    response: httpResponse,
                    data: data,
                    underlyingError: nil
                )
            )
        }

        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveHangarRepositoryError.unexpectedMarkup(
                directHTTPDiagnostics(
                    summary: "RSI returned an empty or non-text page payload.",
                    requestedURL: requestedURL,
                    response: httpResponse,
                    data: data,
                    underlyingError: nil
                )
            )
        }

        return HTTPPagePayload(
            html: html,
            requestedURL: requestedURL,
            finalURL: httpResponse.url ?? requestedURL,
            statusCode: httpResponse.statusCode
        )
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
            throw LiveHangarRepositoryError.unexpectedMarkup("Unable to build the RSI direct page URL.")
        }

        return url
    }

    private func cookieHeader() -> String? {
        let now = Date()
        return cookies
            .filter { cookie in
                guard let expiresAt = cookie.expiresAt else {
                    return true
                }

                return expiresAt > now
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
            .nilIfEmpty
    }

    private func cookieValue(named name: String) -> String? {
        cookies.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.value.nilIfEmpty
    }

    private func mergeCookies(from response: HTTPURLResponse, url: URL) {
        var headerFields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else {
                continue
            }

            headerFields[key] = String(describing: value)
        }

        let receivedCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url).map(SessionCookie.init)
        guard !receivedCookies.isEmpty else {
            return
        }

        var merged = Dictionary(uniqueKeysWithValues: cookies.map { (cookieStorageKey($0), $0) })
        for cookie in receivedCookies {
            merged[cookieStorageKey(cookie)] = cookie
        }

        cookies = Array(merged.values)
    }

    private func cookieStorageKey(_ cookie: SessionCookie) -> String {
        [
            cookie.name.lowercased(),
            cookie.domain.lowercased(),
            cookie.path
        ].joined(separator: "|")
    }

    private func directHTTPDiagnostics(
        summary: String,
        requestedURL: URL,
        response: URLResponse?,
        data: Data?,
        underlyingError: Error?
    ) -> String {
        let httpResponse = response as? HTTPURLResponse
        var lines = [
            summary,
            "",
            "Direct HTTP Diagnostics",
            "transport=URLSession.directHTML",
            "requestedURL=\(requestedURL.absoluteString)",
            "finalURL=\(response?.url?.absoluteString ?? "unknown")",
            "timeoutSeconds=\(Int(timeoutSeconds))",
            "httpStatus=\(httpResponse.map { String($0.statusCode) } ?? "unknown")",
            "mimeType=\(response?.mimeType ?? "unknown")",
            "expectedContentLength=\(response?.expectedContentLength ?? -1)",
            "responseBytes=\(data?.count ?? 0)",
            "cookieCount=\(cookies.count)",
            "cookieNames=\(cookieNamesSummary())",
            "authCookies=\(authCookieSummary())"
        ]

        if let underlyingError {
            let nsError = underlyingError as NSError
            lines.append("errorType=\(String(reflecting: type(of: underlyingError)))")
            lines.append("errorDomain=\(nsError.domain)")
            lines.append("errorCode=\(nsError.code)")
            lines.append("errorDescription=\(underlyingError.localizedDescription)")
        }

        if let data,
           let body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            lines.append("bodyPreview=\(RSIAccountHTMLParser.previewText(from: body, limit: 700))")
        }

        return lines.joined(separator: "\n")
    }

    private func cookieNamesSummary() -> String {
        let names = Array(Set(cookies.map(\.name))).sorted()
        guard !names.isEmpty else {
            return "none"
        }

        let prefix = names.prefix(12).joined(separator: ",")
        return names.count > 12 ? "\(prefix),..." : prefix
    }

    private func authCookieSummary() -> String {
        let authNames = [
            "Rsi-Token",
            "_rsi_device",
            "Rsi-Account-Auth",
            "Rsi-ShipUpgrades-Context"
        ]
        let available = authNames.filter { name in
            cookieValue(named: name) != nil
        }

        return available.isEmpty ? "none" : available.joined(separator: ",")
    }

    private nonisolated struct HTTPPagePayload {
        let html: String
        let requestedURL: URL
        let finalURL: URL
        let statusCode: Int
    }
}

private nonisolated enum RSIAccountHTMLParser {
    static func parsePledgePage(
        html: String,
        pageURL: URL,
        requestedURL: URL,
        statusCode: Int,
        cookieCount: Int
    ) throws -> RemotePledgePage {
        let title = firstText(in: html, selectors: ["title"])
        let accessDenied = isAccessDenied(html: html, title: title)
        let currentPage = currentPageNumber(from: pageURL)
        let totalPages = totalPages(in: html)
        let hasNextPage = totalPages.map { $0 > currentPage }
        let listHTML = firstElement(in: html, selector: ".list-items")?.html ?? html
        let rows = elements(in: listHTML, tag: nil, className: "row")

        guard accessDenied || !rows.isEmpty else {
            throw LiveHangarRepositoryError.unexpectedMarkup(
                parserDiagnostics(
                    summary: "Direct RSI hangar page HTML did not contain pledge rows.",
                    html: html,
                    requestedURL: requestedURL,
                    finalURL: pageURL,
                    statusCode: statusCode,
                    cookieCount: cookieCount,
                    extra: [
                        "parser=pledges",
                        "rowCount=0"
                    ]
                )
            )
        }

        return RemotePledgePage(
            accessDenied: accessDenied,
            title: title,
            totalPages: totalPages,
            hasNextPage: hasNextPage,
            items: rows.map { row in
                parsePledgeRow(row, pageURL: pageURL)
            }
        )
    }

    static func parseBuybackPage(
        html: String,
        pageURL: URL,
        requestedURL: URL,
        statusCode: Int,
        cookieCount: Int
    ) throws -> RemoteBuybackPage {
        let title = firstText(in: html, selectors: ["title"])
        let accessDenied = isAccessDenied(html: html, title: title)
        let currentPage = currentPageNumber(from: pageURL)
        let totalPages = totalPages(in: html)
        let hasNextPage = totalPages.map { $0 > currentPage }
        let articles = elements(in: html, tag: "article", className: "pledge")
        let isEmptyBuybackListing = currentPage == 1
            && articles.isEmpty
            && isRecognizedBuybackPage(html: html, title: title)
            && !containsBuybackActionLink(in: html)

        guard accessDenied || !articles.isEmpty || currentPage > 1 || isEmptyBuybackListing else {
            throw LiveHangarRepositoryError.unexpectedMarkup(
                parserDiagnostics(
                    summary: "Direct RSI buy-back page HTML did not contain buy-back pledge articles.",
                    html: html,
                    requestedURL: requestedURL,
                    finalURL: pageURL,
                    statusCode: statusCode,
                    cookieCount: cookieCount,
                    extra: [
                        "parser=buyback",
                        "articleCount=0"
                    ]
                )
            )
        }

        return RemoteBuybackPage(
            accessDenied: accessDenied,
            title: title,
            totalPages: totalPages,
            hasNextPage: hasNextPage,
            items: articles.map { article in
                parseBuybackArticle(article, pageURL: pageURL)
            }
        )
    }

    private static func isRecognizedBuybackPage(html: String, title: String) -> Bool {
        let normalizedTitle = normalizedText(title).lowercased()
        if normalizedTitle.contains("buy back pledges") || normalizedTitle.contains("buy-back pledges") {
            return true
        }

        let normalizedBody = normalizedText(textContent(html)).lowercased()
        return normalizedBody.contains("pledge buy back system")
            || normalizedBody.contains("reacquire your converted pledges")
            || normalizedBody.contains("buy back pledges")
            || normalizedBody.contains("buy-back pledges")
    }

    private static func containsBuybackActionLink(in html: String) -> Bool {
        html.range(of: "/pledge/buyback/", options: [.caseInsensitive]) != nil
            || html.range(of: "pledge/buyback/", options: [.caseInsensitive]) != nil
    }

    static func previewText(from html: String, limit: Int) -> String {
        let text = normalizedText(textContent(html))
        guard text.count > limit else {
            return text.nilIfEmpty ?? "none"
        }

        return "\(text.prefix(limit))..."
    }

    private static func parsePledgeRow(_ row: HTMLElementFragment, pageURL: URL) -> RemotePledge {
        let rawStatusValue = firstValue(in: row.html, selectors: [".js-pledge-status"])
        let titles = elements(in: row.html, tag: nil, className: "title")
            .map { textContent($0.html) }
            .map(normalizedText)
            .filter { !$0.isEmpty }
        let remoteItems = contentItemFragments(in: row.html).compactMap { item -> RemotePledgeItem? in
            let title = cleanContentTitle(
                firstText(in: item.html, selectors: [".title", ".name", "h1", "h2", "h3"])
            )
            let normalizedTitle = normalizedText(title).localizedLowercase
            guard !normalizedTitle.isEmpty,
                  !shouldSkipContentItemTitle(normalizedTitle) else {
                return nil
            }

            return RemotePledgeItem(
                title: title,
                kind: firstText(in: item.html, selectors: [".kind", ".type", ".category"]),
                detail: firstText(in: item.html, selectors: [".liner", ".subtitle"]),
                imageURL: firstImageURL(in: item.html, baseURL: pageURL)
            )
        }

        return RemotePledge(
            id: intValue(firstValue(in: row.html, selectors: [".js-pledge-id"])),
            title: firstValue(in: row.html, selectors: [".js-pledge-name"])
                .nilIfEmpty ?? firstText(in: row.html, selectors: ["h1", "h2", ".title"]),
            statusText: normalizedText(rawStatusValue)
                .nilIfEmpty ?? firstText(in: row.html, selectors: [".availability", ".status"]),
            isUpgradedStatusFlag: isUpgradedStatusFlag(in: row.html, rawStatusValue: rawStatusValue),
            dateText: firstText(in: row.html, selectors: [".date-col", ".date"]),
            valueText: firstValue(in: row.html, selectors: [".js-pledge-value"])
                .nilIfEmpty ?? firstText(in: row.html, selectors: [".value", ".price"]),
            containsText: firstText(in: row.html, selectors: [".items-col", ".contains"]),
            thumbnailImageURL: firstImageURL(
                in: firstElement(in: row.html, selector: ".image-col")?.html ?? row.html,
                baseURL: pageURL
            ),
            alsoContains: titles,
            canGift: containsClass("js-gift", in: row.html),
            canReclaim: containsClass("js-reclaim", in: row.html),
            canUpgrade: containsClass("js-apply-upgrade", in: row.html),
            upgradeMetadata: parseUpgradeMetadata(in: row.html),
            items: remoteItems,
            sourcePage: nil,
            sourcePageIndex: nil
        )
    }

    private static func parseBuybackArticle(_ article: HTMLElementFragment, pageURL: URL) -> RemoteBuybackPledge {
        let button = firstElement(in: article.html, selector: ".holosmallbtn")
            ?? firstElementWithAttribute(in: article.html, tag: "a", attribute: "href", containing: "/pledge/buyback/")
        let href = button.flatMap { attribute("href", in: $0.openingTag) } ?? ""
        let hrefID = href.split(separator: "/").last.flatMap { Int($0) }
        let dataID = button.flatMap { intValue(attribute("data-pledgeid", in: $0.openingTag)) }
        let fromShipID = button.flatMap { intValue(attribute("data-fromshipid", in: $0.openingTag)) }
        let toShipID = button.flatMap { intValue(attribute("data-toshipid", in: $0.openingTag)) }
        let toSkuID = button.flatMap { intValue(attribute("data-toskuid", in: $0.openingTag)) }
        let definitionLabels = elements(in: article.html, tag: "dt", className: nil)
            .map { normalizedText(textContent($0.html)) }
            .filter { !$0.isEmpty }
        let definitionValues = elements(in: article.html, tag: "dd", className: nil)
            .map { normalizedText(textContent($0.html)) }
            .filter { !$0.isEmpty }
        let informationHTML = firstElement(in: article.html, selector: ".information")?.html ?? article.html
        let articleText = normalizedText(textContent(article.html))
        let dateText = definitionValue(
            in: definitionValues,
            labels: definitionLabels,
            matching: ["date", "created", "added", "modified", "reclaim", "recovered"]
        ) ?? definitionValues.first(where: looksLikeRSIDateText)
            ?? firstRSIDateText(in: articleText)
            ?? ""
        let containsText = definitionValue(
            in: definitionValues,
            labels: definitionLabels,
            matching: ["contains", "includes", "items"]
        ) ?? value(at: 2, in: definitionValues)
            ?? plainTextValue(
                in: articleText,
                after: ["Contained"],
                before: ["Buy Back", "Not available", "Why can't", "This pledge", "Account FAQ"]
            )
        let resolvedContainsText = containsText
            ?? firstText(in: article.html, selectors: [".information .contains", ".contains"])
        let titleText = firstText(in: informationHTML, selectors: ["h1", "h2"])
            .nilIfEmpty ?? firstText(in: article.html, selectors: ["h1", "h2"])
        let valueText = firstText(in: article.html, selectors: [".price", ".value", ".cost"])
        let imageURL = firstImageURL(in: article.html, baseURL: pageURL)
        let upgradeContext: BuybackUpgradeContext?

        if let fromShipID, fromShipID > 0,
           let toShipID, toShipID > 0,
           let toSkuID, toSkuID > 0
        {
            upgradeContext = BuybackUpgradeContext(
                fromShipID: fromShipID,
                toShipID: toShipID,
                toSkuID: toSkuID
            )
        } else {
            upgradeContext = nil
        }

        return RemoteBuybackPledge(
            id: dataID ?? hrefID,
            title: titleText,
            dateText: dateText,
            containsText: resolvedContainsText,
            valueText: valueText,
            imageURL: imageURL,
            upgradeContext: upgradeContext,
            sourceRawInfo: BuybackPledgeRawInfo(
                buttonHref: href.nilIfEmpty,
                buttonDataPledgeID: dataID,
                buttonFromShipID: fromShipID,
                buttonToShipID: toShipID,
                buttonToSkuID: toSkuID,
                titleText: titleText,
                dateText: dateText,
                containsText: resolvedContainsText,
                valueText: valueText,
                imageURL: imageURL,
                definitionLabels: definitionLabels,
                definitionValues: definitionValues,
                articleText: String(articleText.prefix(4_000))
            )
        )
    }

    private static func definitionValue(
        in values: [String],
        labels: [String],
        matching labelFragments: [String]
    ) -> String? {
        for (index, label) in labels.enumerated() {
            let normalizedLabel = label.localizedLowercase
            guard labelFragments.contains(where: { normalizedLabel.contains($0) }),
                  let value = value(at: index, in: values),
                  !value.isEmpty else {
                continue
            }

            return value
        }

        return nil
    }

    private static func looksLikeRSIDateText(_ value: String) -> Bool {
        firstRSIDateText(in: value) != nil
    }

    private static func firstRSIDateText(in value: String) -> String? {
        let normalized = normalizedText(value)
        guard !normalized.isEmpty else {
            return nil
        }

        let patterns = [
            #"(?i)\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{4}\b"#,
            #"\b\d{4}-\d{1,2}-\d{1,2}\b"#
        ]

        for pattern in patterns {
            guard let range = normalized.range(of: pattern, options: .regularExpression) else {
                continue
            }

            return String(normalized[range])
        }

        return nil
    }

    private static func plainTextValue(in text: String, after labels: [String], before stopLabels: [String]) -> String? {
        let normalized = normalizedText(text)
        guard !normalized.isEmpty else {
            return nil
        }

        let labelPattern = labels
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let stopPattern = stopLabels
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let pattern = "(?i)\\b(?:\(labelPattern))\\b\\s+(.+?)(?=\\s+\\b(?:\(stopPattern))\\b|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(normalized.startIndex..., in: normalized)
        guard let match = regex.firstMatch(in: normalized, range: range),
              let captureRange = Range(match.range(at: 1), in: normalized) else {
            return nil
        }

        let value = normalized[captureRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value)
    }

    private static func contentItemFragments(in html: String) -> [HTMLElementFragment] {
        var seen = Set<String>()
        var results: [HTMLElementFragment] = []

        for className in ["with-images", "without-images", "items-col", "contains"] {
            for container in elements(in: html, tag: nil, className: className) {
                for item in elements(in: container.html, tag: nil, className: "item") {
                    guard seen.insert(item.html).inserted else {
                        continue
                    }

                    results.append(item)
                }
            }
        }

        return results
    }

    private static func parseUpgradeMetadata(in html: String) -> RemotePledgeUpgradeMetadata? {
        guard let rawValue = firstValue(in: html, selectors: [".js-upgrade-data"]).nilIfEmpty,
              let data = rawValue.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return RemotePledgeUpgradeMetadata(
            id: intValue(json["id"]),
            name: stringValue(json["name"])?.nilIfEmpty,
            upgradeType: stringValue(json["upgrade_type"])?.nilIfEmpty,
            matchItems: upgradeMatchItems(json["match_items"]),
            targetItems: upgradeMatchItems(json["target_items"])
        )
    }

    private static func upgradeMatchItems(_ value: Any?) -> [RemotePledgeUpgradeMatchItem] {
        guard let items = value as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let name = stringValue(item["name"])?.nilIfEmpty else {
                return nil
            }

            return RemotePledgeUpgradeMatchItem(
                id: intValue(item["id"]),
                name: name
            )
        }
    }

    private static func isUpgradedStatusFlag(in html: String, rawStatusValue: String) -> Bool {
        let statusText = [
            rawStatusValue,
            firstText(in: html, selectors: [".availability", ".status"]),
            textContent(html)
        ]
            .map(normalizedText)
            .joined(separator: " ")

        return statusText.range(
            of: #"(^|\s)upgraded(\s|$)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func shouldSkipContentItemTitle(_ normalizedTitle: String) -> Bool {
        if normalizedTitle == "standard upgrade" || normalizedTitle == "and" {
            return true
        }

        return normalizedTitle.range(
            of: #"^(?:and\s+)?\d+\s+(?:items?|ships?|vehicles?)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func cleanContentTitle(_ value: String) -> String {
        normalizedText(value)
            .replacingOccurrences(
                of: #"\s+(?:and\s+)?\d+\s+(?:items?|ships?|vehicles?)$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func value(at index: Int, in values: [String]) -> String? {
        values.indices.contains(index) ? values[index] : nil
    }

    private static func isAccessDenied(html: String, title: String) -> Bool {
        let bodyText = textContent(html)
        return title.localizedCaseInsensitiveContains("access denied")
            || bodyText.localizedCaseInsensitiveContains("Access denied")
    }

    private static func currentPageNumber(from url: URL) -> Int {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "page" }?
            .value
            .flatMap(Int.init) ?? 1
    }

    private static func totalPages(in html: String) -> Int? {
        var pageNumbers: [Int] = []
        pageNumbers.append(contentsOf: captureIntMatches(in: html, pattern: #"page=(\d+)"#))
        pageNumbers.append(contentsOf: captureIntMatches(in: html, pattern: #"data-page\s*=\s*['"](\d+)['"]"#))
        return pageNumbers.max()
    }

    private static func firstText(in html: String, selectors: [String]) -> String {
        for selector in selectors {
            guard let element = firstElement(in: html, selector: selector) else {
                continue
            }

            let value = normalizedText(textContent(element.html))
            if !value.isEmpty {
                return value
            }
        }

        return ""
    }

    private static func firstValue(in html: String, selectors: [String]) -> String {
        for selector in selectors {
            guard let element = firstElement(in: html, selector: selector) else {
                continue
            }

            for attributeName in ["value", "content", "data-value"] {
                if let value = attribute(attributeName, in: element.openingTag)?.nilIfEmpty {
                    return value
                }
            }

            let text = normalizedText(textContent(element.html))
            if !text.isEmpty {
                return text
            }
        }

        return ""
    }

    private static func firstImageURL(in html: String, baseURL: URL) -> String? {
        for image in elements(in: html, tag: "img", className: nil) {
            let candidates = [
                attribute("src", in: image.openingTag),
                attribute("data-src", in: image.openingTag),
                attribute("data-original", in: image.openingTag),
                attribute("data-lazy", in: image.openingTag),
                attribute("srcset", in: image.openingTag)?.components(separatedBy: ",").first?.components(separatedBy: .whitespaces).first
            ]

            for candidate in candidates.compactMap({ $0?.nilIfEmpty }) {
                if let url = normalizedURL(candidate, baseURL: baseURL) {
                    return url.absoluteString
                }
            }
        }

        for openingTag in openingTags(in: html) {
            guard let style = attribute("style", in: openingTag),
                  style.localizedCaseInsensitiveContains("background-image"),
                  let rawURL = firstCapture(in: style, pattern: #"url\((['"]?)(.*?)\1\)"#, group: 2),
                  let url = normalizedURL(rawURL, baseURL: baseURL) else {
                continue
            }

            return url.absoluteString
        }

        return nil
    }

    private static func firstElement(in html: String, selector: String) -> HTMLElementFragment? {
        let parts = selector
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            return nil
        }

        var scopes = [html]
        var latest: [HTMLElementFragment] = []

        for part in parts {
            latest = scopes.flatMap { scope in
                elements(in: scope, simpleSelector: part)
            }
            guard !latest.isEmpty else {
                return nil
            }

            scopes = latest.map(\.html)
        }

        return latest.first
    }

    private static func firstElementWithAttribute(
        in html: String,
        tag: String,
        attribute attributeName: String,
        containing value: String
    ) -> HTMLElementFragment? {
        elements(in: html, tag: tag, className: nil).first { element in
            attribute(attributeName, in: element.openingTag)?.contains(value) == true
        }
    }

    private static func elements(in html: String, simpleSelector: String) -> [HTMLElementFragment] {
        if simpleSelector.hasPrefix(".") {
            return elements(in: html, tag: nil, className: String(simpleSelector.dropFirst()))
        }

        return elements(in: html, tag: simpleSelector, className: nil)
    }

    private static func elements(in html: String, tag tagFilter: String?, className: String?) -> [HTMLElementFragment] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<([A-Za-z][A-Za-z0-9:-]*)(?:\s[^<>]*?)?>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var fragments: [HTMLElementFragment] = []

        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: html),
                  let tagRange = Range(match.range(at: 1), in: html) else {
                continue
            }

            let openingTag = String(html[fullRange])
            let tagName = String(html[tagRange]).lowercased()

            if let tagFilter,
               tagName != tagFilter.lowercased()
            {
                continue
            }

            if let className,
               !openingTagHasClass(className, openingTag: openingTag)
            {
                continue
            }

            let endIndex = endIndexForElement(
                in: html,
                tagName: tagName,
                openingRange: fullRange,
                openingTag: openingTag
            )
            fragments.append(
                HTMLElementFragment(
                    html: String(html[fullRange.lowerBound ..< endIndex]),
                    openingTag: openingTag
                )
            )
        }

        return fragments
    }

    private static func openingTags(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<[A-Za-z][A-Za-z0-9:-]*(?:\s[^<>]*?)?>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            Range(match.range, in: html).map { String(html[$0]) }
        }
    }

    private static func endIndexForElement(
        in html: String,
        tagName: String,
        openingRange: Range<String.Index>,
        openingTag: String
    ) -> String.Index {
        if isVoidTag(tagName) || openingTag.hasSuffix("/>") {
            return openingRange.upperBound
        }

        let escapedTag = NSRegularExpression.escapedPattern(for: tagName)
        guard let regex = try? NSRegularExpression(
            pattern: #"</?\#(escapedTag)\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else {
            return openingRange.upperBound
        }

        let searchRange = NSRange(openingRange.upperBound..., in: html)
        var depth = 1

        for match in regex.matches(in: html, range: searchRange) {
            guard let range = Range(match.range, in: html) else {
                continue
            }

            let token = String(html[range])
            if token.hasPrefix("</") {
                depth -= 1
                if depth == 0 {
                    return range.upperBound
                }
            } else if !token.hasSuffix("/>") && !isVoidTag(tagName) {
                depth += 1
            }
        }

        return openingRange.upperBound
    }

    private static func isVoidTag(_ tagName: String) -> Bool {
        ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
            .contains(tagName.lowercased())
    }

    private static func openingTagHasClass(_ className: String, openingTag: String) -> Bool {
        guard let classAttribute = attribute("class", in: openingTag) else {
            return false
        }

        return classAttribute
            .split(whereSeparator: \.isWhitespace)
            .contains { $0.caseInsensitiveCompare(className) == .orderedSame }
    }

    private static func containsClass(_ className: String, in html: String) -> Bool {
        !elements(in: html, tag: nil, className: className).isEmpty
    }

    private static func attribute(_ name: String, in openingTag: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(
            pattern: #"\b\#(escapedName)\s*=\s*(['"])(.*?)\1"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let range = NSRange(openingTag.startIndex..., in: openingTag)
        guard let match = regex.firstMatch(in: openingTag, range: range),
              let valueRange = Range(match.range(at: 2), in: openingTag) else {
            return nil
        }

        return decodeHTMLEntities(String(openingTag[valueRange]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func textContent(_ html: String) -> String {
        var text = html
        text = replacingMatches(in: text, pattern: #"(?is)<script\b[^>]*>.*?</script>"#, with: " ")
        text = replacingMatches(in: text, pattern: #"(?is)<style\b[^>]*>.*?</style>"#, with: " ")
        text = replacingMatches(in: text, pattern: #"(?is)<!--.*?-->"#, with: " ")
        text = replacingMatches(in: text, pattern: #"(?i)<br\s*/?>"#, with: "\n")
        text = replacingMatches(in: text, pattern: #"(?i)</(?:p|div|li|dd|dt|h1|h2|h3|tr)>"#, with: "\n")
        text = replacingMatches(in: text, pattern: #"(?is)<[^>]+>"#, with: " ")
        return decodeHTMLEntities(text)
    }

    private static func normalizedText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")

        guard let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#) else {
            return result
        }

        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let valueRange = Range(match.range(at: 1), in: result) else {
                continue
            }

            let rawValue = String(result[valueRange])
            let scalarValue: UInt32?
            if rawValue.lowercased().hasPrefix("x") {
                scalarValue = UInt32(rawValue.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(rawValue, radix: 10)
            }

            guard let scalarValue,
                  let scalar = UnicodeScalar(scalarValue) else {
                continue
            }

            result.replaceSubrange(fullRange, with: String(Character(scalar)))
        }

        return result
    }

    private static func normalizedURL(_ rawValue: String, baseURL: URL) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix("//") {
            return URL(string: "https:\(trimmed)")
        }

        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    private static func parserDiagnostics(
        summary: String,
        html: String,
        requestedURL: URL,
        finalURL: URL,
        statusCode: Int,
        cookieCount: Int,
        extra: [String]
    ) -> String {
        ([
            summary,
            "",
            "Direct HTML Parser Diagnostics",
            "transport=URLSession.directHTML",
            "requestedURL=\(requestedURL.absoluteString)",
            "finalURL=\(finalURL.absoluteString)",
            "httpStatus=\(statusCode)",
            "cookieCount=\(cookieCount)",
            "title=\(firstText(in: html, selectors: ["title"]).nilIfEmpty ?? "none")",
            "htmlLength=\(html.count)",
            "bodyPreview=\(previewText(from: html, limit: 700))"
        ] + extra).joined(separator: "\n")
    }

    private static func captureIntMatches(in text: String, pattern: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else {
                return nil
            }

            return Int(text[range])
        }
    }

    private static func firstCapture(in text: String, pattern: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > group,
              let captureRange = Range(match.range(at: group), in: text) else {
            return nil
        }

        return String(text[captureRange])
    }

    private static func replacingMatches(in text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: replacement
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }

        if let value = value as? Double, value.isFinite {
            return Int(value)
        }

        if let value = stringValue(value) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let value?:
            return String(describing: value)
        case nil:
            return nil
        }
    }

    private struct HTMLElementFragment {
        let html: String
        let openingTag: String
    }
}

@MainActor
final class RSIAccountPageBrowser: NSObject, WKNavigationDelegate {
    private static let limitedShipCartLogMessageName = "limitedShipCartLog"

    private let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadTimeoutTask: Task<Void, Never>?
    private var limitedShipCartLogBridge: LimitedShipCartLogBridge?
    private var activeLoadURL: URL?
    private var lastNavigationEvents: [String] = []
    private var lastNavigationFailureDescription: String?
    private var lastNavigationResponseSummary: String?
    private let loadTimeoutNanoseconds: UInt64 = 30_000_000_000
    private let maximumNavigationEventCount = 10

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    fileprivate func extractPledges(
        using cookies: [SessionCookie],
        page: Int,
        pageSize: Int
    ) async throws -> RemotePledgePage {
        let url = try pageURL(path: "/en/account/pledges", page: page, pageSize: pageSize)
        try await prepareWebView(with: cookies)
        try await load(url: url)
        return try await evaluate(script: Self.pledgesExtractionScript, as: RemotePledgePage.self)
    }

    fileprivate func extractBuybackPledges(
        using cookies: [SessionCookie],
        page: Int,
        pageSize: Int
    ) async throws -> RemoteBuybackPage {
        let url = try pageURL(path: "/en/account/buy-back-pledges", page: page, pageSize: pageSize)
        try await prepareWebView(with: cookies)
        try await load(url: url)
        return try await evaluate(script: Self.buybackExtractionScript, as: RemoteBuybackPage.self)
    }

    fileprivate func fetchHangarLogPage(
        using cookies: [SessionCookie],
        page: Int,
        maxEntries: Int,
        knownRawTexts: [String] = []
    ) async throws -> RemoteHangarLogPage {
        let url = try storefrontURL(path: "/en/account/pledges")
        try await prepareWebView(with: cookies)
        try await ensureLoaded(url: url)
        return try await evaluate(
            script: Self.hangarLogExtractionScript,
            arguments: [
                "page": page,
                "maxEntries": maxEntries,
                "knownRawTexts": knownRawTexts
            ],
            as: RemoteHangarLogPage.self
        )
    }

    fileprivate func reclaimPledges(
        using cookies: [SessionCookie],
        pledgeIDs: [Int],
        password: String
    ) async throws -> MeltPackagesResult {
        let url = try storefrontURL(path: "/en/account/pledges")
        try await prepareWebView(with: cookies)
        try await load(url: url)

        let result = try await evaluate(
            script: Self.reclaimPledgesScript,
            arguments: [
                "pledgeIDs": pledgeIDs,
                "currentPassword": password
            ],
            as: RemoteReclaimExecution.self
        )

        if result.accessDenied {
            throw LiveHangarRepositoryError.sessionExpired
        }

        let updatedCookies = await currentRSICookies()
        let hasCompletedEveryRequestedPledge = result.completedPledgeIDs.count == pledgeIDs.count
        let shouldTreatAsSuccess = result.status == "ok"
            && result.failedPledgeID == nil
            && hasCompletedEveryRequestedPledge

        let failureMessage: String?
        if shouldTreatAsSuccess {
            failureMessage = nil
        } else {
            failureMessage = [result.failureMessage, result.debugSummary]
                .compactMap { value in
                    value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                }
                .joined(separator: "\n\n")
                .nilIfEmpty
        }

        return MeltPackagesResult(
            requestedPledgeIDs: pledgeIDs,
            completedPledgeIDs: result.completedPledgeIDs,
            failedPledgeID: result.failedPledgeID,
            failureMessage: failureMessage,
            updatedCookies: updatedCookies
        )
    }

    fileprivate func giftPledges(
        using cookies: [SessionCookie],
        pledgeIDs: [Int],
        password: String,
        recipientEmail: String,
        recipientName: String
    ) async throws -> GiftPackagesResult {
        let url = try storefrontURL(path: "/en/account/pledges")
        try await prepareWebView(with: cookies)
        try await load(url: url)

        let result = try await evaluate(
            script: Self.giftPledgesScript,
            arguments: [
                "pledgeIDs": pledgeIDs,
                "currentPassword": password,
                "recipientEmail": recipientEmail,
                "recipientName": recipientName
            ],
            as: RemoteGiftExecution.self
        )

        if result.accessDenied {
            throw LiveHangarRepositoryError.sessionExpired
        }

        let updatedCookies = await currentRSICookies()
        let hasCompletedEveryRequestedPledge = result.completedPledgeIDs.count == pledgeIDs.count
        let shouldTreatAsSuccess = result.status == "ok"
            && result.failedPledgeID == nil
            && hasCompletedEveryRequestedPledge

        let failureMessage: String?
        if shouldTreatAsSuccess {
            failureMessage = nil
        } else {
            failureMessage = [result.failureMessage, result.debugSummary]
                .compactMap { value in
                    value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                }
                .joined(separator: "\n\n")
                .nilIfEmpty
        }

        return GiftPackagesResult(
            requestedPledgeIDs: pledgeIDs,
            completedPledgeIDs: result.completedPledgeIDs,
            failedPledgeID: result.failedPledgeID,
            failureMessage: failureMessage,
            updatedCookies: updatedCookies
        )
    }

    fileprivate func fetchUpgradeTargets(
        using cookies: [SessionCookie],
        upgradeItemPledgeID: Int
    ) async throws -> [UpgradeTargetCandidate] {
        let url = try storefrontURL(path: "/en/account/pledges")
        try await prepareWebView(with: cookies)
        try await load(url: url)

        let result = try await evaluate(
            script: Self.chooseUpgradeTargetsScript,
            arguments: [
                "upgradeItemPledgeID": upgradeItemPledgeID
            ],
            as: RemoteUpgradeTargetLookup.self
        )

        if result.accessDenied {
            throw LiveHangarRepositoryError.sessionExpired
        }

        if result.status != "ok" {
            let failureMessage = [result.failureMessage, result.debugSummary]
                .compactMap { value in
                    value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                }
                .joined(separator: "\n\n")
                .nilIfEmpty ?? "RSI did not return the eligible pledges for this upgrade item."
            throw LiveHangarRepositoryError.unexpectedMarkup(failureMessage)
        }

        return result.candidates.map(\.domainModel)
    }

    fileprivate func applyUpgrade(
        using cookies: [SessionCookie],
        upgradeItemPledgeID: Int,
        targetPledgeID: Int,
        password: String
    ) async throws -> ApplyUpgradeResult {
        let url = try storefrontURL(path: "/en/account/pledges")
        try await prepareWebView(with: cookies)
        try await load(url: url)

        let result = try await evaluate(
            script: Self.applyUpgradeScript,
            arguments: [
                "upgradeItemPledgeID": upgradeItemPledgeID,
                "targetPledgeID": targetPledgeID,
                "currentPassword": password
            ],
            as: RemoteApplyUpgradeExecution.self
        )

        if result.accessDenied {
            throw LiveHangarRepositoryError.sessionExpired
        }

        let updatedCookies = await currentRSICookies()
        let shouldTreatAsSuccess = result.status == "ok"

        let failureMessage: String?
        if shouldTreatAsSuccess {
            failureMessage = nil
        } else {
            failureMessage = [result.failureMessage, result.debugSummary]
                .compactMap { value in
                    value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                }
                .joined(separator: "\n\n")
                .nilIfEmpty
        }

        return ApplyUpgradeResult(
            upgradeItemPledgeID: upgradeItemPledgeID,
            targetPledgeID: targetPledgeID,
            wasSuccessful: shouldTreatAsSuccess,
            failureMessage: failureMessage,
            updatedCookies: updatedCookies
        )
    }

    fileprivate func requestCharacterRepair(
        using cookies: [SessionCookie],
        password: String
    ) async throws -> CharacterRepairResult {
        let url = try storefrontURL(path: "/en/account/reset")
        try await prepareWebView(with: cookies)
        try await load(url: url)

        let result = try await evaluate(
            script: Self.requestCharacterRepairScript,
            arguments: [
                "reason": "Character reset",
                "issueCouncilURL": "",
                "currentPassword": password
            ],
            as: RemoteCharacterRepairExecution.self
        )

        if result.accessDenied {
            throw LiveHangarRepositoryError.sessionExpired
        }

        let shouldTreatAsSuccess = result.status == "ok"
        let failureMessage: String?
        if shouldTreatAsSuccess {
            failureMessage = nil
        } else {
            failureMessage = [result.failureMessage, result.debugSummary]
                .compactMap { value in
                    value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                }
                .joined(separator: "\n\n")
                .nilIfEmpty
        }

        return CharacterRepairResult(
            wasSuccessful: shouldTreatAsSuccess,
            failureMessage: failureMessage,
            updatedCookies: await currentRSICookies()
        )
    }

    fileprivate func prepareBuybackCheckout(
        using cookies: [SessionCookie],
        pledge: BuybackPledge
    ) async throws -> BuybackCheckoutPreparation {
        let url = try storefrontURL(path: "/en/account/buy-back-pledges")
        try await prepareWebView(with: cookies)
        try await load(url: url)

        let upgradeContext = pledge.upgradeContext
        let result = try await evaluate(
            script: Self.prepareBuybackCheckoutScript,
            arguments: [
                "buybackPledgeID": pledge.id,
                "buybackTitle": pledge.title,
                "isUpgradeBuyback": pledge.isUpgrade && upgradeContext?.isValid == true,
                "fromShipID": upgradeContext?.fromShipID ?? 0,
                "toShipID": upgradeContext?.toShipID ?? 0,
                "toSkuID": upgradeContext?.toSkuID ?? 0
            ],
            as: RemoteBuybackCheckoutPreparation.self
        )

        if result.accessDenied {
            throw LiveHangarRepositoryError.sessionExpired
        }

        guard result.status == "ok" else {
            let failureMessage = [result.failureMessage, result.debugSummary]
                .compactMap { value in
                    value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                }
                .joined(separator: "\n\n")
                .nilIfEmpty ?? "RSI did not add the selected buy-back pledge to the cart."
            throw LiveHangarRepositoryError.unexpectedMarkup(failureMessage)
        }

        let fallbackCheckoutURL = try storefrontURL(path: "/en/pledge/cart")
        let checkoutURL = result.checkoutURL
            .flatMap(URL.init(string:))
            ?? fallbackCheckoutURL

        return BuybackCheckoutPreparation(
            buybackPledgeID: pledge.id,
            checkoutURL: checkoutURL,
            updatedCookies: await currentRSICookies()
        )
    }

    fileprivate func addLimitedShipToCart(
        using cookies: [SessionCookie],
        ship: LimitedShipSale,
        log: @escaping LimitedShipCartLogHandler,
        maxAttemptCount: Int? = nil
    ) async throws -> LimitedShipCartInsertionResult {
        try Task.checkCancellation()
        let browseURL = try limitedShipStandaloneBrowseURL()
        let initialURL = shouldPreferStandaloneShipBrowseURL(for: ship.storeURL) ? browseURL : ship.storeURL

        log("Preparing RSI browser session for \(ship.name).")
        log("Installing \(cookies.count) saved RSI session cookie(s) into the cart WebView.")
        try await prepareWebView(with: cookies)
        try Task.checkCancellation()

        if initialURL != ship.storeURL {
            log("Ship feed URL points to an RSI ship detail page. Using standalone ships browse page for the Add to Cart control.")
        }

        log("Loading RSI ship page: \(initialURL.absoluteString)")
        try await load(url: initialURL)
        try Task.checkCancellation()
        log("RSI ship page loaded: \(webView.url?.absoluteString ?? initialURL.absoluteString)")

        installLimitedShipCartLogHandler(log)
        defer {
            removeLimitedShipCartLogHandler()
        }

        var result = try await evaluateLimitedShipCartInsertion(
            ship: ship,
            browseURL: browseURL,
            log: log,
            maxAttemptCount: maxAttemptCount
        )
        try Task.checkCancellation()

        if result.status != "ok",
           webView.url?.absoluteString != browseURL.absoluteString,
           shouldRetryLimitedShipCartFromBrowsePage(result: result) {
            log("Retrying from standalone ships browse page because the first page did not expose a usable Add to Cart control.")
            try await load(url: browseURL)
            try Task.checkCancellation()
            log("RSI standalone ships page loaded: \(webView.url?.absoluteString ?? browseURL.absoluteString)")
            result = try await evaluateLimitedShipCartInsertion(
                ship: ship,
                browseURL: browseURL,
                log: log,
                maxAttemptCount: maxAttemptCount
            )
            try Task.checkCancellation()
        }

        if result.accessDenied {
            result.debugLog.forEach(log)
            throw LiveHangarRepositoryError.sessionExpired
        }

        guard result.status == "ok" else {
            result.debugLog.forEach(log)
            let failureMessage = [result.failureMessage, result.debugSummary]
                .compactMap { value in
                    value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                }
                .joined(separator: "\n\n")
                .nilIfEmpty ?? "RSI did not confirm that the limited ship was added to the cart."
            throw LiveHangarRepositoryError.unexpectedMarkup(failureMessage)
        }

        let fallbackCartURL = try storefrontURL(path: "/en/pledge/cart")
        let cartURL = result.cartURL
            .flatMap(URL.init(string:))
            ?? fallbackCartURL

        result.debugLog.forEach(log)
        log("Add to Cart finished with status=\(result.status), attempts=\(result.attemptCount).")
        return LimitedShipCartInsertionResult(
            shipID: ship.id,
            cartURL: cartURL,
            attemptCount: result.attemptCount,
            debugSummary: result.debugSummary,
            debugLog: result.debugLog,
            updatedCookies: await currentRSICookies()
        )
    }

    private func evaluateLimitedShipCartInsertion(
        ship: LimitedShipSale,
        browseURL: URL,
        log: @escaping LimitedShipCartLogHandler,
        maxAttemptCount: Int? = nil
    ) async throws -> RemoteLimitedShipCartInsertion {
        log("Starting Add to Cart retry script.")
        var arguments: [String: Any] = [
            "shipName": ship.name,
            "storeURL": ship.storeURL.absoluteString,
            "browseURL": browseURL.absoluteString,
            "maxDurationMilliseconds": 12_000,
            "retryIntervalMinimumMilliseconds": 350,
            "retryIntervalMaximumMilliseconds": 580,
            "singleAttemptTimeoutMilliseconds": 5_000,
            "untrackedClickCooldownMilliseconds": 650
        ]

        if let maxAttemptCount {
            arguments["maxAttemptCount"] = maxAttemptCount
        }

        return try await evaluate(
            script: Self.limitedShipAddToCartScript,
            arguments: arguments,
            as: RemoteLimitedShipCartInsertion.self
        )
    }

    private func limitedShipStandaloneBrowseURL() throws -> URL {
        try storefrontURL(path: "/en/store/pledge/browse/extras/standalone-ships")
    }

    private func shouldPreferStandaloneShipBrowseURL(for url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("/pledge/ships/")
    }

    private func shouldRetryLimitedShipCartFromBrowsePage(result: RemoteLimitedShipCartInsertion) -> Bool {
        guard result.status != "ok" else {
            return false
        }

        let message = [result.failureMessage, result.debugSummary]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return result.attemptCount == 0 ||
            message.contains("no enabled add to cart") ||
            message.contains("no scoped add to cart") ||
            message.contains("no add to cart")
    }

    fileprivate func fetchAuthorizedDevices(
        using cookies: [SessionCookie],
        password: String?
    ) async throws -> [AuthorizedDevice] {
        let url = try storefrontURL(path: "/en/account/security/devices")
        try await prepareWebView(with: cookies)
        try await load(url: url)

        let result = try await evaluate(
            script: Self.authorizedDevicesExtractionScript,
            arguments: [
                "currentPassword": password ?? ""
            ],
            as: RemoteAuthorizedDevicesLookup.self
        )

        if result.accessDenied {
            throw LiveHangarRepositoryError.sessionExpired
        }

        guard result.status == "ok" else {
            let failureMessage = [result.failureMessage, result.debugSummary]
                .compactMap { value in
                    value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                }
                .joined(separator: "\n\n")
                .nilIfEmpty ?? "RSI did not return the authorized device list."
            throw LiveHangarRepositoryError.unexpectedMarkup(failureMessage)
        }

        return result.devices.map(\.domainModel)
    }

    fileprivate func removeAuthorizedDevice(
        using cookies: [SessionCookie],
        device: AuthorizedDevice,
        password: String?
    ) async throws {
        let url = try storefrontURL(path: "/en/account/security/devices")
        try await prepareWebView(with: cookies)
        try await load(url: url)

        let result = try await evaluate(
            script: Self.removeAuthorizedDeviceScript,
            arguments: [
                "deviceID": device.id,
                "deviceName": device.displayName,
                "currentPassword": password ?? ""
            ],
            as: RemoteAuthorizedDeviceRemoval.self
        )

        if result.accessDenied {
            throw LiveHangarRepositoryError.sessionExpired
        }

        guard result.status == "ok" else {
            let failureMessage = [result.failureMessage, result.debugSummary]
                .compactMap { value in
                    value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                }
                .joined(separator: "\n\n")
                .nilIfEmpty ?? "RSI did not remove the selected authorized device."
            throw LiveHangarRepositoryError.unexpectedMarkup(failureMessage)
        }
    }

    fileprivate func removeAuthorizedDevices(
        using cookies: [SessionCookie],
        devices: [AuthorizedDevice],
        password: String?
    ) async throws {
        guard !devices.isEmpty else {
            return
        }

        let url = try storefrontURL(path: "/en/account/security/devices")
        try await prepareWebView(with: cookies)
        try await load(url: url)

        let devicePayload = devices.map { device in
            [
                "id": device.id,
                "name": device.displayName
            ]
        }
        let result = try await evaluate(
            script: Self.removeAuthorizedDevicesScript,
            arguments: [
                "devicesToRemove": devicePayload,
                "currentPassword": password ?? ""
            ],
            as: RemoteAuthorizedDeviceBulkRemoval.self
        )

        if result.accessDenied {
            throw LiveHangarRepositoryError.sessionExpired
        }

        guard result.status == "ok" else {
            let failureMessage = [result.failureMessage, result.debugSummary]
                .compactMap { value in
                    value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                }
                .joined(separator: "\n\n")
                .nilIfEmpty ?? "RSI did not remove the selected authorized devices."
            throw LiveHangarRepositoryError.unexpectedMarkup(failureMessage)
        }
    }

    fileprivate func currentRSICookies() async -> [SessionCookie] {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await allCookies(from: store)
        return cookies
            .filter { $0.domain.contains("robertsspaceindustries.com") }
            .map(SessionCookie.init)
    }

    fileprivate static func loadPledgeChunk(
        using cookies: [SessionCookie],
        pages: [Int],
        pageSize: Int,
        onPageLoaded: @escaping @Sendable (_ page: Int, _ itemCount: Int) async -> Void
    ) async throws -> [(Int, RemotePledgePage)] {
        let browser = RSIAccountPageBrowser()
        return try await browser.extractPledgeChunk(
            using: cookies,
            pages: pages,
            pageSize: pageSize,
            onPageLoaded: onPageLoaded
        )
    }

    fileprivate static func loadBuybackChunk(
        using cookies: [SessionCookie],
        pages: [Int],
        pageSize: Int,
        onPageLoaded: @escaping @Sendable (_ page: Int, _ itemCount: Int) async -> Void
    ) async throws -> [(Int, RemoteBuybackPage)] {
        let browser = RSIAccountPageBrowser()
        return try await browser.extractBuybackChunk(
            using: cookies,
            pages: pages,
            pageSize: pageSize,
            onPageLoaded: onPageLoaded
        )
    }

    static func validateAuthenticatedPledgeAccess(using cookies: [SessionCookie]) async throws {
        let browser = RSIAccountPageBrowser()
        let result = try await browser.extractPledges(
            using: cookies,
            page: 1,
            pageSize: 1
        )

        if result.accessDenied {
            throw LiveHangarRepositoryError.sessionExpired
        }
    }

    fileprivate func fetchShipCatalog(using cookies: [SessionCookie]) async throws -> RSIShipCatalog {
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
                    imageURL: ship.imageURL.flatMap(URL.init(string:)),
                    sourceImageURL: nil
                )
            }
        )
    }

    fileprivate func fetchAccountOverview(
        using cookies: [SessionCookie],
        accountHandle: String,
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

        let primaryOrganizationOverview = try? await fetchPrimaryOrganization(
            profileCandidates: [accountHandle, profileName]
        )

        return AccountOverview(
            storeCreditUSD: storeCreditUSD,
            totalSpendUSD: billingPayload.totalSpendText.flatMap(RSIStoreCreditParser.parseCurrencyText),
            avatarURL: normalizedRSIURL(from: payload.avatarURL),
            primaryOrganization: primaryOrganizationOverview?.organization,
            didRefreshPrimaryOrganization: primaryOrganizationOverview?.didRefreshPrimaryOrganization ?? false
        )
    }

    fileprivate func fetchReferralStats(using cookies: [SessionCookie]) async throws -> ReferralStats {
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
            inviteCode: currentPayload.inviteCode,
            legacyGraphQLCount: legacyPayload.graphQLCount,
            legacyParsedCount: legacyPayload.legacyLadderCount,
            legacyPageUnavailable: legacyPayload.pageUnavailable
        )
    }

    private func fetchPrimaryOrganization(profileCandidates: [String]) async throws -> PrimaryOrganizationOverview {
        let resolvedCandidates = profileCandidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { uniqueCandidates, candidate in
                if !uniqueCandidates.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                    uniqueCandidates.append(candidate)
                }
            }

        guard !resolvedCandidates.isEmpty else {
            return PrimaryOrganizationOverview(
                organization: nil,
                didRefreshPrimaryOrganization: false
            )
        }

        var didReachCitizenDossier = false

        for candidate in resolvedCandidates {
            let dossierURL = try citizenDossierURL(profileName: candidate)
            try await load(url: dossierURL)

            let payload = try await evaluate(script: Self.primaryOrganizationExtractionScript, as: RemotePrimaryOrganization.self)

            if payload.accessDenied {
                throw LiveHangarRepositoryError.sessionExpired
            }

            guard !payload.pageUnavailable else {
                continue
            }

            didReachCitizenDossier = true

            if let organization = payload.organization {
                return PrimaryOrganizationOverview(
                    organization: organization,
                    didRefreshPrimaryOrganization: true
                )
            }
        }

        return PrimaryOrganizationOverview(
            organization: nil,
            didRefreshPrimaryOrganization: didReachCitizenDossier
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        appendNavigationEvent("didFinish url=\(webView.url?.absoluteString ?? "unknown")")
        finishLoading(with: .success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        lastNavigationFailureDescription = navigationErrorSummary(error)
        appendNavigationEvent("didFail \(lastNavigationFailureDescription ?? error.localizedDescription)")
        Task {
            await finishLoadingAfterNavigationFailure(error, requestedURL: activeLoadURL)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        lastNavigationFailureDescription = navigationErrorSummary(error)
        appendNavigationEvent("didFailProvisional \(lastNavigationFailureDescription ?? error.localizedDescription)")
        Task {
            await finishLoadingAfterNavigationFailure(error, requestedURL: activeLoadURL)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        appendNavigationEvent("didStartProvisional url=\(webView.url?.absoluteString ?? "unknown")")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        appendNavigationEvent("didCommit url=\(webView.url?.absoluteString ?? "unknown")")
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        appendNavigationEvent("didReceiveRedirect url=\(webView.url?.absoluteString ?? "unknown")")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            let summary = [
                "status=\(httpResponse.statusCode)",
                "url=\(httpResponse.url?.absoluteString ?? "unknown")",
                "mime=\(httpResponse.mimeType ?? "unknown")"
            ].joined(separator: ", ")
            lastNavigationResponseSummary = summary
            appendNavigationEvent("navigationResponse \(summary)")
        } else {
            let summary = [
                "url=\(navigationResponse.response.url?.absoluteString ?? "unknown")",
                "mime=\(navigationResponse.response.mimeType ?? "unknown")"
            ].joined(separator: ", ")
            lastNavigationResponseSummary = summary
            appendNavigationEvent("navigationResponse \(summary)")
        }

        decisionHandler(.allow)
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

    private func extractPledgeChunk(
        using cookies: [SessionCookie],
        pages: [Int],
        pageSize: Int,
        onPageLoaded: @escaping @Sendable (_ page: Int, _ itemCount: Int) async -> Void
    ) async throws -> [(Int, RemotePledgePage)] {
        guard !pages.isEmpty else {
            return []
        }

        try await prepareWebView(with: cookies)

        var results: [(Int, RemotePledgePage)] = []
        var previousSignature: String?

        for page in pages {
            let url = try pageURL(path: "/en/account/pledges", page: page, pageSize: pageSize)
            try await load(url: url)
            let result = try await evaluate(script: Self.pledgesExtractionScript, as: RemotePledgePage.self)

            if result.accessDenied {
                throw LiveHangarRepositoryError.sessionExpired
            }

            if result.items.isEmpty {
                throw LiveHangarRepositoryError.unexpectedMarkup(
                    "RSI returned an empty hangar page for page \(page) during parallel sync."
                )
            }

            if let previousSignature,
               previousSignature == result.pageSignature
            {
                throw LiveHangarRepositoryError.unexpectedMarkup(
                    "RSI repeated the same hangar page content while loading page \(page) in parallel."
                )
            }

            results.append((page, result))
            previousSignature = result.pageSignature
            await onPageLoaded(page, result.items.count)
        }

        return results
    }

    private func extractBuybackChunk(
        using cookies: [SessionCookie],
        pages: [Int],
        pageSize: Int,
        onPageLoaded: @escaping @Sendable (_ page: Int, _ itemCount: Int) async -> Void
    ) async throws -> [(Int, RemoteBuybackPage)] {
        guard !pages.isEmpty else {
            return []
        }

        try await prepareWebView(with: cookies)

        var results: [(Int, RemoteBuybackPage)] = []
        var previousSignature: String?

        for page in pages {
            let url = try pageURL(path: "/en/account/buy-back-pledges", page: page, pageSize: pageSize)
            try await load(url: url)
            let result = try await evaluate(script: Self.buybackExtractionScript, as: RemoteBuybackPage.self)

            if result.accessDenied {
                throw LiveHangarRepositoryError.sessionExpired
            }

            if result.items.isEmpty {
                throw LiveHangarRepositoryError.unexpectedMarkup(
                    "RSI returned an empty buy-back page for page \(page) during parallel sync."
                )
            }

            if let previousSignature,
               previousSignature == result.pageSignature
            {
                throw LiveHangarRepositoryError.unexpectedMarkup(
                    "RSI repeated the same buy-back page content while loading page \(page) in parallel."
                )
            }

            results.append((page, result))
            previousSignature = result.pageSignature
            await onPageLoaded(page, result.items.count)
        }

        return results
    }

    private func load(url: URL) async throws {
        if loadContinuation != nil {
            throw LiveHangarRepositoryError.unexpectedMarkup("The RSI page loader is already busy.")
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                loadContinuation = continuation
                activeLoadURL = url
                lastNavigationEvents.removeAll()
                lastNavigationFailureDescription = nil
                lastNavigationResponseSummary = nil
                appendNavigationEvent("loadRequest url=\(url.absoluteString)")
                loadTimeoutTask?.cancel()
                loadTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: self?.loadTimeoutNanoseconds ?? 30_000_000_000)
                    await self?.finishLoadingAfterTimeout(requestedURL: url)
                }
                webView.load(URLRequest(url: url))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelActiveLoad()
            }
        }
    }

    private func cancelActiveLoad() {
        webView.stopLoading()
        guard loadContinuation != nil else {
            return
        }

        appendNavigationEvent("cancelled")
        finishLoading(with: .failure(CancellationError()))
    }

    private func finishLoadingAfterTimeout(requestedURL: URL) async {
        guard loadContinuation != nil else {
            return
        }

        appendNavigationEvent("timeoutAfter \(loadTimeoutNanoseconds / 1_000_000_000)s")
        let diagnostics = await pageLoadDiagnostics(
            requestedURL: requestedURL,
            reason: "timeout"
        )
        webView.stopLoading()
        finishLoading(
            with: .failure(
                LiveHangarRepositoryError.unexpectedMarkup(
                    """
                    RSI page load timed out while opening \(requestedURL.absoluteString).

                    \(diagnostics)
                    """
                )
            )
        )
    }

    private func finishLoadingAfterNavigationFailure(_ error: Error, requestedURL: URL?) async {
        guard loadContinuation != nil else {
            return
        }

        let diagnostics = await pageLoadDiagnostics(
            requestedURL: requestedURL ?? webView.url,
            reason: "navigationFailure"
        )
        finishLoading(
            with: .failure(
                LiveHangarRepositoryError.unexpectedMarkup(
                    """
                    RSI page load failed: \(navigationErrorSummary(error)).

                    \(diagnostics)
                    """
                )
            )
        )
    }

    private func finishLoading(with result: Result<Void, Error>) {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil

        guard let loadContinuation else {
            return
        }

        self.loadContinuation = nil
        activeLoadURL = nil

        switch result {
        case .success:
            loadContinuation.resume()
        case let .failure(error):
            loadContinuation.resume(throwing: error)
        }
    }

    private func pageLoadDiagnostics(requestedURL: URL?, reason: String) async -> String {
        let currentCookies = await currentRSICookies()
        let pageTitle = await diagnosticJavaScriptValue("document.title")
        let readyState = await diagnosticJavaScriptValue("document.readyState")
        let locationHref = await diagnosticJavaScriptValue("window.location.href")
        let navigatorOnline = await diagnosticJavaScriptValue("navigator.onLine")
        let htmlLength = await diagnosticJavaScriptValue("""
        (() => {
            try {
                return String(document.documentElement ? document.documentElement.outerHTML.length : 0);
            } catch (error) {
                return 'error=' + String(error && error.message ? error.message : error);
            }
        })()
        """)
        let performanceSummary = await diagnosticJavaScriptValue("""
        (() => {
            try {
                const nav = performance.getEntriesByType('navigation')[0];
                if (!nav) {
                    return 'unavailable';
                }
                return [
                    'type=' + nav.type,
                    'duration=' + Math.round(nav.duration),
                    'domInteractive=' + Math.round(nav.domInteractive),
                    'domContentLoaded=' + Math.round(nav.domContentLoadedEventEnd),
                    'loadEventEnd=' + Math.round(nav.loadEventEnd),
                    'transferSize=' + (nav.transferSize || 0)
                ].join(', ');
            } catch (error) {
                return 'error=' + String(error && error.message ? error.message : error);
            }
        })()
        """)
        let bodyPreview = await diagnosticJavaScriptValue("""
        (() => {
            try {
                const text = document.body ? document.body.innerText : '';
                return text.replace(/\\s+/g, ' ').trim().slice(0, 700);
            } catch (error) {
                return 'error=' + String(error && error.message ? error.message : error);
            }
        })()
        """)

        let cookieNames = Array(Set(currentCookies.map(\.name))).sorted()
        let cookieDomains = Array(Set(currentCookies.map(\.domain))).sorted()
        let eventSummary = lastNavigationEvents.isEmpty ? "none" : lastNavigationEvents.joined(separator: " | ")

        return [
            "Page Load Diagnostics",
            "reason=\(reason)",
            "requestedURL=\(requestedURL?.absoluteString ?? "unknown")",
            "webViewURL=\(webView.url?.absoluteString ?? "unknown")",
            "locationHref=\(diagnosticValue(locationHref))",
            "title=\(diagnosticValue(pageTitle))",
            "readyState=\(diagnosticValue(readyState))",
            "isLoading=\(webView.isLoading ? "yes" : "no")",
            "estimatedProgress=\(String(format: "%.2f", webView.estimatedProgress))",
            "navigatorOnline=\(diagnosticValue(navigatorOnline))",
            "lastNavigationResponse=\(lastNavigationResponseSummary ?? "none")",
            "lastNavigationFailure=\(lastNavigationFailureDescription ?? "none")",
            "rsiCookieCount=\(currentCookies.count)",
            "rsiCookieNames=\(limitedJoined(cookieNames, limit: 12))",
            "rsiCookieDomains=\(limitedJoined(cookieDomains, limit: 6))",
            "performanceNavigation=\(diagnosticValue(performanceSummary))",
            "htmlLength=\(diagnosticValue(htmlLength))",
            "navigationEvents=\(eventSummary)",
            "bodyPreview=\(diagnosticValue(bodyPreview))"
        ].joined(separator: "\n")
    }

    private func diagnosticJavaScriptValue(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(returning: "error=\(error.localizedDescription)")
                    return
                }

                guard let result else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: String(describing: result))
            }
        }
    }

    private func diagnosticValue(_ value: String?) -> String {
        guard let value = value?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return "none"
        }

        return value
    }

    private func limitedJoined(_ values: [String], limit: Int) -> String {
        guard !values.isEmpty else {
            return "none"
        }

        let prefix = values.prefix(limit).joined(separator: ",")
        return values.count > limit ? "\(prefix),..." : prefix
    }

    private func appendNavigationEvent(_ event: String) {
        let sanitizedEvent = event
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedEvent.isEmpty else {
            return
        }

        lastNavigationEvents.append(sanitizedEvent)
        if lastNavigationEvents.count > maximumNavigationEventCount {
            lastNavigationEvents.removeFirst(lastNavigationEvents.count - maximumNavigationEventCount)
        }
    }

    private func navigationErrorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        return [
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "description=\(error.localizedDescription)"
        ].joined(separator: ", ")
    }

    private func evaluate<Value: Decodable>(script: String, as type: Value.Type) async throws -> Value {
        try await evaluate(script: script, arguments: [:], as: type)
    }

    private func evaluate<Value: Decodable>(
        script: String,
        arguments: [String: Any],
        as type: Value.Type
    ) async throws -> Value {
        let result = try await webView.callAsyncJavaScript(
            script,
            arguments: arguments,
            in: nil,
            contentWorld: .page
        )

        guard let result else {
            throw LiveHangarRepositoryError.unexpectedMarkup("RSI returned an empty page payload.")
        }

        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func installLimitedShipCartLogHandler(_ log: @escaping LimitedShipCartLogHandler) {
        removeLimitedShipCartLogHandler()

        let bridge = LimitedShipCartLogBridge(handler: log)
        limitedShipCartLogBridge = bridge
        webView.configuration.userContentController.add(
            bridge,
            name: Self.limitedShipCartLogMessageName
        )
    }

    private func removeLimitedShipCartLogHandler() {
        if limitedShipCartLogBridge != nil {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: Self.limitedShipCartLogMessageName
            )
            limitedShipCartLogBridge = nil
        }
    }

    private func ensureLoaded(url: URL) async throws {
        guard webView.url?.host == url.host, webView.url?.path == url.path else {
            try await load(url: url)
            return
        }

        if webView.isLoading {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                loadContinuation = continuation
            }
        }
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

    const normalizeText = (value) => String(value || '').replace(/\\s+/g, ' ').trim();

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

    const cleanContentTitle = (value) =>
      normalizeText(value).replace(/\\s+(?:and\\s+)?\\d+\\s+(?:items?|ships?|vehicles?)$/i, '').trim();

    const normalizeUpgradeMatchItems = (items) =>
      Array.isArray(items)
        ? items
            .map((item) => {
              const parsedID = Number.parseInt(String(item?.id ?? ''), 10);
              const name = String(item?.name || '').trim();
              if (!name) {
                return null;
              }

              return {
                id: Number.isFinite(parsedID) ? parsedID : null,
                name
              };
            })
            .filter(Boolean)
        : [];

    const parseUpgradeMetadata = (row) => {
      const rawValue = firstValue(row, ['.js-upgrade-data']);
      if (!rawValue) {
        return null;
      }

      try {
        const parsed = JSON.parse(rawValue);
        const parsedID = Number.parseInt(String(parsed?.id ?? ''), 10);
        return {
          id: Number.isFinite(parsedID) ? parsedID : null,
          name: String(parsed?.name || '').trim() || null,
          upgradeType: String(parsed?.upgrade_type || '').trim() || null,
          matchItems: normalizeUpgradeMatchItems(parsed?.match_items),
          targetItems: normalizeUpgradeMatchItems(parsed?.target_items)
        };
      } catch {
        return null;
      }
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
        const rawStatusValue = firstValue(row, ['.js-pledge-status']);
        const contentItemNodes = (() => {
          const selectors = [
            '.with-images .item',
            '.without-images .item',
            '.items-col .item',
            '.contains .item'
          ];
          const seen = new Set();
          const nodes = [];

          for (const selector of selectors) {
            for (const item of Array.from(row.querySelectorAll(selector))) {
              if (seen.has(item)) {
                continue;
              }

              seen.add(item);
              nodes.push(item);
            }
          }

          return nodes.filter((item) => {
            const title = cleanContentTitle(firstText(item, ['.title', '.name', 'h1', 'h2', 'h3']));
            const normalizedTitle = normalizeText(title).toLowerCase();
            if (!normalizedTitle) {
              return false;
            }

            if (/^(?:and\\s+)?\\d+\\s+(?:items?|ships?|vehicles?)$/.test(normalizedTitle) || normalizedTitle === 'standard upgrade' || normalizedTitle === 'and') {
              return false;
            }

            return true;
          });
        })();
        const items = contentItemNodes.map((item) => ({
          title: cleanContentTitle(firstText(item, ['.title', '.name', 'h1', 'h2', 'h3'])),
          kind: firstText(item, ['.kind', '.type', '.category']),
          detail: firstText(item, ['.liner', '.subtitle']),
          imageURL: firstImageURL(item.querySelector('.image, .thumb, .thumbnail, picture, img, [style*="background-image"]') || item)
        }));

        return {
          id: (() => {
            const value = Number.parseInt(firstValue(row, ['.js-pledge-id']), 10);
            return Number.isFinite(value) ? value : null;
          })(),
          title: firstValue(row, ['.js-pledge-name']) || firstText(row, ['h1', 'h2', '.title']),
          statusText: normalizeText(rawStatusValue) || firstText(row, ['.availability', '.status']),
          isUpgradedStatusFlag: (() => {
            try {
              const statusNodes = Array.from(
                row.querySelectorAll('.availability, .status, .availability *, .status *')
              );
              const combinedStatusText = statusNodes
                .map((node) => normalizeText(node.textContent))
                .filter(Boolean)
                .join(' ');
              const rowVisibleText = normalizeText(row.innerText || row.textContent || '');
              const searchableStatusText = [
                normalizeText(rawStatusValue),
                combinedStatusText,
                rowVisibleText
              ]
                .filter(Boolean)
                .join(' ');
              return /(^|\\s)upgraded(\\s|$)/i.test(searchableStatusText);
            } catch {
              return false;
            }
          })(),
          dateText: firstText(row, ['.date-col', '.date']),
          valueText: firstValue(row, ['.js-pledge-value']) || firstText(row, ['.value', '.price']),
          containsText: firstText(row, ['.items-col', '.contains']),
          thumbnailImageURL: firstImageURL(packageThumbnailNode),
          alsoContains: titles,
          canGift: row.querySelector('.shadow-button.js-gift, .js-gift') !== null,
          canReclaim: row.querySelector('.shadow-button.js-reclaim, .js-reclaim') !== null,
          canUpgrade: row.querySelector('.shadow-button.js-apply-upgrade, .js-apply-upgrade') !== null,
          upgradeMetadata: parseUpgradeMetadata(row),
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

    const dossierRoot =
      document.querySelector('.citizen-record') ||
      document.querySelector('.profile-content') ||
      document.querySelector('.left-col') ||
      document.querySelector('.right-col') ||
      document.querySelector('.main-org') ||
      document.querySelector('.box-content.org.main');

    if (!dossierRoot) {
      return {
        accessDenied,
        pageUnavailable: true,
        organizationName: null,
        organizationRank: null
      };
    }

    const extractionRoots = [];
    const pushUniqueRoot = (root) => {
      if (root && !extractionRoots.includes(root)) {
        extractionRoots.push(root);
      }
    };

    [
      document.querySelector('.main-org .info'),
      document.querySelector('.main-org'),
      document.querySelector('.box-content.org.main .info'),
      document.querySelector('.box-content.org.main'),
      document.querySelector('.right-col')
    ].forEach(pushUniqueRoot);

    let organization = {
      name: '',
      rank: ''
    };

    extractionRoots.forEach((root) => {
      Array.from(root.querySelectorAll('.entry')).forEach((entry, index) => {
        const label = normalizeText(entry.querySelector('.label')?.textContent).toLowerCase();
        const linkedValue = normalizeText(entry.querySelector('a[href*="/orgs/"]')?.textContent);
        const strongValue = normalizeText(entry.querySelector('strong')?.textContent);
        const plainValue = normalizeText(entry.querySelector('.value')?.textContent);
        const value = linkedValue || plainValue || strongValue;

        if (!value) {
          return;
        }

        if ((label.includes('main organization') || label.includes('organization')) && !organization.name) {
          organization.name = value;
          return;
        }

        if ((label.includes('organization rank') || label === 'rank') && !organization.rank) {
          organization.rank = value;
          return;
        }

        if (!label && !organization.name && linkedValue) {
          organization.name = linkedValue;
          return;
        }

        if (!label && !organization.name && index === 0) {
          organization.name = value;
          return;
        }
      });

      if (!organization.name) {
        const fallbackLink = root.querySelector('a[href*="/orgs/"]');
        const fallbackName = normalizeText(fallbackLink?.textContent);
        if (fallbackName) {
          organization.name = fallbackName;
        }
      }

      if (!organization.rank) {
        const strongValues = Array.from(root.querySelectorAll('.entry strong'))
          .map((item) => normalizeText(item.textContent))
          .filter(Boolean);

        if (strongValues.length >= 3) {
          organization.rank = strongValues[2];
        }
      }
    });

    if (!organization.name) {
      const dossierOrgLink = dossierRoot.querySelector('a[href*="/orgs/"]');
      const dossierOrgName = normalizeText(dossierOrgLink?.textContent);
      if (dossierOrgName) {
        organization.name = dossierOrgName;
      }
    }

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

    const normalizeInviteCode = (value) => {
      const match = String(value || '').toUpperCase().match(/\\bSTAR-[A-Z0-9]{4}-[A-Z0-9]{4}\\b/);
      return match ? match[0] : null;
    };

    const attributeValue = (element, name) => {
      return element && typeof element.getAttribute === 'function' ? element.getAttribute(name) : null;
    };

    const extractInviteCodeFromElement = (element) => {
      if (!element) {
        return null;
      }

      const textCode = normalizeInviteCode(element.textContent);
      if (textCode) {
        return textCode;
      }

      const directValues = [
        element.value,
        attributeValue(element, 'value'),
        attributeValue(element, 'aria-label'),
        attributeValue(element, 'title'),
        attributeValue(element, 'data-referral'),
        attributeValue(element, 'data-referral-code')
      ];

      for (const value of directValues) {
        const code = normalizeInviteCode(value);
        if (code) {
          return code;
        }
      }

      if (element.attributes) {
        for (const attribute of Array.from(element.attributes)) {
          if (String(attribute.name || '').toLowerCase() === 'href') {
            continue;
          }

          const code = normalizeInviteCode(attribute.value);
          if (code) {
            return code;
          }
        }
      }

      return null;
    };

    const extractInviteCode = (includePageHTML = true) => {
      const selectors = [
        '.accountReferralCopyForm__referralCodeValue',
        '.accountReferralCopyForm__referralCode',
        '.accountReferralCopyForm',
        '[data-cy-id="button-copy-referral-code"]',
        '[class*="referralCodeValue"]',
        '[class*="referralCode"]',
        '[class*="ReferralCode"]',
        '[class*="referral-code"]',
        '[class*="ReferralCopy"]',
        '[class*="referralCopy"]'
      ];

      for (const selector of selectors) {
        for (const element of Array.from(document.querySelectorAll(selector))) {
          const code = extractInviteCodeFromElement(element);
          if (code) {
            return code;
          }
        }
      }

      const textCode = normalizeInviteCode(document.body?.innerText);
      if (textCode) {
        return textCode;
      }

      return includePageHTML ? normalizeInviteCode(document.documentElement?.outerHTML) : null;
    };

    const fetchAccountInviteCode = async () => {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '';
      if (!csrfToken) {
        return null;
      }

      const query = `query AccountReferralCode {
        account {
          isAnonymous
          ... on RsiAuthenticatedAccount {
            referral_code
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
            'X-CSRF-TOKEN': csrfToken,
            'Accept-Language': document.documentElement.getAttribute('lang') || 'en'
          },
          body: JSON.stringify({
            operationName: 'AccountReferralCode',
            query,
            variables: {}
          })
        });

        const rawBody = await response.text();
        let payload = null;
        try {
          payload = JSON.parse(rawBody);
        } catch {
          return null;
        }

        return normalizeInviteCode(payload?.data?.account?.referral_code);
      } catch {
        return null;
      }
    };

    const fetchInviteCodeFromReferralHTML = async () => {
      const paths = Array.from(new Set([
        window.location.pathname.includes('/referral') ? window.location.pathname + window.location.search : '/en/referral',
        '/en/referral'
      ]));

      for (const path of paths) {
        try {
          const response = await fetch(path, {
            method: 'GET',
            credentials: 'include',
            headers: {
              'Accept': 'text/html,application/xhtml+xml',
              'Accept-Language': document.documentElement.getAttribute('lang') || 'en'
            }
          });

          if (!response.ok) {
            continue;
          }

          const code = normalizeInviteCode(await response.text());
          if (code) {
            return code;
          }
        } catch {
        }
      }

      return null;
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

    await waitFor(() => document.querySelector('.accountReferralHeroBanner, .accountReferralRecruitsCount__text'), 2400);
    const inviteCode =
      await fetchAccountInviteCode() ||
      await waitFor(() => extractInviteCode(false), 3600) ||
      extractInviteCode(true) ||
      await fetchInviteCodeFromReferralHTML();

    const accessDenied = document.title.toLowerCase().includes('access denied') || document.body.innerText.includes('Access denied');
    const campaignId = extractCampaignId();
    const graphQLCount = await fetchReferralCount(campaignId);
    const counterText = normalizeText(document.querySelector('.accountReferralRecruitsCount__text')?.textContent);

    return {
      accessDenied,
      campaignId,
      inviteCode,
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

    const firstDateText = (value) => {
      const normalized = String(value || '').replace(/\\s+/g, ' ').trim();
      const monthMatch = normalized.match(/\\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\\.?\\s+\\d{1,2}(?:st|nd|rd|th)?,?\\s+\\d{4}\\b/i);
      if (monthMatch?.[0]) {
        return monthMatch[0];
      }

      const isoMatch = normalized.match(/\\b\\d{4}-\\d{1,2}-\\d{1,2}\\b/);
      return isoMatch?.[0] || '';
    };

    const looksLikeDateText = (value) => {
      return Boolean(firstDateText(value));
    };

    const definitionValue = (labels, values, labelPatterns) => {
      for (let index = 0; index < labels.length; index += 1) {
        const label = String(labels[index] || '').toLowerCase();
        if (!labelPatterns.some((pattern) => pattern.test(label))) {
          continue;
        }

        const value = values[index];
        if (value) {
          return value;
        }
      }

      return '';
    };

    const containedTextFromArticle = (text) => {
      const normalized = String(text || '').replace(/\\s+/g, ' ').trim();
      const match = normalized.match(/\\bContained\\b\\s+(.+?)(?=\\s+\\b(?:Buy Back|Not available|Why can't|This pledge|Account FAQ)\\b|$)/i);
      return match?.[1]?.trim() || '';
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
        const fromShipID = Number(button?.getAttribute('data-fromshipid'));
        const toShipID = Number(button?.getAttribute('data-toshipid'));
        const toSkuID = Number(button?.getAttribute('data-toskuid'));
        const definitionLabels = Array.from(article.querySelectorAll('dl dt'))
          .map((node) => node.textContent.trim())
          .filter(Boolean);
        const definitionValues = Array.from(article.querySelectorAll('dl dd'))
          .map((node) => node.textContent.trim())
          .filter(Boolean);
        const articleText = String(article.innerText || article.textContent || '').replace(/\\s+/g, ' ').trim();
        const dateText =
          definitionValue(definitionLabels, definitionValues, [/date/, /created/, /added/, /modified/, /reclaim/, /recovered/]) ||
          definitionValues.find(looksLikeDateText) ||
          firstDateText(articleText) ||
          '';
        const containsText =
          definitionValue(definitionLabels, definitionValues, [/contains/, /includes/, /items/]) ||
          definitionValues[2] ||
          containedTextFromArticle(articleText) ||
          firstText(article, ['.information .contains']);
        const titleText = firstText(article, ['.information h1', 'h1', 'h2']);
        const valueText = firstText(article, ['.price', '.value', '.cost']);
        const imageURL = firstImageURL(article.querySelector('.image, .thumb, .thumbnail, picture, img') || article);
        const upgradeContext = Number.isFinite(fromShipID) && fromShipID > 0 &&
          Number.isFinite(toShipID) && toShipID > 0 &&
          Number.isFinite(toSkuID) && toSkuID > 0
            ? {
                fromShipID,
                toShipID,
                toSkuID
              }
            : null;

        return {
          id: Number.isFinite(hrefId) && hrefId > 0 ? hrefId : (Number.isFinite(dataId) && dataId > 0 ? dataId : null),
          title: titleText,
          dateText,
          containsText,
          valueText,
          imageURL,
          upgradeContext,
          sourceRawInfo: {
            buttonHref: href || null,
            buttonDataPledgeID: Number.isFinite(dataId) && dataId > 0 ? dataId : null,
            buttonFromShipID: Number.isFinite(fromShipID) && fromShipID > 0 ? fromShipID : null,
            buttonToShipID: Number.isFinite(toShipID) && toShipID > 0 ? toShipID : null,
            buttonToSkuID: Number.isFinite(toSkuID) && toSkuID > 0 ? toSkuID : null,
            titleText,
            dateText,
            containsText,
            valueText,
            imageURL,
            definitionLabels,
            definitionValues,
            articleText: articleText.slice(0, 4000)
          }
        };
      })
    };
    """

    private static let hangarLogExtractionScript = """
    const normalizeText = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
    const resolvedMaxEntries = Number.isFinite(Number(maxEntries)) && Number(maxEntries) > 0
      ? Math.min(Math.floor(Number(maxEntries)), 500)
      : 10;
    const knownFullTexts = new Set(
      (Array.isArray(knownRawTexts) ? knownRawTexts : [])
        .map((value) => normalizeText(value))
        .filter(Boolean)
    );
    const cookieValue = (name) => {
      const escapedName = name.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
      const match = document.cookie.match(new RegExp('(?:^|; )' + escapedName + '=([^;]*)'));
      return match ? decodeURIComponent(match[1]) : '';
    };
    const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    const waitFor = async (predicate, timeoutMs = 6000, intervalMs = 125) => {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        if (predicate()) {
          return true;
        }
        await wait(intervalMs);
      }
      return predicate();
    };
    const isVisible = (node) => !!node && !!(node.offsetWidth || node.offsetHeight || node.getClientRects().length);
    const clickElement = (node) => {
      if (!node) {
        return false;
      }
      if (typeof node.click === 'function') {
        node.click();
      } else {
        node.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
      }
      return true;
    };
    const collectEntries = () =>
      Array.from(document.querySelectorAll('.pledge-log-entry')).map((entry) => {
        const paragraphText = normalizeText(entry.querySelector('p')?.textContent);
        const itemName = normalizeText(entry.querySelector('span')?.textContent);
        const splitIndex = paragraphText.indexOf(' - ');
        const timeText = splitIndex >= 0
          ? normalizeText(paragraphText.slice(0, splitIndex)).replace(/\\bam\\b/g, 'AM').replace(/\\bpm\\b/g, 'PM')
          : '';
        const messageText = splitIndex >= 0 ? normalizeText(paragraphText.slice(splitIndex + 3)) : paragraphText;
        const contentText = itemName && messageText.startsWith(itemName)
          ? normalizeText(messageText.slice(itemName.length))
          : messageText;

        return {
          timeText,
          itemName,
          fullText: paragraphText,
          contentText
        };
      });
    const parseRenderedEntries = (rendered) => {
      const container = document.createElement('div');
      container.innerHTML = typeof rendered === 'string' ? rendered : '';
      return Array.from(container.querySelectorAll('.pledge-log-entry')).map((entry) => {
        const paragraphText = normalizeText(entry.querySelector('p')?.textContent);
        const itemName = normalizeText(entry.querySelector('span')?.textContent);
        const splitIndex = paragraphText.indexOf(' - ');
        const timeText = splitIndex >= 0
          ? normalizeText(paragraphText.slice(0, splitIndex)).replace(/\\bam\\b/g, 'AM').replace(/\\bpm\\b/g, 'PM')
          : '';
        const messageText = splitIndex >= 0 ? normalizeText(paragraphText.slice(splitIndex + 3)) : paragraphText;
        const contentText = itemName && messageText.startsWith(itemName)
          ? normalizeText(messageText.slice(itemName.length))
          : messageText;

        return {
          timeText,
          itemName,
          fullText: paragraphText,
          contentText
        };
      });
    };
    const dedupeEntries = (entries) => {
      const seen = new Set();
      const results = [];
      for (const entry of entries) {
        const key = [entry.timeText, entry.itemName, entry.contentText].join('•');
        if (seen.has(key)) {
          continue;
        }
        seen.add(key);
        results.push(entry);
        if (results.length >= resolvedMaxEntries) {
          break;
        }
      }
      return results;
    };
    const isKnownEntry = (entry) => knownFullTexts.has(normalizeText(entry.fullText));
    const onlyUnknownEntries = (entries) => entries.filter((entry) => !isKnownEntry(entry));
    const findScrollableContainers = () =>
      Array.from(document.querySelectorAll('*')).filter((node) => {
        if (!(node instanceof HTMLElement)) {
          return false;
        }
        const style = window.getComputedStyle(node);
        const overflowY = style.overflowY;
        const canScroll = /(auto|scroll|overlay)/.test(overflowY) && node.scrollHeight > node.clientHeight + 48;
        return canScroll && node.querySelector('.pledge-log-entry');
      });
    const findLoadMoreButton = () =>
      Array.from(document.querySelectorAll('button, a, [role=\"button\"], input[type=\"button\"], input[type=\"submit\"]'))
        .find((node) => {
          const label = normalizeText(node.textContent || node.value || '').toLowerCase();
          return isVisible(node) && (
            label.includes('load more') ||
            label === 'more' ||
            label.includes('show more')
          );
        });
    const findHangarLogButton = () =>
      Array.from(document.querySelectorAll('button, a, [role=\"button\"], input[type=\"button\"], input[type=\"submit\"]'))
        .find((node) => {
          const label = normalizeText(node.textContent || node.value || '').toLowerCase();
          return isVisible(node) && label.includes('hangar log');
        });

    const hasAccessDeniedMarkup =
      document.title.toLowerCase().includes('access denied') ||
      document.body.innerText.includes('Access denied');

    if (hasAccessDeniedMarkup) {
      return {
        accessDenied: true,
        statusCode: 403,
        items: [],
        failureMessage: 'The RSI account page reported access denied before the hangar log request started.',
        debugSummary: null
      };
    }

    const hangarLogButton = findHangarLogButton();
    if (!hangarLogButton) {
      return {
        accessDenied: false,
        statusCode: 200,
        items: [],
        failureMessage: 'The RSI account page loaded, but the Hangar log button could not be found.',
        debugSummary: normalizeText(document.body.innerText).slice(0, 500)
      };
    }

    clickElement(hangarLogButton);

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '';
    const rsiToken = cookieValue('Rsi-Token') || cookieValue('rsi-token');
    const rsiDevice = cookieValue('_rsi_device');
    const requestHeaders = {
      'Content-Type': 'application/json;charset=UTF-8',
      'Accept': 'application/json',
      'X-Requested-With': 'XMLHttpRequest'
    };
    if (csrfToken) {
      requestHeaders['x-csrf-token'] = csrfToken;
    }
    if (rsiToken) {
      requestHeaders['x-rsi-token'] = rsiToken;
    }
    if (rsiDevice) {
      requestHeaders['x-rsi-device'] = rsiDevice;
    }

    const modalAppeared = await waitFor(
      () =>
        document.querySelector('.pledge-log-entry') ||
        document.querySelector('[class*=\"modal\"] [class*=\"pledge\"]') ||
        document.querySelector('[class*=\"overlay\"] [class*=\"pledge\"]'),
      8000,
      150
    );

    if (!modalAppeared) {
      return {
        accessDenied: false,
        statusCode: 200,
        items: [],
        failureMessage: 'RSI did not finish opening the Hangar log window.',
        debugSummary: normalizeText(document.body.innerText).slice(0, 700)
      };
    }

    let items = dedupeEntries(onlyUnknownEntries(collectEntries()));
    let stablePasses = 0;
    let pagedFetchStatus = 'not-started';
    let pagedFetchPageCount = null;
    let pagedFetchStoppedAt = 1;

    for (let index = 0; index < 80 && items.length < resolvedMaxEntries; index += 1) {
      const beforeCount = items.length;

      for (const container of findScrollableContainers()) {
        container.scrollTop = container.scrollHeight;
      }

      window.scrollTo(0, document.body.scrollHeight);
      clickElement(findLoadMoreButton());
      await wait(250);

      items = dedupeEntries(onlyUnknownEntries(collectEntries())).slice(0, resolvedMaxEntries);

      if (items.length > beforeCount) {
        stablePasses = 0;
        continue;
      }

      stablePasses += 1;
      if (stablePasses >= 4) {
        break;
      }
    }

    items = dedupeEntries(onlyUnknownEntries(collectEntries())).slice(0, resolvedMaxEntries);

    try {
      const pageOneResponse = await fetch('/api/account/pledgeLog', {
        method: 'POST',
        credentials: 'include',
        headers: requestHeaders,
        body: JSON.stringify({ page: 1 })
      });

      const pageOneRawBody = await pageOneResponse.text();
      let pageOnePayload = null;
      try {
        pageOnePayload = JSON.parse(pageOneRawBody);
      } catch {}

      if (pageOneResponse.ok && pageOnePayload?.data) {
        const apiItems = parseRenderedEntries(pageOnePayload.data.rendered);
        const pageOneHitKnown = apiItems.some(isKnownEntry);
        const pageOneNewItems = onlyUnknownEntries(apiItems);
        if (pageOneNewItems.length > 0) {
          items = dedupeEntries(pageOneNewItems.concat(items));
        }

        const reportedPageCount = Number.parseInt(String(pageOnePayload.data.pagecount || ''), 10);
        const pageCount = Number.isFinite(reportedPageCount) && reportedPageCount > 0 ? reportedPageCount : null;
        pagedFetchPageCount = pageCount;
        pagedFetchStatus = pageOneHitKnown ? 'page-1-hit-known' : 'page-1-ok';

        if (!pageOneHitKnown) {
          for (let page = 2; page <= (pageCount || 100) && items.length < resolvedMaxEntries; page += 1) {
            const response = await fetch('/api/account/pledgeLog', {
              method: 'POST',
              credentials: 'include',
              headers: requestHeaders,
              body: JSON.stringify({ page })
            });

            const rawBody = await response.text();
            let payload = null;
            try {
              payload = JSON.parse(rawBody);
            } catch {}

            if (!response.ok || !payload?.data) {
              pagedFetchStatus = `page-${page}-http-${response.status}`;
              pagedFetchStoppedAt = page;
              break;
            }

            const currentPage = Number.parseInt(String(payload.data.page || page), 10);
            const currentPageCount = Number.parseInt(String(payload.data.pagecount || pageCount || ''), 10);
            if (Number.isFinite(currentPageCount) && currentPageCount > 0) {
              pagedFetchPageCount = currentPageCount;
            }

            if (Number.isFinite(currentPage) && Number.isFinite(currentPageCount) && currentPage > currentPageCount) {
              pagedFetchStatus = `page-${page}-past-end`;
              pagedFetchStoppedAt = page;
              break;
            }

            const pageItems = parseRenderedEntries(payload.data.rendered);
            if (pageItems.length === 0) {
              pagedFetchStatus = `page-${page}-empty`;
              pagedFetchStoppedAt = page;
              break;
            }

            const pageHitKnown = pageItems.some(isKnownEntry);
            const newPageItems = onlyUnknownEntries(pageItems);
            const beforeCount = items.length;
            if (newPageItems.length > 0) {
              items = dedupeEntries(items.concat(newPageItems));
            }
            pagedFetchStoppedAt = page;

            if (pageHitKnown) {
              pagedFetchStatus = `page-${page}-hit-known`;
              break;
            }

            if (items.length === beforeCount) {
              pagedFetchStatus = `page-${page}-duplicate`;
              break;
            }

            pagedFetchStatus = `page-${page}-ok`;
          }
        }

        if (items.length >= resolvedMaxEntries) {
          pagedFetchStatus = `cap-${resolvedMaxEntries}`;
        }
      } else {
        pagedFetchStatus = `page-1-http-${pageOneResponse.status}`;
      }
    } catch (error) {
      pagedFetchStatus = `fetch-error:${normalizeText(error?.message || String(error))}`;
    }

    items = dedupeEntries(items).slice(0, resolvedMaxEntries);

    const failureMessage = items.length === 0 && knownFullTexts.size === 0
      ? 'RSI opened the Hangar log flow, but no .pledge-log-entry rows were rendered.'
      : null;

    const debugSummary = [
      `button=${normalizeText(hangarLogButton.textContent || hangarLogButton.value || '')}`,
      `entries=${items.length}`,
      `max=${resolvedMaxEntries}`,
      `knownMarkers=${knownFullTexts.size}`,
      `pagedStatus=${pagedFetchStatus}`,
      `pagedCount=${pagedFetchPageCount ?? 'unknown'}`,
      `pagedStop=${pagedFetchStoppedAt}`,
      `scrollables=${findScrollableContainers().length}`,
      `loadMoreVisible=${Boolean(findLoadMoreButton())}`,
      `body=${normalizeText(document.body.innerText).slice(0, 500)}`
    ].join(' | ');

    return {
      accessDenied: false,
      statusCode: 200,
      items,
      failureMessage,
      debugSummary
    };
    """

    private static let prepareBuybackCheckoutScript = """
    const normalizeText = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
    const cookieValue = (name) => {
      const escapedName = name.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
      const match = document.cookie.match(new RegExp('(?:^|; )' + escapedName + '=([^;]*)'));
      return match ? decodeURIComponent(match[1]) : '';
    };

    const requestedBuybackPledgeID = Number(buybackPledgeID);
    let parsedBuybackPledgeID = requestedBuybackPledgeID;
    let parsedFromShipID = Number(fromShipID);
    let parsedToShipID = Number(toShipID);
    let parsedToSkuID = Number(toSkuID);
    const buybackTitleText = normalizeText(typeof buybackTitle === 'string' ? buybackTitle : '');
    const looksLikeUpgradeBuyback = (value) => {
      const normalized = normalizeText(value).toLowerCase();
      return /\\b(?:upgrade|ccu|cross[-\\s]?chassis)\\b/.test(normalized)
        || /\\S+\\s+to\\s+\\S+/.test(normalized);
    };
    let shouldUseUpgradeBuybackFlow = isUpgradeBuyback === true && looksLikeUpgradeBuyback(buybackTitleText);

    const hasAccessDeniedMarkup =
      document.title.toLowerCase().includes('access denied') ||
      document.body.innerText.includes('Access denied');

    if (hasAccessDeniedMarkup) {
      return {
        accessDenied: true,
        status: 'access-denied',
        checkoutURL: null,
        failureMessage: 'The RSI buy-back page reported access denied before checkout preparation started.',
        debugSummary: null
      };
    }

    if (!Number.isFinite(parsedBuybackPledgeID) || parsedBuybackPledgeID <= 0) {
      return {
        accessDenied: false,
        status: 'invalid-buyback-pledge',
        checkoutURL: null,
        failureMessage: 'Hangar Express could not determine the selected buy-back pledge id.',
        debugSummary: `buybackPledgeID=${String(buybackPledgeID)}`
      };
    }

    const buybackButtonID = (button) => {
      if (!button) {
        return 0;
      }

      const href = button.getAttribute('href') || '';
      const hrefID = Number(href.split('/').filter(Boolean).pop());
      if (Number.isFinite(hrefID) && hrefID > 0) {
        return hrefID;
      }

      const dataID = Number(button.getAttribute('data-pledgeid'));
      return Number.isFinite(dataID) && dataID > 0 ? dataID : 0;
    };

    const allBuybackButtons = Array.from(document.querySelectorAll('.holosmallbtn, .js-open-ship-upgrades, a[href*="/pledge/buyback/"]'));
    const articleForButton = (button) => button?.closest?.('article.pledge') || null;
    const articleTitleForButton = (button) => {
      const article = articleForButton(button);
      return article
        ? normalizeText(article.querySelector('.information h1, h1, h2')?.textContent || '')
        : '';
    };
    const upgradeContextForButton = (button) => {
      const liveFromShipID = Number(button?.getAttribute?.('data-fromshipid'));
      const liveToShipID = Number(button?.getAttribute?.('data-toshipid'));
      const liveToSkuID = Number(button?.getAttribute?.('data-toskuid'));
      const hasLiveUpgradeContext =
        Number.isFinite(liveFromShipID) && liveFromShipID > 0 &&
        Number.isFinite(liveToShipID) && liveToShipID > 0 &&
        Number.isFinite(liveToSkuID) && liveToSkuID > 0;

      return {
        fromShipID: liveFromShipID,
        toShipID: liveToShipID,
        toSkuID: liveToSkuID,
        hasLiveUpgradeContext
      };
    };

    let selectedButton = allBuybackButtons
      .find((button) => buybackButtonID(button) === parsedBuybackPledgeID);
    if (!selectedButton && shouldUseUpgradeBuybackFlow) {
      selectedButton = allBuybackButtons.find((button) => {
        const liveContext = upgradeContextForButton(button);
        if (!liveContext.hasLiveUpgradeContext) {
          return false;
        }

        const title = articleTitleForButton(button);
        const titleMatches =
          !buybackTitleText ||
          title === buybackTitleText ||
          title.includes(buybackTitleText) ||
          buybackTitleText.includes(title);
        const contextMatches =
          liveContext.fromShipID === parsedFromShipID &&
          liveContext.toShipID === parsedToShipID &&
          liveContext.toSkuID === parsedToSkuID;

        return titleMatches && contextMatches;
      });
    }

    const selectedArticleTitle = articleTitleForButton(selectedButton);
    const selectedItemLooksLikeUpgrade = looksLikeUpgradeBuyback([buybackTitleText, selectedArticleTitle].join(' '));
    let selectedUpgradeAPIURL = '';

    if (selectedButton) {
      const livePledgeID = buybackButtonID(selectedButton);
      if (Number.isFinite(livePledgeID) && livePledgeID > 0) {
        parsedBuybackPledgeID = livePledgeID;
      }

      const liveAPIURL = normalizeText(selectedButton.getAttribute('data-apiurl') || '');
      if (liveAPIURL) {
        selectedUpgradeAPIURL = liveAPIURL;
      }

      const liveContext = upgradeContextForButton(selectedButton);
      if (liveContext.hasLiveUpgradeContext && selectedItemLooksLikeUpgrade) {
        parsedFromShipID = liveContext.fromShipID;
        parsedToShipID = liveContext.toShipID;
        parsedToSkuID = liveContext.toSkuID;
        shouldUseUpgradeBuybackFlow = true;
      }
    }

    if (shouldUseUpgradeBuybackFlow) {
      const hasValidUpgradeContext =
        Number.isFinite(parsedFromShipID) && parsedFromShipID > 0 &&
        Number.isFinite(parsedToShipID) && parsedToShipID > 0 &&
        Number.isFinite(parsedToSkuID) && parsedToSkuID > 0;

      if (!hasValidUpgradeContext) {
        return {
          accessDenied: false,
          status: 'invalid-upgrade-buyback-context',
          checkoutURL: null,
          failureMessage: 'Hangar Express could not determine the ship-upgrade metadata for this buy-back item.',
          debugSummary: `pledge=${parsedBuybackPledgeID}, fromShipID=${String(fromShipID)}, toShipID=${String(toShipID)}, toSkuID=${String(toSkuID)}`
        };
      }
    }

    const csrfToken = document.querySelector('meta[name=\"csrf-token\"]')?.getAttribute('content') || '';
    const rsiToken = cookieValue('Rsi-Token') || cookieValue('rsi-token');
    const rsiDevice = cookieValue('_rsi_device');
    const requestHeaders = {
      'Content-Type': 'application/json;charset=UTF-8',
      'Accept': 'application/json',
      'X-Requested-With': 'XMLHttpRequest'
    };

    if (csrfToken) {
      requestHeaders['x-csrf-token'] = csrfToken;
    }
    if (rsiToken) {
      requestHeaders['x-rsi-token'] = rsiToken;
    }
    if (rsiDevice) {
      requestHeaders['x-rsi-device'] = rsiDevice;
    }

    const readJSONResponse = async (response) => {
      const responseText = await response.text();
      let payload = null;
      try {
        payload = responseText ? JSON.parse(responseText) : null;
      } catch {
        payload = null;
      }

      return {
        responseText,
        payload
      };
    };

    const postJSON = async (endpoint, body, label, requiresSuccessFlag = false) => {
      const response = await fetch(endpoint, {
        method: 'POST',
        credentials: 'include',
        headers: requestHeaders,
        body: JSON.stringify(body)
      });
      const { responseText, payload } = await readJSONResponse(response);

      if (response.status === 401 || response.status === 403) {
        return {
          ok: false,
          accessDenied: true,
          failureMessage: normalizeText(payload?.msg || payload?.code || responseText || `RSI rejected ${label}.`),
          debugSummary: `${label}: httpStatus=${response.status}`
        };
      }

      const hasSuccessFlag = payload && Object.prototype.hasOwnProperty.call(payload, 'success');
      const successValue = Number(payload?.success ?? 1);
      if (!response.ok || (requiresSuccessFlag && (!hasSuccessFlag || successValue !== 1)) || (hasSuccessFlag && successValue === 0)) {
        return {
          ok: false,
          accessDenied: false,
          failureMessage: normalizeText(payload?.msg || payload?.code || responseText || `RSI returned HTTP ${response.status} while preparing ${label}.`),
          debugSummary: `${label}: httpStatus=${response.status}, responsePreview=${normalizeText(responseText).slice(0, 280) || 'n/a'}`
        };
      }

      return {
        ok: true,
        accessDenied: false,
        payload,
        debugSummary: `${label}: httpStatus=${response.status}`
      };
    };

    const checkoutURL = new URL('/en/pledge/cart', window.location.origin).toString();

    if (!shouldUseUpgradeBuybackFlow) {
      const buybackResponse = await postJSON(
        '/api/store/buyBackPledge',
        { id: parsedBuybackPledgeID },
        'buy-back cart insertion',
        true
      );

      if (!buybackResponse.ok) {
        return {
          accessDenied: buybackResponse.accessDenied,
          status: buybackResponse.accessDenied ? 'access-denied' : 'failed',
          checkoutURL: null,
          failureMessage: buybackResponse.failureMessage,
          debugSummary: `${buybackResponse.debugSummary}, csrfTokenPresent=${csrfToken ? 'yes' : 'no'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}, rsiDevicePresent=${rsiDevice ? 'yes' : 'no'}`
        };
      }

      return {
        accessDenied: false,
        status: 'ok',
        checkoutURL,
        failureMessage: null,
        debugSummary: `pledge=${parsedBuybackPledgeID}, flow=buyBackPledge, csrfTokenPresent=${csrfToken ? 'yes' : 'no'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}, rsiDevicePresent=${rsiDevice ? 'yes' : 'no'}`
      };
    }

    const authTokenResponse = await postJSON(
      '/api/account/v2/setAuthToken',
      {},
      'buy-back auth token setup'
    );
    if (!authTokenResponse.ok) {
      return {
        accessDenied: authTokenResponse.accessDenied,
        status: authTokenResponse.accessDenied ? 'access-denied' : 'failed',
        checkoutURL: null,
        failureMessage: authTokenResponse.failureMessage,
        debugSummary: authTokenResponse.debugSummary
      };
    }

    const contextResponse = await postJSON(
      '/api/ship-upgrades/setContextToken',
      {
        fromShipId: parsedFromShipID,
        pledgeId: parsedBuybackPledgeID,
        toShipId: parsedToShipID,
        toSkuId: parsedToSkuID
      },
      'buy-back upgrade context setup',
      true
    );
    if (!contextResponse.ok) {
      return {
        accessDenied: contextResponse.accessDenied,
        status: contextResponse.accessDenied ? 'access-denied' : 'failed',
        checkoutURL: null,
        failureMessage: contextResponse.failureMessage,
        debugSummary: contextResponse.debugSummary
      };
    }

    const upgradeAddToCartQuery = `mutation addToCart($from: Int!, $to: Int!) {
      addToCart(from: $from, to: $to) {
        jwt
      }
    }`;

    const upgradeGraphQLEndpoint = (() => {
      const base = (selectedUpgradeAPIURL || '/pledge-store/api/upgrade/v2').replace(/\\/+$/, '');
      return base.endsWith('/graphql') ? base : `${base}/graphql`;
    })();

    const requestUpgradeCartToken = async (targetID, targetLabel) => {
      const response = await fetch(upgradeGraphQLEndpoint, {
        method: 'POST',
        credentials: 'include',
        headers: requestHeaders,
        body: JSON.stringify({
          query: upgradeAddToCartQuery,
          variables: {
            from: parsedFromShipID,
            to: targetID
          }
        })
      });
      const body = await readJSONResponse(response);
      const errors = Array.isArray(body.payload?.errors)
        ? body.payload.errors.map((entry) => normalizeText(entry?.message || JSON.stringify(entry))).filter(Boolean)
        : [];

      return {
        response,
        body,
        errors,
        token: body.payload?.data?.addToCart?.jwt || '',
        targetID,
        targetLabel
      };
    };

    const upgradeTargetCandidates = [
      { id: parsedToSkuID, label: 'toSkuID' },
      { id: parsedToShipID, label: 'toShipID' }
    ]
      .filter((candidate) => Number.isFinite(candidate.id) && candidate.id > 0)
      .filter((candidate, index, candidates) => candidates.findIndex((entry) => entry.id === candidate.id) === index);
    const graphQLAttemptSummaries = [];
    let graphQLAttempt = null;

    for (const candidate of upgradeTargetCandidates) {
      graphQLAttempt = await requestUpgradeCartToken(candidate.id, candidate.label);
      graphQLAttemptSummaries.push(
        `${candidate.label}:${candidate.id}->${graphQLAttempt.response.status}/${graphQLAttempt.token ? 'token' : 'no-token'}`
      );

      if (graphQLAttempt.response.status === 401 || graphQLAttempt.response.status === 403) {
        break;
      }

      if (graphQLAttempt.response.ok && graphQLAttempt.errors.length === 0 && graphQLAttempt.token) {
        break;
      }
    }

    if (!graphQLAttempt) {
      return {
        accessDenied: false,
        status: 'failed',
        checkoutURL: null,
        failureMessage: 'Hangar Express could not determine the target ship metadata for this buy-back upgrade.',
        debugSummary: `upgradeGraphQL: noTargetCandidates, pledge=${parsedBuybackPledgeID}, requestedPledge=${requestedBuybackPledgeID}, endpoint=${upgradeGraphQLEndpoint}, fromShipID=${parsedFromShipID}, toShipID=${parsedToShipID}, toSkuID=${parsedToSkuID}`
      };
    }

    const graphQLResponse = graphQLAttempt.response;
    const graphQLBody = graphQLAttempt.body;
    const graphQLErrors = graphQLAttempt.errors;
    const upgradeToken = graphQLAttempt.token;
    const graphQLTargetSummary = `${graphQLAttempt.targetLabel}:${graphQLAttempt.targetID}`;
    const graphQLAttemptsSummary = graphQLAttemptSummaries.join(', ');

    if (graphQLResponse.status === 401 || graphQLResponse.status === 403) {
      return {
        accessDenied: true,
        status: 'access-denied',
        checkoutURL: null,
        failureMessage: normalizeText(graphQLBody.responseText || 'RSI rejected the buy-back upgrade cart request.'),
        debugSummary: `upgradeGraphQL: httpStatus=${graphQLResponse.status}, pledge=${parsedBuybackPledgeID}, requestedPledge=${requestedBuybackPledgeID}, endpoint=${upgradeGraphQLEndpoint}, target=${graphQLTargetSummary}, attempts=${graphQLAttemptsSummary}`
      };
    }

    if (!graphQLResponse.ok || graphQLErrors.length > 0 || !upgradeToken) {
      return {
        accessDenied: false,
        status: 'failed',
        checkoutURL: null,
        failureMessage: normalizeText(graphQLErrors.join(' ') || graphQLBody.responseText || 'RSI did not return the buy-back upgrade cart token.'),
        debugSummary: `upgradeGraphQL: httpStatus=${graphQLResponse.status}, pledge=${parsedBuybackPledgeID}, requestedPledge=${requestedBuybackPledgeID}, endpoint=${upgradeGraphQLEndpoint}, target=${graphQLTargetSummary}, attempts=${graphQLAttemptsSummary}, tokenPresent=${upgradeToken ? 'yes' : 'no'}, responsePreview=${normalizeText(graphQLBody.responseText).slice(0, 280) || 'n/a'}`
      };
    }

    const tokenResponse = await postJSON(
      '/api/store/v2/cart/token',
      { jwt: upgradeToken },
      'buy-back upgrade cart token',
      true
    );
    if (!tokenResponse.ok) {
      return {
        accessDenied: tokenResponse.accessDenied,
        status: tokenResponse.accessDenied ? 'access-denied' : 'failed',
        checkoutURL: null,
        failureMessage: tokenResponse.failureMessage,
        debugSummary: tokenResponse.debugSummary
      };
    }

    return {
      accessDenied: false,
      status: 'ok',
      checkoutURL,
      failureMessage: null,
      debugSummary: `pledge=${parsedBuybackPledgeID}, flow=upgradeBuyback, fromShipID=${parsedFromShipID}, toShipID=${parsedToShipID}, toSkuID=${parsedToSkuID}, csrfTokenPresent=${csrfToken ? 'yes' : 'no'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}, rsiDevicePresent=${rsiDevice ? 'yes' : 'no'}`
    };
    """

    private static let limitedShipAddToCartScript = """
    const normalizeText = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
    const normalizeKey = (value) => normalizeText(value).toLowerCase().replace(/&/g, ' and ').replace(/[^a-z0-9]+/g, ' ').trim();
    const compactKey = (value) => normalizeKey(value).replace(/\\s+/g, '');
    const desiredShipLabel = normalizeText(typeof shipName === 'string' ? shipName : '');
    const desiredShipName = desiredShipLabel.toLowerCase();
    const desiredShipKey = normalizeKey(desiredShipLabel);
    const desiredShipCompact = compactKey(desiredShipLabel);
    const desiredStoreURL = normalizeText(typeof storeURL === 'string' ? storeURL : '');
    const desiredStorePath = (() => {
      try {
        return desiredStoreURL ? new URL(desiredStoreURL, window.location.origin).pathname.toLowerCase() : '';
      } catch (error) {
        return '';
      }
    })();
    const desiredStoreSlug = compactKey(desiredStorePath.split('/').filter(Boolean).pop() || '');
    const maxDuration = Math.max(1000, Number(maxDurationMilliseconds) || 12000);
    const maximumAttemptCount = Math.max(0, Number(maxAttemptCount) || 0);
    const retryIntervalMinimum = Math.max(100, Number(retryIntervalMinimumMilliseconds) || 350);
    const retryIntervalMaximum = Math.max(retryIntervalMinimum, Number(retryIntervalMaximumMilliseconds) || 580);
    const nextRetryInterval = () => Math.floor(retryIntervalMinimum + Math.random() * (retryIntervalMaximum - retryIntervalMinimum + 1));
    const singleAttemptTimeout = Math.max(1000, Number(singleAttemptTimeoutMilliseconds) || 2500);
    const untrackedClickCooldown = Math.min(1200, Math.max(350, Number(untrackedClickCooldownMilliseconds) || 650));
    const cartURL = new URL('/en/pledge/cart', window.location.origin).toString();
    const debugLog = [];
    const postLog = (message) => {
      const entry = `[${new Date().toISOString()}] ${String(message || '')}`;
      debugLog.push(entry);
      try {
        window.webkit?.messageHandlers?.limitedShipCartLog?.postMessage(entry);
      } catch (error) {
        // Keep logging local even if the native bridge is unavailable.
      }
      return entry;
    };
    const waitForNextRetry = (reason) => {
      const delay = nextRetryInterval();
      postLog(`Waiting ${delay}ms before next retry${reason ? ` (${reason})` : ''}.`);
      return wait(delay);
    };

    postLog(`Initialized limited ship cart script for ship="${desiredShipLabel || 'unknown'}", maxDurationMs=${maxDuration}, maxAttemptCount=${maximumAttemptCount || 'unlimited'}, retryIntervalRangeMs=${retryIntervalMinimum}-${retryIntervalMaximum}, url=${window.location.href}, title=${document.title}`);
    postLog(`Desired store path="${desiredStorePath || 'n/a'}", desired slug="${desiredStoreSlug || 'n/a'}".`);

    const hasAccessDeniedMarkup =
      document.title.toLowerCase().includes('access denied') ||
      document.body.innerText.includes('Access denied');

    if (hasAccessDeniedMarkup) {
      postLog('Access denied markup found before cart insertion started.');
      return {
        accessDenied: true,
        status: 'access-denied',
        cartURL: null,
        attemptCount: 0,
        failureMessage: 'The RSI store page reported access denied before cart insertion started.',
        debugSummary: null,
        debugLog
      };
    }

    const wait = (milliseconds) => new Promise(resolve => setTimeout(resolve, milliseconds));
    const cartRequestTracker = (() => {
      const state = {
        pending: 0,
        observed: 0,
        lastStartedAt: 0,
        lastFinishedAt: 0,
        lastDescription: ''
      };
      const bodyText = (body) => {
        if (!body) {
          return '';
        }

        if (typeof body === 'string') {
          return body;
        }

        if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) {
          return body.toString();
        }

        if (typeof FormData !== 'undefined' && body instanceof FormData) {
          return Array.from(body.entries())
            .map(([key, value]) => `${key}=${typeof File !== 'undefined' && value instanceof File ? value.name : String(value)}`)
            .join('&');
        }

        return '';
      };
      const requestInfo = (input, init) => {
        const request = typeof Request !== 'undefined' && input instanceof Request ? input : null;
        return {
          method: normalizeText(init?.method || request?.method || 'GET').toUpperCase(),
          url: normalizeText(request?.url || (typeof input === 'string' ? input : input?.url || '')),
          body: bodyText(init?.body)
        };
      };
      const shouldTrack = (info) => {
        if (!info || info.method === 'GET' || info.method === 'HEAD') {
          return false;
        }

        const urlText = info.url.toLowerCase();
        const haystack = `${urlText} ${info.body.toLowerCase()}`;
        return haystack.includes('addtocart') ||
          haystack.includes('add_to_cart') ||
          /add\\s*to\\s*cart/.test(haystack) ||
          haystack.includes('/cart') ||
          (urlText.includes('graphql') && /cart|store|pledge|sku/.test(haystack));
      };
      const start = (info) => {
        state.pending += 1;
        state.observed += 1;
        state.lastStartedAt = Date.now();
        state.lastDescription = `${info.method} ${info.url || 'unknown url'}`.slice(0, 220);
        postLog(`Observed RSI cart request start: ${state.lastDescription}`);

        let finished = false;
        return () => {
          if (finished) {
            return;
          }

          finished = true;
          state.pending = Math.max(0, state.pending - 1);
          state.lastFinishedAt = Date.now();
          postLog(`Observed RSI cart request finish: pending=${state.pending}, request=${state.lastDescription}`);
        };
      };

      if (typeof window.fetch === 'function' && !window.fetch.__hangerExpressCartTracked) {
        const originalFetch = window.fetch.bind(window);
        const trackedFetch = (...args) => {
          const info = requestInfo(args[0], args[1]);
          if (!shouldTrack(info)) {
            return originalFetch(...args);
          }

          const finish = start(info);
          return originalFetch(...args).then(
            (value) => {
              finish();
              return value;
            },
            (error) => {
              finish();
              throw error;
            }
          );
        };
        trackedFetch.__hangerExpressCartTracked = true;
        window.fetch = trackedFetch;
      }

      if (typeof XMLHttpRequest !== 'undefined' && !XMLHttpRequest.prototype.__hangerExpressCartTracked) {
        const originalOpen = XMLHttpRequest.prototype.open;
        const originalSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(method, url) {
          this.__hangerExpressCartInfo = {
            method: normalizeText(method).toUpperCase(),
            url: normalizeText(url)
          };
          return originalOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function(body) {
          const info = {
            method: this.__hangerExpressCartInfo?.method || 'GET',
            url: this.__hangerExpressCartInfo?.url || '',
            body: bodyText(body)
          };
          const finish = shouldTrack(info) ? start(info) : null;
          if (finish) {
            this.addEventListener('loadend', finish, { once: true });
            this.addEventListener('error', finish, { once: true });
            this.addEventListener('abort', finish, { once: true });
          }

          return originalSend.apply(this, arguments);
        };
        XMLHttpRequest.prototype.__hangerExpressCartTracked = true;
      }

      return state;
    })();
    const classText = (node) => {
      const value = node?.className;
      if (!value) {
        return '';
      }

      return typeof value === 'string' ? value : String(value.baseVal || value);
    };
    const textFor = (node) => normalizeText([
      node?.textContent,
      node?.getAttribute?.('aria-label'),
      node?.getAttribute?.('title'),
      node?.getAttribute?.('value'),
      node?.getAttribute?.('data-action'),
      node?.getAttribute?.('data-cy-id'),
      classText(node)
    ].filter(Boolean).join(' '));

    const isVisible = (node) => {
      if (!node || !node.getBoundingClientRect) {
        return false;
      }

      const rect = node.getBoundingClientRect();
      const style = window.getComputedStyle(node);
      return rect.width > 0 &&
        rect.height > 0 &&
        style.visibility !== 'hidden' &&
        style.display !== 'none';
    };

    const isDisabled = (node) => {
      if (!node) {
        return true;
      }

      if (node.disabled || node.matches?.('[disabled], [aria-disabled="true"]')) {
        return true;
      }

      const label = textFor(node).toLowerCase();
      const nodeClasses = classText(node).toLowerCase();
      const disabledAncestor = node.closest?.('.disabled, .-disabled, .-isDisabled, [aria-disabled="true"]');
      return node.classList?.contains('disabled') ||
        nodeClasses.includes('-disabled') ||
        nodeClasses.includes('-isdisabled') ||
        disabledAncestor ||
        /sold\\s*out|out\\s*of\\s*stock|unavailable|not\\s*available/.test(label);
    };

    const cartCount = () => {
      const selectors = [
        '.cart-count',
        '.js-cart-count',
        '[class*="cart-count"]',
        '[data-cart-count]',
        '[aria-label*="cart" i]',
        'a[href*="/pledge/cart"]'
      ];

      const values = Array.from(document.querySelectorAll(selectors.join(',')))
        .flatMap((node) => [
          node.getAttribute?.('data-cart-count'),
          node.getAttribute?.('aria-label'),
          node.textContent
        ])
        .map((value) => String(value || '').match(/\\b(\\d+)\\b/)?.[1])
        .filter(Boolean)
        .map((value) => Number.parseInt(value, 10))
        .filter((value) => Number.isFinite(value));

      return values.length ? Math.max(...values) : null;
    };

    const initialCartCount = cartCount();
    postLog(`Initial cart count=${initialCartCount === null ? 'unknown' : initialCartCount}`);
    postLog(`Found ${document.querySelectorAll('.c-skuCard').length} RSI sku card(s) and ${document.querySelectorAll('button.a-skuButton, .c-skuCard__actions button, .m-skuDrawerContent__actionsContainer button').length} sku button candidate(s) on load.`);

    const successSignal = () => {
      if (window.location.pathname.includes('/pledge/cart')) {
        return 'cart page opened';
      }

      const pageText = normalizeText(document.body?.innerText || '').toLowerCase();
      if (/added\\s+(?:to|in)\\s+(?:your\\s+)?cart/.test(pageText)) {
        return 'added-to-cart text found';
      }

      if (/item\\s+has\\s+been\\s+added/.test(pageText) || pageText.includes('cart updated')) {
        return 'cart update text found';
      }

      if (pageText.includes('view cart') || pageText.includes('checkout now')) {
        return 'post-add cart action found';
      }

      const currentCartCount = cartCount();
      if (initialCartCount !== null && currentCartCount !== null && currentCartCount > initialCartCount) {
        return `cart count changed ${initialCartCount}->${currentCartCount}`;
      }

      return '';
    };

    const waitForAttemptResolution = async (attemptNumber) => {
      const attemptStartedAt = Date.now();
      const observedBaseline = cartRequestTracker.observed;
      let sawTrackedRequest = false;
      let didLogUntrackedWait = false;
      postLog(`Attempt ${attemptNumber}: waiting for RSI cart response before another click.`);
      await wait(250);

      while (Date.now() - attemptStartedAt <= singleAttemptTimeout) {
        const successReason = successSignal();
        if (successReason) {
          return successReason;
        }

        sawTrackedRequest = sawTrackedRequest ||
          cartRequestTracker.observed > observedBaseline ||
          cartRequestTracker.pending > 0;

        if (
          sawTrackedRequest &&
          cartRequestTracker.pending === 0 &&
          cartRequestTracker.lastFinishedAt >= attemptStartedAt &&
          Date.now() - cartRequestTracker.lastFinishedAt >= 300
        ) {
          postLog(`Attempt ${attemptNumber}: RSI cart request settled without a success signal.`);
          return '';
        }

        if (!sawTrackedRequest && !didLogUntrackedWait && Date.now() - attemptStartedAt >= untrackedClickCooldown) {
          didLogUntrackedWait = true;
          postLog(`Attempt ${attemptNumber}: no RSI cart request was observed after ${untrackedClickCooldown}ms; continuing to wait so the same click cannot overlap with a second cart insertion.`);
        }

        if (sawTrackedRequest && !didLogUntrackedWait && Date.now() - attemptStartedAt >= untrackedClickCooldown) {
          didLogUntrackedWait = true;
          postLog(`Attempt ${attemptNumber}: RSI cart request is still in flight; not sending an overlapping click.`);
        }

        await wait(150);
      }

      postLog(`Attempt ${attemptNumber}: cart response wait timed out after ${singleAttemptTimeout}ms; allowing one retry.`);
      return '';
    };

    const addToCartRegex = /\\badd\\s+to\\s+(?:cart|basket)\\b/i;
    const cartClassRegex = /(?:^|\\s)(?:a-skuButton|-shoppingCart|shoppingCart)(?:\\s|$)/i;
    const candidateSelectors = [
      'button.a-skuButton',
      '.c-skuCard__actions button',
      '.m-skuDrawerContent__actionsContainer button',
      'button[data-cy-id="button"]',
      'button',
      '[role="button"]',
      'input[type="button"]',
      'input[type="submit"]',
      '.add-to-cart',
      '.js-add-to-cart',
      '.js-add-to-customizer',
      '[data-action*="cart" i]',
      '[class*="add-to-cart" i]',
      '[class*="skuButton" i]'
    ];

    const hrefFor = (node) => {
      const anchor = node?.closest?.('a[href]') || (node?.matches?.('a[href]') ? node : null);
      return normalizeText(anchor?.getAttribute?.('href') || anchor?.href || '');
    };

    const scopeFor = (node) => node?.closest?.(
      '.c-skuCard, .m-skuDrawerContent, .c-skuDrawer, [data-rsi-component="StoreSkuWidget"], article, .pledge, .product, .card, .row, li, section, a'
    ) || node;

    const scopeTitleFor = (scope) => normalizeText(
      scope?.querySelector?.('.c-skuCard__skuTitle, [data-cy-id="sku_title"], h1, h2, h3, [class*="title" i]')?.textContent ||
      ''
    );

    const isCartIntent = (node, label) => {
      const classes = classText(node);
      return addToCartRegex.test(label) ||
        cartClassRegex.test(classes) ||
        Boolean(node?.querySelector?.('.-shoppingCart, [class*="shoppingCart" i]'));
    };

    const scopeMatchesShip = (scope, href, titleText) => {
      if (!desiredShipKey && !desiredStoreSlug) {
        return true;
      }

      const titleKey = normalizeKey(titleText);
      const titleCompact = compactKey(titleText);
      const scopeKey = normalizeKey(scope?.innerText || scope?.textContent || '');
      const scopeCompact = compactKey(scope?.innerText || scope?.textContent || '');
      const hrefPath = (() => {
        try {
          return href ? new URL(href, window.location.origin).pathname.toLowerCase() : '';
        } catch (error) {
          return href.toLowerCase();
        }
      })();
      const hrefCompact = compactKey(hrefPath);

      if (desiredShipKey && (titleKey === desiredShipKey || titleKey.includes(desiredShipKey))) {
        return true;
      }

      if (desiredShipCompact && titleCompact.includes(desiredShipCompact)) {
        return true;
      }

      if (desiredStoreSlug && hrefCompact.includes(desiredStoreSlug)) {
        return true;
      }

      return desiredShipKey ? scopeKey.includes(desiredShipKey) || scopeCompact.includes(desiredShipCompact) : false;
    };

    const findAddToCartCandidate = () => {
      const nodes = Array.from(document.querySelectorAll(candidateSelectors.join(',')));
      const candidates = nodes
        .map((node) => {
          const label = textFor(node);
          const scope = scopeFor(node);
          const href = hrefFor(node);
          const titleText = scopeTitleFor(scope);
          const shipScoped = scopeMatchesShip(scope, href, titleText);
          return {
            node,
            label,
            href,
            titleText,
            shipScoped,
            scopeText: normalizeText(scope?.innerText || scope?.textContent || '').slice(0, 220)
          };
        })
        .filter((candidate) => {
          const label = candidate.label.toLowerCase();
          return isCartIntent(candidate.node, label) &&
            isVisible(candidate.node) &&
            !isDisabled(candidate.node);
        });

      const scopedCandidates = candidates.filter((candidate) => candidate.shipScoped);
      if (scopedCandidates.length > 0) {
        return scopedCandidates[0];
      }

      return candidates.length === 1 ? candidates[0] : null;
    };

    let didApplySearchFilter = false;
    const applySearchFilterIfAvailable = () => {
      if (didApplySearchFilter || !desiredShipLabel) {
        return false;
      }

      const input = Array.from(document.querySelectorAll('input[type="search"], input[placeholder*="Search" i], input'))
        .find((candidate) => isVisible(candidate) && !candidate.disabled);
      if (!input) {
        return false;
      }

      didApplySearchFilter = true;
      const prototype = Object.getPrototypeOf(input);
      const valueSetter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
      if (valueSetter) {
        valueSetter.call(input, desiredShipLabel);
      } else {
        input.value = desiredShipLabel;
      }
      input.dispatchEvent(new InputEvent('input', { bubbles: true, cancelable: true, inputType: 'insertText', data: desiredShipLabel }));
      input.dispatchEvent(new Event('change', { bubbles: true, cancelable: true }));
      input.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, cancelable: true, key: 'Enter' }));
      postLog(`Applied RSI page search filter for "${desiredShipLabel}".`);
      return true;
    };

    const clickCandidate = (candidate) => {
      const node = candidate.node;
      node.scrollIntoView({ block: 'center', inline: 'center' });
      const rect = node.getBoundingClientRect();
      const clientX = Math.max(0, rect.left + rect.width / 2);
      const clientY = Math.max(0, rect.top + rect.height / 2);
      const target = document.elementFromPoint(clientX, clientY) || node;
      const eventOptions = { bubbles: true, cancelable: true, composed: true, view: window, clientX, clientY };
      const PointerEventConstructor = window.PointerEvent || MouseEvent;

      target.dispatchEvent(new PointerEventConstructor('pointerdown', { ...eventOptions, pointerId: 1, pointerType: 'mouse', isPrimary: true, button: 0 }));
      target.dispatchEvent(new MouseEvent('mousedown', { ...eventOptions, button: 0 }));
      target.dispatchEvent(new PointerEventConstructor('pointerup', { ...eventOptions, pointerId: 1, pointerType: 'mouse', isPrimary: true, button: 0 }));
      target.dispatchEvent(new MouseEvent('mouseup', { ...eventOptions, button: 0 }));
      target.dispatchEvent(new MouseEvent('click', { ...eventOptions, button: 0 }));
      if (target !== node) {
        node.click();
      }
    };

    let attemptCount = 0;
    let lastFailure = '';
    const startedAt = Date.now();

    while (Date.now() - startedAt <= maxDuration) {
      const successReason = successSignal();
      if (successReason) {
        postLog(`Success signal before click: ${successReason}`);
        return {
          accessDenied: false,
          status: 'ok',
          cartURL,
          attemptCount,
          failureMessage: null,
          debugSummary: `success=${successReason}, attempts=${attemptCount}, url=${window.location.href}`,
          debugLog
        };
      }

      const candidate = findAddToCartCandidate();
      if (!candidate) {
        if (applySearchFilterIfAvailable()) {
          await waitForNextRetry('after applying search filter');
          continue;
        }

        lastFailure = 'No scoped enabled Add to Cart button was found on the RSI ship page.';
        postLog(`Attempt ${attemptCount + 1}: ${lastFailure}`);
        await waitForNextRetry('no candidate found');
        continue;
      }

      attemptCount += 1;
      try {
        const buttonLabel = candidate.label.slice(0, 180);
        postLog(`Attempt ${attemptCount}: clicking candidate title="${candidate.titleText || 'n/a'}", label="${buttonLabel}", href="${candidate.href || 'n/a'}"`);
        clickCandidate(candidate);
        lastFailure = `Clicked candidate with title: ${(candidate.titleText || candidate.label).slice(0, 120)}`;
        postLog(`Attempt ${attemptCount}: click dispatched.`);
      } catch (error) {
        lastFailure = `Click failed: ${String(error && error.message ? error.message : error)}`;
        postLog(`Attempt ${attemptCount}: ${lastFailure}`);
      }

      const attemptSuccessReason = await waitForAttemptResolution(attemptCount);
      if (attemptSuccessReason) {
        postLog(`Success signal after click: ${attemptSuccessReason}`);
        return {
          accessDenied: false,
          status: 'ok',
          cartURL,
          attemptCount,
          failureMessage: null,
          debugSummary: `success=${attemptSuccessReason}, attempts=${attemptCount}, url=${window.location.href}`,
          debugLog
        };
      }

      if (maximumAttemptCount > 0 && attemptCount >= maximumAttemptCount) {
        postLog(`Reached maxAttemptCount=${maximumAttemptCount} without an RSI success signal.`);
        break;
      }

      await waitForNextRetry('after settled cart attempt');
    }

    const finalSuccessReason = successSignal();
    if (finalSuccessReason) {
      postLog(`Final success signal: ${finalSuccessReason}`);
      return {
        accessDenied: false,
        status: 'ok',
        cartURL,
        attemptCount,
        failureMessage: null,
        debugSummary: `success=${finalSuccessReason}, attempts=${attemptCount}, url=${window.location.href}`,
        debugLog
      };
    }

    postLog(`Failed before timeout. attempts=${attemptCount}, lastFailure="${lastFailure || 'none'}", url=${window.location.href}, title=${document.title}`);
    return {
      accessDenied: false,
      status: 'failed',
      cartURL: null,
      attemptCount,
      failureMessage: lastFailure || 'RSI did not show an Add to Cart success state before the retry window ended.',
      debugSummary: `attempts=${attemptCount}, durationMs=${Date.now() - startedAt}, url=${window.location.href}, title=${document.title}`,
      debugLog
    };
    """

    private static let reclaimPledgesScript = """
    const normalizeText = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
    const cookieValue = (name) => {
      const escapedName = name.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
      const match = document.cookie.match(new RegExp('(?:^|; )' + escapedName + '=([^;]*)'));
      return match ? decodeURIComponent(match[1]) : '';
    };

    const pledgeIDsToReclaim = Array.isArray(pledgeIDs)
      ? pledgeIDs
          .map((value) => Number(value))
          .filter((value) => Number.isFinite(value) && value > 0)
      : [];
    const currentPasswordValue = typeof currentPassword === 'string' ? currentPassword : '';

    const hasAccessDeniedMarkup =
      document.title.toLowerCase().includes('access denied') ||
      document.body.innerText.includes('Access denied');

    if (hasAccessDeniedMarkup) {
      return {
        accessDenied: true,
        status: 'access-denied',
        completedPledgeIDs: [],
        failedPledgeID: null,
        failureMessage: 'The RSI account page reported access denied before the melt request started.',
        debugSummary: null
      };
    }

    const csrfToken = document.querySelector('meta[name=\"csrf-token\"]')?.getAttribute('content') || '';
    const rsiToken = cookieValue('Rsi-Token') || cookieValue('rsi-token');
    const rsiDevice = cookieValue('_rsi_device');
    const requestHeaders = {
      'Content-Type': 'application/json;charset=UTF-8',
      'Accept': 'application/json',
      'X-Requested-With': 'XMLHttpRequest'
    };

    if (csrfToken) {
      requestHeaders['x-csrf-token'] = csrfToken;
    }
    if (rsiToken) {
      requestHeaders['x-rsi-token'] = rsiToken;
    }
    if (rsiDevice) {
      requestHeaders['x-rsi-device'] = rsiDevice;
    }

    const completedPledgeIDs = [];

    for (const pledgeID of pledgeIDsToReclaim) {
      const response = await fetch('/api/account/reclaimPledge', {
        method: 'POST',
        credentials: 'include',
        headers: requestHeaders,
        body: JSON.stringify({
          pledge_id: String(pledgeID),
          current_password: currentPasswordValue
        })
      });

      const responseText = await response.text();
      let payload = null;
      try {
        payload = responseText ? JSON.parse(responseText) : null;
      } catch {
        payload = null;
      }

      if (response.status === 401 || response.status === 403) {
        return {
          accessDenied: true,
          status: 'access-denied',
          completedPledgeIDs,
          failedPledgeID: pledgeID,
          failureMessage: normalizeText(payload?.msg || payload?.code || responseText || `RSI rejected the melt request for pledge ${pledgeID}.`),
          debugSummary: `httpStatus=${response.status}`
        };
      }

      const successValue = Number(payload?.success ?? 0);
      if (!response.ok || successValue !== 1) {
        return {
          accessDenied: false,
          status: completedPledgeIDs.length > 0 ? 'partial-failure' : 'failed',
          completedPledgeIDs,
          failedPledgeID: pledgeID,
          failureMessage: normalizeText(payload?.msg || payload?.code || responseText || `RSI returned HTTP ${response.status} while reclaiming pledge ${pledgeID}.`),
          debugSummary: `httpStatus=${response.status}, responsePreview=${normalizeText(responseText).slice(0, 280) || 'n/a'}`
        };
      }

      completedPledgeIDs.push(pledgeID);
    }

    return {
      accessDenied: false,
      status: 'ok',
      completedPledgeIDs,
      failedPledgeID: null,
      failureMessage: null,
      debugSummary: `requested=${pledgeIDsToReclaim.length}, completed=${completedPledgeIDs.length}, csrfTokenPresent=${csrfToken ? 'yes' : 'no'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}, rsiDevicePresent=${rsiDevice ? 'yes' : 'no'}`
    };
    """

    private static let giftPledgesScript = """
    const normalizeText = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
    const cookieValue = (name) => {
      const escapedName = name.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
      const match = document.cookie.match(new RegExp('(?:^|; )' + escapedName + '=([^;]*)'));
      return match ? decodeURIComponent(match[1]) : '';
    };

    const pledgeIDsToGift = Array.isArray(pledgeIDs)
      ? pledgeIDs
          .map((value) => Number(value))
          .filter((value) => Number.isFinite(value) && value > 0)
      : [];
    const currentPasswordValue = typeof currentPassword === 'string' ? currentPassword : '';
    const recipientEmailValue = normalizeText(recipientEmail);
    const recipientNameValue = normalizeText(recipientName);

    const hasAccessDeniedMarkup =
      document.title.toLowerCase().includes('access denied') ||
      document.body.innerText.includes('Access denied');

    if (hasAccessDeniedMarkup) {
      return {
        accessDenied: true,
        status: 'access-denied',
        completedPledgeIDs: [],
        failedPledgeID: null,
        failureMessage: 'The RSI account page reported access denied before the gift request started.',
        debugSummary: null
      };
    }

    const csrfToken = document.querySelector('meta[name=\"csrf-token\"]')?.getAttribute('content') || '';
    const rsiToken = cookieValue('Rsi-Token') || cookieValue('rsi-token');
    const rsiDevice = cookieValue('_rsi_device');
    const requestHeaders = {
      'Content-Type': 'application/json;charset=UTF-8',
      'Accept': 'application/json',
      'X-Requested-With': 'XMLHttpRequest'
    };

    if (csrfToken) {
      requestHeaders['x-csrf-token'] = csrfToken;
    }
    if (rsiToken) {
      requestHeaders['x-rsi-token'] = rsiToken;
    }
    if (rsiDevice) {
      requestHeaders['x-rsi-device'] = rsiDevice;
    }

    const completedPledgeIDs = [];

    for (const pledgeID of pledgeIDsToGift) {
      const response = await fetch('/api/account/giftPledge', {
        method: 'POST',
        credentials: 'include',
        headers: requestHeaders,
        body: JSON.stringify({
          pledge_id: String(pledgeID),
          current_password: currentPasswordValue,
          email: recipientEmailValue,
          name: recipientNameValue
        })
      });

      const responseText = await response.text();
      let payload = null;
      try {
        payload = responseText ? JSON.parse(responseText) : null;
      } catch {
        payload = null;
      }

      if (response.status === 401 || response.status === 403) {
        return {
          accessDenied: true,
          status: 'access-denied',
          completedPledgeIDs,
          failedPledgeID: pledgeID,
          failureMessage: normalizeText(payload?.msg || payload?.code || responseText || `RSI rejected the gift request for pledge ${pledgeID}.`),
          debugSummary: `httpStatus=${response.status}`
        };
      }

      const successValue = Number(payload?.success ?? 0);
      if (!response.ok || successValue !== 1) {
        return {
          accessDenied: false,
          status: completedPledgeIDs.length > 0 ? 'partial-failure' : 'failed',
          completedPledgeIDs,
          failedPledgeID: pledgeID,
          failureMessage: normalizeText(payload?.msg || payload?.code || responseText || `RSI returned HTTP ${response.status} while gifting pledge ${pledgeID}.`),
          debugSummary: `httpStatus=${response.status}, responsePreview=${normalizeText(responseText).slice(0, 280) || 'n/a'}`
        };
      }

      completedPledgeIDs.push(pledgeID);
    }

    return {
      accessDenied: false,
      status: 'ok',
      completedPledgeIDs,
      failedPledgeID: null,
      failureMessage: null,
      debugSummary: `requested=${pledgeIDsToGift.length}, completed=${completedPledgeIDs.length}, csrfTokenPresent=${csrfToken ? 'yes' : 'no'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}, rsiDevicePresent=${rsiDevice ? 'yes' : 'no'}`
    };
    """

    private static let chooseUpgradeTargetsScript = """
    const normalizeText = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
    const cookieValue = (name) => {
      const escapedName = name.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
      const match = document.cookie.match(new RegExp('(?:^|; )' + escapedName + '=([^;]*)'));
      return match ? decodeURIComponent(match[1]) : '';
    };

    const parsedUpgradeItemPledgeID = Number(upgradeItemPledgeID);
    const hasAccessDeniedMarkup =
      document.title.toLowerCase().includes('access denied') ||
      document.body.innerText.includes('Access denied');

    if (hasAccessDeniedMarkup) {
      return {
        accessDenied: true,
        status: 'access-denied',
        candidates: [],
        failureMessage: 'The RSI account page reported access denied before the upgrade target lookup started.',
        debugSummary: null
      };
    }

    if (!Number.isFinite(parsedUpgradeItemPledgeID) || parsedUpgradeItemPledgeID <= 0) {
      return {
        accessDenied: false,
        status: 'invalid-upgrade-item',
        candidates: [],
        failureMessage: 'Hangar Express could not determine the selected owned upgrade item id.',
        debugSummary: `upgradeItemPledgeID=${String(upgradeItemPledgeID)}`
      };
    }

    const csrfToken = document.querySelector('meta[name=\"csrf-token\"]')?.getAttribute('content') || '';
    const rsiToken = cookieValue('Rsi-Token') || cookieValue('rsi-token');
    const rsiDevice = cookieValue('_rsi_device');
    const requestHeaders = {
      'Content-Type': 'application/json;charset=UTF-8',
      'Accept': 'application/json',
      'X-Requested-With': 'XMLHttpRequest'
    };

    if (csrfToken) {
      requestHeaders['x-csrf-token'] = csrfToken;
    }
    if (rsiToken) {
      requestHeaders['x-rsi-token'] = rsiToken;
    }
    if (rsiDevice) {
      requestHeaders['x-rsi-device'] = rsiDevice;
    }

    const response = await fetch('/api/account/chooseUpgradeTarget', {
      method: 'POST',
      credentials: 'include',
      headers: requestHeaders,
      body: JSON.stringify({
        upgrade_id: String(parsedUpgradeItemPledgeID)
      })
    });

    const responseText = await response.text();
    let payload = null;
    try {
      payload = responseText ? JSON.parse(responseText) : null;
    } catch {
      payload = null;
    }

    if (response.status === 401 || response.status === 403) {
      return {
        accessDenied: true,
        status: 'access-denied',
        candidates: [],
        failureMessage: normalizeText(payload?.msg || payload?.code || responseText || `RSI rejected the upgrade target lookup for pledge ${parsedUpgradeItemPledgeID}.`),
        debugSummary: `httpStatus=${response.status}`
      };
    }

    const successValue = Number(payload?.success ?? 0);
    if (!response.ok || successValue !== 1) {
      return {
        accessDenied: false,
        status: 'failed',
        candidates: [],
        failureMessage: normalizeText(payload?.msg || payload?.code || responseText || `RSI returned HTTP ${response.status} while loading upgrade targets for pledge ${parsedUpgradeItemPledgeID}.`),
        debugSummary: `httpStatus=${response.status}, responsePreview=${normalizeText(responseText).slice(0, 280) || 'n/a'}`
      };
    }

    const renderedHTML = payload?.data?.rendered || '';
    const documentFragment = new DOMParser().parseFromString(renderedHTML, 'text/html');
    const candidates = Array.from(documentFragment.querySelectorAll('div.row'))
      .map((row) => {
        const inputValue = row.querySelector('input')?.getAttribute('value') || '';
        const parsedPledgeID = Number.parseInt(inputValue, 10);
        const title = normalizeText(row.querySelector('span')?.textContent || row.textContent || '');
        if (!Number.isFinite(parsedPledgeID) || parsedPledgeID <= 0 || !title) {
          return null;
        }

        return {
          pledgeID: parsedPledgeID,
          title
        };
      })
      .filter(Boolean);

    return {
      accessDenied: false,
      status: 'ok',
      candidates,
      failureMessage: null,
      debugSummary: `upgradeItemPledgeID=${parsedUpgradeItemPledgeID}, candidateCount=${candidates.length}, csrfTokenPresent=${csrfToken ? 'yes' : 'no'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}, rsiDevicePresent=${rsiDevice ? 'yes' : 'no'}`
    };
    """

    private static let authorizedDevicesExtractionScript = """
    const normalizeText = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
    const currentPasswordValue = typeof currentPassword === 'string' ? currentPassword : '';
    const cookieValue = (name) => {
      const escapedName = name.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
      const match = document.cookie.match(new RegExp('(?:^|; )' + escapedName + '=([^;]*)'));
      return match ? decodeURIComponent(match[1]) : '';
    };
    const isPasswordConfirmationRequired = (payload, responseText) => {
      const raw = normalizeText([
        payload?.code,
        payload?.msg,
        payload?.message,
        responseText
      ].filter(Boolean).join(' ')).toLowerCase();
      return raw.includes('errpassword-confirmationrequired') ||
        raw.includes('password confirmation required');
    };
    const deviceContainer = document.querySelector('.js-devices');
    let currentDeviceID = normalizeText(
      deviceContainer?.dataset?.current ||
      deviceContainer?.getAttribute('data-current') ||
      ''
    );
    const hasAccessDeniedMarkup =
      document.title.toLowerCase().includes('access denied') ||
      document.body.innerText.includes('Access denied');

    if (hasAccessDeniedMarkup) {
      return {
        accessDenied: true,
        status: 'access-denied',
        devices: [],
        failureMessage: 'The RSI security page reported access denied before the authorized-device request started.',
        debugSummary: null
      };
    }

    const csrfToken = document.querySelector('meta[name=\"csrf-token\"]')?.getAttribute('content') || '';
    const rsiToken = cookieValue('Rsi-Token') || cookieValue('rsi-token');
    const rsiDevice = cookieValue('_rsi_device');
    const requestHeaders = {
      'Content-Type': 'application/json;charset=UTF-8',
      'Accept': 'application/json',
      'X-Requested-With': 'XMLHttpRequest'
    };

    if (csrfToken) {
      requestHeaders['x-csrf-token'] = csrfToken;
    }
    if (rsiToken) {
      requestHeaders['x-rsi-token'] = rsiToken;
    }
    if (rsiDevice) {
      requestHeaders['x-rsi-device'] = rsiDevice;
    }

    const confirmPassword = async () => {
      if (!currentPasswordValue) {
        return {
          ok: false,
          failureMessage: 'RSI requires password confirmation before showing logged-in devices. Sign in again with saved credentials, then try again.',
          debugSummary: 'passwordConfirmationRequired=yes, passwordPresent=no'
        };
      }

      const formBody = new URLSearchParams();
      formBody.set('password', currentPasswordValue);
      const confirmHeaders = {
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        'X-Requested-With': 'XMLHttpRequest'
      };
      if (rsiToken) {
        confirmHeaders['x-rsi-token'] = rsiToken;
      }

      const response = await fetch('/api/account/validatePassword', {
        method: 'POST',
        credentials: 'include',
        headers: confirmHeaders,
        body: formBody.toString()
      });
      const responseText = await response.text();
      let payload = null;
      try {
        payload = responseText ? JSON.parse(responseText) : null;
      } catch {
        payload = null;
      }
      const successValue = Number(payload?.success ?? 0);
      if (!response.ok || successValue !== 1) {
        return {
          ok: false,
          failureMessage: normalizeText(payload?.msg || payload?.code || responseText || 'RSI rejected password confirmation for logged-in devices.'),
          debugSummary: `passwordConfirmation: httpStatus=${response.status}, responsePreview=${normalizeText(responseText).slice(0, 280) || 'n/a'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}`
        };
      }

      return {
        ok: true,
        failureMessage: null,
        debugSummary: `passwordConfirmation: httpStatus=${response.status}`
      };
    };

    const refreshCurrentDeviceID = async () => {
      const response = await fetch(window.location.pathname, {
        method: 'GET',
        credentials: 'include',
        headers: {
          'Accept': 'text/html'
        }
      });
      if (!response.ok) {
        return;
      }

      const html = await response.text();
      const parsed = new DOMParser().parseFromString(html, 'text/html');
      const refreshedContainer = parsed.querySelector('.js-devices');
      currentDeviceID = normalizeText(
        refreshedContainer?.dataset?.current ||
        refreshedContainer?.getAttribute('data-current') ||
        currentDeviceID
      );
    };

    const fetchPage = async (page) => {
      const response = await fetch('/api/account/getDevices', {
        method: 'POST',
        credentials: 'include',
        headers: requestHeaders,
        body: JSON.stringify({ page: String(page) })
      });
      const responseText = await response.text();
      let payload = null;
      try {
        payload = responseText ? JSON.parse(responseText) : null;
      } catch {
        payload = null;
      }
      return { response, responseText, payload };
    };

    const devices = [];
    const seenDeviceIDs = new Set();
    let page = 1;
    let pageCount = 1;
    let firstResponseStatus = 0;
    let lastResponsePreview = '';
    let didConfirmPassword = false;
    let passwordConfirmationDebug = '';

    while (page <= pageCount && page <= 50) {
      const { response, responseText, payload } = await fetchPage(page);
      if (page === 1) {
        firstResponseStatus = response.status;
      }
      lastResponsePreview = normalizeText(responseText).slice(0, 280);

      if (response.status === 401 || response.status === 403) {
        return {
          accessDenied: true,
          status: 'access-denied',
          devices: [],
          failureMessage: normalizeText(payload?.msg || payload?.code || responseText || 'RSI rejected the authorized-device request.'),
          debugSummary: `httpStatus=${response.status}`
        };
      }

      const successValue = Number(payload?.success ?? 0);
      if (!response.ok || successValue !== 1) {
        if (isPasswordConfirmationRequired(payload, responseText) && !didConfirmPassword) {
          const confirmation = await confirmPassword();
          didConfirmPassword = true;
          passwordConfirmationDebug = confirmation.debugSummary || '';
          if (!confirmation.ok) {
            return {
              accessDenied: false,
              status: 'password-confirmation-required',
              devices: [],
              failureMessage: confirmation.failureMessage,
              debugSummary: `httpStatus=${response.status}, responsePreview=${lastResponsePreview || 'n/a'}, ${passwordConfirmationDebug}, csrfTokenPresent=${csrfToken ? 'yes' : 'no'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}, rsiDevicePresent=${rsiDevice ? 'yes' : 'no'}`
            };
          }
          await refreshCurrentDeviceID();
          continue;
        }

        return {
          accessDenied: false,
          status: 'failed',
          devices: [],
          failureMessage: normalizeText(payload?.msg || payload?.code || responseText || `RSI returned HTTP ${response.status} while loading authorized devices.`),
          debugSummary: `httpStatus=${response.status}, responsePreview=${lastResponsePreview || 'n/a'}, ${passwordConfirmationDebug}, csrfTokenPresent=${csrfToken ? 'yes' : 'no'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}, rsiDevicePresent=${rsiDevice ? 'yes' : 'no'}`
        };
      }

      const data = payload?.data || {};
      const resultset = Array.isArray(data.resultset) ? data.resultset : [];
      for (const item of resultset) {
        const id = normalizeText(item?.id);
        if (!id || seenDeviceIDs.has(id)) {
          continue;
        }

        seenDeviceIDs.add(id);
        devices.push({
          id,
          name: normalizeText(item?.name),
          type: normalizeText(item?.type) || null,
          createdAtLabel: normalizeText(item?.time_created)?.replace(' - ', ' ') || null,
          duration: normalizeText(item?.duration) || null,
          isCurrent: currentDeviceID ? id === currentDeviceID : false
        });
      }

      const parsedPage = Number.parseInt(data.page || page, 10);
      const parsedPageCount = Number.parseInt(data.pagecount || data.page_count || pageCount, 10);
      page = Number.isFinite(parsedPage) ? parsedPage + 1 : page + 1;
      pageCount = Number.isFinite(parsedPageCount) && parsedPageCount > 0 ? parsedPageCount : pageCount;
    }

    return {
      accessDenied: false,
      status: 'ok',
      devices,
      failureMessage: null,
      debugSummary: `deviceCount=${devices.length}, currentDeviceID=${currentDeviceID || 'unknown'}, firstHttpStatus=${firstResponseStatus || 'n/a'}, passwordConfirmed=${didConfirmPassword ? 'yes' : 'no'}, csrfTokenPresent=${csrfToken ? 'yes' : 'no'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}, rsiDevicePresent=${rsiDevice ? 'yes' : 'no'}`
    };
    """

    private static let removeAuthorizedDeviceScript = """
    const normalizeText = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
    const currentPasswordValue = typeof currentPassword === 'string' ? currentPassword : '';
    const cookieValue = (name) => {
      const escapedName = name.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
      const match = document.cookie.match(new RegExp('(?:^|; )' + escapedName + '=([^;]*)'));
      return match ? decodeURIComponent(match[1]) : '';
    };
    const isPasswordConfirmationRequired = (payload, responseText) => {
      const raw = normalizeText([
        payload?.code,
        payload?.msg,
        payload?.message,
        responseText
      ].filter(Boolean).join(' ')).toLowerCase();
      return raw.includes('errpassword-confirmationrequired') ||
        raw.includes('password confirmation required');
    };
    const targetDeviceID = normalizeText(deviceID);
    const targetDeviceName = normalizeText(deviceName);
    const hasAccessDeniedMarkup =
      document.title.toLowerCase().includes('access denied') ||
      document.body.innerText.includes('Access denied');

    if (hasAccessDeniedMarkup) {
      return {
        accessDenied: true,
        status: 'access-denied',
        failureMessage: 'The RSI security page reported access denied before the authorized-device removal request started.',
        debugSummary: null
      };
    }

    if (!targetDeviceID) {
      return {
        accessDenied: false,
        status: 'invalid-device',
        failureMessage: 'Hangar Express could not determine which authorized device to remove.',
        debugSummary: `deviceID=${String(deviceID || '')}`
      };
    }

    const csrfToken = document.querySelector('meta[name=\"csrf-token\"]')?.getAttribute('content') || '';
    const rsiToken = cookieValue('Rsi-Token') || cookieValue('rsi-token');
    const rsiDevice = cookieValue('_rsi_device');
    const requestHeaders = {
      'Content-Type': 'application/json;charset=UTF-8',
      'Accept': 'application/json',
      'X-Requested-With': 'XMLHttpRequest'
    };

    if (csrfToken) {
      requestHeaders['x-csrf-token'] = csrfToken;
    }
    if (rsiToken) {
      requestHeaders['x-rsi-token'] = rsiToken;
    }
    if (rsiDevice) {
      requestHeaders['x-rsi-device'] = rsiDevice;
    }

    const confirmPassword = async () => {
      if (!currentPasswordValue) {
        return {
          ok: false,
          failureMessage: 'RSI requires password confirmation before removing logged-in devices. Sign in again with saved credentials, then try again.',
          debugSummary: 'passwordConfirmationRequired=yes, passwordPresent=no'
        };
      }

      const formBody = new URLSearchParams();
      formBody.set('password', currentPasswordValue);
      const confirmHeaders = {
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        'X-Requested-With': 'XMLHttpRequest'
      };
      if (rsiToken) {
        confirmHeaders['x-rsi-token'] = rsiToken;
      }

      const response = await fetch('/api/account/validatePassword', {
        method: 'POST',
        credentials: 'include',
        headers: confirmHeaders,
        body: formBody.toString()
      });
      const responseText = await response.text();
      let payload = null;
      try {
        payload = responseText ? JSON.parse(responseText) : null;
      } catch {
        payload = null;
      }
      const successValue = Number(payload?.success ?? 0);
      if (!response.ok || successValue !== 1) {
        return {
          ok: false,
          failureMessage: normalizeText(payload?.msg || payload?.code || responseText || 'RSI rejected password confirmation for logged-in devices.'),
          debugSummary: `passwordConfirmation: httpStatus=${response.status}, responsePreview=${normalizeText(responseText).slice(0, 280) || 'n/a'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}`
        };
      }

      return {
        ok: true,
        failureMessage: null,
        debugSummary: `passwordConfirmation: httpStatus=${response.status}`
      };
    };

    const postRemoval = async () => {
      const response = await fetch('/api/account/removeDevice', {
        method: 'POST',
        credentials: 'include',
        headers: requestHeaders,
        body: JSON.stringify({
          id: targetDeviceID,
          name: targetDeviceName
        })
      });
      const responseText = await response.text();
      let payload = null;
      try {
        payload = responseText ? JSON.parse(responseText) : null;
      } catch {
        payload = null;
      }
      return { response, responseText, payload };
    };

    let { response, responseText, payload } = await postRemoval();
    let didConfirmPassword = false;
    let passwordConfirmationDebug = '';

    if (response.status === 401 || response.status === 403) {
      return {
        accessDenied: true,
        status: 'access-denied',
        failureMessage: normalizeText(payload?.msg || payload?.code || responseText || `RSI rejected removal for authorized device ${targetDeviceID}.`),
        debugSummary: `httpStatus=${response.status}`
      };
    }

    const successValue = Number(payload?.success ?? 0);
    if (!response.ok || successValue !== 1) {
      if (isPasswordConfirmationRequired(payload, responseText)) {
        const confirmation = await confirmPassword();
        didConfirmPassword = true;
        passwordConfirmationDebug = confirmation.debugSummary || '';
        if (!confirmation.ok) {
          return {
            accessDenied: false,
            status: 'password-confirmation-required',
            failureMessage: confirmation.failureMessage,
            debugSummary: `httpStatus=${response.status}, responsePreview=${normalizeText(responseText).slice(0, 280) || 'n/a'}, ${passwordConfirmationDebug}, csrfTokenPresent=${csrfToken ? 'yes' : 'no'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}, rsiDevicePresent=${rsiDevice ? 'yes' : 'no'}`
          };
        }

        ({ response, responseText, payload } = await postRemoval());
        if (response.status === 401 || response.status === 403) {
          return {
            accessDenied: true,
            status: 'access-denied',
            failureMessage: normalizeText(payload?.msg || payload?.code || responseText || `RSI rejected removal for authorized device ${targetDeviceID}.`),
            debugSummary: `httpStatus=${response.status}, ${passwordConfirmationDebug}`
          };
        }
      }
    }

    const retrySuccessValue = Number(payload?.success ?? 0);
    if (!response.ok || retrySuccessValue !== 1) {
      return {
        accessDenied: false,
        status: 'failed',
        failureMessage: normalizeText(payload?.msg || payload?.code || responseText || `RSI returned HTTP ${response.status} while removing authorized device ${targetDeviceID}.`),
        debugSummary: `httpStatus=${response.status}, responsePreview=${normalizeText(responseText).slice(0, 280) || 'n/a'}, ${passwordConfirmationDebug}, csrfTokenPresent=${csrfToken ? 'yes' : 'no'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}, rsiDevicePresent=${rsiDevice ? 'yes' : 'no'}`
      };
    }

    return {
      accessDenied: false,
      status: 'ok',
      failureMessage: null,
      debugSummary: `deviceID=${targetDeviceID}, passwordConfirmed=${didConfirmPassword ? 'yes' : 'no'}, csrfTokenPresent=${csrfToken ? 'yes' : 'no'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}, rsiDevicePresent=${rsiDevice ? 'yes' : 'no'}`
    };
    """

    private static let removeAuthorizedDevicesScript = """
    const normalizeText = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
    const currentPasswordValue = typeof currentPassword === 'string' ? currentPassword : '';
    const cookieValue = (name) => {
      const escapedName = name.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
      const match = document.cookie.match(new RegExp('(?:^|; )' + escapedName + '=([^;]*)'));
      return match ? decodeURIComponent(match[1]) : '';
    };
    const isPasswordConfirmationRequired = (payload, responseText) => {
      const raw = normalizeText([
        payload?.code,
        payload?.msg,
        payload?.message,
        responseText
      ].filter(Boolean).join(' ')).toLowerCase();
      return raw.includes('errpassword-confirmationrequired') ||
        raw.includes('password confirmation required');
    };
    const targetDevices = Array.isArray(devicesToRemove)
      ? devicesToRemove
          .map((device) => ({
            id: normalizeText(device?.id),
            name: normalizeText(device?.name)
          }))
          .filter((device) => device.id)
      : [];
    const hasAccessDeniedMarkup =
      document.title.toLowerCase().includes('access denied') ||
      document.body.innerText.includes('Access denied');

    if (hasAccessDeniedMarkup) {
      return {
        accessDenied: true,
        status: 'access-denied',
        completedDeviceIDs: [],
        failedDeviceID: null,
        failureMessage: 'The RSI security page reported access denied before the authorized-device removal request started.',
        debugSummary: null
      };
    }

    if (targetDevices.length === 0) {
      return {
        accessDenied: false,
        status: 'invalid-device',
        completedDeviceIDs: [],
        failedDeviceID: null,
        failureMessage: 'Hangar Express could not determine which authorized devices to remove.',
        debugSummary: `deviceCount=${Array.isArray(devicesToRemove) ? devicesToRemove.length : 0}`
      };
    }

    const csrfToken = document.querySelector('meta[name=\"csrf-token\"]')?.getAttribute('content') || '';
    const rsiToken = cookieValue('Rsi-Token') || cookieValue('rsi-token');
    const rsiDevice = cookieValue('_rsi_device');
    const requestHeaders = {
      'Content-Type': 'application/json;charset=UTF-8',
      'Accept': 'application/json',
      'X-Requested-With': 'XMLHttpRequest'
    };

    if (csrfToken) {
      requestHeaders['x-csrf-token'] = csrfToken;
    }
    if (rsiToken) {
      requestHeaders['x-rsi-token'] = rsiToken;
    }
    if (rsiDevice) {
      requestHeaders['x-rsi-device'] = rsiDevice;
    }

    const confirmPassword = async () => {
      if (!currentPasswordValue) {
        return {
          ok: false,
          failureMessage: 'RSI requires password confirmation before removing logged-in devices. Sign in again with saved credentials, then try again.',
          debugSummary: 'passwordConfirmationRequired=yes, passwordPresent=no'
        };
      }

      const formBody = new URLSearchParams();
      formBody.set('password', currentPasswordValue);
      const confirmHeaders = {
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        'X-Requested-With': 'XMLHttpRequest'
      };
      if (rsiToken) {
        confirmHeaders['x-rsi-token'] = rsiToken;
      }

      const response = await fetch('/api/account/validatePassword', {
        method: 'POST',
        credentials: 'include',
        headers: confirmHeaders,
        body: formBody.toString()
      });
      const responseText = await response.text();
      let payload = null;
      try {
        payload = responseText ? JSON.parse(responseText) : null;
      } catch {
        payload = null;
      }
      const successValue = Number(payload?.success ?? 0);
      if (!response.ok || successValue !== 1) {
        return {
          ok: false,
          failureMessage: normalizeText(payload?.msg || payload?.code || responseText || 'RSI rejected password confirmation for logged-in devices.'),
          debugSummary: `passwordConfirmation: httpStatus=${response.status}, responsePreview=${normalizeText(responseText).slice(0, 280) || 'n/a'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}`
        };
      }

      return {
        ok: true,
        failureMessage: null,
        debugSummary: `passwordConfirmation: httpStatus=${response.status}`
      };
    };

    const postRemoval = async (device) => {
      const response = await fetch('/api/account/removeDevice', {
        method: 'POST',
        credentials: 'include',
        headers: requestHeaders,
        body: JSON.stringify({
          id: device.id,
          name: device.name
        })
      });
      const responseText = await response.text();
      let payload = null;
      try {
        payload = responseText ? JSON.parse(responseText) : null;
      } catch {
        payload = null;
      }
      return { response, responseText, payload };
    };

    const completedDeviceIDs = [];
    let didConfirmPassword = false;
    let passwordConfirmationDebug = '';

    for (const device of targetDevices) {
      let { response, responseText, payload } = await postRemoval(device);
      if (response.status === 401 || response.status === 403) {
        return {
          accessDenied: true,
          status: 'access-denied',
          completedDeviceIDs,
          failedDeviceID: device.id,
          failureMessage: normalizeText(payload?.msg || payload?.code || responseText || `RSI rejected removal for authorized device ${device.id}.`),
          debugSummary: `httpStatus=${response.status}, completed=${completedDeviceIDs.length}`
        };
      }

      let successValue = Number(payload?.success ?? 0);
      if ((!response.ok || successValue !== 1) && isPasswordConfirmationRequired(payload, responseText) && !didConfirmPassword) {
        const confirmation = await confirmPassword();
        didConfirmPassword = true;
        passwordConfirmationDebug = confirmation.debugSummary || '';
        if (!confirmation.ok) {
          return {
            accessDenied: false,
            status: completedDeviceIDs.length > 0 ? 'partial-failure' : 'password-confirmation-required',
            completedDeviceIDs,
            failedDeviceID: device.id,
            failureMessage: confirmation.failureMessage,
            debugSummary: `httpStatus=${response.status}, responsePreview=${normalizeText(responseText).slice(0, 280) || 'n/a'}, completed=${completedDeviceIDs.length}, ${passwordConfirmationDebug}, csrfTokenPresent=${csrfToken ? 'yes' : 'no'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}, rsiDevicePresent=${rsiDevice ? 'yes' : 'no'}`
          };
        }

        ({ response, responseText, payload } = await postRemoval(device));
        if (response.status === 401 || response.status === 403) {
          return {
            accessDenied: true,
            status: 'access-denied',
            completedDeviceIDs,
            failedDeviceID: device.id,
            failureMessage: normalizeText(payload?.msg || payload?.code || responseText || `RSI rejected removal for authorized device ${device.id}.`),
            debugSummary: `httpStatus=${response.status}, completed=${completedDeviceIDs.length}, ${passwordConfirmationDebug}`
          };
        }
      }

      successValue = Number(payload?.success ?? 0);
      if (!response.ok || successValue !== 1) {
        return {
          accessDenied: false,
          status: completedDeviceIDs.length > 0 ? 'partial-failure' : 'failed',
          completedDeviceIDs,
          failedDeviceID: device.id,
          failureMessage: normalizeText(payload?.msg || payload?.code || responseText || `RSI returned HTTP ${response.status} while removing authorized device ${device.id}.`),
          debugSummary: `httpStatus=${response.status}, responsePreview=${normalizeText(responseText).slice(0, 280) || 'n/a'}, completed=${completedDeviceIDs.length}, ${passwordConfirmationDebug}, csrfTokenPresent=${csrfToken ? 'yes' : 'no'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}, rsiDevicePresent=${rsiDevice ? 'yes' : 'no'}`
        };
      }

      completedDeviceIDs.push(device.id);
    }

    return {
      accessDenied: false,
      status: 'ok',
      completedDeviceIDs,
      failedDeviceID: null,
      failureMessage: null,
      debugSummary: `requested=${targetDevices.length}, completed=${completedDeviceIDs.length}, passwordConfirmed=${didConfirmPassword ? 'yes' : 'no'}, csrfTokenPresent=${csrfToken ? 'yes' : 'no'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}, rsiDevicePresent=${rsiDevice ? 'yes' : 'no'}`
    };
    """

    private static let requestCharacterRepairScript = """
    const normalizeText = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
    const repairReason = typeof reason === 'string' && reason.trim() ? reason.trim() : 'Character reset';
    const issueCouncilValue = typeof issueCouncilURL === 'string' ? issueCouncilURL.trim() : '';
    const currentPasswordValue = typeof currentPassword === 'string' ? currentPassword : '';
    const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

    const hasAccessDeniedMarkup =
      document.title.toLowerCase().includes('access denied') ||
      document.body.innerText.includes('Access denied');

    if (hasAccessDeniedMarkup) {
      return {
        accessDenied: true,
        status: 'access-denied',
        failureMessage: 'The RSI character repair page reported access denied before the request started.',
        debugSummary: null
      };
    }

    if (!currentPasswordValue) {
      return {
        accessDenied: false,
        status: 'missing-password',
        failureMessage: 'Hangar Express does not have a saved RSI password for the character repair request.',
        debugSummary: 'passwordPresent=no'
      };
    }

    const isVisible = (element) => {
      if (!element) {
        return false;
      }
      const style = window.getComputedStyle(element);
      if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) {
        return false;
      }
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };

    const setFieldValue = (element, value) => {
      if (!element) {
        return false;
      }
      element.focus?.();
      element.value = value;
      element.dispatchEvent(new Event('input', { bubbles: true }));
      element.dispatchEvent(new Event('change', { bubbles: true }));
      return true;
    };

    const findRequestRepairButton = () => {
      const preferred = document.querySelector('.js-reset-account');
      if (preferred) {
        return preferred;
      }

      return Array.from(document.querySelectorAll('a, button'))
        .find((element) => normalizeText(element.textContent).toLowerCase() === 'request repair') || null;
    };

    const findRepairForm = () => {
      const forms = Array.from(document.querySelectorAll('form[name="reset-account"], form[action*="/account/reset"]'))
        .filter((form) =>
          form.querySelector('[name="reason"]') &&
          form.querySelector('[name="link_council_report"]') &&
          form.querySelector('[name="current_password"]')
        );

      if (!forms.length) {
        return null;
      }

      const visibleForms = forms.filter(isVisible);
      const candidates = visibleForms.length ? visibleForms : forms;
      return candidates.find((form) => {
        const action = normalizeText(form.getAttribute('action') || form.action || '');
        return action.includes('/account/reset') || action === '';
      }) || candidates[candidates.length - 1];
    };

    const requestButton = findRequestRepairButton();
    if (requestButton) {
      requestButton.click();
    }

    let form = null;
    for (let attempt = 0; attempt < 25; attempt += 1) {
      form = findRepairForm();
      if (form) {
        break;
      }
      await wait(100);
    }

    if (!form) {
      return {
        accessDenied: false,
        status: 'missing-form',
        failureMessage: 'Hangar Express could not find the RSI character repair request form.',
        debugSummary: normalizeText(document.body.innerText).slice(0, 700)
      };
    }

    const reasonField = form.querySelector('[name="reason"]');
    const issueCouncilField = form.querySelector('[name="link_council_report"]');
    const passwordField = form.querySelector('[name="current_password"]');
    setFieldValue(reasonField, repairReason);
    setFieldValue(issueCouncilField, issueCouncilValue);
    setFieldValue(passwordField, currentPasswordValue);

    const formData = new FormData(form);
    formData.set('reason', repairReason);
    formData.set('link_council_report', issueCouncilValue);
    formData.set('current_password', currentPasswordValue);

    const submitURL = new URL(form.getAttribute('action') || window.location.href, window.location.href).toString();
    const requestBody = new URLSearchParams(formData);
    const response = await fetch(submitURL, {
      method: 'POST',
      credentials: 'include',
      headers: {
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8'
      },
      body: requestBody.toString(),
      redirect: 'follow'
    });

    const responseText = await response.text();
    const parsedDocument = new DOMParser().parseFromString(responseText, 'text/html');
    const responseBodyText = normalizeText(parsedDocument.body?.innerText || responseText);
    const resetScopes = Array.from(parsedDocument.querySelectorAll('#reset-account'))
      .filter((element) =>
        element.querySelector('form[name="reset-account"]') ||
        element.querySelector('.error-message') ||
        element.querySelector('.success-message')
      );
    const messageScopes = resetScopes.length ? resetScopes : [parsedDocument];
    const collectMessages = (selector) => messageScopes
      .flatMap((scope) => Array.from(scope.querySelectorAll(selector)))
      .map((element) => normalizeText(element.textContent))
      .filter(Boolean);
    const errorMessages = collectMessages('.js-error-message, .error-message, .alert-danger, .flash-error');
    const successMessages = collectMessages('.js-success-message, .success-message, .alert-success, .flash-success');
    const responseLooksAccessDenied =
      response.status === 401 ||
      response.status === 403 ||
      parsedDocument.title.toLowerCase().includes('access denied') ||
      responseBodyText.includes('Access denied');

    if (responseLooksAccessDenied) {
      return {
        accessDenied: true,
        status: 'access-denied',
        failureMessage: errorMessages[0] || `RSI rejected the character repair request with HTTP ${response.status}.`,
        debugSummary: `httpStatus=${response.status}, responseURL=${response.url || 'n/a'}`
      };
    }

    if (!response.ok) {
      return {
        accessDenied: false,
        status: 'failed',
        failureMessage: errorMessages[0] || `RSI returned HTTP ${response.status} while requesting character repair.`,
        debugSummary: `httpStatus=${response.status}, responsePreview=${responseBodyText.slice(0, 500) || 'n/a'}`
      };
    }

    if (errorMessages.length) {
      return {
        accessDenied: false,
        status: 'failed',
        failureMessage: errorMessages.join('\\n'),
        debugSummary: `httpStatus=${response.status}, responseURL=${response.url || 'n/a'}, successMessages=${successMessages.length}`
      };
    }

    return {
      accessDenied: false,
      status: 'ok',
      failureMessage: null,
      debugSummary: `httpStatus=${response.status}, responseURL=${response.url || 'n/a'}, requestButtonClicked=${requestButton ? 'yes' : 'no'}, successMessages=${successMessages.length}`
    };
    """

    private static let applyUpgradeScript = """
    const normalizeText = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
    const cookieValue = (name) => {
      const escapedName = name.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
      const match = document.cookie.match(new RegExp('(?:^|; )' + escapedName + '=([^;]*)'));
      return match ? decodeURIComponent(match[1]) : '';
    };

    const parsedUpgradeItemPledgeID = Number(upgradeItemPledgeID);
    const parsedTargetPledgeID = Number(targetPledgeID);
    const currentPasswordValue = typeof currentPassword === 'string' ? currentPassword : '';

    const hasAccessDeniedMarkup =
      document.title.toLowerCase().includes('access denied') ||
      document.body.innerText.includes('Access denied');

    if (hasAccessDeniedMarkup) {
      return {
        accessDenied: true,
        status: 'access-denied',
        failureMessage: 'The RSI account page reported access denied before the upgrade request started.',
        debugSummary: null
      };
    }

    if (!Number.isFinite(parsedUpgradeItemPledgeID) || parsedUpgradeItemPledgeID <= 0) {
      return {
        accessDenied: false,
        status: 'invalid-upgrade-item',
        failureMessage: 'Hangar Express could not determine the selected owned upgrade item id.',
        debugSummary: `upgradeItemPledgeID=${String(upgradeItemPledgeID)}`
      };
    }

    if (!Number.isFinite(parsedTargetPledgeID) || parsedTargetPledgeID <= 0) {
      return {
        accessDenied: false,
        status: 'invalid-target',
        failureMessage: 'Hangar Express could not determine the selected pledge that should receive the upgrade.',
        debugSummary: `targetPledgeID=${String(targetPledgeID)}`
      };
    }

    const csrfToken = document.querySelector('meta[name=\"csrf-token\"]')?.getAttribute('content') || '';
    const rsiToken = cookieValue('Rsi-Token') || cookieValue('rsi-token');
    const rsiDevice = cookieValue('_rsi_device');
    const requestHeaders = {
      'Content-Type': 'application/json;charset=UTF-8',
      'Accept': 'application/json',
      'X-Requested-With': 'XMLHttpRequest'
    };

    if (csrfToken) {
      requestHeaders['x-csrf-token'] = csrfToken;
    }
    if (rsiToken) {
      requestHeaders['x-rsi-token'] = rsiToken;
    }
    if (rsiDevice) {
      requestHeaders['x-rsi-device'] = rsiDevice;
    }

    const response = await fetch('/api/account/applyUpgrade', {
      method: 'POST',
      credentials: 'include',
      headers: requestHeaders,
      body: JSON.stringify({
        upgrade_id: String(parsedUpgradeItemPledgeID),
        pledge_id: String(parsedTargetPledgeID),
        current_password: currentPasswordValue
      })
    });

    const responseText = await response.text();
    let payload = null;
    try {
      payload = responseText ? JSON.parse(responseText) : null;
    } catch {
      payload = null;
    }

    if (response.status === 401 || response.status === 403) {
      return {
        accessDenied: true,
        status: 'access-denied',
        failureMessage: normalizeText(payload?.msg || payload?.code || responseText || `RSI rejected the upgrade request for upgrade ${parsedUpgradeItemPledgeID}.`),
        debugSummary: `httpStatus=${response.status}`
      };
    }

    const successValue = Number(payload?.success ?? 0);
    if (!response.ok || successValue !== 1) {
      return {
        accessDenied: false,
        status: 'failed',
        failureMessage: normalizeText(payload?.msg || payload?.code || responseText || `RSI returned HTTP ${response.status} while applying upgrade ${parsedUpgradeItemPledgeID} to pledge ${parsedTargetPledgeID}.`),
        debugSummary: `httpStatus=${response.status}, responsePreview=${normalizeText(responseText).slice(0, 280) || 'n/a'}, csrfTokenPresent=${csrfToken ? 'yes' : 'no'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}, rsiDevicePresent=${rsiDevice ? 'yes' : 'no'}`
      };
    }

    return {
      accessDenied: false,
      status: 'ok',
      failureMessage: null,
      debugSummary: `upgradeItemPledgeID=${parsedUpgradeItemPledgeID}, targetPledgeID=${parsedTargetPledgeID}, csrfTokenPresent=${csrfToken ? 'yes' : 'no'}, rsiTokenPresent=${rsiToken ? 'yes' : 'no'}, rsiDevicePresent=${rsiDevice ? 'yes' : 'no'}`
    };
    """
}

nonisolated enum RSIStoreCreditParser {
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

private nonisolated struct AccountOverview {
    let storeCreditUSD: Decimal?
    let totalSpendUSD: Decimal?
    let avatarURL: URL?
    let primaryOrganization: AccountOrganization?
    let didRefreshPrimaryOrganization: Bool
}

nonisolated enum HangarPledgeSummaryParser {
    static func supplementalTitles(
        from containsSummary: String,
        alsoContains: [String],
        excluding excludedTitles: [String]
    ) -> [String] {
        var seenKeys = Set(excludedTitles.map(normalizedKey).filter { !$0.isEmpty })
        var titles: [String] = []

        for candidate in visibleCandidates(from: alsoContains) + residualCandidates(from: containsSummary, excluding: excludedTitles) {
            let title = cleanedTitle(candidate)
            let key = normalizedKey(title)

            guard !key.isEmpty, !seenKeys.contains(key), shouldRenderContentTitle(title) else {
                continue
            }

            seenKeys.insert(key)
            titles.append(title)
        }

        return titles
    }

    static func shouldRenderContentTitle(_ title: String) -> Bool {
        !shouldSkip(title)
    }

    private static func visibleCandidates(from titles: [String]) -> [String] {
        titles.flatMap { splitCandidates(from: $0) }
    }

    private static func residualCandidates(from containsSummary: String, excluding excludedTitles: [String]) -> [String] {
        var residual = normalizedWhitespace(containsSummary)

        for title in excludedTitles
            .map(cleanedTitle)
            .filter({ !$0.isEmpty })
            .sorted(by: { $0.count > $1.count }) {
            residual = residual.replacingOccurrences(
                of: title,
                with: "\n",
                options: [.caseInsensitive, .diacriticInsensitive]
            )
        }

        return splitCandidates(from: residual)
    }

    private static func splitCandidates(from value: String) -> [String] {
        normalizedWhitespace(value)
            .replacingOccurrences(of: "#", with: "\n")
            .replacingOccurrences(of: "•", with: "\n")
            .replacingOccurrences(of: "|", with: "\n")
            .replacingOccurrences(of: ";", with: "\n")
            .components(separatedBy: .newlines)
    }

    private static func cleanedTitle(_ value: String) -> String {
        var title = normalizedWhitespace(value)

        for prefix in ["also contains:", "contains:", "included:", "includes:"] {
            if let range = title.range(of: prefix, options: [.caseInsensitive, .anchored]) {
                title = String(title[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        for prefix in ["also contains ", "contains ", "included ", "includes "] {
            if let range = title.range(of: prefix, options: [.caseInsensitive, .anchored]) {
                title = String(title[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        title = title.replacingOccurrences(
            of: #"\s+(?:and\s+)?\d+\s+(?:items?|ships?|vehicles?)$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return title
    }

    private static func shouldSkip(_ title: String) -> Bool {
        let key = normalizedKey(title)
        let labels: Set<String> = [
            "contains",
            "contents",
            "also contains",
            "included",
            "includes",
            "and",
            "standard upgrade"
        ]

        if labels.contains(key) {
            return true
        }

        return key.range(
            of: #"^(?:and )?\d+ (?:items?|ships?|vehicles?)$"#,
            options: .regularExpression
        ) != nil
    }

    private static func normalizedWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                line
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedKey(_ value: String) -> String {
        cleanedTitle(value)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
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
    let isUpgradedStatusFlag: Bool?
    let dateText: String
    let valueText: String
    let containsText: String
    let thumbnailImageURL: String?
    let alsoContains: [String]
    let canGift: Bool
    let canReclaim: Bool
    let canUpgrade: Bool
    let upgradeMetadata: RemotePledgeUpgradeMetadata?
    let items: [RemotePledgeItem]
    var sourcePage: Int?
    var sourcePageIndex: Int?

    var pageSignature: String {
        [
            id.map(String.init) ?? "nil",
            title,
            statusText,
            isUpgradedStatusFlag == true ? "upgraded-status" : "base-status",
            dateText,
            valueText,
            containsText,
            alsoContains.joined(separator: ","),
            canGift ? "gift" : "locked",
            canReclaim ? "reclaim" : "keep",
            canUpgrade ? "upgrade" : "fixed",
            upgradeMetadata == nil ? "no-owned-upgrade" : "owned-upgrade",
            items.map(\.pageSignature).joined(separator: ",")
        ].joined(separator: "•")
    }

    func withSourcePage(_ page: Int, index: Int) -> RemotePledge {
        var copy = self
        copy.sourcePage = page
        copy.sourcePageIndex = index
        return copy
    }
}

private nonisolated struct RemotePledgeUpgradeMetadata: Decodable {
    let id: Int?
    let name: String?
    let upgradeType: String?
    let matchItems: [RemotePledgeUpgradeMatchItem]
    let targetItems: [RemotePledgeUpgradeMatchItem]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case upgradeType = "upgradeType"
        case matchItems = "matchItems"
        case targetItems = "targetItems"
    }

    var domainModel: HangarPackage.UpgradeMetadata {
        HangarPackage.UpgradeMetadata(
            id: id,
            name: name?.nilIfEmpty,
            upgradeType: upgradeType?.nilIfEmpty,
            matchItems: matchItems.map(\.domainModel),
            targetItems: targetItems.map(\.domainModel)
        )
    }
}

private nonisolated struct RemotePledgeUpgradeMatchItem: Decodable {
    let id: Int?
    let name: String?

    var domainModel: HangarPackage.UpgradeMetadata.MatchItem {
        HangarPackage.UpgradeMetadata.MatchItem(
            id: id,
            name: name?.nilIfEmpty ?? "Unknown"
        )
    }
}

private nonisolated struct RemotePledgeItem: Decodable {
    let title: String
    let kind: String
    let detail: String
    let imageURL: String?

    var pageSignature: String {
        [
            title,
            kind,
            detail,
            imageURL ?? ""
        ].joined(separator: "~")
    }
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
    let inviteCode: String?
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

nonisolated enum ReferralStatsResolver {
    static func resolve(
        currentLadderCount: Int?,
        inviteCode: String? = nil,
        legacyGraphQLCount: Int?,
        legacyParsedCount: Int?,
        legacyPageUnavailable: Bool
    ) -> ReferralStats {
        ReferralStats(
            currentLadderCount: currentLadderCount,
            legacyLadderCount: legacyPageUnavailable ? nil : (legacyGraphQLCount ?? legacyParsedCount),
            hasLegacyLadder: !legacyPageUnavailable,
            inviteCode: inviteCode
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
    let upgradeContext: BuybackUpgradeContext?
    let sourceRawInfo: BuybackPledgeRawInfo?

    var pageSignature: String {
        [
            id.map(String.init) ?? "nil",
            title,
            dateText,
            containsText,
            valueText,
            imageURL ?? "",
            upgradeContext.map { "\($0.fromShipID)-\($0.toShipID)-\($0.toSkuID)" } ?? ""
        ].joined(separator: "•")
    }
}

private final class LimitedShipCartLogBridge: NSObject, WKScriptMessageHandler {
    private let handler: LimitedShipCartLogHandler

    init(handler: @escaping LimitedShipCartLogHandler) {
        self.handler = handler
    }

    func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let renderedMessage = Self.render(message.body)
        guard !renderedMessage.isEmpty else {
            return
        }

        let handler = handler
        Task { @MainActor in
            handler(renderedMessage)
        }
    }

    private static func render(_ body: Any) -> String {
        if let string = body as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if JSONSerialization.isValidJSONObject(body),
           let data = try? JSONSerialization.data(withJSONObject: body),
           let string = String(data: data, encoding: .utf8) {
            return string
        }

        return String(describing: body).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private nonisolated struct RemoteBuybackCheckoutPreparation: Decodable {
    let accessDenied: Bool
    let status: String
    let checkoutURL: String?
    let failureMessage: String?
    let debugSummary: String?
}

private nonisolated struct RemoteLimitedShipCartInsertion: Decodable {
    let accessDenied: Bool
    let status: String
    let cartURL: String?
    let attemptCount: Int
    let failureMessage: String?
    let debugSummary: String?
    let debugLog: [String]
}

private nonisolated struct RemoteHangarLogPage: Decodable {
    let accessDenied: Bool
    let statusCode: Int
    let items: [RemoteHangarLogItem]
    let failureMessage: String?
    let debugSummary: String?
}

private nonisolated struct RemoteHangarLogItem: Decodable {
    let timeText: String
    let itemName: String
    let fullText: String
    let contentText: String
}

private nonisolated enum HangarLogParser {
    private static let createdPattern = #"^#(\d+?) - Created by ([\w\d-]+?) - order #([A-Z0-9]+?), value: \$([0-9.]+?) USD$"#
    private static let reclaimedPattern = #"^#(\d+?) - Reclaimed by ([\w\d-]+?) for \$([0-9.]+?) USD$"#
    private static let consumedPattern = #"^#(\d+?) - Consumed by ([\w\d-]+?) on pledge #(\d+?), value: \$([0-9.]+?) USD$"#
    private static let appliedUpgradePattern = #"^#(\d+?) - Upgrade applied: #(\d+?) ([^,]+?), new value: \$([0-9.]+?) USD$"#
    private static let buybackPattern = #"^#(\d+?) - Buy-back by ([\w\d-]+?) - order #([\w\d]+?)$"#
    private static let giftPattern = #"^#(\d+?) - Gifted to ([^,]+?), value: \$([0-9.]+?) USD$"#
    private static let giftClaimedPattern = #"^#(\d+) - Claimed as a gift by ([\w\d-]+?), value: \$([0-9.]+?) USD$"#
    private static let giftCancelledPattern = #"^#(\d+?) - Gift cancelled by ([\d\w-]+?), value: \$([0-9.]+?) USD$"#
    private static let nameChangePattern = #"^#(\d+) - Name Reservation: \((.+)\) on item (.+)$"#
    private static let nameChangeReclaimedPattern = #"^#(\d+) - Name Release: \(([^\)]+)\) on item (\S+) Reclaimed$"#
    private static let giveawayPattern = #"^#(\d+?) - (.*?)$"#

    static func parse(_ items: [RemoteHangarLogItem]) -> [HangarLogEntry] {
        items.compactMap(parse)
    }

    private static func parse(_ item: RemoteHangarLogItem) -> HangarLogEntry? {
        let occurredAt = parsedDate(from: item.timeText) ?? .distantPast
        let content = item.contentText.trimmingCharacters(in: .whitespacesAndNewlines)

        var action: HangarLogAction = .unknown
        var priceUSD: Decimal?
        var orderCode: String?
        var sourcePledgeID: String?
        var targetPledgeID: String?
        var operatorName: String?
        var reason: String?
        var upgradeContext: HangarLogUpgradeContext?

        if let groups = match(createdPattern, in: content) {
            action = .created
            targetPledgeID = groupValue(groups, 0)
            operatorName = groupValue(groups, 1)
            orderCode = groupValue(groups, 2)
            priceUSD = parseMoney(groupValue(groups, 3))
        } else if let groups = match(reclaimedPattern, in: content) {
            action = .reclaimed
            targetPledgeID = groupValue(groups, 0)
            operatorName = groupValue(groups, 1)
            priceUSD = parseMoney(groupValue(groups, 2))
        } else if let groups = match(consumedPattern, in: content) {
            action = .consumed
            targetPledgeID = groupValue(groups, 0)
            operatorName = groupValue(groups, 1)
            sourcePledgeID = groupValue(groups, 2)
            priceUSD = parseMoney(groupValue(groups, 3))
        } else if let groups = match(appliedUpgradePattern, in: content) {
            action = .appliedUpgrade
            targetPledgeID = groupValue(groups, 0)
            sourcePledgeID = groupValue(groups, 1)
            reason = groupValue(groups, 2)
            priceUSD = parseMoney(groupValue(groups, 3))
            operatorName = "CIG"
            upgradeContext = HangarLogUpgradeContext.inferred(
                from: [
                    reason,
                    item.itemName
                ]
            )
        } else if let groups = match(buybackPattern, in: content) {
            action = .buyback
            targetPledgeID = groupValue(groups, 0)
            operatorName = groupValue(groups, 1)
            orderCode = groupValue(groups, 2)
        } else if let groups = match(giftPattern, in: content) {
            action = .gift
            targetPledgeID = groupValue(groups, 0)
            operatorName = groupValue(groups, 1)
            priceUSD = parseMoney(groupValue(groups, 2))
        } else if let groups = match(giftClaimedPattern, in: content) {
            action = .giftClaimed
            targetPledgeID = groupValue(groups, 0)
            operatorName = groupValue(groups, 1)
            priceUSD = parseMoney(groupValue(groups, 2))
        } else if let groups = match(giftCancelledPattern, in: content) {
            action = .giftCancelled
            targetPledgeID = groupValue(groups, 0)
            operatorName = groupValue(groups, 1)
            priceUSD = parseMoney(groupValue(groups, 2))
        } else if let groups = match(nameChangePattern, in: content) {
            action = .nameChange
            targetPledgeID = groupValue(groups, 0)
            sourcePledgeID = groupValue(groups, 1)
            reason = groupValue(groups, 2)
        } else if let groups = match(nameChangeReclaimedPattern, in: content) {
            action = .nameChangeReclaimed
            targetPledgeID = groupValue(groups, 0)
            sourcePledgeID = groupValue(groups, 1)
            reason = groupValue(groups, 2)
        } else if let groups = match(giveawayPattern, in: content) {
            action = .giveaway
            targetPledgeID = groupValue(groups, 0)
            reason = groupValue(groups, 1)
        }

        let resolvedOperatorName = operatorName?.nilIfEmpty ?? "CIG"
        let resolvedTargetID = targetPledgeID?.nilIfEmpty
        let identifier = [
            action.rawValue,
            resolvedTargetID ?? "unknown",
            String(Int(occurredAt.timeIntervalSince1970)),
            content
        ].joined(separator: "#")

        return HangarLogEntry(
            id: identifier,
            occurredAt: occurredAt,
            action: action,
            itemName: item.itemName.nilIfEmpty ?? "Unknown item",
            operatorName: resolvedOperatorName,
            priceUSD: priceUSD,
            sourcePledgeID: sourcePledgeID?.nilIfEmpty,
            targetPledgeID: resolvedTargetID,
            orderCode: orderCode?.nilIfEmpty,
            reason: reason?.nilIfEmpty,
            rawText: item.fullText.nilIfEmpty ?? content,
            upgradeContext: upgradeContext
        )
    }

    private static func parsedDate(from rawValue: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MMM d yyyy, h:mm a"
        return formatter.date(from: rawValue)
    }

    private static func parseMoney(_ rawValue: String?) -> Decimal? {
        guard let rawValue else {
            return nil
        }

        return Decimal(string: rawValue, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func groupValue(_ groups: [String], _ index: Int) -> String? {
        guard groups.indices.contains(index) else {
            return nil
        }

        return groups[index]
    }

    private static func match(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, options: [], range: range) else {
            return nil
        }

        return (1 ..< match.numberOfRanges).compactMap { index in
            let captureRange = match.range(at: index)
            guard captureRange.location != NSNotFound,
                  let range = Range(captureRange, in: text) else {
                return nil
            }

            return String(text[range])
        }
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
