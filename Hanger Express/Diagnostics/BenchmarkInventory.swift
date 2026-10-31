#if DEBUG || HANGAR_BENCHMARKS
import Foundation

/// Versioned synthetic data: no cookies, credentials, real account identifiers,
/// image URLs, live requests, or random inventory fields.
nonisolated enum BenchmarkInventory {
    static let version = 1
    static let sizes = [100, 1_000, 10_000]
    static let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    struct Workload: Sendable {
        let snapshot: HangarSnapshot
        let catalog: RSIShipCatalog
        let session: UserSession
    }

    static func make(pledgeCount: Int, accountIndex: Int = 0) -> Workload {
        precondition(sizes.contains(pledgeCount))
        let ships = (0..<64).map { index in
            RSIShipCatalog.Ship(
                id: index + 1, name: shipName(index), manufacturer: "Benchmark Manufacturer",
                msrpUSD: Decimal(30 + index * 10), storeAvailable: true,
                aliases: ["Legacy \(shipName(index))"], type: "Exploration", focus: "Touring",
                imageURL: nil
            )
        }
        let catalog = RSIShipCatalog(ships: ships)
        let offset = accountIndex * 100_000
        let packages = (0..<pledgeCount).map { index -> HangarPackage in
            if ReferralRewardsBenchmark.enabled {
                let title: String?
                switch index {
                case 0: title = "CDS GCD-Army Medium Armor Set - Referral Reward"
                case 1: title = "Gladius Dunlevy Model - Referral Reward"
                case 2: title = "Gear - Gladius Dunlevy Model - Referral Reward"
                default: title = nil
                }
                if let title {
                    return HangarPackage(id: offset + index + 1, title: title, status: "Attributed - Account Bound",
                        insurance: "", acquiredAt: referenceDate, originalValueUSD: 0, currentValueUSD: 0,
                        canGift: false, canReclaim: false, canUpgrade: false,
                        contents: [PackageItem(id: "referral-\(index)", title: index == 0 ? "GCD-Army Helmet" : "Gladius Dunlevy Model",
                            detail: "Referral reward", category: .flair, imageURL: nil, upgradePricing: nil)])
                }
            }
            // One quarter unique, the remaining entries share stable templates.
            let template = index % 4 == 0 ? 1_000 + index : index % 100
            let source = template % 60
            let target = source + 1
            let isUpgrade = template % 5 == 0
            let isPack = template % 5 == 1
            let title = isUpgrade
                ? "Upgrade - \(shipName(source)) to \(shipName(target))"
                : "\(isPack ? "Package" : "Standalone Ship") - \(shipName(source)) \(template)"
            var items: [PackageItem]
            if isUpgrade {
                items = [PackageItem(
                    id: "\(offset + index)-upgrade", title: title, detail: "Ship Upgrade",
                    category: .upgrade, imageURL: nil,
                    upgradePricing: .init(
                        sourceShipName: shipName(source), sourceShipMSRPUSD: Decimal(30 + source * 10),
                        sourceShipImageURL: nil, targetShipName: shipName(target),
                        targetShipMSRPUSD: Decimal(30 + target * 10), targetShipImageURL: nil,
                        actualValueUSD: 10, meltValueUSD: 5
                    )
                )]
            } else {
                items = [PackageItem(
                    id: "\(offset + index)-ship", title: shipName(source), detail: "Exploration",
                    category: .ship, imageURL: nil, upgradePricing: nil
                )]
                if isPack {
                    items.append(PackageItem(
                        id: "\(offset + index)-second", title: shipName(target), detail: "Touring",
                        category: .ship, imageURL: nil, upgradePricing: nil
                    ))
                    items.append(PackageItem(
                        id: "\(offset + index)-game", title: "Star Citizen Digital Download",
                        detail: "Game access", category: .gamePackage, imageURL: nil, upgradePricing: nil
                    ))
                }
            }
            return HangarPackage(
                id: offset + index + 1, title: title, status: "Attributed",
                insurance: template % 2 == 0 ? "LTI" : "120 months",
                acquiredAt: referenceDate.addingTimeInterval(Double(-index)),
                originalValueUSD: isUpgrade ? 5 : Decimal(30 + source * 10),
                currentValueUSD: isUpgrade ? 10 : Decimal(30 + source * 10),
                canGift: template % 3 != 0, canReclaim: true, canUpgrade: !isUpgrade,
                contents: items
            )
        }
        let buyback = (0..<(pledgeCount / 4)).map { index in
            BuybackPledge(
                id: offset + index + 50_000,
                title: index % 3 == 0
                    ? "Upgrade - \(shipName(index % 60)) to \(shipName(index % 60 + 1))"
                    : "Starter Package - \(shipName(index % 64))",
                recoveredValueUSD: Decimal(10 + index % 50),
                addedToBuybackAt: referenceDate.addingTimeInterval(Double(-index)),
                notes: "Synthetic buyback template \(index % 40)"
            )
        }
        let fleet = FleetProjector.project(packages: packages, shipCatalog: catalog)
        let snapshot = HangarSnapshot(
            accountHandle: "benchmark-account-\(accountIndex)", lastSyncedAt: referenceDate,
            storeCreditUSD: 500, totalSpendUSD: 1_000,
            packages: packages, fleet: fleet, buyback: buyback,
            referralStats: ReferralRewardsBenchmark.enabled ? ReferralStats(currentLadderCount: 9, legacyLadderCount: nil, hasLegacyLadder: false) : .unavailable
        )
        let session = UserSession(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", accountIndex + 1))!,
            handle: snapshot.accountHandle, displayName: snapshot.accountHandle,
            email: "benchmark-\(accountIndex)@example.invalid", authMode: .developerPreview,
            notes: "Synthetic performance fixture v\(version)", credentials: nil,
            cookies: [], createdAt: referenceDate
        )
        return Workload(snapshot: snapshot, catalog: catalog, session: session)
    }

    private static func shipName(_ index: Int) -> String {
        String(format: "Benchmark Ship %02d", index)
    }

    /// Supplement v1: two unique buybacks per pledge. The standard v1 fixture
    /// remains unchanged so previously recorded baselines stay comparable.
    static func makeBuybackHeavy(pledgeCount: Int, accountIndex: Int = 0) -> Workload {
        let base = make(pledgeCount: pledgeCount, accountIndex: accountIndex)
        let buyback = (0..<(pledgeCount * 2)).map { index in
            BuybackPledge(
                id: accountIndex * 100_000 + index + 50_000,
                title: "\(index % 3 == 0 ? "Upgrade" : "Starter Package") - \(shipName(index % 64)) - Lot \(index)",
                recoveredValueUSD: Decimal(10 + index % 50),
                addedToBuybackAt: referenceDate.addingTimeInterval(Double(-index)),
                notes: "Synthetic unique buyback \(index); insurance 120 months"
            )
        }
        let snapshot = HangarSnapshot(
            accountHandle: base.snapshot.accountHandle, lastSyncedAt: referenceDate,
            storeCreditUSD: base.snapshot.storeCreditUSD, totalSpendUSD: base.snapshot.totalSpendUSD,
            packages: base.snapshot.packages, fleet: base.snapshot.fleet, buyback: buyback
        )
        return Workload(snapshot: snapshot, catalog: base.catalog, session: base.session)
    }
}
#endif
