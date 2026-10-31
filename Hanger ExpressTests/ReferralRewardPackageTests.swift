import Foundation
import Testing
@testable import Hanger_Express

@MainActor
struct ReferralRewardPackageTests {
    private func reward(_ title: String, threshold: Int = 1) -> ReferralReward {
        .init(threshold: threshold, title: title, imageURL: URL(string: "https://example.invalid/reward.jpg")!)
    }
    private func package(_ id: Int, _ title: String, status: String = "Attributed", items: [PackageItem] = []) -> HangarPackage {
        .init(id: id, title: title, status: status, insurance: "LTI", acquiredAt: .distantPast,
              originalValueUSD: 0, currentValueUSD: 0, canGift: false, canReclaim: false,
              canUpgrade: false, contents: items)
    }
    private func matches(_ reward: ReferralReward, _ packages: [HangarPackage], ladder: ReferralLadder = .current) async throws -> [GroupedHangarPackage] {
        try await ReferralRewardPackageMatcher.shared.matches(reward: reward, ladder: ladder,
            groups: packages.groupedForInventoryDisplay)
    }

    @Test func findsPublishedReferralNamesAndFormattingVariants() async throws {
        let result = try await matches(reward("VOLT Quartz 'GCD-Army' SMG", threshold: 2), [
            package(1, "Gear - VOLT Quartz ‘GCD-Army’ SMG - Referral Reward"),
            package(2, "VOLT Quartz SMG")])
        #expect(result.flatMap(\.packages).map(\.id) == [1])
        let pulse = try await matches(reward("Mirai Pulse & 'GCD-Army' Paint", threshold: 4), [
            package(3, "Mirai Pulse and ‘GCD-Army’ Paint - Referral Reward")])
        #expect(pulse.first?.representative.id == 3)
    }

    @Test func legacyNumericRewardsDoNotMatchTheNewLadder() async throws {
        let saved = [package(1, "Referral 200")]
        #expect(try await matches(reward("Ready For Battle", threshold: 200), saved, ladder: .legacy).count == 1)
        #expect(try await matches(reward("Esperia Stinger", threshold: 200), saved).isEmpty)
        #expect(try await matches(reward("A different future award", threshold: 200), saved, ladder: .legacy).isEmpty)
    }

    @Test func doesNotGuessFromShipWordsUpgradesOrGenericReferralItems() async throws {
        let ship = PackageItem(id: "ship", title: "Stinger", detail: "Medium Fighter", category: .ship, imageURL: nil, upgradePricing: nil)
        let saved = [package(1, "Standalone Ships - Stinger", items: [ship]),
                     package(2, "Upgrade - Apollo to Stinger"), package(3, "Referral Bonus")]
        #expect(try await matches(reward("Esperia Stinger", threshold: 200), saved).isEmpty)
        let referralShip = PackageItem(id: "ship", title: "Stinger", detail: "Referral reward", category: .ship, imageURL: nil, upgradePricing: nil)
        #expect(try await matches(reward("Esperia Stinger", threshold: 200), [package(4, "Referral ship", items: [referralShip])]).first?.representative.id == 4)
    }

    @Test func prefersExplicitRewardPledgesAndRetainsDistinctChoicesAndCopies() async throws {
        let name = "CDS GCD-Army Medium Armor Set"
        let items = [PackageItem(id: "armor", title: name, detail: "Armor", category: .flair, imageURL: nil, upgradePricing: nil)]
        let result = try await matches(reward(name), [package(1, "A bundle", items: items),
            package(2, name + " - Referral Reward"), package(3, name + " - Referral Reward"),
            package(4, "Gear - " + name + " - Referral Reward")])
        #expect(result.count == 2)
        #expect(Set(result.flatMap(\.packages).map(\.id)) == [2,3,4])
        #expect(result.contains { $0.quantity == 2 })
    }

    @Test func ignoresRemovedPledgesButKeepsGiftableEntries() async throws {
        let result = try await matches(reward("Badger and Badges"), [
            package(1, "Badger and Badges", status: "Reclaimed"),
            package(2, "Badger and Badges", status: "Gifted"),
            package(3, "Badger and Badges", status: "Attributed - Giftable")], ladder: .legacy)
        #expect(result.flatMap(\.packages).map(\.id) == [3])
    }
}
