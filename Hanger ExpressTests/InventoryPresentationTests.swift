import Foundation
import Testing
@testable import Hanger_Express

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct InventoryPresentationTests {
    let resources = TestResources()
    private func presentation(_ workload: BenchmarkInventory.Workload) async throws -> InventoryPresentation {
        try await InventoryPresentationBuilder().build(snapshot: workload.snapshot, key: .init(accountID: workload.session.id,
            hangarRevision: 1, buybackRevision: 1, contentEpoch: 1))
    }
    private func key(_ presentation: InventoryPresentation, language: HangarItemLanguage = .original, generation: Int = 0, upgraded: Bool = false, section: InventorySearchSection = .buyback) -> InventorySearchKey {
        InventorySearchKey(presentation: presentation.key, language: language.rawValue, dictionaryLocale: language == .original ? nil : "zh-Hans",
                           dictionaryVersion: language == .original ? nil : 1, cacheGeneration: generation, upgradedNames: upgraded, section: section)
    }

    @Test func backgroundPresentationPreservesGroupingStableIDsAndMemberLookups() async throws {
        let workload = BenchmarkInventory.make(pledgeCount: 1000)
        let index = try await presentation(workload)
        #expect(index.packages == workload.snapshot.packages.groupedForInventoryDisplay)
        #expect(index.fleet == workload.snapshot.fleet.groupedForFleetDisplay)
        #expect(index.buyback == workload.snapshot.buyback.groupedForBuybackDisplay)
        for group in index.packages {
            for package in group.packages { #expect(index.packagesByID[package.id]?.id == group.id) }
        }
        let group = try #require(index.fleet.first)
        #expect(GroupedFleetShip(representative: group.representative, ships: Array(group.ships.reversed())).id == group.id)
        #expect(index.fleetByGroupID[group.id] == group)
        let buyback = try #require(index.buyback.first)
        #expect(GroupedBuybackPledge(representative: buyback.representative, pledges: Array(buyback.pledges.reversed())).id == buyback.id)
        #expect(index.buybackByGroupID[buyback.id] == buyback)
    }

    @Test func translatedSearchInvalidatesForLanguageCachePreferenceAndAccountAndIsBounded() async throws {
        let workload = BenchmarkInventory.make(pledgeCount: 100)
        let index = try await presentation(workload)
        let source = try #require(index.buyback.first?.representative.title)
        let dictionary = try HangarItemTranslationDictionary(locale: "zh-Hans", version: 1, generatedAt: nil,
            entries: [.init(source: source, translation: "测试回购飞船", kind: "package", aliases: [])])
        let builder = InventorySearchBuilder()
        let english = InventoryTranslationContext(translator: .original, translations: [:])
        let first = try await builder.index(presentation: index, context: english, key: key(index))
        let reused = try await builder.index(presentation: index, context: english, key: key(index))
        #expect(first.buyback == reused.buyback)
        #expect(await builder.buildCount == 1)
        let chinese = InventoryTranslationContext(translator: .init(language: .simplifiedChinese, dictionary: dictionary), translations: [:])
        let translated = try await builder.index(presentation: index, context: chinese, key: key(index, language: .simplifiedChinese))
        let groupID = try #require(index.buyback.first?.id)
        #expect(translated.buyback[groupID]?.contains("测试回购飞船") == true)
        #expect(translated.buyback[groupID]?.contains(source.localizedLowercase) == true)
        _ = try await builder.index(presentation: index, context: chinese, key: key(index, language: .simplifiedChinese, generation: 1, upgraded: true))
        #expect(await builder.cachedContextCount == 1)
        _ = try await builder.index(presentation: index, context: chinese, key: key(index, language: .simplifiedChinese, section: .hangar))
        _ = try await builder.index(presentation: index, context: chinese, key: key(index, language: .simplifiedChinese, section: .fleet))
        #expect(await builder.cachedContextCount == 3)
        let other = try await presentation(BenchmarkInventory.make(pledgeCount: 100, accountIndex: 1))
        let otherValue = try await builder.index(presentation: other, context: english, key: key(other))
        #expect(otherValue.key.presentation.accountID != first.key.presentation.accountID)
        #expect(Set(otherValue.buyback.keys).isDisjoint(with: first.buyback.keys))
        #expect(await builder.cachedContextCount == 1)
    }

    @Test func queryCacheKeepsOnlyTheLatestSignatureAndPreservesResultIdentity() {
        let cache = InventoryQueryCache<Int, [Int]>()
        var builds = 0
        let first = cache.result(for: 1) { builds += 1; return [1] }
        let again = cache.result(for: 1) { builds += 1; return [] }
        #expect(first == again && builds == 1)
        _ = cache.result(for: 2) { builds += 1; return [2] }
        _ = cache.result(for: 1) { builds += 1; return [1] }
        #expect(builds == 3)
    }

    @Test func optimizedMatchingPreservesCanonicalAndGraphemeBoundaries() {
        let cases = [("👨‍👩‍👧", "👩"), ("a⃝", "a"), ("Café", "Café"), ("Café", "Café"),
                     ("星际公民", "星际"), ("Standalone Ship 123", "ship 12"), ("Not present", "different")]
        for (text, query) in cases {
            #expect(InventorySearchText(text.localizedLowercase).contains(InventorySearchQuery(query)) == text.localizedLowercase.contains(query.localizedLowercase))
        }
    }

    @Test func buybackClassificationKeepsSkinUpgradeGearAndPackagePrecedence() {
        let cases: [(String, BuybackPledge.InventoryKind)] = [
            ("Upgrade - Paint Ship to Titan", .upgrade), ("Avenger Paint", .skin),
            ("Starter Package with Helmet", .gear), ("Starter Package", .package),
            ("Avenger Standalone", .standalone), ("Unknown Pledge", .standalone)
        ]
        for (title, kind) in cases {
            let pledge = BuybackPledge(id: 1, title: title, recoveredValueUSD: 1, addedToBuybackAt: .distantPast, notes: "")
            #expect(pledge.inventoryKind == kind)
        }
    }

    @Test func flagsMatchExistingFilterSemantics() async throws {
        let index = try await presentation(BenchmarkInventory.makeBuybackHeavy(pledgeCount: 100))
        for group in index.packages {
            let flags = index.packageFlags[group.id] ?? []
            #expect(flags.contains(.lifetimeInsurance) == group.representative.hasLifetimeInsurance)
            #expect(flags.contains(.package) == group.representative.isMultiShipPackage)
            #expect(flags.contains(.upgrade) == group.representative.hasUpgradeItems)
        }
        for group in index.buyback {
            let flags = index.buybackFlags[group.id] ?? []
            #expect(flags.contains(.standalone) == group.representative.isStandaloneShip)
            #expect(flags.contains(.package) == group.representative.isPackage)
            #expect(flags.contains(.upgrade) == group.representative.isUpgrade)
            #expect(flags.contains(.gear) == group.representative.isGear)
        }
    }
}
