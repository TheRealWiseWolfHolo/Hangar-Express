import Foundation
import WebKit

@MainActor
final class LiveHangarRepository: HangarRepository {
    private let browser = RSIAccountPageBrowser()
    private let shipCatalogClient = HostedShipCatalogClient()
    private let previewRepository = PreviewHangarRepository()
    private let refreshDiagnostics: RefreshDiagnosticsStore
    private let maxHangarLogEntries = HangarLogFetchMode.expanded.entryLimit
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
        return min(
            max(fallbackValue, SyncPreferences.minWorkerCount),
            SyncPreferences.maxWorkerCount
        )
    }

    private enum FullRefreshTracker {
        static let hangar = "hangar"
        static let buyback = "buyback"
        static let account = "account"
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
            progress: progress,
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
                totalUnitCount: 2
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
            progress: progress,
            stepNumber: 2,
            stepCount: 2
        )

        let resolvedRemoteBuyback = try await remoteBuyback
        let resolvedShipCatalog = await shipCatalog
        let buyback = resolvedRemoteBuyback.map { normalize(buyback: $0, shipCatalog: resolvedShipCatalog) }

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
            progress: progress,
            stepNumber: 1,
            stepCount: 1,
            trackerID: FullRefreshTracker.buyback,
            trackerTitle: "Buy Back"
        )

        let resolvedRemoteBuyback = try await remoteBuyback
        let resolvedShipCatalog = await shipCatalog
        return resolvedRemoteBuyback.map { normalize(buyback: $0, shipCatalog: resolvedShipCatalog) }
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
            detail: "Restoring \(session.cookies.count) saved RSI cookies.",
            completedUnitCount: 1,
            totalUnitCount: 1
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
                    for: "pledges",
                    page: 1,
                    totalPages: nil,
                    loadedCount: 0,
                    isLoading: true
                ),
                completedUnitCount: 0,
                totalUnitCount: nil,
                trackerID: trackerID,
                trackerTitle: trackerTitle
            )
        )

        let activeBrowser = activeBrowser ?? browser
        let firstPage: RemotePledgePage
        do {
            firstPage = try await activeBrowser.extractPledges(
                using: cookies,
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
                    for: "pledges",
                    page: 1,
                    totalPages: inferredTotalPages,
                    loadedCount: remotePledges.count,
                    isLoading: false
                ),
                completedUnitCount: 1,
                totalUnitCount: inferredTotalPages,
                trackerID: trackerID,
                trackerTitle: trackerTitle
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

        let warmedCookies = await activeBrowser.currentRSICookies()
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
                            for: "pledges",
                            completedPages: completedPages,
                            totalPages: totalPages,
                            loadedCount: loadedCount,
                            workerCount: workerCount
                        ),
                        completedUnitCount: completedPages,
                        totalUnitCount: totalPages,
                        trackerID: trackerID,
                        trackerTitle: trackerTitle
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
                detail: "Refreshing the affected hangar tail beginning with page \(startPage).",
                completedUnitCount: 0,
                totalUnitCount: nil,
                trackerID: trackerID,
                trackerTitle: trackerTitle
            )
        )

        let activeBrowser = activeBrowser ?? browser
        let firstPage: RemotePledgePage
        do {
            firstPage = try await activeBrowser.extractPledges(
                using: cookies,
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
                    for: "pledges",
                    page: startPage,
                    totalPages: inferredTotalPages,
                    loadedCount: remotePledges.count,
                    isLoading: false
                ),
                completedUnitCount: 1,
                totalUnitCount: inferredTotalPages.map { max($0 - startPage + 1, 1) },
                trackerID: trackerID,
                trackerTitle: trackerTitle
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

        let warmedCookies = await activeBrowser.currentRSICookies()
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
                            for: "pledges",
                            completedPages: completedPages,
                            totalPages: max(totalPages - startPage + 1, 1),
                            loadedCount: loadedCount,
                            workerCount: workerCount
                        ),
                        completedUnitCount: completedPages,
                        totalUnitCount: max(totalPages - startPage + 1, 1),
                        trackerID: trackerID,
                        trackerTitle: trackerTitle
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
                    for: "buy-back items",
                    page: 1,
                    totalPages: nil,
                    loadedCount: 0,
                    isLoading: true
                ),
                completedUnitCount: 0,
                totalUnitCount: nil,
                trackerID: trackerID,
                trackerTitle: trackerTitle
            )
        )

        let activeBrowser = activeBrowser ?? browser
        let firstPage: RemoteBuybackPage
        do {
            firstPage = try await activeBrowser.extractBuybackPledges(
                using: cookies,
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
                    for: "buy-back items",
                    page: 1,
                    totalPages: inferredTotalPages,
                    loadedCount: remoteBuyback.count,
                    isLoading: false
                ),
                completedUnitCount: 1,
                totalUnitCount: inferredTotalPages,
                trackerID: trackerID,
                trackerTitle: trackerTitle
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

        let warmedCookies = await activeBrowser.currentRSICookies()
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
                            for: "buy-back items",
                            completedPages: completedPages,
                            totalPages: totalPages,
                            loadedCount: loadedCount,
                            workerCount: workerCount
                        ),
                        completedUnitCount: completedPages,
                        totalUnitCount: totalPages,
                        trackerID: trackerID,
                        trackerTitle: trackerTitle
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
        let activeBrowser = activeBrowser ?? browser

        for page in startPage ... maxPledgePages {
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
                    totalUnitCount: pledgeTotalPages,
                    trackerID: trackerID,
                    trackerTitle: trackerTitle
                )
            )

            let result = try await activeBrowser.extractPledges(
                using: cookies,
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
                        for: "pledges",
                        page: page,
                        totalPages: pledgeTotalPages,
                        loadedCount: remotePledges.count,
                        isLoading: false
                    ),
                    completedUnitCount: page,
                    totalUnitCount: pledgeTotalPages,
                    trackerID: trackerID,
                    trackerTitle: trackerTitle
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
        let activeBrowser = activeBrowser ?? browser

        for page in startPage ... maxBuybackPages {
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
                    totalUnitCount: buybackTotalPages,
                    trackerID: trackerID,
                    trackerTitle: trackerTitle
                )
            )

            let result = try await activeBrowser.extractBuybackPledges(
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
                    totalUnitCount: buybackTotalPages,
                    trackerID: trackerID,
                    trackerTitle: trackerTitle
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
        let progressTracker = ConcurrentPageProgress(
            completedPages: 1,
            loadedCount: initialLoadedCount
        )
        var resultsByPage: [Int: RemotePledgePage] = [:]

        try await withThrowingTaskGroup(of: [(Int, RemotePledgePage)].self) { group in
            for chunk in chunks {
                group.addTask {
                    try await RSIAccountPageBrowser.loadPledgeChunk(
                        using: cookies,
                        pages: chunk,
                        pageSize: pageSize
                    ) { _, itemCount in
                        let totals = await progressTracker.record(
                            completedPages: 1,
                            loadedCount: itemCount
                        )
                        await MainActor.run {
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
        let progressTracker = ConcurrentPageProgress(
            completedPages: 1,
            loadedCount: initialLoadedCount
        )
        var resultsByPage: [Int: RemoteBuybackPage] = [:]

        try await withThrowingTaskGroup(of: [(Int, RemoteBuybackPage)].self) { group in
            for chunk in chunks {
                group.addTask {
                    try await RSIAccountPageBrowser.loadBuybackChunk(
                        using: cookies,
                        pages: chunk,
                        pageSize: pageSize
                    ) { _, itemCount in
                        let totals = await progressTracker.record(
                            completedPages: 1,
                            loadedCount: itemCount
                        )
                        await MainActor.run {
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
                extra: ["knownMarkerCount=\(existingLogs.prefix(50).count)"]
            )
        )
        progress(
            makeProgress(
                stage: .hangarLog,
                stepNumber: stepNumber,
                stepCount: stepCount,
                detail: "Opening RSI's hangar log window and loading the current entries.",
                completedUnitCount: 0,
                totalUnitCount: 1,
                trackerID: trackerID,
                trackerTitle: trackerTitle
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
                ? "Loaded \(hangarLogs.count) hangar log entries from RSI (cap \(mode.entryLimit))."
                : "Loaded \(hangarLogs.count) hangar log entries from RSI."
        } else if addedEntryCount > 0 {
            detail = "Added \(addedEntryCount) new hangar log entr\(addedEntryCount == 1 ? "y" : "ies") from RSI. \(hangarLogs.count) cached total."
        } else {
            detail = "Your cached hangar log is already up to date."
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
                trackerTitle: trackerTitle
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
                detail: "Loading hosted ship MSRP and thumbnail data for upgrade valuation.",
                completedUnitCount: 0,
                totalUnitCount: 2,
                trackerID: trackerID,
                trackerTitle: trackerTitle
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
                totalUnitCount: 2,
                trackerID: trackerID,
                trackerTitle: trackerTitle
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
                detail: "Loading account balances and profile details.",
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
                    ? "Account balances were unavailable. Continuing with saved account metadata."
                    : "Loaded \(accountOverview?.storeCreditUSD?.usdString ?? "an unavailable") store credit balance and \(accountOverview?.totalSpendUSD?.usdString ?? "an unavailable total spend").",
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
                detail: "Account overview sync complete.",
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
        extra: [String] = []
    ) -> String {
        var details: [String] = [
            "path=\(path)",
            "browserStore=WKWebView.nonPersistent",
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
        trackerTitle: String? = nil
    ) -> RefreshProgress {
        RefreshProgress(
            stage: stage,
            stepNumber: stepNumber,
            stepCount: stepCount,
            detail: detail,
            completedUnitCount: completedUnitCount,
            totalUnitCount: totalUnitCount,
            trackerID: trackerID,
            trackerTitle: trackerTitle
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

    private func parallelPageDetail(
        for itemLabel: String,
        completedPages: Int,
        totalPages: Int,
        loadedCount: Int,
        workerCount: Int
    ) -> String {
        let countLabel = loadedCount == 1 ? "1 \(itemLabel.dropLast())" : "\(loadedCount) \(itemLabel)"
        return "Loaded \(completedPages) of \(totalPages) pages across \(workerCount) workers. \(countLabel) synced so far."
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

    private func normalize(buyback remote: RemoteBuybackPledge, shipCatalog: RSIShipCatalog?) -> BuybackPledge {
        let title = remote.title.nilIfEmpty ?? "Untitled Buy Back"
        let notes = remote.containsText.nilIfEmpty ?? ""

        return BuybackPledge(
            id: remote.id ?? stableNumericID(from: title),
            title: title,
            recoveredValueUSD: parseMoney(remote.valueText),
            addedToBuybackAt: parseRSIDate(remote.dateText) ?? .now,
            notes: notes,
            imageURL: mirroredCatalogImageURL(
                remote.imageURL.flatMap(URL.init(string:)),
                shipCatalog: shipCatalog
            )
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
                    role: role(for: item, matchedShip: matchedShip),
                    roleCategories: roleCategories(for: item, matchedShip: matchedShip),
                    msrpUSD: hostedMSRP(for: item, matchedShip: matchedShip),
                    msrpLabel: hostedMSRPLabel(for: item, matchedShip: matchedShip),
                    catalogWarning: catalogWarning(for: item, matchedShip: matchedShip),
                    insurance: package.insurance,
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
    private var completedPages: Int
    private var loadedCount: Int

    init(completedPages: Int, loadedCount: Int) {
        self.completedPages = completedPages
        self.loadedCount = loadedCount
    }

    func record(completedPages additionalPages: Int, loadedCount additionalItems: Int) -> (completedPages: Int, loadedCount: Int) {
        completedPages += additionalPages
        loadedCount += additionalItems
        return (completedPages, loadedCount)
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

@MainActor
final class RSIAccountPageBrowser: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadTimeoutTask: Task<Void, Never>?
    private let loadTimeoutNanoseconds: UInt64 = 30_000_000_000

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
        finishLoading(with: .success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(with: .failure(error))
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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            loadTimeoutTask?.cancel()
            loadTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.loadTimeoutNanoseconds ?? 30_000_000_000)
                await MainActor.run {
                    guard let self, self.loadContinuation != nil else {
                        return
                    }

                    self.webView.stopLoading()
                    self.finishLoading(
                        with: .failure(
                            LiveHangarRepositoryError.unexpectedMarkup(
                                "RSI page load timed out while opening \(url.absoluteString)."
                            )
                        )
                    )
                }
            }
            webView.load(URLRequest(url: url))
        }
    }

    private func finishLoading(with result: Result<Void, Error>) {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil

        guard let loadContinuation else {
            return
        }

        self.loadContinuation = nil

        switch result {
        case .success:
            loadContinuation.resume()
        case let .failure(error):
            loadContinuation.resume(throwing: error)
        }
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

    const extractionRoots = [
      document.querySelector('.main-org .info'),
      document.querySelector('.box-content.org.main .info'),
      document.querySelector('.right-col')
    ].filter(Boolean);

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
            upgradeMetadata == nil ? "no-owned-upgrade" : "owned-upgrade"
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
            rawText: item.fullText.nilIfEmpty ?? content
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
