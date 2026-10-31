import Foundation
import Testing
@testable import Hanger_Express

@MainActor
struct ReferralRewardsTests {
    let resources = TestResources()
    private func data(thresholds: [Int] = [1, 10], image: String = "https://example.invalid/reward.jpg", version: Int = 1) throws -> Data {
        let rewards = thresholds.map { ["threshold": $0, "title": "Reward \($0)", "imageURL": image] as [String: Any] }
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": version, "reviewedAt": "2026-10-28", "current": rewards, "legacy": rewards])
    }

    @Test func unavailableLegacyDoesNotBorrowCurrentCountOrInventZero() {
        let stats = ReferralStats(currentLadderCount: 12, legacyLadderCount: 99, hasLegacyLadder: false)
        #expect(ReferralLadder.current.count(in: stats) == 12)
        #expect(ReferralLadder.legacy.count(in: stats) == nil)
        #expect(ReferralLadder.current.count(in: .unavailable) == nil)
    }

    @Test func laddersRetainIndependentCountsAndZeroIsValid() {
        let stats = ReferralStats(currentLadderCount: 0, legacyLadderCount: 14, hasLegacyLadder: true)
        #expect(ReferralLadder.current.count(in: stats) == 0)
        #expect(ReferralLadder.legacy.count(in: stats) == 14)
        #expect(ReferralLadder.current.count(in: ReferralStats(currentLadderCount: -1, legacyLadderCount: nil, hasLegacyLadder: false)) == nil)
    }

    @Test func rejectsMalformedMilestonesAndUnsafeImages() throws {
        for thresholds in [[], [0], [-1], [10, 1], [1, 1]] {
            #expect(throws: (any Error).self) { try ReferralRewardsCatalog.decode(data(thresholds: thresholds)) }
        }
        for image in ["http://example.invalid/a.jpg", "file:///tmp/a.jpg", "https://user:secret@example.invalid/a.jpg"] {
            #expect(throws: (any Error).self) { try ReferralRewardsCatalog.decode(data(image: image)) }
        }
        #expect(throws: (any Error).self) { try ReferralRewardsCatalog.decode(data(version: 2)) }
    }

    @Test func pictureProportionsAreOptionalAndRejectInvalidLayoutSizes() throws {
        let original = try data()
        #expect(try ReferralRewardsCatalog.decode(original).current[0].imageAspectRatio == nil)
        for ratio in [0.0, -1.0, 10.0, 285.0 / 120.0] {
            var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var rewards = try #require(json["legacy"] as? [[String: Any]])
            rewards[0]["imageAspectRatio"] = ratio
            json["legacy"] = rewards
            let encoded = try JSONSerialization.data(withJSONObject: json)
            if ratio > 0 && ratio <= 5 {
                #expect(try ReferralRewardsCatalog.decode(encoded).legacy[0].imageAspectRatio == ratio)
            } else {
                #expect(throws: (any Error).self) { try ReferralRewardsCatalog.decode(encoded) }
            }
        }
    }

    @Test func offlineCatalogRetainsBothLaddersWithoutPersonalData() async throws {
        let payload = try data()
        let urls = [URL(string: "https://example.invalid/referral-rewards.json")!]
        let directory = resources.temporaryDirectory()
        let online = resources.session { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Cache-Control": "public, max-age=0"])!, payload)
        }
        let first = HostedReferralRewardsClient(urls: urls, session: online, directory: directory)
        #expect(try await first.load().current.map(\.threshold) == [1, 10])
        let offline = resources.session { _ in throw URLError(.notConnectedToInternet) }
        let restored = HostedReferralRewardsClient(urls: urls, session: offline, directory: directory)
        let catalog = try await restored.load()
        #expect(catalog.legacy.map(\.threshold) == [1, 10])
    }
}
