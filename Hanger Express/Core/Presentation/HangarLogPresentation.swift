import Foundation

/// Reuses the inventory builder's groups. Only Hangar/Fleet content changes rebuild
/// navigation lookups; unrelated Buy Back, profile and log updates keep identity.
nonisolated struct HangarLogInventoryLookup: Sendable {
    let identity = UUID()
    let accountID: UUID?
    private let sourcePackages: [HangarPackage]
    private let sourceFleet: [FleetShip]
    let packageGroups: [GroupedHangarPackage]
    let shipGroups: [GroupedFleetShip]
    let packageByPledgeID: [Int: HangarPackage]
    let packageGroupByPledgeID: [Int: GroupedHangarPackage]
    let packageGroupByNormalizedTitle: [String: GroupedHangarPackage]
    let shipGroupBySourcePackageID: [Int: GroupedFleetShip]
    let shipGroupByNormalizedName: [String: GroupedFleetShip]

    static let empty = Self(accountID: nil, packages: [], fleet: [], packageGroups: [], shipGroups: [])

    func matches(snapshot: HangarSnapshot, accountID: UUID) -> Bool {
        self.accountID == accountID && sourcePackages == snapshot.packages && sourceFleet == snapshot.fleet
    }

    init(accountID: UUID?, packages: [HangarPackage], fleet: [FleetShip],
         packageGroups: [GroupedHangarPackage], shipGroups: [GroupedFleetShip]) {
        self.accountID = accountID
        sourcePackages = packages; sourceFleet = fleet
        self.packageGroups = packageGroups; self.shipGroups = shipGroups
        var packageByPledgeID: [Int: HangarPackage] = [:]
        var packageGroupByPledgeID: [Int: GroupedHangarPackage] = [:]
        var packageGroupByNormalizedTitle: [String: GroupedHangarPackage] = [:]
        for packageGroup in packageGroups {
            for package in packageGroup.packages {
                packageByPledgeID[package.id] = package
                packageGroupByPledgeID[package.id] = packageGroup

                let packageTitle = hangarLogNormalizedLookupText(package.title)
                if !packageTitle.isEmpty, packageGroupByNormalizedTitle[packageTitle] == nil {
                    packageGroupByNormalizedTitle[packageTitle] = packageGroup
                }

                for item in package.contents {
                    let itemTitle = hangarLogNormalizedLookupText(item.title)
                    if !itemTitle.isEmpty, packageGroupByNormalizedTitle[itemTitle] == nil {
                        packageGroupByNormalizedTitle[itemTitle] = packageGroup
                    }
                }
            }
        }

        var shipGroupBySourcePackageID: [Int: GroupedFleetShip] = [:]
        var shipGroupByNormalizedName: [String: GroupedFleetShip] = [:]
        for shipGroup in shipGroups {
            for ship in shipGroup.ships {
                shipGroupBySourcePackageID[ship.sourcePackageID] = shipGroup

                let shipName = hangarLogNormalizedLookupText(ship.displayName)
                if !shipName.isEmpty, shipGroupByNormalizedName[shipName] == nil {
                    shipGroupByNormalizedName[shipName] = shipGroup
                }
            }
        }

        self.packageByPledgeID = packageByPledgeID
        self.packageGroupByPledgeID = packageGroupByPledgeID
        self.packageGroupByNormalizedTitle = packageGroupByNormalizedTitle
        self.shipGroupBySourcePackageID = shipGroupBySourcePackageID
        self.shipGroupByNormalizedName = shipGroupByNormalizedName
    }
}

nonisolated func hangarLogNormalizedLookupText(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
}

/// Constant-cost event identity. Content epochs are advanced at source commits,
/// not by comparing IDs or re-deriving inventory while the screen is idle.
nonisolated struct HangarLogPresentationKey: Equatable, Sendable {
    let accountID: UUID?
    let accountContextID: UUID
    let hasSnapshot: Bool
    let logContentEpoch: UInt64
    let previewEpoch: UInt64
    let usesPreview: Bool
    let inventoryLookupID: UUID?
    let isPro: Bool
    let hangarLogEntryLimit: Int
    let imageReloadToken: UUID

    static let empty = Self(accountID: nil, accountContextID: UUID(), hasSnapshot: false,
        logContentEpoch: 0, previewEpoch: 0, usesPreview: false, inventoryLookupID: nil,
        isPro: false, hangarLogEntryLimit: ProSubscriptionConfiguration.standardHangarLogEntryLimit,
        imageReloadToken: UUID())
}

nonisolated struct HangarLogPresentationSnapshot: Sendable {
    static let empty = Self(key: .empty, hangarLogs: [], lookup: .empty)
    let key: HangarLogPresentationKey
    let hangarLogs: [HangarLogEntry]
    let lookup: HangarLogInventoryLookup
    var packageGroups: [GroupedHangarPackage] { lookup.packageGroups }
    var shipGroups: [GroupedFleetShip] { lookup.shipGroups }
    var packageByPledgeID: [Int: HangarPackage] { lookup.packageByPledgeID }
    var packageGroupByPledgeID: [Int: GroupedHangarPackage] { lookup.packageGroupByPledgeID }
    var packageGroupByNormalizedTitle: [String: GroupedHangarPackage] { lookup.packageGroupByNormalizedTitle }
    var shipGroupBySourcePackageID: [Int: GroupedFleetShip] { lookup.shipGroupBySourcePackageID }
    var shipGroupByNormalizedName: [String: GroupedFleetShip] { lookup.shipGroupByNormalizedName }
    var isPro: Bool { key.isPro }
    var hangarLogEntryLimit: Int { key.hangarLogEntryLimit }
    var imageReloadToken: UUID { key.imageReloadToken }
    func hasSameDisplay(as other: Self) -> Bool { key == other.key }
}

/// Keep rows stable during refresh/interaction, but never buffer an account
/// boundary or retain the previous account when the source is cleared.
nonisolated struct HangarLogPresentationBuffer: Sendable {
    private(set) var displayed = HangarLogPresentationSnapshot.empty
    private(set) var pending: HangarLogPresentationSnapshot?

    mutating func receive(_ next: HangarLogPresentationSnapshot, isRefreshing: Bool,
                          isInteracting: Bool, immediate: Bool = false) {
        guard !next.hasSameDisplay(as: displayed) else { pending = nil; return }
        let accountChanged = next.key.accountID != displayed.key.accountID
            || next.key.accountContextID != displayed.key.accountContextID
        if immediate || accountChanged || !next.key.hasSnapshot || displayed.hangarLogs.isEmpty
            || (!isRefreshing && !isInteracting) {
            displayed = next; pending = nil
        } else { pending = next }
    }

    mutating func applyPending(isRefreshing: Bool, isInteracting: Bool, force: Bool = false) {
        guard let pending, force || (!isRefreshing && !isInteracting) else { return }
        displayed = pending; self.pending = nil
    }
}
