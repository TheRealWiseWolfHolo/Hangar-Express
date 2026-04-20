import Foundation

struct PreviewHangarRepository: HangarRepository {
    func fetchSnapshot(
        for session: UserSession,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        progress(
            RefreshProgress(
                stage: .preview,
                stepNumber: 1,
                stepCount: 1,
                detail: "Loading the local sample hangar snapshot.",
                completedUnitCount: 0,
                totalUnitCount: 1
            )
        )

        let snapshot = Self.previewSnapshot(for: session, lastSyncedAt: .now)

        progress(
            RefreshProgress(
                stage: .preview,
                stepNumber: 1,
                stepCount: 1,
                detail: "Preview hangar ready.",
                completedUnitCount: 1,
                totalUnitCount: 1
            )
        )

        return snapshot
    }

    func refreshHangarData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        progress(
            RefreshProgress(
                stage: .preview,
                stepNumber: 1,
                stepCount: 1,
                detail: "Refreshing the preview hangar and fleet sections.",
                completedUnitCount: 0,
                totalUnitCount: 1
            )
        )

        progress(
            RefreshProgress(
                stage: .preview,
                stepNumber: 1,
                stepCount: 1,
                detail: "Preview hangar and fleet ready.",
                completedUnitCount: 1,
                totalUnitCount: 1
            )
        )

