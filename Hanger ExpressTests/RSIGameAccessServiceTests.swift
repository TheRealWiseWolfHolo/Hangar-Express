import Foundation
import Testing
@testable import Hanger_Express

struct RSIGameAccessServiceTests {
    @Test func gameAccessPersistsWithAccountSnapshot() throws {
        let access = RSIGameAccessSummary(starCitizen: .granted, squadron42: .notGranted)
        let snapshot = HangarSnapshot(
            accountHandle: "test-citizen",
            lastSyncedAt: Date(timeIntervalSince1970: 0),
            storeCreditUSD: nil,
            packages: [],
            fleet: [],
            buyback: [],
            gameAccess: access
        )

        let restored = try JSONDecoder().decode(HangarSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.gameAccess == access)
        #expect(restored.updatingHangar(packages: [], fleet: []).gameAccess == access)
        #expect(restored.updatingBuyback(buyback: []).gameAccess == access)
        #expect(restored.updatingAccount(
            avatarURL: nil,
            primaryOrganization: nil,
            didRefreshPrimaryOrganization: false,
            storeCreditUSD: nil,
            totalSpendUSD: nil,
            referralStats: .unavailable
        ).gameAccess == access)

        let refreshWithoutEntitlements = HangarSnapshot(
            accountHandle: "test-citizen",
            lastSyncedAt: .now,
            storeCreditUSD: nil,
            packages: [],
            fleet: [],
            buyback: []
        )
        #expect(refreshWithoutEntitlements.preservingUnavailableProfile(from: restored).gameAccess == access)
    }

    @Test func legacySnapshotWithoutGameAccessStillLoads() throws {
        let snapshot = HangarSnapshot(
            accountHandle: "test-citizen",
            lastSyncedAt: Date(timeIntervalSince1970: 0),
            storeCreditUSD: nil,
            packages: [],
            fleet: [],
            buyback: []
        )

        let restored = try JSONDecoder().decode(HangarSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.gameAccess == nil)
    }

    @Test func currentGamesLibraryResponseLightsBothGames() throws {
        let response = Data(
            #"""
            {"data":{"account":{"isAnonymous":false},"gameEntitlements":[{"game":"SC","gameName":"Star Citizen","status":"active"},{"game":"SQ42","gameName":"Squadron 42","status":"active"}]}}
            """#.utf8
        )

        let summary = try RSIGameAccessService.decode(response)

        #expect(summary.access(for: .starCitizen) == .granted)
        #expect(summary.access(for: .squadron42) == .granted)
    }

    @Test func activeEntitlementsLightBothGames() throws {
        let response = Data(
            #"""
            {
              "data": {
                "account": {"isAnonymous": false},
                "gameEntitlements": [
                  {"game": "star-citizen", "gameName": "Star Citizen", "status": "active"},
                  {"game": "squadron-42", "gameName": "Squadron 42", "status": "ACTIVE"}
                ]
              }
            }
            """#.utf8
        )

        let summary = try RSIGameAccessService.decode(response)

        #expect(summary.access(for: .starCitizen) == .granted)
        #expect(summary.access(for: .squadron42) == .granted)
    }

    @Test func missingOrRevokedEntitlementIsDimmed() throws {
        let response = Data(
            #"""
            {
              "data": {
                "account": {"isAnonymous": false},
                "gameEntitlements": [
                  {"gameName": "Squadron 42", "status": "revoked"}
                ]
              }
            }
            """#.utf8
        )

        let summary = try RSIGameAccessService.decode(response)

        #expect(summary.access(for: .starCitizen) == .notGranted)
        #expect(summary.access(for: .squadron42) == .notGranted)
    }

    @Test func unknownStatusDoesNotClaimAccess() throws {
        let response = Data(
            #"""
            {"data":{"account":{"isAnonymous":false},"gameEntitlements":[{"gameName":"Star Citizen","status":"pending-review"}]}}
            """#.utf8
        )

        let summary = try RSIGameAccessService.decode(response)

        #expect(summary.access(for: .starCitizen) == .unknown)
    }

    @Test func GraphQLErrorsDoNotLookLikeMissingAccess() {
        let response = Data(
            #"""
            {"data":{"account":{"isAnonymous":false},"gameEntitlements":[]},"errors":[{"message":"Not authenticated"}]}
            """#.utf8
        )

        #expect(throws: Error.self) {
            try RSIGameAccessService.decode(response)
        }
    }

    @Test func anonymousEmptyEntitlementsDoNotLookLikeMissingAccess() {
        let response = Data(
            #"""
            {"data":{"account":{"isAnonymous":true},"gameEntitlements":[]}}
            """#.utf8
        )

        #expect(throws: Error.self) {
            try RSIGameAccessService.decode(response)
        }
    }
}
