import Foundation
import Testing
@testable import Hanger_Express

@MainActor
struct SnapshotSectionTests {
    private var base: HangarSnapshot { PreviewHangarRepository.sampleSnapshot }
    @Test func logRefreshDoesNotMakeInventoryFreshAndNoOpKeepsContentRevision() {
        let original = base
        let next = original.updatingHangarLogs(hangarLogs: original.hangarLogs, lastSyncedAt: original.lastSyncedAt.addingTimeInterval(100))
        #expect(next.sections.hangar == original.sections.hangar)
        #expect(next.sections.buyback == original.sections.buyback)
        #expect(next.sections.hangarLog.refreshedAt != original.sections.hangarLog.refreshedAt)
        #expect(next.sections.hangarLog.contentRevision == original.sections.hangarLog.contentRevision)
    }
    @Test func changedInventoryAdvancesOneRevisionAndKeepsFleetWithPackages() {
        let original = base
        let next = original.updatingHangar(packages: [], fleet: [])
        #expect(next.sections.hangar.contentRevision == original.sections.hangar.contentRevision + 1)
        #expect(next.sections.account == original.sections.account)
        #expect(next.packages.isEmpty && next.fleet.isEmpty)
    }
    @Test func accountRefreshAndOptimisticRemovalDoNotResetInventoryAge() {
        let original = base
        let account = original.updatingAccount(avatarURL: original.avatarURL, primaryOrganization: original.primaryOrganization,
            didRefreshPrimaryOrganization: original.didRefreshPrimaryOrganization, storeCreditUSD: original.storeCreditUSD,
            totalSpendUSD: original.totalSpendUSD, referralStats: original.referralStats,
            lastSyncedAt: original.lastSyncedAt.addingTimeInterval(10_000))
        let optimistic = account.removingPackages(withIDs: Set(original.packages.map(\.id)), lastSyncedAt: account.lastSyncedAt)
        #expect(account.sections.hangar.refreshedAt == original.sections.hangar.refreshedAt)
        #expect(optimistic.sections.hangar.refreshedAt == original.sections.hangar.refreshedAt)
        #expect(optimistic.sections.hangar.contentRevision > original.sections.hangar.contentRevision)
    }

    @Test func mixedResultsKeepFailedSectionsAndTheirFreshness() {
        let original = base
        let changed = original.updatingBuyback(buyback: [])
        let date = original.lastSyncedAt.addingTimeInterval(100)
        let mixed = SnapshotRefreshMerger.merge(base: original, outcomes: [
            .hangar: .failure(requiresAuthentication: false), .buyback: .success(changed),
            .account: .failure(requiresAuthentication: true)
        ], at: date)
        #expect(mixed.packages == original.packages && mixed.fleet == original.fleet)
        #expect(mixed.sections.hangar.refreshedAt == original.sections.hangar.refreshedAt)
        #expect(mixed.sections.hangar.failedAt == date)
        #expect(mixed.buyback.isEmpty)
        #expect(mixed.sections.buyback.refreshedAt == date)
        #expect(mixed.sections.account.requiresAuthentication)
        let retry = SnapshotRefreshMerger.merge(base: mixed, outcomes: [.hangar: .success(original)], at: date.addingTimeInterval(1))
        #expect(retry.sections.hangar.failedAt == nil)
        #expect(retry.sections.account.failedAt == date)
    }

    @Test func sectionStateRoundTripsAndLegacyTimestampMigrates() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let snapshot = base.updatingBuyback(buyback: [], lastSyncedAt: Date(timeIntervalSince1970: 900))
        let roundtrip = try decoder.decode(HangarSnapshot.self, from: encoder.encode(snapshot))
        #expect(roundtrip.sections == snapshot.sections)
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(base)) as? [String: Any])
        object.removeValue(forKey: "sections")
        let legacy = try decoder.decode(HangarSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.sections.hangar.refreshedAt == legacy.lastSyncedAt)
        #expect(legacy.packages == base.packages)
    }
}