        return snapshot.updatingHangar(
            packages: Self.samplePackages,
            fleet: Self.sampleFleet
        )
    }

    func refreshBuybackData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        progress(
            RefreshProgress(
                stage: .preview,
                stepNumber: 1,
                stepCount: 1,
                detail: "Refreshing the preview buy-back section.",
                completedUnitCount: 0,
                totalUnitCount: 1
            )
        )

        progress(
            RefreshProgress(
                stage: .preview,
                stepNumber: 1,
                stepCount: 1,
                detail: "Preview buy-back ready.",
                completedUnitCount: 1,
                totalUnitCount: 1
            )
        )

        return snapshot.updatingBuyback(
            buyback: Self.sampleBuyback
        )
    }

    func refreshHangarLogData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        progress(
            RefreshProgress(
                stage: .preview,
                stepNumber: 1,
                stepCount: 1,
                detail: "Refreshing the preview hangar log.",
                completedUnitCount: 0,
                totalUnitCount: 1
            )
        )

        progress(
            RefreshProgress(
                stage: .preview,
                stepNumber: 1,
                stepCount: 1,
                detail: "Preview hangar log ready.",
                completedUnitCount: 1,
                totalUnitCount: 1
            )
        )

        return snapshot.updatingHangarLogs(
            hangarLogs: Self.sampleHangarLogs
        )
    }

    func refreshAccountData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        progress(
            RefreshProgress(
                stage: .preview,
                stepNumber: 1,
                stepCount: 1,
                detail: "Refreshing the preview account overview.",
                completedUnitCount: 0,
                totalUnitCount: 1
            )
        )

        let refreshedSnapshot = Self.previewSnapshot(for: session, lastSyncedAt: .now)

        progress(
            RefreshProgress(
                stage: .preview,
                stepNumber: 1,
                stepCount: 1,
                detail: "Preview account overview ready.",
                completedUnitCount: 1,
                totalUnitCount: 1
            )
        )

        return snapshot.updatingAccount(
            accountHandle: refreshedSnapshot.accountHandle,
            avatarURL: refreshedSnapshot.avatarURL,
            primaryOrganization: refreshedSnapshot.primaryOrganization,
            storeCreditUSD: refreshedSnapshot.storeCreditUSD,
            totalSpendUSD: refreshedSnapshot.totalSpendUSD,
            referralStats: refreshedSnapshot.referralStats
        )
    }

    static let sampleSnapshot = HangarSnapshot(
        accountHandle: UserSession.preview.handle,
        lastSyncedAt: referenceDate(year: 2026, month: 4, day: 17),
        primaryOrganization: AccountOrganization(
            name: "Skewers Gentlemen's Club",
            rank: "President"
        ),
        storeCreditUSD: 145,
        totalSpendUSD: 1215,
        packages: samplePackages,
        fleet: sampleFleet,
        buyback: sampleBuyback,
        hangarLogs: sampleHangarLogs,
        referralStats: sampleReferralStats
    )

    private static func previewSnapshot(for session: UserSession, lastSyncedAt: Date) -> HangarSnapshot {
        HangarSnapshot(
            accountHandle: session.handle,
            lastSyncedAt: lastSyncedAt,
            avatarURL: session.avatarURL,
            storeCreditUSD: 145,
            totalSpendUSD: 1215,
            packages: samplePackages,
            fleet: sampleFleet,
            buyback: sampleBuyback,
            hangarLogs: sampleHangarLogs,
            referralStats: sampleReferralStats
        )
    }

    private static let sampleReferralStats = ReferralStats(
        currentLadderCount: 18,
        legacyLadderCount: 7,
        hasLegacyLadder: true
    )

    private static let sampleHangarLogs: [HangarLogEntry] = [
        HangarLogEntry(
            id: "preview-created-1001",
            occurredAt: referenceDate(year: 2026, month: 4, day: 18),
            action: .created,
            itemName: "Polaris Expedition Pack",
            operatorName: "WiseWolfHolo",
            priceUSD: 750,
            sourcePledgeID: nil,
            targetPledgeID: "1001",
            orderCode: "ORD-EXAMPLE-1001",
            reason: nil,
            rawText: "#1001 - Created by WiseWolfHolo - order #ORD-EXAMPLE-1001, value: $750.00 USD"
        ),
        HangarLogEntry(
            id: "preview-upgrade-1003",
            occurredAt: referenceDate(year: 2026, month: 4, day: 10),
            action: .appliedUpgrade,
            itemName: "Zeus Mk II MR Patrol Build",
            operatorName: "CIG",
            priceUSD: 190,
            sourcePledgeID: "1002",
            targetPledgeID: "1003",
            orderCode: nil,
            reason: "Zeus MR upgrade",
            rawText: "#1003 - Upgrade applied: #1002 Zeus MR upgrade, new value: $190.00 USD"
        ),
        HangarLogEntry(
            id: "preview-gift-1004",
            occurredAt: referenceDate(year: 2026, month: 3, day: 27),
            action: .gift,
            itemName: "Vulture Foundation Token",
            operatorName: "friend@example.com",
            priceUSD: 150,
            sourcePledgeID: nil,
            targetPledgeID: "1004",
            orderCode: nil,
            reason: nil,
            rawText: "#1004 - Gifted to friend@example.com, value: $150.00 USD"
        ),
        HangarLogEntry(
            id: "preview-reclaim-1005",
            occurredAt: referenceDate(year: 2026, month: 2, day: 14),
            action: .reclaimed,
            itemName: "Legacy Aurora Starter",
            operatorName: "WiseWolfHolo",
            priceUSD: 45,
            sourcePledgeID: nil,
            targetPledgeID: "1005",
            orderCode: nil,
            reason: nil,
            rawText: "#1005 - Reclaimed by WiseWolfHolo for $45.00 USD"
        )
    ]

    private static let samplePackages: [HangarPackage] = [
        HangarPackage(
            id: 1001,
            title: "Polaris Expedition Pack",
            status: "Attributed",
            insurance: "LTI",
            acquiredAt: referenceDate(year: 2024, month: 11, day: 22),
            originalValueUSD: 750,
            currentValueUSD: 900,
            canGift: true,
            canReclaim: true,
            canUpgrade: false,
            contents: [
                PackageItem(id: "1001-1", title: "RSI Polaris", detail: "Capital ship", category: .ship, imageURL: sampleURL("polaris"), upgradePricing: nil),
                PackageItem(id: "1001-2", title: "Ursa Medivac", detail: "Ground vehicle", category: .vehicle, imageURL: sampleURL("ursa-medivac"), upgradePricing: nil),
                PackageItem(id: "1001-3", title: "Star Citizen Digital Download", detail: "Game access", category: .gamePackage, imageURL: nil, upgradePricing: nil),
                PackageItem(id: "1001-4", title: "Revelation Paint", detail: "Limited event skin", category: .flair, imageURL: nil, upgradePricing: nil)
            ]
        ),
        HangarPackage(
            id: 1002,
            title: "Vulture Foundation Token",
            status: "Hangar Ready",
            insurance: "LTI",
            acquiredAt: referenceDate(year: 2025, month: 2, day: 14),
            originalValueUSD: 150,
            currentValueUSD: 175,
            canGift: false,
            canReclaim: true,
            canUpgrade: true,
            contents: [
                PackageItem(id: "1002-1", title: "Drake Vulture", detail: "Salvage starter", category: .ship, imageURL: sampleURL("vulture"), upgradePricing: nil),
                PackageItem(id: "1002-2", title: "Self-Land Hangar", detail: "Legacy hangar flair", category: .flair, imageURL: nil, upgradePricing: nil)
            ]
        ),
        HangarPackage(
            id: 1003,
            title: "Zeus Mk II MR Patrol Build",
            status: "Hangar Ready",
            insurance: "120 months",
            acquiredAt: referenceDate(year: 2025, month: 9, day: 6),
            originalValueUSD: 170,
            currentValueUSD: 190,
            canGift: true,
            canReclaim: true,
            canUpgrade: true,
            contents: [
                PackageItem(id: "1003-1", title: "RSI Zeus Mk II MR", detail: "Pathfinder / patrol", category: .ship, imageURL: sampleURL("zeus-mk-ii-mr"), upgradePricing: nil),
                PackageItem(
                    id: "1003-2",
                    title: "Cutlass Black to Zeus Mk II MR",
                    detail: "Applied CCU history",
                    category: .upgrade,
                    imageURL: sampleURL("zeus-mk-ii-mr"),
                    upgradePricing: PackageItem.UpgradePricing(
                        sourceShipName: "Cutlass Black",
                        sourceShipMSRPUSD: 110,
                        targetShipName: "Zeus Mk II MR",
                        targetShipMSRPUSD: 190,
                        actualValueUSD: 80,
                        meltValueUSD: 20
                    )
                )
            ]
        ),
        HangarPackage(
            id: 1004,
            title: "Referral Pulse Reward",
            status: "Account Bound",
            insurance: "LTI",
            acquiredAt: referenceDate(year: 2026, month: 1, day: 19),
            originalValueUSD: 0,
            currentValueUSD: 30,
            canGift: false,
            canReclaim: false,
            canUpgrade: false,
            contents: [
                PackageItem(id: "1004-1", title: "Mirai Pulse", detail: "Referral reward", category: .vehicle, imageURL: sampleURL("mirai-pulse"), upgradePricing: nil),
                PackageItem(id: "1004-2", title: "Referral Bonus Token", detail: "Locked reward", category: .perk, imageURL: nil, upgradePricing: nil)
            ]
        )
    ]

    private static let sampleFleet: [FleetShip] = [
        FleetShip(
            id: 2001,
            displayName: "Polaris",
            manufacturer: "RSI",
            role: "Capital combat",
            insurance: "LTI",
            sourcePackageID: 1001,
            sourcePackageName: "Polaris Expedition Pack",
            meltValueUSD: 750,
            canGift: true,
            canReclaim: true,
            imageURL: sampleURL("polaris")
        ),
        FleetShip(
            id: 2002,
            displayName: "Ursa Medivac",
            manufacturer: "RSI",
            role: "Medical vehicle",
            insurance: "LTI",
            sourcePackageID: 1001,
            sourcePackageName: "Polaris Expedition Pack",
            meltValueUSD: 0,
            canGift: true,
            canReclaim: true,
            imageURL: sampleURL("ursa-medivac")
        ),
        FleetShip(
            id: 2003,
            displayName: "Vulture",
            manufacturer: "Drake",
            role: "Salvage",
            insurance: "LTI",
            sourcePackageID: 1002,
            sourcePackageName: "Vulture Foundation Token",
            meltValueUSD: 150,
            canGift: false,
            canReclaim: true,
            imageURL: sampleURL("vulture")
        ),
        FleetShip(
            id: 2004,
            displayName: "Zeus Mk II MR",
            manufacturer: "RSI",
            role: "Patrol / expedition",
            insurance: "120 months",
            sourcePackageID: 1003,
            sourcePackageName: "Zeus Mk II MR Patrol Build",
            meltValueUSD: 170,
            canGift: true,
            canReclaim: true,
            imageURL: sampleURL("zeus-mk-ii-mr")
        )
    ]

    private static let sampleBuyback: [BuybackPledge] = [
        BuybackPledge(
            id: 3001,
            title: "Cutlass Black Starter Package",
            recoveredValueUSD: 115,
            addedToBuybackAt: referenceDate(year: 2025, month: 8, day: 2),
            notes: "Good base for future CCU chains.",
            imageURL: sampleURL("cutlass-black")
        ),
        BuybackPledge(
            id: 3002,
            title: "Spirit C1 Warbond",
            recoveredValueUSD: 110,
            addedToBuybackAt: referenceDate(year: 2025, month: 10, day: 17),
            notes: "Watch sale windows before re-purchasing.",
            imageURL: sampleURL("spirit-c1")
        ),
        BuybackPledge(
            id: 3003,
            title: "STV Referral Utility Pack",
            recoveredValueUSD: 35,
            addedToBuybackAt: referenceDate(year: 2026, month: 2, day: 7),
            notes: "Low-value item, but useful for fleet notes.",
            imageURL: sampleURL("stv")
        )
    ]
}

private func referenceDate(year: Int, month: Int, day: Int) -> Date {
    let components = DateComponents(calendar: .current, year: year, month: month, day: day)
    return components.date ?? .now
}

private func sampleURL(_ slug: String) -> URL? {
    URL(string: "https://cdn.robertsspaceindustries.com/static/images/store/\(slug).jpg")
}
