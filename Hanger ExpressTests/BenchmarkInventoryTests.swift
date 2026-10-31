import Foundation
import Testing
@testable import Hanger_Express

@MainActor
struct BenchmarkInventoryTests {
    @Test func fixturesAreDeterministicAndContainRepresentativeRows() throws {
        let first = BenchmarkInventory.make(pledgeCount: 100)
        let second = BenchmarkInventory.make(pledgeCount: 100)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(first.snapshot) == encoder.encode(second.snapshot))
        #expect(first.snapshot.packages.count == 100)
        #expect(first.snapshot.buyback.count == 25)
        #expect(first.snapshot.packages.contains { $0.contents.contains { $0.category == .upgrade } })
        #expect(first.snapshot.packages.contains { $0.contents.filter { $0.category == .ship }.count > 1 })
        #expect(first.session.cookies.isEmpty)
        #expect(first.session.credentials == nil)
        #expect(first.snapshot.packages.flatMap(\.contents).allSatisfy { $0.imageURL == nil })
    }

    @Test func multipleAccountsHaveSeparateIdentitiesAndDuplicateGroups() {
        let first = BenchmarkInventory.make(pledgeCount: 1_000)
        let other = BenchmarkInventory.make(pledgeCount: 1_000, accountIndex: 1)
        #expect(first.session.accountKey != other.session.accountKey)
        #expect(Set(first.snapshot.packages.map(\.id)).isDisjoint(with: other.snapshot.packages.map(\.id)))
        #expect(first.snapshot.packages.groupedForInventoryDisplay.count < 1_000)
    }

    @Test func buybackHeavySupplementPreservesUniqueGroupsAndStandardFixture() {
        let heavy = BenchmarkInventory.makeBuybackHeavy(pledgeCount: 100)
        #expect(heavy.snapshot.buyback.count == 200)
        #expect(heavy.snapshot.buyback.groupedForBuybackDisplay.count == 200)
        #expect(BenchmarkInventory.make(pledgeCount: 100).snapshot.buyback.count == 25)
        #expect(heavy.session.cookies.isEmpty && heavy.session.credentials == nil)
    }
}
