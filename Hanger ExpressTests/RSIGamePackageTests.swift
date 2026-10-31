import Foundation
import Testing
@testable import Hanger_Express

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RSIGamePackageTests {
    private func item(_ title: String, detail: String = "Game access", category: PackageItem.Category = .gamePackage) -> PackageItem {
        .init(id: title, title: title, detail: detail, category: category, imageURL: nil, upgradePricing: nil)
    }
    private func package(_ id: Int, _ contents: [PackageItem], title: String = "Starter Pack", status: String = "Attributed") -> HangarPackage {
        .init(id: id, title: title, status: status, insurance: "LTI", acquiredAt: .distantPast,
              originalValueUSD: 45, currentValueUSD: 45, canGift: false, canReclaim: false,
              canUpgrade: false, contents: contents)
    }

    @Test func indexesEachGameAndKeepsAllCopiesWithTheirEvidence() throws {
        let sc = item("Star Citizen Digital Download"), sq = item("Squadron 42 Digital Download")
        let values = [package(1,[sc]), package(2,[sq]), package(3,[sc,sq]), package(4,[sc])]
        let result = try RSIGamePackageResolver.index(packages: values)
        #expect(result[.starCitizen]?.map(\.id) == [1,3,4])
        #expect(result[.squadron42]?.map(\.id) == [2,3])
        #expect(result[.starCitizen]?.first?.accessItems == [sc])
        #expect(result[.squadron42]?.last?.accessItems == [sq])
    }

    @Test func doesNotInferAccessFromMarketingShipNamesMerchandiseOrGenericPackages() throws {
        let cases = [package(1,[],title: "Star Citizen Game Package"),
            package(2,[item("Star Citizen Birthday Paint", category: .flair)]),
            package(3,[item("Squadron 42 Soundtrack Digital Download", category: .flair)]),
            package(4,[item("Digital Download")]),
            package(5,[item("Squadron 420 Digital Download")]),
            package(6,[item("Squadron 42", detail: "No game access")]),
            package(7,[item("Star Citizen", detail: "Not included")])]
        let result = try RSIGamePackageResolver.index(packages: cases)
        #expect(result[.starCitizen]?.isEmpty == true)
        #expect(result[.squadron42]?.isEmpty == true)
    }

    @Test func supportsExplicitNamesCombinedLicensesAndFormattingVariants() {
        #expect(RSIGamePackageResolver.games(in: item("STAR CITIZEN® Digital Download")) == [.starCitizen])
        #expect(RSIGamePackageResolver.games(in: item("ＳＱ４２ Digital Download")) == [.squadron42])
        #expect(RSIGamePackageResolver.games(in: item("Star Citizen and Squadron 42 Digital Download")) == [.starCitizen,.squadron42])
        #expect(RSIGamePackageResolver.games(in: item("星际公民数字版")) == [.starCitizen])
        #expect(RSIGamePackageResolver.games(in: item("42中队", detail: "游戏权限")) == [.squadron42])
        #expect(RSIGamePackageResolver.games(in: item("Star Citizen", detail: "", category: .gamePackage)) == [.starCitizen])
        #expect(RSIGamePackageResolver.games(in: item("Star Citizen", detail: "Poster", category: .flair)).isEmpty)
    }

    @Test func excludesRemovedPledgesButDoesNotConfuseGiftableWithGifted() throws {
        let sc = item("Star Citizen Digital Download")
        let result = try RSIGamePackageResolver.index(packages: [package(1,[sc],status:"Gifted"),
            package(2,[sc],status:"Reclaimed"),package(3,[sc],status:"Cancelled"),
            package(4,[sc],status:"Attributed - Giftable")])
        #expect(result[.starCitizen]?.map(\.id) == [4])
    }

    @Test func liveNormalizationRetainsSupplementalGameDownloadsForMatching() async throws {
        let data = Data(#"""
        {"id":123,"title":"Dual Game Package","statusText":"Attributed","dateText":"Oct 27, 2026",
         "valueText":"$100.00","containsText":"Avenger Titan","alsoContains":["Star Citizen Digital Download","Squadron 42 Digital Download"],
         "canGift":false,"canReclaim":false,"canUpgrade":false,
         "items":[{"title":"Avenger Titan","kind":"Ship","detail":"Light Freight"}]}
        """#.utf8)
        let remote = try JSONDecoder().decode(RemotePledge.self, from: data)
        let normalized = try await HangarInventoryNormalizer().hangar([remote], catalog: nil)
        let result = try RSIGamePackageResolver.index(packages: normalized.packages)
        #expect(result[.starCitizen]?.map(\.id) == [123])
        #expect(result[.squadron42]?.map(\.id) == [123])
    }

    @Test func presentationRebuildReflectsSameIDContentsInsteadOfGrantingFromAccountStatus() async throws {
        let builder = InventoryPresentationBuilder(), id = UUID()
        let sc = item("Star Citizen Digital Download")
        func snapshot(_ contents: [PackageItem]) -> HangarSnapshot {
            .init(accountHandle: "fixture", lastSyncedAt: .distantPast, storeCreditUSD: nil,
                  packages: [package(1, contents)], fleet: [], buyback: [],
                  gameAccess: .init(starCitizen: .granted, squadron42: .granted))
        }
        let first = try await builder.build(snapshot: snapshot([sc]), key: .init(accountID: id, hangarRevision: 1, buybackRevision: 1, contentEpoch: 1))
        #expect(first.gameAccessPackages[.starCitizen]?.count == 1)
        #expect(first.gameAccessPackages[.squadron42]?.isEmpty == true)
        let next = try await builder.build(snapshot: snapshot([]), key: .init(accountID: id, hangarRevision: 1, buybackRevision: 1, contentEpoch: 2))
        #expect(next.gameAccessPackages[.starCitizen]?.isEmpty == true)
        #expect(next.gameAccessPackages[.squadron42]?.isEmpty == true)
    }
}
