import Foundation
import Testing
@testable import Hanger_Express

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HangarLogPresentationTests {
    private let accountID = UUID()
    private let contextID = UUID()
    private let imageToken = UUID()

    private func entry(_ title: String) -> HangarLogEntry {
        .init(id: "same-log-id", occurredAt: .distantPast, action: .created, itemName: title,
              operatorName: nil, priceUSD: nil, sourcePledgeID: nil, targetPledgeID: "1",
              orderCode: nil, reason: nil, rawText: title)
    }
    private func value(_ epoch: UInt64, title: String = "Original", account: UUID? = nil,
                       context: UUID? = nil, hasSnapshot: Bool = true) -> HangarLogPresentationSnapshot {
        let key = HangarLogPresentationKey(accountID: account ?? accountID, accountContextID: context ?? contextID,
            hasSnapshot: hasSnapshot, logContentEpoch: epoch, previewEpoch: 0, usesPreview: false,
            inventoryLookupID: nil, isPro: false, hangarLogEntryLimit: 5, imageReloadToken: imageToken)
        return .init(key: key, hangarLogs: hasSnapshot ? [entry(title)] : [], lookup: .empty)
    }

    @Test func latestSameIDChangesWaitForRefreshAndInteractionThenApply() {
        var buffer = HangarLogPresentationBuffer()
        buffer.receive(value(1), isRefreshing: false, isInteracting: false)
        buffer.receive(value(2, title: "First edit"), isRefreshing: true, isInteracting: false)
        buffer.receive(value(3, title: "Latest edit"), isRefreshing: true, isInteracting: true)
        #expect(buffer.displayed.hangarLogs.first?.itemName == "Original")
        #expect(buffer.pending?.hangarLogs.first?.itemName == "Latest edit")
        buffer.applyPending(isRefreshing: false, isInteracting: true)
        #expect(buffer.displayed.key.logContentEpoch == 1)
        buffer.applyPending(isRefreshing: true, isInteracting: false)
        #expect(buffer.displayed.key.logContentEpoch == 1)
        buffer.applyPending(isRefreshing: false, isInteracting: false)
        #expect(buffer.displayed.hangarLogs.first?.itemName == "Latest edit")
        #expect(buffer.pending == nil)
    }

    @Test func explicitShowOverridesInteractionAndRevertedSourceDiscardsPending() {
        var buffer = HangarLogPresentationBuffer()
        buffer.receive(value(1), isRefreshing: false, isInteracting: false)
        buffer.receive(value(2), isRefreshing: true, isInteracting: true)
        buffer.applyPending(isRefreshing: true, isInteracting: true, force: true)
        #expect(buffer.displayed.key.logContentEpoch == 2 && buffer.pending == nil)
        buffer.receive(value(3), isRefreshing: false, isInteracting: true)
        buffer.receive(value(2), isRefreshing: false, isInteracting: true)
        #expect(buffer.pending == nil)
    }

    @Test func accountSwitchResetAndSameAccountReauthenticationNeverBufferPrivateRows() {
        var buffer = HangarLogPresentationBuffer()
        buffer.receive(value(1), isRefreshing: false, isInteracting: false)
        buffer.receive(value(2), isRefreshing: true, isInteracting: true)
        let other = UUID()
        buffer.receive(value(3, title: "Other account", account: other), isRefreshing: true, isInteracting: true)
        #expect(buffer.displayed.key.accountID == other && buffer.pending == nil)
        buffer.receive(value(4, hasSnapshot: false), isRefreshing: true, isInteracting: true)
        #expect(buffer.displayed.hangarLogs.isEmpty && buffer.pending == nil)
        buffer.receive(value(5), isRefreshing: false, isInteracting: false)
        buffer.receive(value(6, title: "Fresh login", context: UUID()), isRefreshing: true, isInteracting: true)
        #expect(buffer.displayed.hangarLogs.first?.itemName == "Fresh login" && buffer.pending == nil)
    }

    @Test func lookupsReuseAcrossUnrelatedContentButRebuildSameIDPackageAndFleetChanges() async throws {
        let workload = BenchmarkInventory.make(pledgeCount: 100)
        let builder = InventoryPresentationBuilder()
        func key(_ epoch: UInt64, account: UUID? = nil) -> InventoryPresentationKey {
            .init(accountID: account ?? workload.session.id, hangarRevision: 1, buybackRevision: epoch, contentEpoch: epoch)
        }
        let first = try await builder.build(snapshot: workload.snapshot, key: key(1))
        let unrelated = workload.snapshot.updatingBuyback(buyback: [])
        let second = try await builder.build(snapshot: unrelated, key: key(2))
        #expect(first.hangarLogLookup.identity == second.hangarLogLookup.identity)
        let originalPackage = try #require(workload.snapshot.packages.first)
        var packageJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(originalPackage)) as? [String: Any])
        packageJSON["title"] = "Changed title with unchanged ID"
        let edited = try JSONDecoder().decode(HangarPackage.self, from: JSONSerialization.data(withJSONObject: packageJSON))
        let originalShip = try #require(workload.snapshot.fleet.first)
        var shipJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(originalShip)) as? [String: Any])
        shipJSON["displayName"] = "Changed ship with unchanged ID"
        let editedShip = try JSONDecoder().decode(FleetShip.self, from: JSONSerialization.data(withJSONObject: shipJSON))
        let changed = workload.snapshot.updatingHangar(
            packages: workload.snapshot.packages.map { $0.id == edited.id ? edited : $0 },
            fleet: workload.snapshot.fleet.map { $0.id == editedShip.id ? editedShip : $0 })
        let third = try await builder.build(snapshot: changed, key: key(3))
        #expect(third.hangarLogLookup.identity != second.hangarLogLookup.identity)
        #expect(third.hangarLogLookup.packageByPledgeID[edited.id]?.title == edited.title)
        #expect(third.hangarLogLookup.packageGroupByNormalizedTitle[hangarLogNormalizedLookupText(edited.title)] != nil)
        let destination = try #require(third.hangarLogLookup.shipGroupByNormalizedName[hangarLogNormalizedLookupText(editedShip.displayName)])
        #expect(destination.ships.contains { $0.id == editedShip.id && $0.displayName == editedShip.displayName })
        #expect(editedShip.displayName != originalShip.displayName)
        let other = try await builder.build(snapshot: changed, key: key(4, account: UUID()))
        #expect(other.hangarLogLookup.identity != third.hangarLogLookup.identity)
    }
}
