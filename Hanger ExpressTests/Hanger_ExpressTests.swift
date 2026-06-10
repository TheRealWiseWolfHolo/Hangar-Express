import Foundation
import Testing
import UIKit
import WebKit
@testable import Hanger_Express

@MainActor
struct Hanger_ExpressTests {
    @Test func sampleSnapshotRollsUpMetrics() async throws {
        let snapshot = PreviewHangarRepository.sampleSnapshot

        #expect(snapshot.metrics.packageCount == 4)
        #expect(snapshot.metrics.shipCount == 4)
        #expect(snapshot.metrics.giftableCount == 2)
        #expect(snapshot.metrics.reclaimableCount == 3)
        #expect(snapshot.metrics.storeCreditUSD == 145)
        #expect(snapshot.metrics.totalSpendUSD == 1215)
        #expect(snapshot.metrics.totalOriginalValue == 1070)
        #expect(snapshot.metrics.totalCurrentValue == 1295)
        #expect(snapshot.referralStats.currentLadderCount == 18)
        #expect(snapshot.referralStats.legacyLadderCount == 7)
        #expect(snapshot.referralStats.hasLegacyLadder)
    }

    @Test func hostedLimitedShipFeedDecodesRequiredFields() throws {
        let data = Data(
            #"""
            {
              "ships": [
                {
                  "id": "gladius-standalone",
                  "name": "Gladius",
                  "manufacturer": "Aegis Dynamics",
                  "priceUsd": 90,
                  "availabilitySlots": [
                    {
                      "startsAt": "2026-05-01T00:00:00Z",
                      "endsAt": "2026-12-31T23:59:59Z"
                    }
                  ],
                  "storeUrl": "https://example.com/gladius"
                }
              ]
            }
            """#.utf8
        )

        let ships = try HostedLimitedShipSaleClient.decodeSales(from: data)

        #expect(ships.count == 1)
        #expect(ships.first?.name == "Gladius")
        #expect(ships.first?.priceUSD == 90)
    }

    @Test func hostedLimitedShipFeedRejectsInvalidData() throws {
        let data = Data(
            #"""
            {
              "ships": [
                {
                  "id": "gladius-standalone",
                  "name": "Gladius",
                  "availabilitySlots": [],
                  "storeUrl": "https://example.com/gladius"
                }
              ]
            }
            """#.utf8
        )

        var didThrowInvalidFeedError = false
        do {
            _ = try HostedLimitedShipSaleClient.decodeSales(from: data)
        } catch let error as HostedShipCatalogError {
            didThrowInvalidFeedError = true
            #expect(error.errorDescription?.contains("missing priceUsd") == true)
        }

        #expect(didThrowInvalidFeedError)
    }

    @Test func sessionCookieRoundTripsBackToHTTPCookie() async throws {
        let expiresAt = Date(timeIntervalSince1970: 1_800_000_000)
        let sourceCookie = try #require(
            HTTPCookie(
                properties: [
                    .name: "Rsi-Token",
                    .value: "cookie-value",
                    .domain: ".robertsspaceindustries.com",
                    .path: "/",
                    .expires: expiresAt,
                    .secure: "TRUE",
                    HTTPCookiePropertyKey("HttpOnly"): "TRUE"
                ]
            )
        )

        let storedCookie = SessionCookie(sourceCookie)
        let rebuiltCookie = try #require(storedCookie.httpCookie)

        #expect(rebuiltCookie.name == sourceCookie.name)
        #expect(rebuiltCookie.value == sourceCookie.value)
        #expect(rebuiltCookie.domain == sourceCookie.domain)
        #expect(rebuiltCookie.path == sourceCookie.path)
        #expect(rebuiltCookie.expiresDate == expiresAt)
        #expect(rebuiltCookie.isSecure)
        #expect(rebuiltCookie.isHTTPOnly)
    }

    @Test func subscriptionEntitlementsClampRefreshWorkersByPlan() async throws {
        #expect(ProSubscriptionConfiguration.productIDs == Set(["0001", "0002", "HangarExpLTI"]))
        #expect(ProSubscriptionConfiguration.productIDOrder == ["0001", "0002", "HangarExpLTI"])
        #expect(ProSubscriptionConfiguration.isLifetimeProductID("HangarExpLTI"))
        #expect(ProSubscriptionConfiguration.isSubscriptionProductID("0001"))
        #expect(ProSubscriptionConfiguration.isSubscriptionProductID("0002"))
        #expect(!ProSubscriptionConfiguration.isSubscriptionProductID("HangarExpLTI"))
        #expect(ProSubscriptionConfiguration.allowsPurchasing("HangarExpLTI", withActiveProductIDs: []))
        #expect(!ProSubscriptionConfiguration.allowsPurchasing("HangarExpLTI", withActiveProductIDs: ["0001"]))
        #expect(!ProSubscriptionConfiguration.allowsPurchasing("HangarExpLTI", withActiveProductIDs: ["0002"]))
        #expect(!ProSubscriptionConfiguration.allowsPurchasing("0001", withActiveProductIDs: ["HangarExpLTI"]))
        #expect(!ProSubscriptionConfiguration.allowsPurchasing("0002", withActiveProductIDs: ["HangarExpLTI"]))
        #expect(ProSubscriptionConfiguration.allowsPurchasing("0002", withActiveProductIDs: ["0001"]))
        #expect(!ProSubscriptionConfiguration.allowsPurchasing("unknown", withActiveProductIDs: []))
        let lifetimeDetails = ProSubscriptionDetails(
            productID: "HangarExpLTI",
            displayName: "Early Access for Life",
            nextRenewalDate: nil,
            expirationDate: nil,
            willAutoRenew: nil
        )
        #expect(lifetimeDetails.isLifetime)
        #expect(SyncPreferences.constrainedWorkerCount(10, isPro: false) == 2)
        #expect(SyncPreferences.constrainedWorkerCount(0, isPro: false) == 1)
        #expect(SyncPreferences.constrainedWorkerCount(10, isPro: true) == 10)
        #expect(SyncPreferences.constrainedWorkerCount(11, isPro: true) == 10)
        #expect(ProSubscriptionConfiguration.savedAccountLimit(isPro: false) == 1)
        #expect(ProSubscriptionConfiguration.savedAccountLimit(isPro: true) == 10)

        let suiteName = "SubscriptionStoreTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        userDefaults.set(["HangarExpLTI"], forKey: ProSubscriptionConfiguration.activeProductIDsDefaultsKey)

        let subscriptionStore = SubscriptionStore(userDefaults: userDefaults, storeKitEnabled: false)
        #expect(subscriptionStore.hasLifetimePro)
        #expect(!subscriptionStore.hasActiveProSubscription)
    }

    @Test func hangarLogFetchModesRespectSubscriptionLimits() async throws {
        #expect(HangarLogFetchMode.initial.entryLimit(isPro: false) == 5)
        #expect(HangarLogFetchMode.initial.entryLimit(isPro: true) == 5)
        #expect(HangarLogFetchMode.expanded.entryLimit(isPro: false) == 5)
        #expect(HangarLogFetchMode.expanded.entryLimit(isPro: true) == 500)
    }

    @Test func hangarLogUpgradeContextInfersShipPathFromCCUTitles() async throws {
        let context = try #require(
            HangarLogUpgradeContext.inferred(
                from: [
                    "Zeus MR upgrade",
                    "Upgrade - Cutlass Black to Zeus Mk II MR CCU"
                ]
            )
        )

        #expect(context.sourceShipName == "Cutlass Black")
        #expect(context.targetShipName == "Zeus Mk II MR")
        #expect(context.upgradeName == "Cutlass Black to Zeus Mk II MR")
        #expect(context.summaryText == "Cutlass Black to Zeus Mk II MR")
    }

    @Test func hangarLogEntryDecodesLegacyCacheWithoutUpgradeContext() async throws {
        let json = #"""
        {
          "id": "legacy-upgrade-1",
          "occurredAt": "2026-04-18T12:00:00Z",
          "action": "APPLIED_UPGRADE",
          "itemName": "Legacy Upgrade",
          "operatorName": "CIG",
          "priceUSD": 190,
          "sourcePledgeID": "1002",
          "targetPledgeID": "1003",
          "reason": "Cutlass Black to Zeus Mk II MR CCU",
          "rawText": "#1003 - Upgrade applied: #1002 Cutlass Black to Zeus Mk II MR CCU, new value: $190.00 USD"
        }
        """#

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let entry = try decoder.decode(HangarLogEntry.self, from: Data(json.utf8))

        #expect(entry.action == .appliedUpgrade)
        #expect(entry.upgradeContext == nil)
        #expect(entry.targetPledgeID == "1003")
    }

    @Test func ccuPlannerBuildsLowestNewPurchaseChainFromHangarAndBuyback() throws {
        let catalogShips = CCUUpgradeCatalogShip.makeShips(from: makeCCUTestCatalog())
        let snapshot = makeCCUTestSnapshot(
            storeCreditUSD: 50,
            packages: [
                makeCCUTestUpgradePackage(
                    id: 100,
                    title: "Aurora MR to 300i Standard Upgrade",
                    source: "Aurora MR",
                    target: "300i",
                    currentValueUSD: 30,
                    meltValueUSD: 35
                ),
                makeCCUTestUpgradePackage(
                    id: 101,
                    title: "300i to Cutlass Black Warbond Upgrade",
                    source: "300i",
                    target: "Cutlass Black",
                    currentValueUSD: 50,
                    meltValueUSD: 20
                )
            ],
            buyback: [
                BuybackPledge(
                    id: 200,
                    title: "Cutlass Black to Zeus Mk II MR CCU",
                    recoveredValueUSD: 70,
                    addedToBuybackAt: Date(timeIntervalSince1970: 1_800),
                    notes: "Recovered from buy back."
                )
            ]
        )

        let source = try #require(catalogShips.first { $0.name == "Aurora MR" })
        let destination = try #require(catalogShips.first { $0.name == "Zeus Mk II MR" })
        let route = try #require(
            CCUUpgradePlanner.bestRoute(
                from: source,
                to: destination,
                snapshot: snapshot,
                catalogShips: catalogShips
            )
        )

        #expect(route.steps.map(\.kind) == [
            .hangarStandardMeltAboveCurrent,
            .hangarWarbond,
            .buyback
        ])
        #expect(route.totalNewPurchaseCostUSD == 70)
        #expect(route.totalStoreCreditNeededUSD == 50)
        #expect(route.totalNewMoneyNeededUSD == 20)
        #expect(route.totalEffectiveCostUSD == 125)
        #expect(route.totalSavingsUSD == 35)
        #expect(!route.hasUnavailableStoreStep)

        let buybackStep = try #require(route.steps.first { $0.kind == .buyback })
        let buybackPayment = try #require(route.paymentRequirement(for: buybackStep))
        #expect(buybackPayment.purchaseCostUSD == 70)
        #expect(buybackPayment.storeCreditUSD == 50)
        #expect(buybackPayment.newMoneyUSD == 20)
    }

    @Test func ccuPlannerChoosesHighestSavingOwnedWarbondUpgrade() throws {
        let catalogShips = CCUUpgradeCatalogShip.makeShips(from: makeCCUTestCatalog())
        let snapshot = makeCCUTestSnapshot(
            packages: [
                makeCCUTestUpgradePackage(
                    id: 100,
                    title: "300i to Cutlass Black Warbond Upgrade",
                    source: "300i",
                    target: "Cutlass Black",
                    currentValueUSD: 50,
                    meltValueUSD: 30
                ),
                makeCCUTestUpgradePackage(
                    id: 101,
                    title: "300i to Cutlass Black Warbond Upgrade - Best",
                    source: "300i",
                    target: "Cutlass Black",
                    currentValueUSD: 50,
                    meltValueUSD: 20
                )
            ],
            buyback: []
        )

        let source = try #require(catalogShips.first { $0.name == "300i" })
        let destination = try #require(catalogShips.first { $0.name == "Cutlass Black" })
        let route = try #require(
            CCUUpgradePlanner.bestRoute(
                from: source,
                to: destination,
                snapshot: snapshot,
                catalogShips: catalogShips
            )
        )

        #expect(route.steps.count == 1)
        #expect(route.steps.first?.title == "300i to Cutlass Black Warbond Upgrade - Best")
        #expect(route.steps.first?.effectiveCostUSD == 20)
        #expect(route.totalSavingsUSD == 30)
    }

    @Test func ccuPlannerWarnsWhenOnlyUnavailableStoreCCUCompletesRoute() throws {
        let catalogShips = CCUUpgradeCatalogShip.makeShips(from: makeCCUTestCatalog())
        let snapshot = makeCCUTestSnapshot(packages: [], buyback: [])

        let source = try #require(catalogShips.first { $0.name == "Aurora MR" })
        let destination = try #require(catalogShips.first { $0.name == "Zeus Mk II MR" })
        let route = try #require(
            CCUUpgradePlanner.bestRoute(
                from: source,
                to: destination,
                snapshot: snapshot,
                catalogShips: catalogShips
            )
        )

        #expect(route.steps.count == 1)
        #expect(route.steps.first?.kind == .unavailableStore)
        #expect(route.hasUnavailableStoreStep)
        #expect(route.totalNewPurchaseCostUSD == 160)
    }

    @Test func ccuPlannerUsesStoreInsteadOfNoSavingBuybackWhenStoreAvailable() throws {
        let catalogShips = CCUUpgradeCatalogShip.makeShips(from: makeCCUTestCatalog())
        let snapshot = makeCCUTestSnapshot(
            storeCreditUSD: 10,
            packages: [],
            buyback: [
                BuybackPledge(
                    id: 201,
                    title: "300i to Cutlass Black CCU",
                    recoveredValueUSD: 50,
                    addedToBuybackAt: Date(timeIntervalSince1970: 1_900),
                    notes: "Recovered from buy back."
                )
            ]
        )

        let source = try #require(catalogShips.first { $0.name == "300i" })
        let destination = try #require(catalogShips.first { $0.name == "Cutlass Black" })
        let route = try #require(
            CCUUpgradePlanner.bestRoute(
                from: source,
                to: destination,
                snapshot: snapshot,
                catalogShips: catalogShips
            )
        )

        #expect(route.steps.map(\.kind) == [.store])
        #expect(route.totalNewPurchaseCostUSD == 50)
        #expect(route.totalStoreCreditNeededUSD == 10)
        #expect(route.totalNewMoneyNeededUSD == 40)

        let storeStep = try #require(route.steps.first)
        let storePayment = try #require(route.paymentRequirement(for: storeStep))
        #expect(storePayment.purchaseCostUSD == 50)
        #expect(storePayment.storeCreditUSD == 10)
        #expect(storePayment.newMoneyUSD == 40)
    }

    @Test func ccuPlannerUsesStoreWarbondCCUAsNewMoneyOnlyPurchase() throws {
        let catalog = makeCCUTestCatalog(
            storeUpgradeOffers: [
                RSIShipCatalog.StoreUpgradeOffer(
                    id: "rsi-upgrade-sku-9001",
                    skuID: 9001,
                    title: "Warbond Edition",
                    targetShipID: 3,
                    targetShipName: "Cutlass Black",
                    targetShipMSRPUSD: 110,
                    priceUSD: 95,
                    savingsUSD: 15,
                    available: true,
                    unlimitedStock: true,
                    availableStock: 0
                )
            ]
        )
        let catalogShips = CCUUpgradeCatalogShip.makeShips(from: catalog)
        let snapshot = makeCCUTestSnapshot(storeCreditUSD: 100, packages: [], buyback: [])

        let source = try #require(catalogShips.first { $0.name == "Aurora MR" })
        let destination = try #require(catalogShips.first { $0.name == "Cutlass Black" })
        let route = try #require(
            CCUUpgradePlanner.bestRoute(
                from: source,
                to: destination,
                snapshot: snapshot,
                catalogShips: catalogShips,
                storeUpgradeOffers: catalog.storeUpgradeOffers
            )
        )

        #expect(route.steps.map(\.kind) == [.storeWarbond])
        #expect(route.totalNewPurchaseCostUSD == 65)
        #expect(route.totalStoreCreditNeededUSD == 0)
        #expect(route.totalNewMoneyNeededUSD == 65)
        #expect(route.totalEffectiveCostUSD == 65)
        #expect(route.totalSavingsUSD == 15)

        let storeWarbondStep = try #require(route.steps.first)
        let payment = try #require(route.paymentRequirement(for: storeWarbondStep))
        #expect(payment.purchaseCostUSD == 65)
        #expect(payment.storeCreditUSD == 0)
        #expect(payment.newMoneyUSD == 65)
    }

    @Test func ccuPlannerSuppressesStandardStoreCCUWhenStoreWarbondExistsForSamePath() throws {
        let catalog = makeCCUTestCatalog(
            additionalShips: [
                makeCCUTestCatalogShip(
                    id: 5,
                    name: "Hercules Starlifter A2",
                    manufacturer: "Crusader",
                    msrpUSD: 750,
                    storeAvailable: true
                ),
                makeCCUTestCatalogShip(
                    id: 6,
                    name: "Polaris",
                    manufacturer: "RSI",
                    msrpUSD: 975,
                    storeAvailable: true
                )
            ],
            storeUpgradeOffers: [
                RSIShipCatalog.StoreUpgradeOffer(
                    id: "rsi-upgrade-sku-9901",
                    skuID: 9901,
                    title: "Warbond Edition",
                    targetShipID: 6,
                    targetShipName: "Polaris",
                    targetShipMSRPUSD: 975,
                    priceUSD: 950,
                    savingsUSD: 25,
                    available: true,
                    unlimitedStock: true,
                    availableStock: 0
                )
            ]
        )
        let catalogShips = CCUUpgradeCatalogShip.makeShips(from: catalog)
        let snapshot = makeCCUTestSnapshot(storeCreditUSD: 500, packages: [], buyback: [])

        let source = try #require(catalogShips.first { $0.name == "Hercules Starlifter A2" })
        let destination = try #require(catalogShips.first { $0.name == "Polaris" })
        let shipIndex = CCUUpgradeShipIndex(ships: catalogShips)
        let samePathStoreCandidates = CCUUpgradePlanner.allCandidates(
            snapshot: snapshot,
            shipIndex: shipIndex,
            storeUpgradeOffers: catalog.storeUpgradeOffers
        )
            .filter {
                $0.sourceShip.key == source.key
                    && $0.targetShip.key == destination.key
                    && ($0.kind == .storeWarbond || $0.kind == .store)
            }

        #expect(samePathStoreCandidates.map(\.kind) == [.storeWarbond])

        let route = try #require(
            CCUUpgradePlanner.bestRoute(
                from: source,
                to: destination,
                snapshot: snapshot,
                catalogShips: catalogShips,
                storeUpgradeOffers: catalog.storeUpgradeOffers
            )
        )

        #expect(route.steps.map(\.kind) == [.storeWarbond])
        #expect(route.totalNewPurchaseCostUSD == 200)
        #expect(route.totalStoreCreditNeededUSD == 0)
        #expect(route.totalNewMoneyNeededUSD == 200)
        #expect(route.totalSavingsUSD == 25)
    }

    @Test func fileSnapshotStorePersistsSnapshotsByAccountKey() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileSnapshotStore(directoryURL: tempDirectory)
        let session = makeUserSession(
            handle: "citizen-cache",
            email: "cache@example.com",
            loginIdentifier: "cache@example.com",
            password: "secret-cache",
            createdAt: Date(timeIntervalSince1970: 400)
        )
        let snapshot = PreviewHangarRepository.sampleSnapshot

        await store.save(snapshot, for: session)
        let restoredSnapshot = await store.load(for: session)

        #expect(restoredSnapshot == snapshot)

        await store.delete(for: session)
        let deletedSnapshot = await store.load(for: session)

        #expect(deletedSnapshot == nil)
    }

    @Test func urlCachedImageStoreLoadsPersistedThumbnailWithoutNetwork() async throws {
        defer {
            MockURLProtocol.requestHandler = nil
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let imageURL = try #require(URL(string: "https://example.com/ship.jpg"))
        let targetSize = CGSize(width: 84, height: 84)
        let redImageData = makeSolidImageData(color: .systemRed)

        let initialSession = makeMockURLSession { request in
            (
                try #require(HTTPURLResponse(url: request.url ?? imageURL, statusCode: 200, httpVersion: nil, headerFields: nil)),
                redImageData
            )
        }

        let firstStore = URLCachedImageStore(
            cache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            session: initialSession,
            storageDirectoryURL: tempDirectory
        )
        let initialImage = try await firstStore.image(
            for: imageURL,
            targetPointSize: targetSize,
            displayScale: 2,
            maxRetries: 1
        )

        #expect(colorMatches(sampledColor(from: initialImage), UIColor.systemRed))

        let offlineSession = makeMockURLSession { _ in
            throw URLError(.notConnectedToInternet)
        }

        let secondStore = URLCachedImageStore(
            cache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            session: offlineSession,
            storageDirectoryURL: tempDirectory
        )
        let restoredImage = try await secondStore.image(
            for: imageURL,
            targetPointSize: targetSize,
            displayScale: 2,
            maxRetries: 1
        )

        #expect(colorMatches(sampledColor(from: restoredImage), UIColor.systemRed))
    }

    @Test func urlCachedImageStoreClearsCompositeImagesWhenSourceURLsInvalidate() async throws {
        defer {
            MockURLProtocol.requestHandler = nil
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = try #require(URL(string: "https://example.com/source.jpg"))
        let targetURL = try #require(URL(string: "https://example.com/target.jpg"))
        let targetSize = CGSize(width: 96, height: 96)
        let sourceDataBox = MutableImageDataBox(data: makeSolidImageData(color: .systemRed))
        let targetImageData = makeSolidImageData(color: .systemBlue)

        let session = makeMockURLSession { request in
            let response = try #require(
                HTTPURLResponse(url: request.url ?? sourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)
            )

            switch request.url?.lastPathComponent {
            case "source.jpg":
                return (response, sourceDataBox.data)
            case "target.jpg":
                return (response, targetImageData)
            default:
                throw URLError(.badURL)
            }
        }

        let store = URLCachedImageStore(
            cache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            session: session,
            storageDirectoryURL: tempDirectory
        )

        let firstComposite = try await store.compositeImage(
            sourceURL: sourceURL,
            targetURL: targetURL,
            targetPointSize: targetSize,
            displayScale: 2,
            maxRetries: 1
        )

        #expect(colorMatches(sampledColor(from: firstComposite, normalizedPoint: CGPoint(x: 0.25, y: 0.5)), UIColor.systemRed))
        #expect(colorMatches(sampledColor(from: firstComposite, normalizedPoint: CGPoint(x: 0.75, y: 0.5)), UIColor.systemBlue))

        sourceDataBox.data = makeSolidImageData(color: .systemGreen)
        await store.clear(urls: [sourceURL])

        let refreshedComposite = try await store.compositeImage(
            sourceURL: sourceURL,
            targetURL: targetURL,
            targetPointSize: targetSize,
            displayScale: 2,
            maxRetries: 1
        )

        #expect(colorMatches(sampledColor(from: refreshedComposite, normalizedPoint: CGPoint(x: 0.25, y: 0.5)), UIColor.systemGreen))
        #expect(colorMatches(sampledColor(from: refreshedComposite, normalizedPoint: CGPoint(x: 0.75, y: 0.5)), UIColor.systemBlue))
    }

    @Test func urlCachedImageStorePersistsFleetCardBaseImagesWithoutRemoteSources() async throws {
        defer {
            MockURLProtocol.requestHandler = nil
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let shipImageURL = try #require(URL(string: "https://example.com/fleet-card-ship.jpg"))
        let recipe = FleetCardBaseSnapshotRecipe(
            style: .compact,
            pointSize: CGSize(width: 220, height: 232),
            manufacturerName: "Aegis Dynamics",
            backdropURL: shipImageURL,
            logoURL: nil
        )
        let initialSession = makeMockURLSession { request in
            (
                try #require(HTTPURLResponse(url: request.url ?? shipImageURL, statusCode: 200, httpVersion: nil, headerFields: nil)),
                makeSolidImageData(color: .systemRed)
            )
        }

        let firstStore = URLCachedImageStore(
            cache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            session: initialSession,
            storageDirectoryURL: tempDirectory
        )

        let initialImage = try await firstStore.fleetCardBaseImage(
            for: recipe,
            displayScale: 2,
            maxRetries: 1
        )
        let sampledPoint = CGPoint(x: 0.72, y: 0.36)
        let initialColor = sampledColor(from: initialImage, normalizedPoint: sampledPoint)
        #expect(initialImage.size.width > 0)
        #expect(initialImage.size.height > 0)

        try? FileManager.default.removeItem(at: tempDirectory.appendingPathComponent("Remote", isDirectory: true))

        let offlineSession = makeMockURLSession { _ in
            throw URLError(.notConnectedToInternet)
        }

        let secondStore = URLCachedImageStore(
            cache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            session: offlineSession,
            storageDirectoryURL: tempDirectory
        )

        let restoredImage = try await secondStore.fleetCardBaseImage(
            for: recipe,
            displayScale: 2,
            maxRetries: 1
        )
        let restoredColor = sampledColor(from: restoredImage, normalizedPoint: sampledPoint)

        #expect(colorsMatch(restoredColor, initialColor, tolerance: 0.03))
    }

    @Test func urlCachedImageStoreClearsFleetCardBaseImagesWhenSourceURLsInvalidate() async throws {
        defer {
            MockURLProtocol.requestHandler = nil
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let shipImageURL = try #require(URL(string: "https://example.com/fleet-card-refresh.jpg"))
        let sourceDataBox = MutableImageDataBox(data: makeSolidImageData(color: .systemRed))
        let recipe = FleetCardBaseSnapshotRecipe(
            style: .compact,
            pointSize: CGSize(width: 220, height: 232),
            manufacturerName: "Origin Jumpworks",
            backdropURL: shipImageURL,
            logoURL: nil
        )

        let session = makeMockURLSession { request in
            (
                try #require(HTTPURLResponse(url: request.url ?? shipImageURL, statusCode: 200, httpVersion: nil, headerFields: nil)),
                sourceDataBox.data
            )
        }

        let store = URLCachedImageStore(
            cache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            session: session,
            storageDirectoryURL: tempDirectory
        )

        let sampledPoint = CGPoint(x: 0.72, y: 0.36)
        let firstImage = try await store.fleetCardBaseImage(
            for: recipe,
            displayScale: 2,
            maxRetries: 1
        )
        let firstColor = sampledColor(from: firstImage, normalizedPoint: sampledPoint)

        sourceDataBox.data = makeSolidImageData(color: .systemGreen)
        await store.clear(urls: [shipImageURL])

        let refreshedImage = try await store.fleetCardBaseImage(
            for: recipe,
            displayScale: 2,
            maxRetries: 1
        )
        let refreshedColor = sampledColor(from: refreshedImage, normalizedPoint: sampledPoint)

        #expect(!colorsMatch(refreshedColor, firstColor, tolerance: 0.08))
    }

    @Test func trustedDeviceDurationIncludesYearOption() async throws {
        #expect(TrustedDeviceDuration.allCases.contains(.year))
        #expect(TrustedDeviceDuration.year.displayName == "1 year")
    }

    @Test func refreshProgressCalculatesFractionWhenTotalUnitsAreKnown() async throws {
        let progress = RefreshProgress(
            stage: .pledges,
            stepNumber: 2,
            stepCount: 4,
            detail: "Finished page 2 of 5. 100 pledges synced so far.",
            completedUnitCount: 2,
            totalUnitCount: 5
        )

        #expect(progress.stepLabel == "Step 2 of 4")
        #expect(progress.fractionCompleted == 0.4)
    }

    @Test func storeCreditParserTreatsStructuredValuesAsMinorUnits() async throws {
        #expect(RSIStoreCreditParser.parseStructuredMinorUnits("1554700") == Decimal(string: "15547"))
        #expect(RSIStoreCreditParser.parseStructuredMinorUnits("1234") == Decimal(string: "12.34"))
    }

    @Test func storeCreditParserKeepsFormattedCurrencyTextAsDisplayedAmount() async throws {
        #expect(RSIStoreCreditParser.parseCurrencyText("$15,547.00 USD") == Decimal(string: "15547"))
    }

    @Test func authenticationDebugFormatterIncludesJavaScriptDetails() async throws {
        let error = NSError(
            domain: WKErrorDomain,
            code: WKError.Code.javaScriptExceptionOccurred.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "A JavaScript exception occurred",
                "WKJavaScriptExceptionMessage": "Can't find variable: arguments",
                "WKJavaScriptExceptionLineNumber": 1,
                "WKJavaScriptExceptionColumnNumber": 18
            ]
        )

        let presentation = AuthenticationDebugFormatter.present(error)

        #expect(presentation.message == "JavaScript error: Can't find variable: arguments (line 1, column 18)")
        #expect(presentation.debugDetails?.contains("javaScriptExceptionOccurred") == true)
        #expect(presentation.debugDetails?.contains("Can't find variable: arguments") == true)
    }

    @Test func authenticationDebugFormatterShowsRawRSIResponseBodyForUnexpectedResponses() async throws {
        let error = NSError(
            domain: "RSIAuthService",
            code: 200,
            userInfo: [
                NSLocalizedDescriptionKey: "RSI returned a response the app could not decode yet.",
                "RSIResponseBody": #"{"errors":[{"message":"SomethingNew","extensions":{"details":{"reason":"backend surprise"}}}]}"#
            ]
        )

        let presentation = AuthenticationDebugFormatter.present(error)

        #expect(presentation.message.contains("RSI returned a response the app could not decode yet."))
        #expect(presentation.message.contains(#""message":"SomethingNew""#))
    }

    @Test func verificationCodesNormalizeToUppercaseAlphanumericCharacters() async throws {
        let normalized = AuthenticationViewModel.normalizedVerificationCode(" ab-12cd_34 ")

        #expect(normalized == "AB12CD34")
    }

    @Test func hangarPackageRecognizesLifetimeInsuranceAndUpgrades() async throws {
        let package = HangarPackage(
            id: 1,
            title: "Exploration Bundle",
            status: "Attributed",
            insurance: "LTI",
            acquiredAt: .now,
            originalValueUSD: 250,
            currentValueUSD: 250,
            canGift: true,
            canReclaim: true,
            canUpgrade: true,
            contents: [
                PackageItem(
                    id: "ship-1",
                    title: "Cutlass Black",
                    detail: "Ship",
                    category: .ship,
                    imageURL: nil,
                    upgradePricing: nil
                ),
                PackageItem(
                    id: "upgrade-1",
                    title: "Upgrade - Cutlass Black to Zeus Mk II MR CCU",
                    detail: "Upgrade",
                    category: .upgrade,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )

        #expect(package.hasLifetimeInsurance)
        #expect(package.hasUpgradeItems)
        #expect(!package.isMultiShipPackage)
    }

    @Test func genericUpgradeableShipDoesNotSurfaceOwnedUpgradeActionWithoutMetadata() async throws {
        let package = HangarPackage(
            id: 11,
            title: "Standalone Ship - Hornet Ghost",
            status: "Attributed",
            insurance: "LTI",
            acquiredAt: .now,
            originalValueUSD: 185,
            currentValueUSD: 185,
            canGift: true,
            canReclaim: true,
            canUpgrade: true,
            upgradeMetadata: nil,
            contents: [
                PackageItem(
                    id: "ship-11",
                    title: "F7C-S Hornet Ghost Mk II",
                    detail: "Standalone Ship",
                    category: .ship,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )

        #expect(package.canUpgrade)
        #expect(!package.isOwnedUpgradeItem)
        #expect(!package.canApplyStoredUpgrade)
    }

    @Test func hornetLegacyPackageTitleDoesNotTriggerFalseUpgradedDetection() async throws {
        let package = HangarPackage(
            id: 81560414,
            title: "Standalone Ships - F7C-S Hornet Mk II - Ghost",
            status: "Attributed",
            insurance: "LTI",
            insuranceOptions: ["LTI"],
            acquiredAt: Date(timeIntervalSince1970: 1_737_244_800),
            originalValueUSD: 132,
            currentValueUSD: 185,
            canGift: true,
            canReclaim: true,
            canUpgrade: false,
            packageThumbnailURL: URL(string: "https://example.com/package.jpg"),
            contents: [
                PackageItem(
                    id: "81560414-0",
                    title: "F7C-S Hornet Ghost Mk II",
                    detail: "Anvil Aerospace (ANVL)",
                    category: .ship,
                    imageURL: URL(string: "https://example.com/ghost.jpg"),
                    upgradePricing: nil
                ),
                PackageItem(
                    id: "81560414-1",
                    title: "Lifetime Insurance",
                    detail: "Insurance",
                    category: .perk,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )

        #expect(!package.isUpgradedShipPledge)
        #expect(package.upgradedShipDisplayTitle == nil)
    }

    @Test func missingUpgradedStatusFlagDoesNotMarkPledgeAsUpgraded() async throws {
        let package = HangarPackage(
            id: 101,
            title: "Standalone Ships - UTV plus Wilderness Camo Paint",
            status: "Attributed",
            insurance: "LTI",
            insuranceOptions: ["LTI"],
            acquiredAt: .now,
            originalValueUSD: 35,
            currentValueUSD: 40,
            canGift: true,
            canReclaim: true,
            canUpgrade: false,
            contents: [
                PackageItem(
                    id: "ship-101",
                    title: "Mustang Gamma",
                    detail: "Consolidated Outland (CNOU)",
                    category: .ship,
                    imageURL: nil,
                    upgradePricing: nil
                ),
                PackageItem(
                    id: "insurance-101",
                    title: "Lifetime Insurance",
                    detail: "Insurance",
                    category: .perk,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )

        #expect(!package.isUpgradedShipPledge)
        #expect(package.upgradedShipDisplayTitle == nil)
    }

    @Test func explicitNonUpgradedStatusKeepsPledgeMarkedAsBase() async throws {
        let package = HangarPackage(
            id: 81560414,
            title: "Standalone Ships - F7C-S Hornet Mk II - Ghost",
            status: "Attributed",
            insurance: "LTI",
            insuranceOptions: ["LTI"],
            acquiredAt: Date(timeIntervalSince1970: 1_737_244_800),
            originalValueUSD: 132,
            currentValueUSD: 185,
            canGift: true,
            canReclaim: true,
            canUpgrade: false,
            isUpgradedStatusFlag: false,
            packageThumbnailURL: URL(string: "https://example.com/package.jpg"),
            contents: [
                PackageItem(
                    id: "81560414-0",
                    title: "F7C-S Hornet Ghost Mk II",
                    detail: "Anvil Aerospace (ANVL)",
                    category: .ship,
                    imageURL: URL(string: "https://example.com/ghost.jpg"),
                    upgradePricing: nil
                ),
                PackageItem(
                    id: "81560414-1",
                    title: "Lifetime Insurance",
                    detail: "Insurance",
                    category: .perk,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )

        #expect(!package.isUpgradedShipPledge)
        #expect(package.upgradedShipDisplayTitle == nil)
    }

    @Test func explicitUpgradedStatusMarksPledgeAsUpgraded() async throws {
        let package = HangarPackage(
            id: 101,
            title: "Standalone Ships - UTV plus Wilderness Camo Paint",
            status: "Attributed",
            insurance: "LTI",
            insuranceOptions: ["LTI"],
            acquiredAt: .now,
            originalValueUSD: 35,
            currentValueUSD: 40,
            canGift: true,
            canReclaim: true,
            canUpgrade: false,
            isUpgradedStatusFlag: true,
            contents: [
                PackageItem(
                    id: "ship-101",
                    title: "Mustang Gamma",
                    detail: "Consolidated Outland (CNOU)",
                    category: .ship,
                    imageURL: nil,
                    upgradePricing: nil
                ),
                PackageItem(
                    id: "insurance-101",
                    title: "Lifetime Insurance",
                    detail: "Insurance",
                    category: .perk,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )

        #expect(package.isUpgradedShipPledge)
        #expect(package.upgradedShipDisplayTitle == "Mustang Gamma")
    }

    @Test func ownedUpgradeItemSurfacesStoredUpgradeActionWhenMetadataExists() async throws {
        let package = HangarPackage(
            id: 12,
            title: "Upgrade - Gladius to Hawk Imperator Subscribers Edition",
            status: "Attributed",
            insurance: "Unknown",
            acquiredAt: .now,
            originalValueUSD: 10,
            currentValueUSD: 10,
            canGift: true,
            canReclaim: true,
            canUpgrade: false,
            upgradeMetadata: HangarPackage.UpgradeMetadata(
                id: 501,
                name: "Gladius to Hawk Imperator Subscribers Edition",
                upgradeType: "ship_upgrade",
                matchItems: [
                    .init(id: 201, name: "Gladius")
                ],
                targetItems: [
                    .init(id: 202, name: "Hawk Imperator Subscribers Edition")
                ]
            ),
            contents: [
                PackageItem(
                    id: "upgrade-12",
                    title: "Upgrade - Gladius to Hawk Imperator Subscribers Edition",
                    detail: "Ship upgrade",
                    category: .upgrade,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )

        #expect(package.isOwnedUpgradeItem)
        #expect(package.canApplyStoredUpgrade)
    }

    @Test func upgradeOnlyPledgeHidesUnknownInsurance() async throws {
        let package = HangarPackage(
            id: 90,
            title: "Upgrade - Cutlass Black to Zeus Mk II MR CCU",
            status: "Attributed",
            insurance: "Unknown",
            acquiredAt: .now,
            originalValueUSD: 15,
            currentValueUSD: 30,
            canGift: false,
            canReclaim: true,
            canUpgrade: false,
            contents: [
                PackageItem(
                    id: "90-1",
                    title: "Upgrade - Cutlass Black to Zeus Mk II MR CCU",
                    detail: "Ship upgrade",
                    category: .upgrade,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )

        #expect(package.isUpgradeOnlyPledge)
        #expect(package.displayedInsurance == nil)
    }

    @Test func upgradeOnlyPledgeShowsExplicitInsuranceWhenPresent() async throws {
        let package = HangarPackage(
            id: 91,
            title: "Upgrade - Hull C to Carrack CCU",
            status: "Attributed",
            insurance: "LTI",
            acquiredAt: .now,
            originalValueUSD: 50,
            currentValueUSD: 100,
            canGift: false,
            canReclaim: true,
            canUpgrade: false,
            contents: [
                PackageItem(
                    id: "91-1",
                    title: "Upgrade - Hull C to Carrack CCU",
                    detail: "Ship upgrade with Lifetime Insurance",
                    category: .upgrade,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )

        #expect(package.isUpgradeOnlyPledge)
        #expect(package.displayedInsurance == "LTI")
    }

    @Test func upgradeOnlyPledgePrefersHighestInsuranceButKeepsAllLevelsForDetails() async throws {
        let package = HangarPackage(
            id: 92,
            title: "Upgrade - Corsair to Polaris CCU",
            status: "Attributed",
            insurance: "LTI",
            insuranceOptions: ["6 months", "120 months", "LTI"],
            acquiredAt: .now,
            originalValueUSD: 75,
            currentValueUSD: 225,
            canGift: false,
            canReclaim: true,
            canUpgrade: false,
            contents: [
                PackageItem(
                    id: "92-1",
                    title: "Upgrade - Corsair to Polaris CCU",
                    detail: "Includes multiple insurance tiers",
                    category: .upgrade,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )

        #expect(package.displayedInsurance == "LTI")
        #expect(package.detailInsuranceText == "LTI, 120M, 6M")
        #expect(package.searchableInsuranceText.contains("120 months"))
    }

    @Test func hangarPackageDecodesLegacySnapshotWithoutInsuranceOptions() async throws {
        let json = #"""
        {
          "id": 93,
          "title": "Legacy Package",
          "status": "Attributed",
          "insurance": "120 months",
          "acquiredAt": "2026-04-18T12:00:00Z",
          "originalValueUSD": 60,
          "currentValueUSD": 60,
          "canGift": false,
          "canReclaim": true,
          "canUpgrade": false,
          "contents": []
        }
        """#

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let package = try decoder.decode(HangarPackage.self, from: Data(json.utf8))

        #expect(package.insurance == "120 months")
        #expect(package.insuranceOptions == nil)
        #expect(package.displayedInsurance == "120M")
        #expect(package.detailInsuranceText == "120M")
    }

    @Test func hangarSnapshotDecodesLegacyCacheWithoutReferralStats() async throws {
        let json = #"""
        {
          "accountHandle": "LegacyCitizen",
          "lastSyncedAt": "2026-04-18T12:00:00Z",
          "storeCreditUSD": 145,
          "packages": [],
          "fleet": [],
          "buyback": []
        }
        """#

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(HangarSnapshot.self, from: Data(json.utf8))

        #expect(snapshot.avatarURL == nil)
        #expect(snapshot.totalSpendUSD == nil)
        #expect(snapshot.referralStats.currentLadderCount == nil)
        #expect(snapshot.referralStats.legacyLadderCount == nil)
        #expect(snapshot.referralStats.hasLegacyLadder == false)
        #expect(snapshot.referralStats.inviteCode == nil)
    }

    @Test func hangarPackageRecognizesMultiShipPackages() async throws {
        let package = HangarPackage(
            id: 2,
            title: "Industrial Pair",
            status: "Attributed",
            insurance: "6 Months",
            acquiredAt: .now,
            originalValueUSD: 400,
            currentValueUSD: 400,
            canGift: false,
            canReclaim: true,
            canUpgrade: false,
            contents: [
                PackageItem(
                    id: "ship-1",
                    title: "Prospector",
                    detail: "Ship",
                    category: .ship,
                    imageURL: nil,
                    upgradePricing: nil
                ),
                PackageItem(
                    id: "vehicle-1",
                    title: "ROC",
                    detail: "Vehicle",
                    category: .vehicle,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )

        #expect(package.isMultiShipPackage)
        #expect(!package.hasLifetimeInsurance)
        #expect(!package.hasUpgradeItems)
    }

    @Test func hangarPledgeSummaryParserPreservesTextOnlyHangarEntitlements() async throws {
        let titles = HangarPledgeSummaryParser.supplementalTitles(
            from: """
            Contains
            Aurora Mk I SE
            Lifetime Insurance
            Self-Land Hangar
            """,
            alsoContains: [
                "Standalone Ships - Aurora Mk I SE",
                "Aurora Mk I SE",
                "Lifetime Insurance"
            ],
            excluding: [
                "Standalone Ships - Aurora Mk I SE",
                "Aurora Mk I SE",
                "Lifetime Insurance"
            ]
        )

        #expect(titles == ["Self-Land Hangar"])
    }

    @Test func hangarPledgeSummaryParserExtractsResidualHangarFromCompressedSummary() async throws {
        let titles = HangarPledgeSummaryParser.supplementalTitles(
            from: "Contains Aurora Mk I SE Lifetime Insurance Self-Land Hangar",
            alsoContains: [],
            excluding: [
                "Standalone Ships - Aurora Mk I SE",
                "Aurora Mk I SE",
                "Lifetime Insurance"
            ]
        )

        #expect(titles == ["Self-Land Hangar"])
    }

    @Test func hangarPledgeSummaryParserSkipsCollapsedItemCountLabels() async throws {
        let titles = HangarPledgeSummaryParser.supplementalTitles(
            from: "Contains 315p Explorer 6 Month Insurance Self-Land Hangar and 2 items",
            alsoContains: [],
            excluding: [
                "315p Explorer",
                "6 Month Insurance"
            ]
        )

        #expect(titles == ["Self-Land Hangar"])
    }

    @Test func hangarPledgeSummaryParserSkipsPlainCollapsedCountLabels() async throws {
        let titles = HangarPledgeSummaryParser.supplementalTitles(
            from: "Contains Monde HighSec Helmet Monde HighSec Core 8 items",
            alsoContains: [
                "Monde HighSec Helmet",
                "Monde HighSec Core",
                "8 items",
                "4 ships",
                "6 ships",
                "and"
            ],
            excluding: [
                "Monde HighSec Helmet",
                "Monde HighSec Core"
            ]
        )

        #expect(titles.isEmpty)
        #expect(!HangarPledgeSummaryParser.shouldRenderContentTitle("8 items"))
        #expect(!HangarPledgeSummaryParser.shouldRenderContentTitle("4 ships"))
        #expect(!HangarPledgeSummaryParser.shouldRenderContentTitle("6 ships"))
        #expect(!HangarPledgeSummaryParser.shouldRenderContentTitle("and"))
    }

    @Test func hangarPledgeSummaryParserSkipsGenericUpgradeEntitlements() async throws {
        let titles = HangarPledgeSummaryParser.supplementalTitles(
            from: "Contains Upgrade - Terrapin To Railen Standard Upgrade",
            alsoContains: [
                "Upgrade - Terrapin To Railen",
                "Standard Upgrade"
            ],
            excluding: [
                "Upgrade - Terrapin To Railen"
            ]
        )

        #expect(titles.isEmpty)
        #expect(!HangarPledgeSummaryParser.shouldRenderContentTitle("and 2 items"))
        #expect(!HangarPledgeSummaryParser.shouldRenderContentTitle("Standard Upgrade"))
    }

    @Test func hangarPackagesGroupOnlyWhenVisibleAttributesMatchExactly() async throws {
        let originalContents = [
            PackageItem(
                id: "ship-1",
                title: "Prospector",
                detail: "Ship",
                category: .ship,
                imageURL: nil,
                upgradePricing: nil
            )
        ]
        let duplicatedContentsWithDifferentSyntheticIDs = [
            PackageItem(
                id: "ship-2",
                title: "Prospector",
                detail: "Ship",
                category: .ship,
                imageURL: nil,
                upgradePricing: nil
            )
        ]
        let acquiredAt = Date(timeIntervalSince1970: 1_700_000_000)

        let giftable = HangarPackage(
            id: 100,
            title: "Prospector",
            status: "Attributed",
            insurance: "LTI",
            acquiredAt: acquiredAt,
            originalValueUSD: 155,
            currentValueUSD: 155,
            canGift: true,
            canReclaim: true,
            canUpgrade: true,
            contents: originalContents
        )
        let identicalCopy = HangarPackage(
            id: 101,
            title: "Prospector",
            status: "Attributed",
            insurance: "LTI",
            acquiredAt: acquiredAt,
            originalValueUSD: 155,
            currentValueUSD: 155,
            canGift: true,
            canReclaim: true,
            canUpgrade: true,
            contents: duplicatedContentsWithDifferentSyntheticIDs
        )
        let lockedVariant = HangarPackage(
            id: 102,
            title: "Prospector",
            status: "Attributed",
            insurance: "LTI",
            acquiredAt: acquiredAt,
            originalValueUSD: 155,
            currentValueUSD: 155,
            canGift: false,
            canReclaim: true,
            canUpgrade: true,
            contents: originalContents
        )

        let grouped = [giftable, identicalCopy, lockedVariant].groupedForInventoryDisplay

        #expect(grouped.count == 2)
        #expect(grouped.first?.representative.id == 100)
        #expect(grouped.first?.quantity == 2)
        #expect(grouped.last?.representative.id == 102)
        #expect(grouped.last?.quantity == 1)
    }

    @Test func hangarUpgradePackagesGroupWhenOnlyHiddenUnknownInsuranceDiffers() async throws {
        let upgradeContents = [
            PackageItem(
                id: "upgrade-1",
                title: "Upgrade - Freelancer DUR to Hull B Standard Edition",
                detail: "Ship upgrade",
                category: .upgrade,
                imageURL: nil,
                upgradePricing: nil
            )
        ]

        let emptyInsurance = HangarPackage(
            id: 200,
            title: "Upgrade - Freelancer DUR to Hull B Standard Edition",
            status: "Attributed",
            insurance: "",
            acquiredAt: .now,
            originalValueUSD: 5,
            currentValueUSD: 5,
            canGift: true,
            canReclaim: true,
            canUpgrade: false,
            contents: upgradeContents
        )
        let unknownInsurance = HangarPackage(
            id: 201,
            title: "Upgrade - Freelancer DUR to Hull B Standard Edition",
            status: "Attributed",
            insurance: "Unknown",
            acquiredAt: .now,
            originalValueUSD: 5,
            currentValueUSD: 5,
            canGift: true,
            canReclaim: true,
            canUpgrade: false,
            contents: upgradeContents
        )

        let grouped = [emptyInsurance, unknownInsurance].groupedForInventoryDisplay

        #expect(grouped.count == 1)
        #expect(grouped.first?.quantity == 2)
    }

    @Test func hangarPackagesGroupWhenContentsMatchButAppearInDifferentOrder() async throws {
        let prospector = PackageItem(
            id: "ship-1",
            title: "Prospector",
            detail: "Ship",
            category: .ship,
            imageURL: nil,
            upgradePricing: nil
        )
        let roc = PackageItem(
            id: "vehicle-1",
            title: "ROC",
            detail: "Vehicle",
            category: .vehicle,
            imageURL: nil,
            upgradePricing: nil
        )

        let firstOrder = HangarPackage(
            id: 300,
            title: "Mining Starter Pair",
            status: "Attributed",
            insurance: "LTI",
            acquiredAt: .now,
            originalValueUSD: 200,
            currentValueUSD: 200,
            canGift: true,
            canReclaim: true,
            canUpgrade: false,
            contents: [prospector, roc]
        )
        let secondOrder = HangarPackage(
            id: 301,
            title: "Mining Starter Pair",
            status: "Attributed",
            insurance: "LTI",
            acquiredAt: .now,
            originalValueUSD: 200,
            currentValueUSD: 200,
            canGift: true,
            canReclaim: true,
            canUpgrade: false,
            contents: [roc, prospector]
        )

        let grouped = [firstOrder, secondOrder].groupedForInventoryDisplay

        #expect(grouped.count == 1)
        #expect(grouped.first?.quantity == 2)
    }

    @Test func hangarPackageThumbnailPrefersThePledgeCardThumbnail() async throws {
        let packageThumbnailURL = try #require(URL(string: "https://example.com/package-thumb.jpg"))
        let itemImageURL = try #require(URL(string: "https://example.com/item-detail.jpg"))

        let package = HangarPackage(
            id: 55,
            title: "Arden Backpack",
            status: "Attributed",
            insurance: "Unknown",
            acquiredAt: .now,
            originalValueUSD: 0,
            currentValueUSD: 0,
            canGift: false,
            canReclaim: false,
            canUpgrade: false,
            packageThumbnailURL: packageThumbnailURL,
            contents: [
                PackageItem(
                    id: "55-1",
                    title: "Arden-SL Backpack",
                    detail: "Flair item",
                    category: .flair,
                    imageURL: itemImageURL,
                    upgradePricing: nil
                )
            ]
        )

        #expect(package.thumbnailURL == packageThumbnailURL)
    }

    @Test func buybackPledgeClassifiesStandaloneShipGearPackageAndUpgradeFilters() async throws {
        let upgrade = BuybackPledge(
            id: 1,
            title: "Upgrade - Cutlass Black to Zeus Mk II MR",
            recoveredValueUSD: 15,
            addedToBuybackAt: .now,
            notes: "CCU"
        )
        let upgradeWithoutKeyword = BuybackPledge(
            id: 6,
            title: "Cutlass Black to Zeus Mk II MR",
            recoveredValueUSD: 15,
            addedToBuybackAt: .now,
            notes: ""
        )
        let skin = BuybackPledge(
            id: 2,
            title: "Foundation Festival Paint Pack",
            recoveredValueUSD: 9,
            addedToBuybackAt: .now,
            notes: "Skin collection"
        )
        let package = BuybackPledge(
            id: 3,
            title: "Aurora MR Starter Package",
            recoveredValueUSD: 45,
            addedToBuybackAt: .now,
            notes: "Game package"
        )
        let ship = BuybackPledge(
            id: 4,
            title: "Drake Cutlass Black",
            recoveredValueUSD: 110,
            addedToBuybackAt: .now,
            notes: "Standalone ship"
        )
        let gear = BuybackPledge(
            id: 5,
            title: "Arden-SL Backpack",
            recoveredValueUSD: 12,
            addedToBuybackAt: .now,
            notes: "FPS equipment"
        )
        let upgradedStandalone = BuybackPledge(
            id: 7,
            title: "Standalone Ships - UTV - upgraded",
            recoveredValueUSD: 0,
            addedToBuybackAt: .now,
            notes: "315p Explorer and 2 items"
        )

        #expect(upgrade.isUpgrade)
        #expect(!upgrade.isStandaloneShip)
        #expect(upgradeWithoutKeyword.isUpgrade)
        #expect(!upgradeWithoutKeyword.isStandaloneShip)
        #expect(skin.isSkin)
        #expect(!skin.isStandaloneShip)
        #expect(package.isPackage)
        #expect(!package.isStandaloneShip)
        #expect(ship.isStandaloneShip)
        #expect(!ship.isUpgrade)
        #expect(gear.isGear)
        #expect(!gear.isPackage)
        #expect(!gear.isStandaloneShip)
        #expect(!upgradedStandalone.isUpgrade)
        #expect(upgradedStandalone.isStandaloneShip)
    }

    @Test func buybackPledgesGroupByVisibleAttributesAndIgnorePlaceholderNotes() async throws {
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = Date(timeIntervalSince1970: 1_710_000_000)
        let placeholderNotes = "Recovered from the RSI buy-back page."

        let first = BuybackPledge(
            id: 10,
            title: "Drake Cutlass Black",
            recoveredValueUSD: 110,
            addedToBuybackAt: firstDate,
            notes: placeholderNotes
        )
        let second = BuybackPledge(
            id: 11,
            title: "Drake Cutlass Black",
            recoveredValueUSD: 110,
            addedToBuybackAt: secondDate,
            notes: ""
        )
        let variant = BuybackPledge(
            id: 12,
            title: "Drake Cutlass Black",
            recoveredValueUSD: 110,
            addedToBuybackAt: secondDate,
            notes: "Warbond buy-back"
        )

        let grouped = [first, second, variant].groupedForBuybackDisplay

        #expect(grouped.count == 2)
        #expect(grouped.first?.quantity == 2)
        #expect(grouped.first?.representative.displayedNotes == nil)
        #expect(grouped.first?.earliestAddedToBuybackAt == firstDate)
        #expect(grouped.first?.latestAddedToBuybackAt == secondDate)
    }

    @Test func signInAcceptsTwoFactorResponsesWithFlexibleGraphQLPayloads() async throws {
        let webSession = FakeAuthenticationWebSession(
            signInResponse: BrowserGraphQLResponse(
                statusCode: 200,
                body: """
                {
                  "data": {
                    "account_signin": false
                  },
                  "errors": [
                    {
                      "message": "MultiStepRequired",
                      "extensions": {
                        "category": "authorization",
                        "details": {
                          "delivery": "email",
                          "channels": ["email"],
                          "rememberDevice": {
                            "year": true
                          }
                        }
                      }
                    }
                  ]
                }
                """
            )
        )

        let service = RSIAuthService(
            recaptchaBroker: webSession,
            diagnostics: AuthenticationDiagnosticsStore()
        )
        let outcome = try await service.signIn(
            loginIdentifier: "pilot@example.com",
            password: "secret-password",
            rememberMe: true,
            forceBrowserLogin: false
        )

        switch outcome {
        case .requiresTwoFactor:
            break
        case .authenticated:
            Issue.record("Expected the auth flow to require a verification code.")
        case let .requiresBrowserChallenge(message):
            Issue.record("Expected a two-factor response, but the service requested browser login instead: \(message)")
        }
    }

    @Test func signInAcceptsAuthenticatedCookieFallbackWhenTwoFactorIsNotRequired() async throws {
        let webSession = FakeAuthenticationWebSession(
            signInResponse: BrowserGraphQLResponse(
                statusCode: 200,
                body: """
                {
                  "data": {
                    "account_signin": false
                  },
                  "errors": []
                }
                """
            ),
            cookies: [
                makeSessionCookie(name: "Rsi-Token", value: "rsi-token"),
                makeSessionCookie(name: "_rsi_device", value: "device-token")
            ]
        )

        let service = RSIAuthService(
            recaptchaBroker: webSession,
            diagnostics: AuthenticationDiagnosticsStore(),
            accountFetcher: { cookies in
                #expect(cookies.map(\.name).sorted() == ["Rsi-Token", "_rsi_device"])
                return AuthenticatedAccount(
                    avatar: "/avatar.png",
                    displayname: "Pilot Example",
                    email: "pilot@example.com",
                    username: "PilotHandle"
                )
            }
        )

        let outcome = try await service.signIn(
            loginIdentifier: "pilot@example.com",
            password: "secret-password",
            rememberMe: true,
            forceBrowserLogin: false
        )

        switch outcome {
        case let .authenticated(session):
            #expect(session.displayName == "Pilot Example")
            #expect(session.handle == "PilotHandle")
            #expect(session.email == "pilot@example.com")
            #expect(session.cookies.count == 2)
        case .requiresTwoFactor:
            Issue.record("Expected browserless sign-in to authenticate immediately when RSI had already issued reusable session cookies.")
        case let .requiresBrowserChallenge(message):
            Issue.record("Expected browserless sign-in to authenticate immediately, but the service requested browser login instead: \(message)")
        }
    }

    @Test func signInAutomaticallyStartsBrowserChallengeWhenCaptchaIsRequired() async throws {
        let webSession = FakeAuthenticationWebSession(
            signInResponse: BrowserGraphQLResponse(
                statusCode: 200,
                body: """
                {
                  "data": {
                    "account_signin": null
                  },
                  "errors": [
                    {
                      "message": "CaptchaRequired",
                      "extensions": {
                        "category": "authorization",
                        "details": {
                          "captcha": "manual verification required"
                        }
                      }
                    }
                  ]
                }
                """
            )
        )

        let service = RSIAuthService(
            recaptchaBroker: webSession,
            diagnostics: AuthenticationDiagnosticsStore(),
            accountFetcher: { cookies in
                #expect(cookies.map(\.name).sorted() == ["Rsi-Token"])
                return AuthenticatedAccount(
                    avatar: "/avatar.png",
                    displayname: "Pilot Example",
                    email: "pilot@example.com",
                    username: "PilotHandle"
                )
            }
        )

        do {
            _ = try await service.signIn(
                loginIdentifier: "pilot@example.com",
                password: "secret-password",
                rememberMe: true,
                forceBrowserLogin: false
            )
            Issue.record("Expected a CAPTCHA response to start browser-assisted sign-in.")
        } catch let error as AuthenticationError {
            guard case let .requiresBrowserChallenge(message) = error else {
                Issue.record("Expected browser challenge fallback, got \(error).")
                return
            }

            #expect(message.contains("in-app browser"))
        } catch {
            Issue.record("Expected AuthenticationError, got \(error).")
        }

        let session = try await service.completeBrowserAuthentication(
            cookies: [
                makeSessionCookie(name: "Rsi-Token", value: "rsi-token")
            ],
            trustBrowserSession: true
        )

        #expect(session.displayName == "Pilot Example")
        #expect(session.credentials?.loginIdentifier == "pilot@example.com")
    }

    @Test func signInHumanizesInvalidCredentialsErrors() async throws {
        let webSession = FakeAuthenticationWebSession(
            signInResponse: BrowserGraphQLResponse(
                statusCode: 200,
                body: """
                {
                  "data": {
                    "account_signin": null
                  },
                  "errors": [
                    {
                      "message": "InvalidPasswordException",
                      "extensions": {
                        "category": "authorization",
                        "details": {
                          "password": "Invalid"
                        }
                      }
                    }
                  ]
                }
                """
            )
        )

        let service = RSIAuthService(
            recaptchaBroker: webSession,
            diagnostics: AuthenticationDiagnosticsStore()
        )

        do {
            _ = try await service.signIn(
                loginIdentifier: "pilot@example.com",
                password: "wrong-password",
                rememberMe: true,
                forceBrowserLogin: false
            )
            Issue.record("Expected invalid credentials to throw an authentication error.")
        } catch let error as AuthenticationError {
            guard case let .signInFailed(message) = error else {
                Issue.record("Expected a sign-in failure message, got \(error).")
                return
            }

            #expect(message == "Incorrect RSI email/Login ID or password. Check your credentials and try again.")
        } catch {
            Issue.record("Expected AuthenticationError, got \(error).")
        }
    }

    @Test func signInHumanizesTooManyAttemptsErrors() async throws {
        let webSession = FakeAuthenticationWebSession(
            signInResponse: BrowserGraphQLResponse(
                statusCode: 200,
                body: """
                {
                  "data": {
                    "account_signin": null
                  },
                  "errors": [
                    {
                      "message": "ErrValidationFailed",
                      "extensions": {
                        "category": "authorization",
                        "details": {
                          "form": "Error Code 1034 - Maximum number of failed login attempts exceeded"
                        }
                      }
                    }
                  ]
                }
                """
            )
        )

        let service = RSIAuthService(
            recaptchaBroker: webSession,
            diagnostics: AuthenticationDiagnosticsStore()
        )

        do {
            _ = try await service.signIn(
                loginIdentifier: "pilot@example.com",
                password: "wrong-password",
                rememberMe: true,
                forceBrowserLogin: false
            )
            Issue.record("Expected RSI lockout to throw an authentication error.")
        } catch let error as AuthenticationError {
            guard case let .signInFailed(message) = error else {
                Issue.record("Expected a sign-in failure message, got \(error).")
                return
            }

            #expect(message == "Too many login attempts. RSI temporarily locked this account. Wait about an hour before trying again.")
        } catch {
            Issue.record("Expected AuthenticationError, got \(error).")
        }
    }

    @Test func signInSurfacesUnknownRSIErrorsWithoutGenericFallback() async throws {
        let webSession = FakeAuthenticationWebSession(
            signInResponse: BrowserGraphQLResponse(
                statusCode: 200,
                body: """
                {
                  "data": {
                    "account_signin": null
                  },
                  "errors": [
                    {
                      "message": "SomethingBrandNew",
                      "code": "ZX-42",
                      "extensions": {
                        "category": "backend",
                        "details": {
                          "reason": "Unexpected upstream rejection"
                        }
                      }
                    }
                  ]
                }
                """
            )
        )

        let service = RSIAuthService(
            recaptchaBroker: webSession,
            diagnostics: AuthenticationDiagnosticsStore()
        )

        do {
            _ = try await service.signIn(
                loginIdentifier: "pilot@example.com",
                password: "secret-password",
                rememberMe: true,
                forceBrowserLogin: false
            )
            Issue.record("Expected the unknown RSI error to throw an authentication error.")
        } catch let error as AuthenticationError {
            guard case let .signInFailed(message) = error else {
                Issue.record("Expected a sign-in failure message, got \(error).")
                return
            }

            #expect(message.contains("SomethingBrandNew"))
            #expect(message.contains("ZX-42"))
            #expect(message.contains("Unexpected upstream rejection"))
        } catch {
            Issue.record("Expected AuthenticationError, got \(error).")
        }
    }

    @Test func submitTwoFactorHumanizesInvalidOrAlreadyUsedCodes() async throws {
        let webSession = FakeAuthenticationWebSession(
            signInResponse: BrowserGraphQLResponse(
                statusCode: 200,
                body: """
                {
                  "data": {
                    "account_signin": false
                  },
                  "errors": [
                    {
                      "message": "MultiStepRequired",
                      "extensions": {
                        "category": "authorization",
                        "details": {
                          "delivery": "email"
                        }
                      }
                    }
                  ]
                }
                """
            ),
            twoFactorResponse: BrowserGraphQLResponse(
                statusCode: 200,
                body: """
                {
                  "data": {
                    "account_multistep": null
                  },
                  "errors": [
                    {
                      "message": "ErrValidationFailed",
                      "extensions": {
                        "category": "authorization",
                        "details": {
                          "code": "invalid or already used"
                        }
                      }
                    }
                  ]
                }
                """
            )
        )

        let service = RSIAuthService(
            recaptchaBroker: webSession,
            diagnostics: AuthenticationDiagnosticsStore()
        )
        _ = try await service.signIn(
            loginIdentifier: "pilot@example.com",
            password: "secret-password",
            rememberMe: true,
            forceBrowserLogin: false
        )

        do {
            _ = try await service.submitTwoFactor(
                code: "123456",
                deviceName: "iPhone",
                trustDuration: .year
            )
            Issue.record("Expected the invalid verification code to throw an authentication error.")
        } catch let error as AuthenticationError {
            guard case let .signInFailed(message) = error else {
                Issue.record("Expected a sign-in failure message, got \(error).")
                return
            }

            #expect(message == "That verification code was not accepted. Use the newest RSI code and try again.")
        } catch {
            Issue.record("Expected AuthenticationError, got \(error).")
        }
    }

    @Test func upgradeTitleParserExtractsSourceAndTargetShips() async throws {
        let path = try #require(UpgradeTitleParser.parse("Upgrade - Cutlass Black to Zeus Mk II MR CCU"))

        #expect(path.sourceShipName == "Cutlass Black")
        #expect(path.targetShipName == "Zeus Mk II MR")
    }

    @Test func shipCatalogMatchesHangarNamesWithManufacturerPrefixes() async throws {
        let catalog = RSIShipCatalog(
            ships: [
                .init(
                    id: 1,
                    name: "Zeus Mk II MR",
                    msrpUSD: 190,
                    imageURL: URL(string: "https://example.com/zeus.jpg")
                )
            ]
        )

        let match = catalog.matchShip(named: "RSI Zeus Mk II MR")

        #expect(match?.name == "Zeus Mk II MR")
        #expect(match?.msrpUSD == 190)
    }

    @Test func shipCatalogMatchesLegacyFleetShipNamesToHostedCatalogEntries() async throws {
        let catalog = RSIShipCatalog(
            ships: [
                .init(
                    id: 1,
                    name: "Idris-M",
                    manufacturer: "Aegis Dynamics",
                    msrpUSD: 1000,
                    imageURL: URL(string: "https://example.com/idris-m.jpg")
                ),
                .init(
                    id: 2,
                    name: "Idris-P",
                    manufacturer: "Aegis Dynamics",
                    msrpUSD: 1900,
                    imageURL: URL(string: "https://example.com/idris-p.jpg")
                ),
                .init(
                    id: 3,
                    name: "F7A Hornet Mk I",
                    manufacturer: "Anvil Aerospace",
                    msrpUSD: 125,
                    imageURL: URL(string: "https://example.com/f7a.jpg")
                ),
                .init(
                    id: 4,
                    name: "F7C-M Super Hornet Heartseeker Mk I",
                    manufacturer: "Anvil Aerospace",
                    msrpUSD: 200,
                    imageURL: URL(string: "https://example.com/heartseeker.jpg")
                ),
                .init(
                    id: 5,
                    name: "Mustang Gamma",
                    manufacturer: "Consolidated Outland",
                    msrpUSD: 65,
                    imageURL: URL(string: "https://example.com/mustang-gamma.jpg")
                )
            ]
        )

        #expect(catalog.matchShip(named: "Idris-M Frigate")?.name == "Idris-M")
        #expect(catalog.matchShip(named: "Idris-P Frigate")?.name == "Idris-P")
        #expect(catalog.matchShip(named: "Ursa Rover")?.name == "Ursa")
        #expect(catalog.matchShip(named: "315p Explorer")?.name == "315p")
        #expect(catalog.matchShip(named: "Mustang Gamma Standard Edition")?.name == "Mustang Gamma")
        #expect(catalog.matchShip(named: "F7A Hornet Mk1")?.name == "F7A Hornet Mk I")
        #expect(catalog.matchShip(named: "F7C-M Hornet Heartseeker Mk I")?.name == "F7C-M Super Hornet Heartseeker Mk I")
    }

    @Test func fleetProjectorUsesCanonicalManufacturerFallbackNames() async throws {
        let package = HangarPackage(
            id: 501,
            title: "Package - Legacy Test",
            status: "Attributed",
            insurance: "LTI",
            acquiredAt: .now,
            originalValueUSD: 100,
            currentValueUSD: 100,
            canGift: false,
            canReclaim: true,
            canUpgrade: false,
            contents: [
                PackageItem(
                    id: "ship-501",
                    title: "F7A Hornet Mk 1",
                    detail: "Anvil",
                    category: .ship,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )

        let fleet = FleetProjector.project(packages: [package], shipCatalog: nil)

        #expect(fleet.count == 1)
        #expect(fleet.first?.manufacturer == "Anvil Aerospace")
    }

    @Test func fleetProjectorSkipsCollapsedShipCountPlaceholders() async throws {
        let package = HangarPackage(
            id: 502,
            title: "Packs - Aurora Mk I Series Pack",
            status: "Attributed",
            insurance: "LTI",
            acquiredAt: .now,
            originalValueUSD: 100,
            currentValueUSD: 100,
            canGift: false,
            canReclaim: true,
            canUpgrade: false,
            contents: [
                PackageItem(
                    id: "ship-count-502",
                    title: "6 ships",
                    detail: "RSI pledge entitlement",
                    category: .ship,
                    imageURL: nil,
                    upgradePricing: nil
                ),
                PackageItem(
                    id: "vehicle-count-502",
                    title: "4 vehicles",
                    detail: "RSI pledge entitlement",
                    category: .vehicle,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )

        let fleet = FleetProjector.project(packages: [package], shipCatalog: nil)

        #expect(fleet.isEmpty)
    }

    @Test func hostedShipCatalogDecodesMSRPAndThumbnailData() async throws {
        let data = Data(
            """
            {
              "generatedAt": "2026-04-18T21:07:57.078Z",
              "ships": [
                {
                  "id": "42",
                  "title": "Polaris",
                  "name": "Polaris",
                  "manufacturer": "Roberts Space Industries",
                  "msrpUsd": 975,
                  "type": "combat",
                  "focus": "Capital",
                  "minCrew": 6,
                  "maxCrew": 14,
                  "thumbnailUrl": "https://mirror.example.com/polaris.webp",
                  "sourceThumbnailUrl": "https://robertsspaceindustries.com/media/polaris.webp"
                }
              ]
            }
            """.utf8
        )

        let catalog = try HostedShipCatalogClient.decodeCatalog(from: data)
        let match = try #require(catalog.matchShip(named: "RSI Polaris"))

        #expect(match.id == 42)
        #expect(match.name == "Polaris")
        #expect(match.manufacturer == "Roberts Space Industries")
        #expect(match.msrpUSD == 975)
        #expect(match.roleSummary == "Combat / Capital")
        #expect(match.minCrew == 6)
        #expect(match.maxCrew == 14)
        #expect(match.imageURL == URL(string: "https://mirror.example.com/polaris.webp"))
        #expect(
            catalog.mirroredAssetURL(
                for: URL(string: "https://robertsspaceindustries.com/media/polaris.webp")
            ) == URL(string: "https://mirror.example.com/polaris.webp")
        )
    }

    @Test func hostedShipCatalogDecodesStoreWarbondUpgradeOffers() async throws {
        let data = Data(
            """
            {
              "generatedAt": "2026-05-16T20:00:00.000Z",
              "ships": [
                {
                  "id": "3",
                  "name": "Cutlass Black",
                  "manufacturer": "Drake Interplanetary",
                  "msrpUsd": 110,
                  "storeAvailable": true
                }
              ],
              "storeUpgradeOffers": [
                {
                  "id": "rsi-upgrade-sku-9001",
                  "skuId": 9001,
                  "title": "Warbond Edition",
                  "targetShipId": "3",
                  "targetShipName": "Cutlass Black",
                  "targetShipMsrpUsd": 110,
                  "priceUsd": 95,
                  "savingsUsd": 15,
                  "available": true,
                  "unlimitedStock": true,
                  "availableStock": 0
                }
              ]
            }
            """.utf8
        )

        let catalog = try HostedShipCatalogClient.decodeCatalog(from: data)
        let offer = try #require(catalog.storeUpgradeOffers.first)

        #expect(offer.id == "rsi-upgrade-sku-9001")
        #expect(offer.skuID == 9001)
        #expect(offer.title == "Warbond Edition")
        #expect(offer.targetShipID == 3)
        #expect(offer.targetShipName == "Cutlass Black")
        #expect(offer.targetShipMSRPUSD == 110)
        #expect(offer.priceUSD == 95)
        #expect(offer.savingsUSD == 15)
        #expect(offer.available)
    }

    @Test func hostedShipCatalogSplitsMultiRoleShipsIntoDistinctCategories() async throws {
        let data = Data(
            """
            {
              "generatedAt": "2026-04-18T21:07:57.078Z",
              "ships": [
                {
                  "id": "135",
                  "title": "135c",
                  "name": "135c",
                  "manufacturer": "Origin Jumpworks",
                  "msrpUsd": 65,
                  "type": "multi",
                  "focus": "Starter / Light Freight",
                  "thumbnailUrl": "https://example.com/135c.webp"
                }
              ]
            }
            """.utf8
        )

        let catalog = try HostedShipCatalogClient.decodeCatalog(from: data)
        let match = try #require(catalog.matchShip(named: "Origin 135c"))

        #expect(match.roleSummary == "Multi: Starter | Light Freight")
        #expect(match.roleCategories == ["Multi", "Starter", "Light Freight"])
        #expect(match.msrpUSD == 65)
    }

    @Test func hostedShipCatalogPrefersWhiteManufacturerLogoVariantWhenAvailable() async throws {
        let data = Data(
            """
            {
              "generatedAt": "2026-04-23T22:40:00.000Z",
              "manufacturers": [
                {
                  "slug": "aegis-dynamics",
                  "name": "Aegis Dynamics",
                  "aliases": ["Aegis"],
                  "logos": {
                    "default": {
                      "path": "media/manufacturers/aegis-dynamics/black.png",
                      "primaryUrl": "https://cdn.example.com/aegis-black.png"
                    },
                    "onDarkBackground": {
                      "path": "media/manufacturers/aegis-dynamics/white.png",
                      "primaryUrl": "https://cdn.example.com/aegis-white.png"
                    },
                    "variants": {
                      "white": {
                        "path": "media/manufacturers/aegis-dynamics/white.png",
                        "primaryUrl": "https://cdn.example.com/aegis-white.png"
                      }
                    }
                  }
                }
              ],
              "ships": [
                {
                  "id": "501",
                  "name": "Gladius",
                  "manufacturer": "Aegis Dynamics",
                  "manufacturerSlug": "aegis-dynamics",
                  "thumbnailUrl": "https://mirror.example.com/gladius.webp"
                }
              ]
            }
            """.utf8
        )

        let catalog = try HostedShipCatalogClient.decodeCatalog(from: data)
        let match = try #require(catalog.matchShip(named: "Gladius"))

        #expect(match.manufacturerLogoURL == URL(string: "https://cdn.example.com/aegis-white.png"))
    }

    @Test func hostedShipCatalogUsesSVGManufacturerLogoWhenNoRasterVariantExists() async throws {
        let data = Data(
            """
            {
              "generatedAt": "2026-04-24T00:30:00.000Z",
              "manufacturers": [
                {
                  "slug": "greycat-industrial",
                  "name": "Greycat Industrial",
                  "aliases": ["Greycat Industrial"],
                  "logos": {
                    "onDarkBackground": {
                      "path": "media/manufacturers/greycat-industrial/black-white.svg",
                      "primaryUrl": "https://cdn.example.com/greycat-white.svg"
                    }
                  }
                }
              ],
              "ships": [
                {
                  "id": "901",
                  "name": "MDC",
                  "manufacturer": "Greycat Industrial",
                  "manufacturerSlug": "greycat-industrial",
                  "thumbnailUrl": "https://mirror.example.com/mdc.webp"
                }
              ]
            }
            """.utf8
        )

        let catalog = try HostedShipCatalogClient.decodeCatalog(from: data)
        let match = try #require(catalog.matchShip(named: "MDC"))

        #expect(match.manufacturerLogoURL == URL(string: "https://cdn.example.com/greycat-white.svg"))
    }

    @Test func hostedShipFeedEndpointsPreferPagesDevAndFallbackToGitHubPages() async throws {
        #expect(
            HostedShipFeedEndpoints.catalogURLs == [
                URL(string: "https://starcitizen-info.pages.dev/ships.json")!,
                URL(string: "https://therealwisewolfholo.github.io/StarCitizen-Info/ships.json")!
            ]
        )
        #expect(
            HostedShipFeedEndpoints.detailCatalogURLs == [
                URL(string: "https://starcitizen-info.pages.dev/ship-details.json")!,
                URL(string: "https://therealwisewolfholo.github.io/StarCitizen-Info/ship-details.json")!
            ]
        )
        #expect(
            HostedShipFeedEndpoints.itemTranslationURLs(for: .simplifiedChinese) == [
                URL(string: "https://starcitizen-info.pages.dev/item-translations/zh-Hans.json")!,
                URL(string: "https://therealwisewolfholo.github.io/StarCitizen-Info/item-translations/zh-Hans.json")!
            ]
        )
        #expect(HostedShipFeedEndpoints.itemTranslationURLs(for: .original).isEmpty)
    }

    @Test func hostedHangarItemTranslationFeedDecodesStrictDictionary() throws {
        let dictionary = try HostedHangarItemTranslationClient.decodeDictionary(
            from: makeHangarItemTranslationPayload(),
            expectedLocale: "zh-Hans"
        )

        #expect(dictionary.translation(for: "F8C Lightning") == "F8C 闪电")
        #expect(dictionary.translation(for: "Anvil F8C Lightning") == "F8C 闪电")
        #expect(dictionary.translation(for: "  f8c   lightning  ") == "F8C 闪电")
        #expect(dictionary.translation(for: "Gladius") == nil)
    }

    @Test func hostedHangarItemTranslationFeedRejectsDuplicateKeys() throws {
        let data = Data(
            #"""
            {
              "locale": "zh-Hans",
              "version": 1,
              "count": 2,
              "entries": [
                {
                  "source": "F8C Lightning",
                  "translation": "F8C 闪电",
                  "kind": "ship",
                  "aliases": []
                },
                {
                  "source": "Other",
                  "translation": "其他",
                  "kind": "ship",
                  "aliases": ["f8c lightning"]
                }
              ]
            }
            """#.utf8
        )

        var didThrowInvalidFeedError = false
        do {
            _ = try HostedHangarItemTranslationClient.decodeDictionary(
                from: data,
                expectedLocale: "zh-Hans"
            )
        } catch let error as HostedShipCatalogError {
            didThrowInvalidFeedError = true
            #expect(error.errorDescription?.contains("Duplicate translation key") == true)
        }

        #expect(didThrowInvalidFeedError)
    }

    @Test func hostedHangarItemTranslationClientFallsBackAcrossURLs() async throws {
        let testID = UUID().uuidString
        let primaryURL = try #require(URL(string: "https://translation.example.com/\(testID)/primary.json"))
        let fallbackURL = try #require(URL(string: "https://translation.example.com/\(testID)/fallback.json"))
        TranslationMockURLProtocol.register(.response(statusCode: 503, data: Data()), for: primaryURL)
        TranslationMockURLProtocol.register(.response(statusCode: 200, data: makeHangarItemTranslationPayload()), for: fallbackURL)
        let session = makeTranslationMockURLSession()

        let fetchedDictionary = try await HostedHangarItemTranslationClient(
            language: .simplifiedChinese,
            urls: [primaryURL, fallbackURL],
            urlSession: session
        ).fetchDictionary()

        #expect(fetchedDictionary.dictionary.translation(for: "Anvil F8C Lightning") == "F8C 闪电")
    }

    @Test func hostedHangarItemTranslationStoreFallsBackToDiskCache() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let testID = UUID().uuidString
        let feedURL = try #require(URL(string: "https://translation.example.com/\(testID)/zh-Hans.json"))
        let offlineURL = try #require(URL(string: "https://translation.example.com/\(testID)/offline-zh-Hans.json"))
        TranslationMockURLProtocol.register(.response(statusCode: 200, data: makeHangarItemTranslationPayload()), for: feedURL)
        TranslationMockURLProtocol.register(.error(URLError(.notConnectedToInternet)), for: offlineURL)
        let onlineSession = makeTranslationMockURLSession()
        let firstStore = HostedHangarItemTranslationStore(directoryURL: tempDirectory)
        let fetchedDictionary = await firstStore.dictionary(
            for: .simplifiedChinese,
            using: HostedHangarItemTranslationClient(
                language: .simplifiedChinese,
                urls: [feedURL],
                urlSession: onlineSession
            )
        )

        #expect(fetchedDictionary?.translation(for: "F8C Lightning") == "F8C 闪电")

        let offlineSession = makeTranslationMockURLSession()
        let secondStore = HostedHangarItemTranslationStore(directoryURL: tempDirectory)
        let cachedDictionary = await secondStore.dictionary(
            for: .simplifiedChinese,
            using: HostedHangarItemTranslationClient(
                language: .simplifiedChinese,
                urls: [offlineURL],
                urlSession: offlineSession
            )
        )

        #expect(cachedDictionary?.translation(for: "Anvil F8C Lightning") == "F8C 闪电")
        await secondStore.clear()
    }

    @Test func hangarItemTranslatorUsesExactDictionaryAndBilingualSearchText() throws {
        let dictionary = try HostedHangarItemTranslationClient.decodeDictionary(
            from: makeHangarItemTranslationPayload(),
            expectedLocale: "zh-Hans"
        )
        let translator = HangarItemTranslator(language: .simplifiedChinese, dictionary: dictionary)
        let originalTranslator = HangarItemTranslator(language: .original, dictionary: dictionary)

        #expect(translator.translated("F8C Lightning") == "F8C 闪电")
        #expect(translator.translated("Anvil F8C Lightning") == "F8C 闪电")
        #expect(translator.translated("Unknown Ship") == "Unknown Ship")
        #expect(originalTranslator.translated("F8C Lightning") == "F8C Lightning")

        let searchableText = translator.searchableText(for: "F8C Lightning")
        #expect(searchableText.localizedLowercase.contains("f8c lightning"))
        #expect(searchableText.contains("F8C 闪电"))
    }

    @Test func appLanguageAndHangarItemLanguageUseIndependentPreferences() throws {
        let suiteName = "HangarItemLanguageTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.storageKey)
        defaults.set(HangarItemLanguage.simplifiedChinese.rawValue, forKey: HangarItemLanguage.storageKey)

        #expect(AppLanguage.storageKey != HangarItemLanguage.storageKey)
        #expect(defaults.string(forKey: AppLanguage.storageKey) == AppLanguage.english.rawValue)
        #expect(defaults.string(forKey: HangarItemLanguage.storageKey) == HangarItemLanguage.simplifiedChinese.rawValue)
        #expect(HangarItemLanguage.resolved(from: "") == .original)
    }

    @Test func hostedShipDetailCatalogDecodesCurrentHostedPayloadShape() async throws {
        let data = Data(
            """
            {
              "generatedAt": "2026-04-23T18:47:05.397Z",
              "sourcePageUrl": "https://starcitizen.tools/List_of_pledge_vehicles",
              "shipCount": 244,
              "ships": [
                {
                  "name": "100i",
                  "pageUrl": "https://starcitizen.tools/100i",
                  "manufacturer": "Origin Jumpworks",
                  "career": "Multi-role",
                  "role": "Starter / Touring",
                  "size": "Small",
                  "inGameStatus": "Flight ready",
                  "pledgeAvailability": "Always available",
                  "minCrew": 1,
                  "maxCrew": 1,
                  "description": "A compact starter ship.",
                  "technicalSpecs": [
                    { "label": "Length", "value": "19 m" }
                  ],
                  "technicalSections": [
                    {
                      "title": "Turret",
                      "items": [
                        { "label": "CF-337 Panther Repeater", "value": "2x · S3 · 1,500 ❤️ · A" }
                      ]
                    }
                  ],
                  "specificationSections": [
                    {
                      "tab": "Weapons & Utility",
                      "title": "Turret",
                      "items": [
                        {
                          "name": "CF-337 Panther Repeater",
                          "count": 2,
                          "size": "S3",
                          "subtitle": "1,500 ❤️ · A",
                          "level": 2
                        }
                      ],
                      "summaryBySize": [
                        { "size": "S3", "count": 2, "entryCount": 1 }
                      ]
                    }
                  ],
                  "componentEntries": [],
                  "weaponsUtilityEntries": [
                    {
                      "tab": "Weapons & Utility",
                      "section": "Turret",
                      "name": "CF-337 Panther Repeater",
                      "count": 2,
                      "size": "S3"
                    }
                  ],
                  "componentSummary": {
                    "totalEntries": 0,
                    "totalCount": 0,
                    "bySection": [],
                    "bySize": []
                  },
                  "weaponsUtilitySummary": {
                    "totalEntries": 1,
                    "totalCount": 2,
                    "bySection": [
                      {
                        "tab": "Weapons & Utility",
                        "section": "Turret",
                        "size": "S3",
                        "count": 2,
                        "entryCount": 1
                      }
                    ],
                    "bySize": [
                      {
                        "size": "S3",
                        "count": 2,
                        "entryCount": 1
                      }
                    ]
                  },
                  "unavailableReason": null
                }
              ]
            }
            """.utf8
        )

        let catalog = try HostedShipDetailCatalogClient.decodeCatalog(from: data)
        let match = try #require(catalog.matchShip(named: "Origin 100i"))

        #expect(match.name == "100i")
        #expect(match.manufacturer == "Origin Jumpworks")
        #expect(match.roleSummary == "Multi Role: Starter | Touring")
        #expect(match.size == "Small")
        #expect(match.minCrew == 1)
        #expect(match.maxCrew == 1)
        #expect(match.pageURL == URL(string: "https://starcitizen.tools/100i"))
        #expect(match.technicalSpecs == [.init(label: "Length", value: "19 m")])
        #expect(
            match.technicalSections == [
                .init(
                    title: "Turret",
                    items: [
                        .init(label: "CF-337 Panther Repeater", value: "2x · S3 · 1,500 ❤️ · A")
                    ]
                )
            ]
        )
    }

    @Test func hostedShipDetailCatalogDecodesSpviewerBackedLoadoutShape() async throws {
        let data = Data(
            """
            {
              "generatedAt": "2026-04-24T18:47:05.397Z",
              "sourcePageUrl": "https://starcitizen.tools/List_of_pledge_vehicles",
              "detailSourceUrl": "https://www.spviewer.eu",
              "shipCount": 1,
              "ships": [
                {
                  "name": "Gladius",
                  "pageUrl": "https://starcitizen.tools/Gladius",
                  "spviewerPageUrl": "https://www.spviewer.eu/performance?ship=aegs_gladius",
                  "manufacturer": "Aegis Dynamics",
                  "manufacturerSlug": "aegis-dynamics",
                  "career": "Combat",
                  "role": "Light Fighter",
                  "size": "Small",
                  "inGameStatus": "Flight ready",
                  "pledgeAvailability": "Always available",
                  "minCrew": 1,
                  "maxCrew": 1,
                  "description": "A dedicated light fighter built for combat patrols.",
                  "technicalSpecs": [
                    { "label": "Length", "value": "20 m" }
                  ],
                  "technicalSections": [
                    {
                      "title": "Hull",
                      "items": [
                        { "label": "Total health points", "value": "8,500 HP" }
                      ]
                    },
                    {
                      "title": "Weapons",
                      "items": [
                        { "label": "CF-337 Panther Repeater", "value": "2x · S3 · 1,024 HP · A" }
                      ]
                    }
                  ],
                  "specificationSections": [
                    {
                      "tab": "Weapons & Utility",
                      "title": "Weapons",
                      "items": [
                        {
                          "name": "CF-337 Panther Repeater",
                          "internalName": null,
                          "countLabel": "2x",
                          "count": 2,
                          "size": "S3",
                          "sizeNumber": 3,
                          "subtitle": "1,024 HP · A",
                          "level": null,
                          "pageUrl": null
                        }
                      ],
                      "summaryBySize": [
                        { "size": "S3", "sizeNumber": 3, "count": 2, "entryCount": 1 }
                      ]
                    },
                    {
                      "tab": "Avionics & Systems",
                      "title": "Shields",
                      "items": [
                        {
                          "name": "Sentry Shield Generator",
                          "countLabel": "1x",
                          "count": 1,
                          "size": "S1",
                          "sizeNumber": 1,
                          "subtitle": "1,500 HP"
                        }
                      ],
                      "summaryBySize": [
                        { "size": "S1", "sizeNumber": 1, "count": 1, "entryCount": 1 }
                      ]
                    }
                  ],
                  "componentEntries": [
                    {
                      "tab": "Avionics & Systems",
                      "section": "Shields",
                      "name": "Sentry Shield Generator",
                      "countLabel": "1x",
                      "count": 1,
                      "size": "S1",
                      "sizeNumber": 1,
                      "subtitle": "1,500 HP"
                    }
                  ],
                  "weaponsUtilityEntries": [
                    {
                      "tab": "Weapons & Utility",
                      "section": "Weapons",
                      "name": "CF-337 Panther Repeater",
                      "countLabel": "2x",
                      "count": 2,
                      "size": "S3",
                      "sizeNumber": 3,
                      "subtitle": "1,024 HP · A"
                    }
                  ],
                  "componentSummary": {
                    "totalEntries": 1,
                    "totalCount": 1,
                    "bySection": [
                      {
                        "tab": "Avionics & Systems",
                        "section": "Shields",
                        "size": "S1",
                        "sizeNumber": 1,
                        "count": 1,
                        "entryCount": 1
                      }
                    ],
                    "bySize": [
                      { "size": "S1", "sizeNumber": 1, "count": 1, "entryCount": 1 }
                    ]
                  },
                  "weaponsUtilitySummary": {
                    "totalEntries": 1,
                    "totalCount": 2,
                    "bySection": [
                      {
                        "tab": "Weapons & Utility",
                        "section": "Weapons",
                        "size": "S3",
                        "sizeNumber": 3,
                        "count": 2,
                        "entryCount": 1
                      }
                    ],
                    "bySize": [
                      { "size": "S3", "sizeNumber": 3, "count": 2, "entryCount": 1 }
                    ]
                  },
                  "unavailableReason": null
                }
              ]
            }
            """.utf8
        )

        let catalog = try HostedShipDetailCatalogClient.decodeCatalog(from: data)
        let match = try #require(catalog.matchShip(named: "Aegis Gladius"))

        #expect(match.sourceDetailURL == URL(string: "https://www.spviewer.eu/performance?ship=aegs_gladius"))
        #expect(match.hasSpecificationData)
        #expect(match.weaponsUtilitySections.map(\.title) == ["Weapons"])
        #expect(match.componentSections.map(\.title) == ["Shields"])
        #expect(match.weaponsUtilityEntries.first?.name == "CF-337 Panther Repeater")
        #expect(match.weaponsUtilityEntries.first?.item.quantityLabel == "2x")
        #expect(match.weaponsUtilitySummary.totalCount == 2)
        #expect(match.componentSummary.totalCount == 1)
        #expect(match.technicalSectionsForDisplay.map(\.title) == ["Hull"])
    }

    @Test func hostedShipDetailCatalogKeepsMetadataForUnavailableSpviewerEntries() async throws {
        let data = Data(
            """
            {
              "generatedAt": "2026-04-24T18:47:05.397Z",
              "sourcePageUrl": "https://starcitizen.tools/List_of_pledge_vehicles",
              "detailSourceUrl": "https://www.spviewer.eu",
              "shipCount": 1,
              "ships": [
                {
                  "name": "A.T.L.S.",
                  "pageUrl": "https://starcitizen.tools/A.T.L.S.",
                  "manufacturer": "Argo Astronautics",
                  "manufacturerSlug": "argo-astronautics",
                  "career": "Ground",
                  "role": "Utility",
                  "size": "Vehicle",
                  "inGameStatus": "Flight ready",
                  "pledgeAvailability": "Always available",
                  "minCrew": 1,
                  "maxCrew": 1,
                  "description": null,
                  "technicalSpecs": [
                    { "label": "Maximum Crew", "value": "1" }
                  ],
                  "technicalSections": [],
                  "specificationSections": [],
                  "componentEntries": [],
                  "weaponsUtilityEntries": [],
                  "componentSummary": {
                    "totalEntries": 0,
                    "totalCount": 0,
                    "bySection": [],
                    "bySize": []
                  },
                  "weaponsUtilitySummary": {
                    "totalEntries": 0,
                    "totalCount": 0,
                    "bySection": [],
                    "bySize": []
                  },
                  "unavailableReason": "No matching SPViewer vehicle entry"
                }
              ]
            }
            """.utf8
        )

        let catalog = try HostedShipDetailCatalogClient.decodeCatalog(from: data)
        let match = try #require(catalog.matchShip(named: "A.T.L.S."))

        #expect(match.isUnavailable)
        #expect(!match.hasSpecificationData)
        #expect(match.size == "Vehicle")
        #expect(match.maxCrew == 1)
        #expect(match.technicalSpecs == [.init(label: "Maximum Crew", value: "1")])
    }

    @Test func hostedShipDetailCatalogUsesSVGManufacturerLogoWhenPreferredVariantIsSVG() async throws {
        let data = Data(
            """
            {
              "generatedAt": "2026-04-23T22:40:00.000Z",
              "manufacturers": [
                {
                  "slug": "origin-jumpworks",
                  "name": "Origin Jumpworks",
                  "aliases": ["Origin"],
                  "logos": {
                    "default": {
                      "path": "media/manufacturers/origin-jumpworks/color.png",
                      "primaryUrl": "https://cdn.example.com/origin-color.png"
                    },
                    "onDarkBackground": {
                      "path": "media/manufacturers/origin-jumpworks/white.svg",
                      "primaryUrl": "https://cdn.example.com/origin-white.svg"
                    }
                  }
                }
              ],
              "ships": [
                {
                  "name": "100i",
                  "pageUrl": "https://starcitizen.tools/100i",
                  "manufacturer": "Origin Jumpworks",
                  "manufacturerSlug": "origin-jumpworks",
                  "career": "Multi-role",
                  "role": "Starter / Touring",
                  "size": "Small",
                  "inGameStatus": "Flight ready",
                  "pledgeAvailability": "Always available",
                  "minCrew": 1,
                  "maxCrew": 1,
                  "description": "A compact starter ship.",
                  "technicalSpecs": [],
                  "technicalSections": [],
                  "unavailableReason": null
                }
              ]
            }
            """.utf8
        )

        let catalog = try HostedShipDetailCatalogClient.decodeCatalog(from: data)
        let match = try #require(catalog.matchShip(named: "100i"))

        #expect(match.manufacturerLogoURL == URL(string: "https://cdn.example.com/origin-white.svg"))
    }

    @Test func hostedShipDetailCatalogRequestsIgnoreLocalURLCacheData() async throws {
        let url = try #require(URL(string: "https://example.com/ship-details.json"))
        let payload = makeHostedShipDetailPayload(
            description: "Fresh feed payload.",
            technicalValue: "1x · S1 · 600 HP · Military (C)"
        )
        let session = makeMockURLSession { request in
            #expect(request.url == url)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)

            return (
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)),
                payload
            )
        }

        let client = HostedShipDetailCatalogClient(urls: [url], urlSession: session)
        let catalog = try await client.fetchCatalog()

        #expect(catalog.matchShip(named: "100i")?.description == "Fresh feed payload.")
    }

    @Test func clearLocalCacheClearsHostedShipDetailCatalogAndSharedResponseCache() async throws {
        await HostedShipDetailCatalogStore.shared.clear()
        defer {
            MockURLProtocol.requestHandler = nil
        }

        let feedURL = try #require(URL(string: "https://example.com/ship-details.json"))
        let stalePayload = makeHostedShipDetailPayload(
            description: "Stale cached description.",
            technicalValue: "1x · S1 · 600 HP · Military (C)"
        )
        let freshPayload = makeHostedShipDetailPayload(
            description: "Fresh description after clearing cache.",
            technicalValue: "1x · S1 · 600 HP · Military (C)"
        )

        let staleSession = makeMockURLSession { request in
            (
                try #require(HTTPURLResponse(url: request.url ?? feedURL, statusCode: 200, httpVersion: nil, headerFields: nil)),
                stalePayload
            )
        }
        let staleCatalog = try await HostedShipDetailCatalogStore.shared.catalog(
            using: HostedShipDetailCatalogClient(urls: [feedURL], urlSession: staleSession)
        )
        #expect(staleCatalog.matchShip(named: "100i")?.description == "Stale cached description.")

        let cachedRequest = URLRequest(url: try #require(URL(string: "https://example.com/cached.json")))
        let cachedResponse = try #require(
            HTTPURLResponse(url: cachedRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
        )
        URLCache.shared.storeCachedResponse(
            CachedURLResponse(response: cachedResponse, data: Data("{}".utf8)),
            for: cachedRequest
        )
        #expect(URLCache.shared.cachedResponse(for: cachedRequest) != nil)

        let imageCache = FakeRemoteImageCache()
        let appModel = AppModel(
            environment: makeTestAppEnvironment(
                sessionStore: FakeSessionStore(storedSnapshot: .empty),
                snapshotStore: FakeSnapshotStore(snapshot: nil),
                hangarRepository: FakeHangarRepository(),
                imageCache: imageCache
            )
        )

        await appModel.clearLocalCache()

        #expect(URLCache.shared.cachedResponse(for: cachedRequest) == nil)
        #expect(await imageCache.clearCallCount() == 1)

        let freshSession = makeMockURLSession { request in
            (
                try #require(HTTPURLResponse(url: request.url ?? feedURL, statusCode: 200, httpVersion: nil, headerFields: nil)),
                freshPayload
            )
        }
        let refreshedCatalog = try await HostedShipDetailCatalogStore.shared.catalog(
            using: HostedShipDetailCatalogClient(urls: [feedURL], urlSession: freshSession)
        )
        #expect(
            refreshedCatalog.matchShip(named: "100i")?.description == "Fresh description after clearing cache."
        )

        await HostedShipDetailCatalogStore.shared.clear()
    }

    @Test func fleetRoleFormatterUsesTypeAndPipeSeparatedFocusSummary() async throws {
        #expect(FleetRoleFormatter.summary(type: "combat", focus: "Medium Fighter") == "Combat: Medium Fighter")
        #expect(FleetRoleFormatter.summary(type: "multi", focus: "Starter / Light Fighter") == "Multi: Starter | Light Fighter")
        #expect(FleetRoleFormatter.summary(type: nil, focus: "Light Freight / Starter") == "Light Freight | Starter")
    }

    @Test func fleetPresentationFormatterNormalizesLegacySlashRoleStringsAndShortManufacturers() async throws {
        #expect(
            FleetPresentationFormatter.roleSummary(
                role: "Ground / Racing",
                categories: ["Ground", "Racing"]
            ) == "Ground: Racing"
        )
        #expect(
            FleetPresentationFormatter.roleSummary(
                role: "Transport / Passenger",
                categories: []
            ) == "Transport: Passenger"
        )
        #expect(FleetPresentationFormatter.manufacturerDisplayName("Drake") == "Drake Interplanetary")
    }

    @Test func fleetProjectorFiltersEquipmentAndUsesHostedGreyManufacturer() async throws {
        let catalog = RSIShipCatalog(
            ships: [
                .init(
                    id: 77,
                    name: "MTC",
                    manufacturer: "Grey's Market",
                    msrpUSD: 30,
                    type: "ground",
                    focus: "Racing",
                    imageURL: URL(string: "https://example.com/mtc.webp")
                )
            ]
        )

        let package = HangarPackage(
            id: 500,
            title: "Mixed Package",
            status: "Attributed",
            insurance: "LTI",
            acquiredAt: .now,
            originalValueUSD: 40,
            currentValueUSD: 40,
            canGift: true,
            canReclaim: true,
            canUpgrade: false,
            contents: [
                PackageItem(
                    id: "500-1",
                    title: "Arden-SL Backpack",
                    detail: "FPS equipment",
                    category: .vehicle,
                    imageURL: nil,
                    upgradePricing: nil
                ),
                PackageItem(
                    id: "500-2",
                    title: "GREY MTC",
                    detail: "Ground Vehicle",
                    category: .vehicle,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )

        let fleet = FleetProjector.project(packages: [package], shipCatalog: catalog)

        #expect(fleet.count == 1)
        #expect(fleet.first?.displayName == "GREY MTC")
        #expect(fleet.first?.manufacturer == "Grey's Market")
        #expect(fleet.first?.role == "Ground: Racing")
        #expect(fleet.first?.roleCategories == ["Ground", "Racing"])
        #expect(fleet.first?.msrpUSD == 30)
        #expect(fleet.first?.meltValueUSD == 40)
    }

    @Test func fleetProjectorUsesBaseDragonflyFunctionButKeepsStarKittenMSRPUnknown() async throws {
        let catalog = RSIShipCatalog(
            ships: [
                .init(
                    id: 112,
                    name: "Dragonfly Black",
                    manufacturer: "Drake Interplanetary",
                    msrpUSD: 40,
                    type: "competition",
                    focus: "Racing",
                    imageURL: URL(string: "https://example.com/dragonfly-black.webp")
                )
            ]
        )

        let package = HangarPackage(
            id: 777,
            title: "IAE 2955 Referral Bonus",
            status: "Attributed",
            insurance: "120 months",
            acquiredAt: .now,
            originalValueUSD: 0,
            currentValueUSD: 0,
            canGift: false,
            canReclaim: false,
            canUpgrade: false,
            contents: [
                PackageItem(
                    id: "ship-777",
                    title: "Dragonfly Star Kitten Edition",
                    detail: "Drake",
                    category: .vehicle,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )

        let fleet = FleetProjector.project(packages: [package], shipCatalog: catalog)
        let ship = try #require(fleet.first)

        #expect(ship.manufacturer == "Drake Interplanetary")
        #expect(ship.role == "Competition: Racing")
        #expect(ship.roleCategories == ["Competition", "Racing"])
        #expect(ship.msrpUSD == nil)
        #expect(ship.imageURL == URL(string: "https://example.com/dragonfly-black.webp"))
    }

    @Test func fleetProjectorDropsUnmatchedItemsWithoutInsurance() async throws {
        let package = HangarPackage(
            id: 888,
            title: "BIS Extras",
            status: "Attributed",
            insurance: "Unknown",
            acquiredAt: .now,
            originalValueUSD: 0,
            currentValueUSD: 0,
            canGift: false,
            canReclaim: false,
            canUpgrade: false,
            contents: [
                PackageItem(
                    id: "ship-888",
                    title: "Ship Showdown Flag",
                    detail: "FPS Equipment",
                    category: .vehicle,
                    imageURL: nil,
                    upgradePricing: nil
                ),
                PackageItem(
                    id: "ship-889",
                    title: "Terrapin 2954 Ship Showdown Poster",
                    detail: "FPS Equipment",
                    category: .vehicle,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )

        let fleet = FleetProjector.project(packages: [package], shipCatalog: nil)

        #expect(fleet.isEmpty)
    }

    @Test func fleetShipsGroupByVisibleShipAttributes() async throws {
        let firstShip = FleetShip(
            id: 1,
            displayName: "Polaris",
            manufacturer: "RSI",
            role: "Capital combat",
            insurance: "LTI",
            sourcePackageID: 101,
            sourcePackageName: "Polaris Expedition Pack",
            meltValueUSD: 750,
            canGift: true,
            canReclaim: true
        )
        let duplicateShip = FleetShip(
            id: 2,
            displayName: "Polaris",
            manufacturer: "RSI",
            role: "Capital combat",
            insurance: "LTI",
            sourcePackageID: 102,
            sourcePackageName: "Fleet Bundle",
            meltValueUSD: 825,
            canGift: false,
            canReclaim: false
        )
        let insuranceVariant = FleetShip(
            id: 3,
            displayName: "Polaris",
            manufacturer: "RSI",
            role: "Capital combat",
            insurance: "120 months",
            sourcePackageID: 103,
            sourcePackageName: "Warbond Pack",
            meltValueUSD: 900,
            canGift: true,
            canReclaim: true
        )

        let grouped = [firstShip, duplicateShip, insuranceVariant].groupedForFleetDisplay

        #expect(grouped.count == 2)
        #expect(grouped.first?.quantity == 2)
        #expect(grouped.first?.totalMeltValueUSD == 1575)
        #expect(grouped.first?.individualMeltValuesUSD == [750, 825])
        #expect(grouped.first?.sourcePackageSummary == "2 packages")
        #expect(grouped.last?.quantity == 1)
        #expect(grouped.last?.representative.insurance == "120 months")
    }

    @Test func fleetProjectorPrefersHostedShipImageForMatchedShips() async throws {
        let hangarImageURL = try #require(URL(string: "https://example.com/hangar-thumb.jpg"))
        let hostedImageURL = try #require(URL(string: "https://example.com/ship-listing-wide.webp"))
        let manufacturerLogoURL = try #require(URL(string: "https://example.com/rsi-white.png"))
        let package = HangarPackage(
            id: 700,
            title: "Polaris Expedition Pack",
            status: "Attributed",
            insurance: "LTI",
            acquiredAt: .now,
            originalValueUSD: 975,
            currentValueUSD: 975,
            canGift: true,
            canReclaim: true,
            canUpgrade: false,
            contents: [
                PackageItem(
                    id: "700-1",
                    title: "RSI Polaris",
                    detail: "Capital ship",
                    category: .ship,
                    imageURL: hangarImageURL,
                    upgradePricing: nil
                )
            ]
        )
        let catalog = RSIShipCatalog(
            ships: [
                RSIShipCatalog.Ship(
                    id: 116,
                    name: "Polaris",
                    manufacturer: "Roberts Space Industries",
                    manufacturerLogoURL: manufacturerLogoURL,
                    msrpUSD: 975,
                    type: "combat",
                    focus: "Capital",
                    imageURL: hostedImageURL
                )
            ]
        )

        let fleet = FleetProjector.project(packages: [package], shipCatalog: catalog)

        #expect(fleet.count == 1)
        #expect(fleet.first?.imageURL == hostedImageURL)
        #expect(fleet.first?.manufacturerLogoURL == manufacturerLogoURL)
        #expect(fleet.first?.role == "Combat / Capital")
        #expect(fleet.first?.roleCategories == ["Combat", "Capital"])
        #expect(fleet.first?.msrpUSD == 975)
    }

    @Test func fleetProjectorKeepsUnmatchedShipWhenHostedCatalogMissesIt() async throws {
        let hangarImageURL = try #require(URL(string: "https://example.com/idris-thumb.jpg"))
        let package = HangarPackage(
            id: 701,
            title: "Idris Owner Package",
            status: "Attributed",
            insurance: "LTI",
            acquiredAt: .now,
            originalValueUSD: 1500,
            currentValueUSD: 1500,
            canGift: false,
            canReclaim: true,
            canUpgrade: false,
            contents: [
                PackageItem(
                    id: "701-1",
                    title: "Aegis Idris",
                    detail: "Capital ship",
                    category: .ship,
                    imageURL: hangarImageURL,
                    upgradePricing: nil
                )
            ]
        )
        let catalog = RSIShipCatalog(
            ships: [
                RSIShipCatalog.Ship(
                    id: 27,
                    name: "Idris-M",
                    manufacturer: "Aegis Dynamics",
                    msrpUSD: 1000,
                    type: "combat",
                    focus: "Frigate",
                    imageURL: URL(string: "https://example.com/idris-m.webp")
                ),
                RSIShipCatalog.Ship(
                    id: 28,
                    name: "Idris-P",
                    manufacturer: "Aegis Dynamics",
                    msrpUSD: 1900,
                    type: "combat",
                    focus: "Frigate",
                    imageURL: URL(string: "https://example.com/idris-p.webp")
                )
            ]
        )

        let fleet = FleetProjector.project(packages: [package], shipCatalog: catalog)

        #expect(fleet.count == 1)
        #expect(fleet.first?.displayName == "Aegis Idris")
        #expect(fleet.first?.manufacturer == "Aegis")
        #expect(fleet.first?.role == "Capital ship")
        #expect(fleet.first?.roleCategories == ["Capital ship"])
        #expect(fleet.first?.msrpUSD == nil)
        #expect(fleet.first?.imageURL == hangarImageURL)
    }

    @Test func fleetShipSearchHaystackIncludesShipNameAndManufacturer() async throws {
        let ship = FleetShip(
            id: 44,
            displayName: "Cutlass Black",
            manufacturer: "Drake",
            role: "Medium freight",
            insurance: "LTI",
            sourcePackageID: 204,
            sourcePackageName: "Drake Pack",
            meltValueUSD: 110,
            canGift: true,
            canReclaim: true
        )

        #expect(ship.searchHaystack.contains("cutlass black"))
        #expect(ship.searchHaystack.contains("drake"))
    }

    @Test func fleetShipDecodesLegacyCacheWithoutRoleCategories() async throws {
        let json = #"""
        {
          "id": 44,
          "displayName": "Cutlass Black",
          "manufacturer": "Drake",
          "role": "Multi / Medium Freight",
          "insurance": "LTI",
          "sourcePackageID": 204,
          "sourcePackageName": "Drake Pack",
          "meltValueUSD": 110,
          "canGift": true,
          "canReclaim": true
        }
        """#

        let ship = try JSONDecoder().decode(FleetShip.self, from: Data(json.utf8))

        #expect(ship.role == "Multi / Medium Freight")
        #expect(ship.roleCategories == ["Multi", "Medium Freight"])
        #expect(ship.msrpUSD == nil)
    }

    @Test func legacyStoredSessionPayloadStillDecodes() async throws {
        let json = """
        {
          "handle": "citizen-1",
          "displayName": "Citizen One",
          "email": "citizen@example.com",
          "credentials": {
            "loginIdentifier": "citizen@example.com",
            "password": "secret"
          },
          "cookies": [
            {
              "name": "Rsi-Token",
              "value": "cookie-value",
              "domain": ".robertsspaceindustries.com",
              "expiresAt": "2026-04-18T04:00:00Z"
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(UserSession.self, from: Data(json.utf8))

        #expect(session.handle == "citizen-1")
        #expect(session.displayName == "Citizen One")
        #expect(session.authMode == .rsiNativeLogin)
        #expect(session.notes == "")
        #expect(session.avatarURL == nil)
        #expect(!session.id.uuidString.isEmpty)
        #expect(session.cookies.count == 1)
        #expect(session.cookies.first?.path == "/")
        #expect(session.cookies.first?.isSecure == true)
        #expect(session.cookies.first?.isHTTPOnly == true)
    }

    @Test func storedSessionsPayloadReplacesExistingAccountInsteadOfDuplicatingIt() async throws {
        let originalSession = makeUserSession(
            handle: "citizen-1",
            email: "citizen@example.com",
            loginIdentifier: "citizen@example.com",
            password: "old-password",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let refreshedSession = makeUserSession(
            handle: "citizen-1",
            email: "citizen@example.com",
            loginIdentifier: "CITIZEN@example.com",
            password: "new-password",
            createdAt: Date(timeIntervalSince1970: 200)
        )

        let payload = StoredSessionsPayload(
            activeSessionID: originalSession.id,
            sessions: [originalSession]
        ).saving(refreshedSession, makeActive: true)

        #expect(payload.sessions.count == 1)
        #expect(payload.snapshot.activeSession?.id == refreshedSession.id)
        #expect(payload.snapshot.savedSessions.first?.credentials?.password == "new-password")
    }

    @Test func deletingActiveSessionFallsBackToAnotherSavedAccount() async throws {
        let firstSession = makeUserSession(
            handle: "citizen-1",
            email: "citizen-1@example.com",
            loginIdentifier: "citizen-1@example.com",
            password: "secret-1",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let secondSession = makeUserSession(
            handle: "citizen-2",
            email: "citizen-2@example.com",
            loginIdentifier: "citizen-2@example.com",
            password: "secret-2",
            createdAt: Date(timeIntervalSince1970: 200)
        )

        let payload = StoredSessionsPayload(
            activeSessionID: firstSession.id,
            sessions: [firstSession, secondSession]
        ).deleting(id: firstSession.id)

        #expect(payload.snapshot.activeSession?.id == secondSession.id)
        #expect(payload.snapshot.savedSessions.count == 1)
    }

    @Test func storedSessionsPayloadLimitsSavedAccountsToTenNewestSessions() async throws {
        var payload = StoredSessionsPayload.empty
        var sessions: [UserSession] = []

        for index in 0 ... 10 {
            let session = makeUserSession(
                handle: "citizen-\(index)",
                email: "citizen-\(index)@example.com",
                loginIdentifier: "citizen-\(index)@example.com",
                password: "secret-\(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
            sessions.append(session)
            payload = payload.saving(session, makeActive: true)
        }

        #expect(payload.sessions.count == StoredSessionsPayload.maxSavedSessionCount)
        #expect(payload.snapshot.savedSessions.count == StoredSessionsPayload.maxSavedSessionCount)
        #expect(payload.snapshot.activeSession?.id == sessions[10].id)
        let containsOldestSession = payload.sessions.contains { $0.id == sessions[0].id }
        #expect(!containsOldestSession)
    }

    @Test func quickLoginSessionsExcludePreviewAccounts() async throws {
        let liveSession = makeUserSession(
            handle: "citizen-3",
            email: "citizen-3@example.com",
            loginIdentifier: "citizen-3@example.com",
            password: "secret-3",
            createdAt: Date(timeIntervalSince1970: 300)
        )

        let appModel = await MainActor.run {
            AppModel(environment: .preview)
        }

        let quickLoginSessions = await MainActor.run {
            appModel.savedSessions = [.preview, liveSession]
            return appModel.quickLoginSessions
        }

        #expect(quickLoginSessions.map(\.id) == [liveSession.id])
    }

    @Test func sponsorAcknowledgementsStaySortedByContribution() async throws {
        #expect(
            SponsorDirectory.displayedSponsors.map(\.name) == [
                "阿狸",
                "Moiety",
                "BrAhMaJiNg",
                "AJMZBXS",
                "zby005160",
                "baozi3160",
                "新疆宴全羊馆",
                "Nekkonyan"
            ]
        )
    }

    @Test func referralStatsResolverPrefersStructuredLegacyCountOverPageHeuristics() async throws {
        let stats = ReferralStatsResolver.resolve(
            currentLadderCount: 42,
            legacyGraphQLCount: 12,
            legacyParsedCount: 842,
            legacyPageUnavailable: false
        )

        #expect(stats.currentLadderCount == 42)
        #expect(stats.legacyLadderCount == 12)
        #expect(stats.hasLegacyLadder)
        #expect(stats.inviteCode == nil)
    }

    @Test func referralStatsResolverMarksLegacyLadderUnavailableWhenPageIsMissing() async throws {
        let stats = ReferralStatsResolver.resolve(
            currentLadderCount: 7,
            legacyGraphQLCount: 12,
            legacyParsedCount: 12,
            legacyPageUnavailable: true
        )

        #expect(stats.currentLadderCount == 7)
        #expect(stats.legacyLadderCount == nil)
        #expect(!stats.hasLegacyLadder)
    }

    @Test func referralStatsResolverPreservesNormalizedInviteCode() async throws {
        let stats = ReferralStatsResolver.resolve(
            currentLadderCount: 7,
            inviteCode: " star-test-code ",
            legacyGraphQLCount: nil,
            legacyParsedCount: nil,
            legacyPageUnavailable: true
        )

        #expect(stats.inviteCode == "STAR-TEST-CODE")
    }

    @Test func successfulMeltRemovesPackagesImmediatelyWithoutVisibleRefreshState() async throws {
        let session = makeUserSession(
            handle: "melt-action",
            email: "melt-action@example.com",
            loginIdentifier: "melt-action@example.com",
            password: "secret-melt",
            createdAt: Date(timeIntervalSince1970: 905)
        )
        let meltedPackage = HangarPackage(
            id: 4101,
            title: "Gladius and Gold",
            status: "Attributed",
            insurance: "LTI",
            acquiredAt: .now,
            originalValueUSD: 90,
            currentValueUSD: 90,
            canGift: true,
            canReclaim: true,
            canUpgrade: true,
            contents: [
                PackageItem(
                    id: "4101-ship",
                    title: "Aegis Gladius",
                    detail: "Light Fighter",
                    category: .ship,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )
        let survivingPackage = HangarPackage(
            id: 4102,
            title: "Cutter Scout",
            status: "Attributed",
            insurance: "120 months",
            acquiredAt: .now,
            originalValueUSD: 50,
            currentValueUSD: 50,
            canGift: true,
            canReclaim: true,
            canUpgrade: true,
            contents: [
                PackageItem(
                    id: "4102-ship",
                    title: "Drake Cutter Scout",
                    detail: "Starter",
                    category: .ship,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )
        let cachedSnapshot = PreviewHangarRepository.sampleSnapshot.updatingHangar(
            packages: [meltedPackage, survivingPackage],
            fleet: [
                FleetShip(
                    id: 9001,
                    displayName: "Gladius",
                    manufacturer: "Aegis Dynamics",
                    role: "Combat: Light Fighter",
                    insurance: "LTI",
                    sourcePackageID: meltedPackage.id,
                    sourcePackageName: meltedPackage.title,
                    meltValueUSD: 90,
                    canGift: true,
                    canReclaim: true
                )
            ],
            lastSyncedAt: Date(timeIntervalSince1970: 906)
        )

        let appModel = AppModel(
            environment: makeTestAppEnvironment(
                sessionStore: FakeSessionStore(
                    storedSnapshot: StoredSessionsSnapshot(activeSession: session, savedSessions: [session])
                ),
                snapshotStore: FakeSnapshotStore(snapshot: cachedSnapshot),
                hangarRepository: FakeHangarRepository(hangarSnapshot: cachedSnapshot)
            )
        )
        appModel.session = session
        appModel.savedSessions = [session]
        appModel.loadState = .loaded(cachedSnapshot)

        let packageGroup = try #require([meltedPackage].groupedForInventoryDisplay.first)

        try await appModel.melt(packageGroup: packageGroup, quantity: 1)
        await Task.yield()

        let updatedSnapshot = try #require(appModel.snapshot)
        #expect(updatedSnapshot.packages.map(\.id) == [survivingPackage.id])
        #expect(updatedSnapshot.fleet.isEmpty)
        #expect(appModel.activeRefreshScope == nil)
        #expect(appModel.refreshProgress == nil)
        #expect(!appModel.isRefreshing)

        await appModel.refresh(scope: .hangar)
    }

    @Test func bulkMeltRemovesAllSelectedPledgesAndSubmitsAllIDs() async throws {
        let session = makeUserSession(
            handle: "bulk-melt-action",
            email: "bulk-melt-action@example.com",
            loginIdentifier: "bulk-melt-action@example.com",
            password: "secret-bulk-melt",
            createdAt: Date(timeIntervalSince1970: 907)
        )
        let firstPackage = makeHangarActionPackage(
            id: 4201,
            title: "Gladius Pack",
            canGift: true,
            canReclaim: true,
            originalValueUSD: 90
        )
        let secondPackage = makeHangarActionPackage(
            id: 4202,
            title: "Cutter Pack",
            canGift: false,
            canReclaim: true,
            originalValueUSD: 50
        )
        let cachedSnapshot = PreviewHangarRepository.sampleSnapshot.updatingHangar(
            packages: [firstPackage, secondPackage],
            fleet: [],
            lastSyncedAt: Date(timeIntervalSince1970: 908)
        )
        let repository = FakeHangarRepository(hangarSnapshot: cachedSnapshot)
        let appModel = AppModel(
            environment: makeTestAppEnvironment(
                sessionStore: FakeSessionStore(
                    storedSnapshot: StoredSessionsSnapshot(activeSession: session, savedSessions: [session])
                ),
                snapshotStore: FakeSnapshotStore(snapshot: cachedSnapshot),
                hangarRepository: repository
            )
        )
        appModel.session = session
        appModel.savedSessions = [session]
        appModel.loadState = .loaded(cachedSnapshot)

        let packageGroups = [firstPackage, secondPackage].groupedForInventoryDisplay

        try await appModel.melt(packageGroups: packageGroups)
        await Task.yield()

        let updatedSnapshot = try #require(appModel.snapshot)
        #expect(updatedSnapshot.packages.isEmpty)
        #expect(await repository.meltRequests() == [[firstPackage.id, secondPackage.id]])
    }

    @Test func bulkGiftRejectsSelectionWhenAnySelectedPledgeCannotBeGifted() async throws {
        let session = makeUserSession(
            handle: "bulk-gift-action",
            email: "bulk-gift-action@example.com",
            loginIdentifier: "bulk-gift-action@example.com",
            password: "secret-bulk-gift",
            createdAt: Date(timeIntervalSince1970: 909)
        )
        let giftablePackage = makeHangarActionPackage(
            id: 4301,
            title: "Giftable Pledge",
            canGift: true,
            canReclaim: true,
            originalValueUSD: 90
        )
        let lockedPackage = makeHangarActionPackage(
            id: 4302,
            title: "Locked Pledge",
            canGift: false,
            canReclaim: true,
            originalValueUSD: 50
        )
        let cachedSnapshot = PreviewHangarRepository.sampleSnapshot.updatingHangar(
            packages: [giftablePackage, lockedPackage],
            fleet: [],
            lastSyncedAt: Date(timeIntervalSince1970: 910)
        )
        let repository = FakeHangarRepository(hangarSnapshot: cachedSnapshot)
        let appModel = AppModel(
            environment: makeTestAppEnvironment(
                sessionStore: FakeSessionStore(
                    storedSnapshot: StoredSessionsSnapshot(activeSession: session, savedSessions: [session])
                ),
                snapshotStore: FakeSnapshotStore(snapshot: cachedSnapshot),
                hangarRepository: repository
            )
        )
        appModel.session = session
        appModel.savedSessions = [session]
        appModel.loadState = .loaded(cachedSnapshot)

        do {
            try await appModel.gift(
                packageGroups: [giftablePackage, lockedPackage].groupedForInventoryDisplay,
                recipientName: "",
                recipientEmail: "recipient@example.com"
            )
            Issue.record("Expected bulk gift to reject a mixed giftable and non-giftable selection.")
        } catch let error as HangarAccountActionError {
            #expect(error == .ineligibleGiftSelection)
        } catch {
            Issue.record("Expected HangarAccountActionError, got \(error).")
        }

        #expect(await repository.giftRequests().isEmpty)
    }

    @Test func successfulUpgradeRemovesConsumedUpgradeImmediatelyWithoutVisibleRefreshState() async throws {
        let session = makeUserSession(
            handle: "upgrade-action",
            email: "upgrade-action@example.com",
            loginIdentifier: "upgrade-action@example.com",
            password: "secret-upgrade",
            createdAt: Date(timeIntervalSince1970: 907)
        )
        let upgradePackage = HangarPackage(
            id: 5101,
            title: "Gladius to Sabre Upgrade",
            status: "Attributed",
            insurance: "None",
            acquiredAt: .now,
            originalValueUSD: 20,
            currentValueUSD: 20,
            canGift: true,
            canReclaim: true,
            canUpgrade: false,
            upgradeMetadata: HangarPackage.UpgradeMetadata(
                id: 77,
                name: "Gladius to Sabre Upgrade",
                upgradeType: "ship_upgrade",
                matchItems: [.init(id: nil, name: "Gladius")],
                targetItems: [.init(id: nil, name: "Sabre")]
            ),
            contents: [
                PackageItem(
                    id: "5101-upgrade",
                    title: "Gladius to Sabre Upgrade",
                    detail: "Upgrade",
                    category: .upgrade,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )
        let targetPackage = HangarPackage(
            id: 5102,
            title: "Gladius Owner Pack",
            status: "Attributed",
            insurance: "LTI",
            acquiredAt: .now,
            originalValueUSD: 90,
            currentValueUSD: 90,
            canGift: true,
            canReclaim: true,
            canUpgrade: true,
            contents: [
                PackageItem(
                    id: "5102-ship",
                    title: "Aegis Gladius",
                    detail: "Light Fighter",
                    category: .ship,
                    imageURL: nil,
                    upgradePricing: nil
                )
            ]
        )
        let cachedSnapshot = PreviewHangarRepository.sampleSnapshot.updatingHangar(
            packages: [upgradePackage, targetPackage],
            fleet: [
                FleetShip(
                    id: 9002,
                    displayName: "Gladius",
                    manufacturer: "Aegis Dynamics",
                    role: "Combat: Light Fighter",
                    insurance: "LTI",
                    sourcePackageID: targetPackage.id,
                    sourcePackageName: targetPackage.title,
                    meltValueUSD: 90,
                    canGift: true,
                    canReclaim: true
                )
            ],
            lastSyncedAt: Date(timeIntervalSince1970: 908)
        )

        let appModel = AppModel(
            environment: makeTestAppEnvironment(
                sessionStore: FakeSessionStore(
                    storedSnapshot: StoredSessionsSnapshot(activeSession: session, savedSessions: [session])
                ),
                snapshotStore: FakeSnapshotStore(snapshot: cachedSnapshot),
                hangarRepository: FakeHangarRepository(hangarSnapshot: cachedSnapshot)
            )
        )
        appModel.session = session
        appModel.savedSessions = [session]
        appModel.loadState = .loaded(cachedSnapshot)

        let packageGroup = try #require([upgradePackage].groupedForInventoryDisplay.first)
        let target = UpgradeTargetCandidate(
            pledgeID: targetPackage.id,
            title: targetPackage.title,
            status: targetPackage.status,
            insurance: targetPackage.insurance,
            thumbnailURL: nil
        )

        try await appModel.applyUpgrade(packageGroup: packageGroup, target: target)
        await Task.yield()

        let updatedSnapshot = try #require(appModel.snapshot)
        #expect(updatedSnapshot.packages.map(\.id) == [targetPackage.id])
        #expect(updatedSnapshot.fleet.map(\.sourcePackageID) == [targetPackage.id])
        #expect(appModel.activeRefreshScope == nil)
        #expect(appModel.refreshProgress == nil)
        #expect(!appModel.isRefreshing)

        await appModel.refresh(scope: .hangar)
    }

    @Test func refreshFailureKeepsCachedSnapshotVisibleWhenRefreshFails() async throws {
        let session = makeUserSession(
            handle: "citizen-cache",
            email: "citizen-cache@example.com",
            loginIdentifier: "citizen-cache@example.com",
            password: "secret-cache",
            createdAt: Date(timeIntervalSince1970: 500)
        )
        let cachedSnapshot = PreviewHangarRepository.sampleSnapshot
        let sessionStore = FakeSessionStore(
            storedSnapshot: StoredSessionsSnapshot(activeSession: session, savedSessions: [session])
        )
        let snapshotStore = FakeSnapshotStore(snapshot: cachedSnapshot)
        let failingRepository = FakeHangarRepository(
            error: AuthenticationError.unavailable("RSI refresh timed out.")
        )

        let appModel = await MainActor.run {
            AppModel(
                environment: makeTestAppEnvironment(
                    sessionStore: sessionStore,
                    snapshotStore: snapshotStore,
                    hangarRepository: failingRepository
                )
            )
        }

        await appModel.bootstrap()
        await appModel.refresh()

        let restoredSnapshot = await MainActor.run { appModel.snapshot }
        let refreshErrorMessage = await MainActor.run { appModel.lastRefreshErrorMessage }
        let stillLoaded = await MainActor.run {
            if case .loaded = appModel.loadState {
                return true
            }

            return false
        }

        #expect(restoredSnapshot == cachedSnapshot)
        #expect(stillLoaded)
        #expect(refreshErrorMessage == "Unable to refresh the full account snapshot. RSI refresh timed out.")
    }

    @Test func refreshHangarScopeUpdatesOnlyHangarBackedSections() async throws {
        let session = makeUserSession(
            handle: "hangar-scope",
            email: "hangar-scope@example.com",
            loginIdentifier: "hangar-scope@example.com",
            password: "secret-hangar",
            createdAt: Date(timeIntervalSince1970: 600)
        )
        let cachedSnapshot = PreviewHangarRepository.sampleSnapshot
        let refreshedSnapshot = cachedSnapshot.updatingHangar(
            packages: Array(cachedSnapshot.packages.prefix(1)),
            fleet: Array(cachedSnapshot.fleet.prefix(1)),
            lastSyncedAt: Date(timeIntervalSince1970: 601)
        )
        let repository = FakeHangarRepository(hangarSnapshot: refreshedSnapshot)

        let appModel = await MainActor.run {
            AppModel(
                environment: makeTestAppEnvironment(
                    sessionStore: FakeSessionStore(
                        storedSnapshot: StoredSessionsSnapshot(activeSession: session, savedSessions: [session])
                    ),
                    snapshotStore: FakeSnapshotStore(snapshot: cachedSnapshot),
                    hangarRepository: repository
                )
            )
        }

        await appModel.bootstrap()
        await appModel.refresh(scope: .hangar)

        let updatedSnapshot = try #require(await MainActor.run { appModel.snapshot })
        let invocationLog = await repository.invocationLog()

        #expect(updatedSnapshot.packages == refreshedSnapshot.packages)
        #expect(updatedSnapshot.fleet == refreshedSnapshot.fleet)
        #expect(updatedSnapshot.buyback == cachedSnapshot.buyback)
        #expect(updatedSnapshot.storeCreditUSD == cachedSnapshot.storeCreditUSD)
        #expect(updatedSnapshot.totalSpendUSD == cachedSnapshot.totalSpendUSD)
        #expect(updatedSnapshot.referralStats == cachedSnapshot.referralStats)
        #expect(invocationLog == ["hangar"])
    }

    @Test func refreshBuybackScopeUpdatesOnlyBuybackSection() async throws {
        let session = makeUserSession(
            handle: "buyback-scope",
            email: "buyback-scope@example.com",
            loginIdentifier: "buyback-scope@example.com",
            password: "secret-buyback",
            createdAt: Date(timeIntervalSince1970: 700)
        )
        let cachedSnapshot = PreviewHangarRepository.sampleSnapshot
        let refreshedSnapshot = cachedSnapshot.updatingBuyback(
            buyback: Array(cachedSnapshot.buyback.prefix(1)),
            lastSyncedAt: Date(timeIntervalSince1970: 701)
        )
        let repository = FakeHangarRepository(buybackSnapshot: refreshedSnapshot)

        let appModel = await MainActor.run {
            AppModel(
                environment: makeTestAppEnvironment(
                    sessionStore: FakeSessionStore(
                        storedSnapshot: StoredSessionsSnapshot(activeSession: session, savedSessions: [session])
                    ),
                    snapshotStore: FakeSnapshotStore(snapshot: cachedSnapshot),
                    hangarRepository: repository
                )
            )
        }

        await appModel.bootstrap()
        await appModel.refresh(scope: .buyback)

        let updatedSnapshot = try #require(await MainActor.run { appModel.snapshot })
        let invocationLog = await repository.invocationLog()

        #expect(updatedSnapshot.buyback == refreshedSnapshot.buyback)
        #expect(updatedSnapshot.packages == cachedSnapshot.packages)
        #expect(updatedSnapshot.fleet == cachedSnapshot.fleet)
        #expect(updatedSnapshot.storeCreditUSD == cachedSnapshot.storeCreditUSD)
        #expect(updatedSnapshot.totalSpendUSD == cachedSnapshot.totalSpendUSD)
        #expect(updatedSnapshot.referralStats == cachedSnapshot.referralStats)
        #expect(invocationLog == ["buyback"])
    }

    @Test func refreshAccountScopeUpdatesOnlyAccountSection() async throws {
        let session = makeUserSession(
            handle: "account-scope",
            email: "account-scope@example.com",
            loginIdentifier: "account-scope@example.com",
            password: "secret-account",
            createdAt: Date(timeIntervalSince1970: 800)
        )
        let cachedSnapshot = PreviewHangarRepository.sampleSnapshot
        let refreshedSnapshot = cachedSnapshot.updatingAccount(
            accountHandle: "account-scope",
            avatarURL: URL(string: "https://example.com/avatar.png"),
            primaryOrganization: nil,
            didRefreshPrimaryOrganization: true,
            storeCreditUSD: 999,
            totalSpendUSD: 1234,
            referralStats: ReferralStats(
                currentLadderCount: 51,
                legacyLadderCount: 12,
                hasLegacyLadder: true
            ),
            lastSyncedAt: Date(timeIntervalSince1970: 801)
        )
        let repository = FakeHangarRepository(accountSnapshot: refreshedSnapshot)

        let appModel = await MainActor.run {
            AppModel(
                environment: makeTestAppEnvironment(
                    sessionStore: FakeSessionStore(
                        storedSnapshot: StoredSessionsSnapshot(activeSession: session, savedSessions: [session])
                    ),
                    snapshotStore: FakeSnapshotStore(snapshot: cachedSnapshot),
                    hangarRepository: repository
                )
            )
        }

        await appModel.bootstrap()
        await appModel.refresh(scope: AppModel.RefreshScope.account)

        let updatedSnapshot = try #require(await MainActor.run { appModel.snapshot })
        let invocationLog = await repository.invocationLog()

        #expect(updatedSnapshot.avatarURL == refreshedSnapshot.avatarURL)
        #expect(updatedSnapshot.storeCreditUSD == refreshedSnapshot.storeCreditUSD)
        #expect(updatedSnapshot.totalSpendUSD == refreshedSnapshot.totalSpendUSD)
        #expect(updatedSnapshot.referralStats == refreshedSnapshot.referralStats)
        #expect(updatedSnapshot.packages == cachedSnapshot.packages)
        #expect(updatedSnapshot.fleet == cachedSnapshot.fleet)
        #expect(updatedSnapshot.buyback == cachedSnapshot.buyback)
        #expect(invocationLog == ["account"])
    }

    @Test func sessionExpiryKeepsCachedSnapshotVisibleAndPromptsForReauthentication() async throws {
        let session = makeUserSession(
            handle: "expired-session",
            email: "expired-session@example.com",
            loginIdentifier: "expired-session@example.com",
            password: "secret-expired",
            createdAt: Date(timeIntervalSince1970: 900),
            cookies: [makeSessionCookie(name: "Rsi-Token", value: "expired-cookie")]
        )
        let cachedSnapshot = PreviewHangarRepository.sampleSnapshot
        let sessionStore = FakeSessionStore(
            storedSnapshot: StoredSessionsSnapshot(activeSession: session, savedSessions: [session])
        )
        let repository = FakeHangarRepository(error: LiveHangarRepositoryError.sessionExpired)

        let appModel = await MainActor.run {
            AppModel(
                environment: makeTestAppEnvironment(
                    sessionStore: sessionStore,
                    snapshotStore: FakeSnapshotStore(snapshot: cachedSnapshot),
                    hangarRepository: repository
                )
            )
        }

        await appModel.bootstrap()
        await appModel.refresh()

        let restoredSnapshot = try #require(await MainActor.run { appModel.snapshot })
        let prompt = try #require(await MainActor.run { appModel.reauthenticationPrompt })
        let activeCookies = await MainActor.run { appModel.session?.cookies.count }
        let savedCookies = await MainActor.run { appModel.savedSessions.first?.cookies.count }
        let refreshErrorMessage = await MainActor.run { appModel.lastRefreshErrorMessage }

        #expect(restoredSnapshot == cachedSnapshot)
        #expect(prompt.message.contains("Sign in again"))
        #expect(activeCookies == 0)
        #expect(savedCookies == 0)
        #expect(refreshErrorMessage == nil)
    }

    @Test func beginReauthenticationRoutesToLoginWithSavedCredentialsPrefilled() async throws {
        let session = makeUserSession(
            handle: "reauth-session",
            email: "reauth-session@example.com",
            loginIdentifier: "reauth-session@example.com",
            password: "secret-reauth",
            createdAt: Date(timeIntervalSince1970: 950),
            cookies: [makeSessionCookie(name: "Rsi-Token", value: "expired-cookie")]
        )
        let cachedSnapshot = PreviewHangarRepository.sampleSnapshot

        let appModel = await MainActor.run {
            AppModel(
                environment: makeTestAppEnvironment(
                    sessionStore: FakeSessionStore(
                        storedSnapshot: StoredSessionsSnapshot(activeSession: session, savedSessions: [session])
                    ),
                    snapshotStore: FakeSnapshotStore(snapshot: cachedSnapshot),
                    hangarRepository: FakeHangarRepository(error: LiveHangarRepositoryError.sessionExpired)
                )
            )
        }

        await appModel.bootstrap()
        await appModel.refresh()
        await appModel.beginReauthentication()

        let currentSession = await MainActor.run { appModel.session }
        let prompt = await MainActor.run { appModel.reauthenticationPrompt }
        let draft = try #require(await MainActor.run { appModel.consumePendingAuthenticationDraft() })

        #expect(currentSession == nil)
        #expect(prompt == nil)
        #expect(draft.loginIdentifier == "reauth-session@example.com")
        #expect(draft.password == "secret-reauth")
        #expect(draft.notice?.contains("Sign in again") == true)
    }
}

private func makeCCUTestCatalog(
    additionalShips: [RSIShipCatalog.Ship] = [],
    storeUpgradeOffers: [RSIShipCatalog.StoreUpgradeOffer] = []
) -> RSIShipCatalog {
    RSIShipCatalog(
        ships: [
            makeCCUTestCatalogShip(id: 1, name: "Aurora MR", manufacturer: "RSI", msrpUSD: 30, storeAvailable: true),
            makeCCUTestCatalogShip(id: 2, name: "300i", manufacturer: "Origin", msrpUSD: 60, storeAvailable: true),
            makeCCUTestCatalogShip(id: 3, name: "Cutlass Black", manufacturer: "Drake", msrpUSD: 110, storeAvailable: true),
            makeCCUTestCatalogShip(id: 4, name: "Zeus Mk II MR", manufacturer: "RSI", msrpUSD: 190, storeAvailable: false)
        ] + additionalShips,
        storeUpgradeOffers: storeUpgradeOffers
    )
}

private func makeCCUTestCatalogShip(
    id: Int,
    name: String,
    manufacturer: String,
    msrpUSD: Decimal,
    storeAvailable: Bool
) -> RSIShipCatalog.Ship {
    RSIShipCatalog.Ship(
        id: id,
        name: name,
        manufacturer: manufacturer,
        msrpUSD: msrpUSD,
        storeAvailability: storeAvailable ? "Available" : "Unavailable",
        storeAvailable: storeAvailable,
        imageURL: nil
    )
}

private func makeCCUTestSnapshot(
    storeCreditUSD: Decimal = 0,
    packages: [HangarPackage],
    buyback: [BuybackPledge]
) -> HangarSnapshot {
    HangarSnapshot(
        accountHandle: "ccu-test",
        lastSyncedAt: Date(timeIntervalSince1970: 1_000),
        storeCreditUSD: storeCreditUSD,
        packages: packages,
        fleet: [],
        buyback: buyback
    )
}

private func makeCCUTestUpgradePackage(
    id: Int,
    title: String,
    source: String,
    target: String,
    currentValueUSD: Decimal,
    meltValueUSD: Decimal
) -> HangarPackage {
    HangarPackage(
        id: id,
        title: title,
        status: "Attributed",
        insurance: "",
        acquiredAt: Date(timeIntervalSince1970: 1_100 + TimeInterval(id)),
        originalValueUSD: meltValueUSD,
        currentValueUSD: currentValueUSD,
        canGift: true,
        canReclaim: true,
        canUpgrade: false,
        contents: [
            PackageItem(
                id: "\(id)-upgrade",
                title: title,
                detail: "Ship Upgrade",
                category: .upgrade,
                imageURL: nil,
                upgradePricing: PackageItem.UpgradePricing(
                    sourceShipName: source,
                    sourceShipMSRPUSD: nil,
                    sourceShipImageURL: nil,
                    targetShipName: target,
                    targetShipMSRPUSD: nil,
                    targetShipImageURL: nil,
                    actualValueUSD: currentValueUSD,
                    meltValueUSD: meltValueUSD
                )
            )
        ]
    )
}

private func makeUserSession(
    handle: String,
    email: String,
    loginIdentifier: String,
    password: String,
    createdAt: Date,
    avatarURL: URL? = nil,
    cookies: [SessionCookie] = []
) -> UserSession {
    UserSession(
        handle: handle,
        displayName: handle,
        email: email,
        authMode: .rsiNativeLogin,
        notes: "",
        avatarURL: avatarURL,
        credentials: AccountCredentials(loginIdentifier: loginIdentifier, password: password),
        cookies: cookies,
        createdAt: createdAt
    )
}

@MainActor
private func makeTestAppEnvironment(
    sessionStore: any SessionStore,
    snapshotStore: any SnapshotStore,
    hangarRepository: any HangarRepository,
    imageCache: (any RemoteImageCaching)? = nil
) -> AppEnvironment {
    let diagnostics = AuthenticationDiagnosticsStore()
    let refreshDiagnostics = RefreshDiagnosticsStore()
    let recaptchaBroker = RecaptchaBroker(diagnostics: diagnostics)

    return AppEnvironment(
        sessionStore: sessionStore,
        snapshotStore: snapshotStore,
        imageCache: imageCache ?? URLCachedImageStore.shared,
        hangarRepository: hangarRepository,
        sensitiveActionAuthorizer: PreviewSensitiveActionAuthorizer(),
        authService: PreviewAuthenticationService(diagnostics: diagnostics),
        recaptchaBroker: recaptchaBroker,
        authDiagnostics: diagnostics,
        refreshDiagnostics: refreshDiagnostics,
        subscriptionStore: SubscriptionStore(storeKitEnabled: false)
    )
}

private func makeHangarActionPackage(
    id: Int,
    title: String,
    canGift: Bool,
    canReclaim: Bool,
    originalValueUSD: Decimal
) -> HangarPackage {
    HangarPackage(
        id: id,
        title: title,
        status: "Attributed",
        insurance: "LTI",
        acquiredAt: Date(timeIntervalSince1970: 1_700 + TimeInterval(id)),
        originalValueUSD: originalValueUSD,
        currentValueUSD: originalValueUSD,
        canGift: canGift,
        canReclaim: canReclaim,
        canUpgrade: true,
        contents: [
            PackageItem(
                id: "\(id)-ship",
                title: title,
                detail: "Ship",
                category: .ship,
                imageURL: nil,
                upgradePricing: nil
            )
        ]
    )
}

private func makeSessionCookie(name: String, value: String) -> SessionCookie {
    SessionCookie(
        name: name,
        value: value,
        domain: ".robertsspaceindustries.com",
        path: "/",
        expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
        isSecure: true,
        isHTTPOnly: true,
        version: 0
    )
}

private func makeHostedShipDetailPayload(description: String, technicalValue: String) -> Data {
    Data(
        """
        {
          "generatedAt": "2026-04-23T19:43:33.708Z",
          "sourcePageUrl": "https://starcitizen.tools/List_of_pledge_vehicles",
          "shipCount": 1,
          "ships": [
            {
              "name": "100i",
              "pageUrl": "https://starcitizen.tools/100i",
              "manufacturer": "Origin Jumpworks",
              "career": "Multi-role",
              "role": "Starter / Touring",
              "size": "Small",
              "inGameStatus": "Flight ready",
              "pledgeAvailability": "Always available",
              "minCrew": 1,
              "maxCrew": 1,
              "description": \(jsonStringLiteral(description)),
              "technicalSpecs": [
                { "label": "Length", "value": "19 m" }
              ],
              "technicalSections": [
                {
                  "title": "Turret",
                  "items": [
                    { "label": "CF-337 Panther Repeater", "value": \(jsonStringLiteral(technicalValue)) }
                  ]
                }
              ],
              "unavailableReason": null
            }
          ]
        }
        """.utf8
    )
}

private func makeHangarItemTranslationPayload() -> Data {
    Data(
        #"""
        {
          "locale": "zh-Hans",
          "version": 1,
          "generatedAt": "2026-06-10T00:00:00.000Z",
          "count": 2,
          "entries": [
            {
              "source": "F8C Lightning",
              "translation": "F8C 闪电",
              "kind": "ship",
              "aliases": ["Anvil F8C Lightning"]
            },
            {
              "source": "Package - Praetorian Pack",
              "translation": "组合包 - 执政官包",
              "kind": "package",
              "aliases": []
            }
          ]
        }
        """#.utf8
    )
}

private func jsonStringLiteral(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    let arrayLiteral = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    return String(arrayLiteral.dropFirst().dropLast())
}

private func makeSolidImageData(
    color: UIColor,
    size: CGSize = CGSize(width: 240, height: 240)
) -> Data {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = true

    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
        color.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }

    return image.jpegData(compressionQuality: 1) ?? Data()
}

private func sampledColor(
    from image: UIImage,
    normalizedPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
) -> UIColor? {
    guard let cgImage = image.cgImage else {
        return nil
    }

    var pixel = [UInt8](repeating: 0, count: 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: &pixel,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    let pixelX = CGFloat(min(max(Int(CGFloat(cgImage.width - 1) * normalizedPoint.x), 0), cgImage.width - 1))
    let pixelY = CGFloat(min(max(Int(CGFloat(cgImage.height - 1) * normalizedPoint.y), 0), cgImage.height - 1))

    context.translateBy(x: -pixelX, y: pixelY - CGFloat(cgImage.height) + 1)
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

    return UIColor(
        red: CGFloat(pixel[0]) / 255,
        green: CGFloat(pixel[1]) / 255,
        blue: CGFloat(pixel[2]) / 255,
        alpha: CGFloat(pixel[3]) / 255
    )
}

private func colorMatches(_ lhs: UIColor?, _ rhs: UIColor, tolerance: CGFloat = 0.12) -> Bool {
    guard let lhs,
          let lhsComponents = lhs.cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components,
          let rhsComponents = rhs.cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components,
          lhsComponents.count >= 3,
          rhsComponents.count >= 3 else {
        return false
    }

    return abs(lhsComponents[0] - rhsComponents[0]) <= tolerance
        && abs(lhsComponents[1] - rhsComponents[1]) <= tolerance
        && abs(lhsComponents[2] - rhsComponents[2]) <= tolerance
}

private func colorsMatch(_ lhs: UIColor?, _ rhs: UIColor?, tolerance: CGFloat = 0.12) -> Bool {
    guard let rhs else {
        return lhs == nil
    }

    return colorMatches(lhs, rhs, tolerance: tolerance)
}

private func makeMockURLSession(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    MockURLProtocol.requestHandler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeTranslationMockURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TranslationMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class FakeAuthenticationWebSession: AuthenticationWebSessionProviding, @unchecked Sendable {
    let signInResponse: BrowserGraphQLResponse
    let twoFactorResponse: BrowserGraphQLResponse
    let cookies: [SessionCookie]

    init(
        signInResponse: BrowserGraphQLResponse,
        twoFactorResponse: BrowserGraphQLResponse = BrowserGraphQLResponse(statusCode: 200, body: #"{"data":{"account_multistep":null},"errors":[]}"#),
        cookies: [SessionCookie] = []
    ) {
        self.signInResponse = signInResponse
        self.twoFactorResponse = twoFactorResponse
        self.cookies = cookies
    }

    @MainActor
    func resetAuthenticationSession() async throws {}

    @MainActor
    func signIn(loginIdentifier: String, password: String, rememberMe: Bool, query: String) async throws -> BrowserGraphQLResponse {
        signInResponse
    }

    @MainActor
    func submitTwoFactor(code: String, deviceName: String, trustDuration: TrustedDeviceDuration, query: String) async throws -> BrowserGraphQLResponse {
        twoFactorResponse
    }

    @MainActor
    func currentRSICookies() async throws -> [SessionCookie] {
        cookies
    }
}

private actor FakeRemoteImageCache: RemoteImageCaching {
    private var clearCalls = 0

    func clear() async {
        clearCalls += 1
    }

    func clear(urls _: [URL]) async {}

    func clearCallCount() async -> Int {
        clearCalls
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "example.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private enum TranslationMockURLResponse: @unchecked Sendable {
    case response(statusCode: Int, data: Data)
    case error(Error)
}

private final class TranslationMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [URL: TranslationMockURLResponse] = [:]

    static func register(_ response: TranslationMockURLResponse, for url: URL) {
        lock.lock()
        defer {
            lock.unlock()
        }

        responses[url] = response
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "translation.example.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = Self.registeredResponse(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch response {
        case let .response(statusCode, data):
            guard let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .error(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func registeredResponse(for url: URL) -> TranslationMockURLResponse? {
        lock.lock()
        defer {
            lock.unlock()
        }

        return responses[url]
    }
}

private final class MutableImageDataBox: @unchecked Sendable {
    var data: Data

    init(data: Data) {
        self.data = data
    }
}

private actor FakeSessionStore: SessionStore {
    private var storedSnapshot: StoredSessionsSnapshot

    init(storedSnapshot: StoredSessionsSnapshot) {
        self.storedSnapshot = storedSnapshot
    }

    func loadSnapshot() async -> StoredSessionsSnapshot {
        storedSnapshot
    }

    func save(_ session: UserSession, makeActive: Bool) async -> StoredSessionsSnapshot {
        let payload = StoredSessionsPayload(
            activeSessionID: storedSnapshot.activeSession?.id,
            sessions: storedSnapshot.savedSessions
        ).saving(session, makeActive: makeActive)
        storedSnapshot = payload.snapshot
        return storedSnapshot
    }

    func selectSession(id: UserSession.ID) async -> StoredSessionsSnapshot {
        let payload = StoredSessionsPayload(
            activeSessionID: storedSnapshot.activeSession?.id,
            sessions: storedSnapshot.savedSessions
        ).selecting(id: id)
        storedSnapshot = payload.snapshot
        return storedSnapshot
    }

    func deleteSession(id: UserSession.ID) async -> StoredSessionsSnapshot {
        let payload = StoredSessionsPayload(
            activeSessionID: storedSnapshot.activeSession?.id,
            sessions: storedSnapshot.savedSessions
        ).deleting(id: id)
        storedSnapshot = payload.snapshot
        return storedSnapshot
    }

    func clear() async -> StoredSessionsSnapshot {
        storedSnapshot = .empty
        return storedSnapshot
    }
}

private actor FakeSnapshotStore: SnapshotStore {
    private var snapshot: HangarSnapshot?

    init(snapshot: HangarSnapshot?) {
        self.snapshot = snapshot
    }

    func load(for session: UserSession) async -> HangarSnapshot? {
        snapshot
    }

    func save(_ snapshot: HangarSnapshot, for session: UserSession) async {
        self.snapshot = snapshot
    }

    func delete(for session: UserSession) async {
        snapshot = nil
    }

    func clear() async {
        snapshot = nil
    }
}

private actor FakeHangarRepository: HangarRepository {
    private let fullSnapshot: HangarSnapshot?
    private let hangarSnapshot: HangarSnapshot?
    private let buybackSnapshot: HangarSnapshot?
    private let accountSnapshot: HangarSnapshot?
    private let fullError: Error?
    private let hangarError: Error?
    private let buybackError: Error?
    private let accountError: Error?
    private var invokedScopes: [String] = []
    private var recordedMeltRequests: [[Int]] = []
    private var recordedGiftRequests: [[Int]] = []

    init(
        snapshot: HangarSnapshot? = nil,
        hangarSnapshot: HangarSnapshot? = nil,
        buybackSnapshot: HangarSnapshot? = nil,
        accountSnapshot: HangarSnapshot? = nil,
        error: Error? = nil,
        hangarError: Error? = nil,
        buybackError: Error? = nil,
        accountError: Error? = nil
    ) {
        fullSnapshot = snapshot
        self.hangarSnapshot = hangarSnapshot
        self.buybackSnapshot = buybackSnapshot
        self.accountSnapshot = accountSnapshot
        fullError = error
        self.hangarError = hangarError
        self.buybackError = buybackError
        self.accountError = accountError
    }

    func fetchSnapshot(
        for session: UserSession,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        invokedScopes.append("full")

        if let fullError {
            throw fullError
        }

        guard let fullSnapshot else {
            throw AuthenticationError.unavailable("No full snapshot was configured for the fake repository.")
        }

        return fullSnapshot
    }

    func refreshHangarData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        invokedScopes.append("hangar")

        if let hangarError {
            throw hangarError
        }

        return hangarSnapshot ?? snapshot
    }

    func refreshHangarData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        affectedPledgeIDs: [Int],
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        invokedScopes.append("hangar-partial")

        if let hangarError {
            throw hangarError
        }

        return hangarSnapshot ?? snapshot
    }

    func refreshBuybackData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        invokedScopes.append("buyback")

        if let buybackError {
            throw buybackError
        }

        return buybackSnapshot ?? snapshot
    }

    func refreshHangarLogData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        mode _: HangarLogFetchMode,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        invokedScopes.append("hangarLog")
        return snapshot
    }

    func refreshAccountData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        invokedScopes.append("account")

        if let accountError {
            throw accountError
        }

        return accountSnapshot ?? snapshot
    }

    func meltPackages(
        for session: UserSession,
        pledgeIDs: [Int],
        password: String
    ) async throws -> MeltPackagesResult {
        invokedScopes.append("melt")
        recordedMeltRequests.append(pledgeIDs)

        return MeltPackagesResult(
            requestedPledgeIDs: pledgeIDs,
            completedPledgeIDs: pledgeIDs,
            failedPledgeID: nil,
            failureMessage: nil,
            updatedCookies: session.cookies
        )
    }

    func giftPackages(
        for session: UserSession,
        pledgeIDs: [Int],
        password: String,
        recipientEmail: String,
        recipientName: String
    ) async throws -> GiftPackagesResult {
        invokedScopes.append("gift")
        recordedGiftRequests.append(pledgeIDs)

        return GiftPackagesResult(
            requestedPledgeIDs: pledgeIDs,
            completedPledgeIDs: pledgeIDs,
            failedPledgeID: nil,
            failureMessage: nil,
            updatedCookies: session.cookies
        )
    }

    func fetchUpgradeTargets(
        for _: UserSession,
        upgradeItemPledgeID _: Int
    ) async throws -> [UpgradeTargetCandidate] {
        [
            UpgradeTargetCandidate(
                pledgeID: 5001,
                title: "Test Target Pledge",
                status: "Attributed",
                insurance: "LTI",
                thumbnailURL: nil
            )
        ]
    }

    func applyUpgrade(
        for session: UserSession,
        upgradeItemPledgeID: Int,
        targetPledgeID: Int,
        password _: String
    ) async throws -> ApplyUpgradeResult {
        ApplyUpgradeResult(
            upgradeItemPledgeID: upgradeItemPledgeID,
            targetPledgeID: targetPledgeID,
            wasSuccessful: true,
            failureMessage: nil,
            updatedCookies: session.cookies
        )
    }

    func prepareBuybackCheckout(
        for session: UserSession,
        pledge: BuybackPledge
    ) async throws -> BuybackCheckoutPreparation {
        BuybackCheckoutPreparation(
            buybackPledgeID: pledge.id,
            checkoutURL: URL(string: "https://example.com/checkout")!,
            updatedCookies: session.cookies
        )
    }

    func fetchLimitedShipSales() async throws -> [LimitedShipSale] {
        [
            LimitedShipSale(
                id: "test-gladius",
                name: "Gladius",
                manufacturer: "Aegis Dynamics",
                priceUSD: 90,
                availabilitySlots: [
                    LimitedShipAvailabilitySlot(
                        startsAt: Date(timeIntervalSince1970: 1_776_000_000),
                        endsAt: Date(timeIntervalSince1970: 1_776_000_600)
                    )
                ],
                storeURL: URL(string: "https://example.com/gladius")!,
                imageURL: nil,
                manufacturerLogoURL: nil
            )
        ]
    }

    func addLimitedShipToCart(
        for session: UserSession,
        ship: LimitedShipSale,
        log: @escaping LimitedShipCartLogHandler
    ) async throws -> LimitedShipCartInsertionResult {
        await log("Test fake added \(ship.name) to cart.")
        return LimitedShipCartInsertionResult(
            shipID: ship.id,
            cartURL: URL(string: "https://example.com/cart")!,
            attemptCount: 1,
            debugSummary: nil,
            debugLog: ["Test fake added \(ship.name) to cart."],
            updatedCookies: session.cookies
        )
    }

    func fetchAuthorizedDevices(
        for _: UserSession,
        password _: String?
    ) async throws -> [AuthorizedDevice] {
        []
    }

    func removeAuthorizedDevice(
        for _: UserSession,
        device _: AuthorizedDevice,
        password _: String?
    ) async throws {}

    func removeAuthorizedDevices(
        for _: UserSession,
        devices _: [AuthorizedDevice],
        password _: String?
    ) async throws {}

    func invocationLog() -> [String] {
        invokedScopes
    }

    func meltRequests() -> [[Int]] {
        recordedMeltRequests
    }

    func giftRequests() -> [[Int]] {
        recordedGiftRequests
    }
}
