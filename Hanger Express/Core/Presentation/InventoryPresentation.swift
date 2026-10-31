import Foundation

nonisolated struct InventoryPresentationKey: Hashable, Sendable {
    let accountID: UUID
    let hangarRevision: UInt64
    let buybackRevision: UInt64
    let contentEpoch: UInt64
}

nonisolated struct InventoryFilterFlags: OptionSet, Sendable {
    let rawValue: Int
    static let giftable = Self(rawValue: 1 << 0)
    static let reclaimable = Self(rawValue: 1 << 1)
    static let lifetimeInsurance = Self(rawValue: 1 << 2)
    static let upgrade = Self(rawValue: 1 << 3)
    static let package = Self(rawValue: 1 << 4)
    static let standalone = Self(rawValue: 1 << 5)
    static let gear = Self(rawValue: 1 << 6)
}

nonisolated struct InventoryPresentation: Sendable {
    let key: InventoryPresentationKey
    let identity = UUID()
    let packages: [GroupedHangarPackage]
    let fleet: [GroupedFleetShip]
    let buyback: [GroupedBuybackPledge]
    let packagesByID: [Int: GroupedHangarPackage]
    let fleetByID: [Int: GroupedFleetShip]
    let packageFlags: [String: InventoryFilterFlags]
    let buybackFlags: [String: InventoryFilterFlags]
    let fleetByGroupID: [String: GroupedFleetShip]
    let gameAccessPackages: [RSIGame: [RSIGamePackageMatch]]
    let hangarLogLookup: HangarLogInventoryLookup
    let buybackByGroupID: [String: GroupedBuybackPledge]

    static func build(snapshot: HangarSnapshot, key: InventoryPresentationKey,
                      reusing lookup: HangarLogInventoryLookup? = nil) throws -> Self {
        try Task.checkCancellation()
        let packages = snapshot.packages.groupedForInventoryDisplay
        try Task.checkCancellation()
        let fleet = snapshot.fleet.groupedForFleetDisplay
        try Task.checkCancellation()
        let buyback = snapshot.buyback.groupedForBuybackDisplay
        var packagesByID: [Int: GroupedHangarPackage] = [:], fleetByID: [Int: GroupedFleetShip] = [:]
        var packageFlags: [String: InventoryFilterFlags] = [:], buybackFlags: [String: InventoryFilterFlags] = [:]
        for group in packages {
            var flags: InventoryFilterFlags = []
            let package = group.representative
            if package.canGift { flags.insert(.giftable) }
            if package.canReclaim { flags.insert(.reclaimable) }
            if package.hasLifetimeInsurance { flags.insert(.lifetimeInsurance) }
            if package.hasUpgradeItems { flags.insert(.upgrade) }
            if package.isMultiShipPackage { flags.insert(.package) }
            packageFlags[group.id] = flags
            for package in group.packages { packagesByID[package.id] = group }
        }
        for group in fleet { for ship in group.ships { fleetByID[ship.id] = group } }
        for group in buyback {
            let pledge = group.representative
            var flags: InventoryFilterFlags = []
            switch pledge.inventoryKind {
            case .standalone: flags.insert(.standalone)
            case .package: flags.insert(.package)
            case .upgrade: flags.insert(.upgrade)
            case .gear: flags.insert(.gear)
            case .skin: break
            }
            buybackFlags[group.id] = flags
        }
        try Task.checkCancellation()
        let hangarLogLookup: HangarLogInventoryLookup
        if let lookup, lookup.matches(snapshot: snapshot, accountID: key.accountID) {
            hangarLogLookup = lookup
        } else {
            hangarLogLookup = HangarLogInventoryLookup(accountID: key.accountID, packages: snapshot.packages,
                fleet: snapshot.fleet, packageGroups: packages, shipGroups: fleet)
        }
        try Task.checkCancellation()
        return Self(key: key, packages: packages, fleet: fleet, buyback: buyback, packagesByID: packagesByID,
                    fleetByID: fleetByID, packageFlags: packageFlags, buybackFlags: buybackFlags,
                    fleetByGroupID: Dictionary(fleet.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                    gameAccessPackages: try RSIGamePackageResolver.index(packages: snapshot.packages),
                    hangarLogLookup: hangarLogLookup,
                    buybackByGroupID: Dictionary(buyback.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
    }
}

actor InventoryPresentationBuilder {
    private var previousLogLookup: HangarLogInventoryLookup?
    func build(snapshot: HangarSnapshot, key: InventoryPresentationKey) throws -> InventoryPresentation {
        assert(!Thread.isMainThread)
        let value = try PerformanceTrace.measure("InventoryPresentation") {
            try InventoryPresentation.build(snapshot: snapshot, key: key, reusing: previousLogLookup)
        }
        previousLogLookup = value.hangarLogLookup
        return value
    }
}

/// One result per view, never a growing cache of arbitrary search queries.
@MainActor
final class InventoryQueryCache<Signature: Equatable, Value> {
    private var signature: Signature?
    private var cached: Value?
    func result(for signature: Signature, build: () -> Value) -> Value {
        if self.signature == signature, let cached { return cached }
        let value = build(); self.signature = signature; cached = value; return value
    }
}
