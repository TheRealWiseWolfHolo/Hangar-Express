import Foundation
import Testing
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
        #expect(package.detailInsuranceText == "LTI, 120 months, 6 months")
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
        #expect(package.displayedInsurance == "120 months")
        #expect(package.detailInsuranceText == "120 months")
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

        #expect(upgrade.isUpgrade)
        #expect(!upgrade.isStandaloneShip)
        #expect(skin.isSkin)
        #expect(!skin.isStandaloneShip)
        #expect(package.isPackage)
        #expect(!package.isStandaloneShip)
        #expect(ship.isStandaloneShip)
        #expect(!ship.isUpgrade)
        #expect(gear.isGear)
        #expect(!gear.isPackage)
        #expect(!gear.isStandaloneShip)
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

        let service = RSIAuthService(recaptchaBroker: webSession)
        let outcome = try await service.signIn(
            loginIdentifier: "pilot@example.com",
            password: "secret-password",
            rememberMe: true
        )

        switch outcome {
        case .requiresTwoFactor:
            break
        case .authenticated:
            Issue.record("Expected the auth flow to require a verification code.")
        }
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

        let service = RSIAuthService(recaptchaBroker: webSession)

        do {
            _ = try await service.signIn(
                loginIdentifier: "pilot@example.com",
                password: "wrong-password",
                rememberMe: true
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

        let service = RSIAuthService(recaptchaBroker: webSession)

        do {
            _ = try await service.signIn(
                loginIdentifier: "pilot@example.com",
                password: "wrong-password",
                rememberMe: true
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

        let service = RSIAuthService(recaptchaBroker: webSession)

        do {
            _ = try await service.signIn(
                loginIdentifier: "pilot@example.com",
                password: "secret-password",
                rememberMe: true
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

        let service = RSIAuthService(recaptchaBroker: webSession)
        _ = try await service.signIn(
            loginIdentifier: "pilot@example.com",
            password: "secret-password",
            rememberMe: true
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
                )
            ]
        )

        #expect(catalog.matchShip(named: "Idris-M Frigate")?.name == "Idris-M")
        #expect(catalog.matchShip(named: "Idris-P Frigate")?.name == "Idris-P")
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
                  "thumbnailUrl": "https://example.com/polaris.webp"
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
        #expect(match.imageURL == URL(string: "https://example.com/polaris.webp"))
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
            canGift: true,
            canReclaim: true
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
                environment: AppEnvironment(
                    sessionStore: sessionStore,
                    snapshotStore: snapshotStore,
                    hangarRepository: failingRepository,
                    authService: PreviewAuthenticationService(),
                    recaptchaBroker: RecaptchaBroker()
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
                environment: AppEnvironment(
                    sessionStore: FakeSessionStore(
                        storedSnapshot: StoredSessionsSnapshot(activeSession: session, savedSessions: [session])
                    ),
                    snapshotStore: FakeSnapshotStore(snapshot: cachedSnapshot),
                    hangarRepository: repository,
                    authService: PreviewAuthenticationService(),
                    recaptchaBroker: RecaptchaBroker()
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
                environment: AppEnvironment(
                    sessionStore: FakeSessionStore(
                        storedSnapshot: StoredSessionsSnapshot(activeSession: session, savedSessions: [session])
                    ),
                    snapshotStore: FakeSnapshotStore(snapshot: cachedSnapshot),
                    hangarRepository: repository,
                    authService: PreviewAuthenticationService(),
                    recaptchaBroker: RecaptchaBroker()
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
                environment: AppEnvironment(
                    sessionStore: FakeSessionStore(
                        storedSnapshot: StoredSessionsSnapshot(activeSession: session, savedSessions: [session])
                    ),
                    snapshotStore: FakeSnapshotStore(snapshot: cachedSnapshot),
                    hangarRepository: repository,
                    authService: PreviewAuthenticationService(),
                    recaptchaBroker: RecaptchaBroker()
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
                environment: AppEnvironment(
                    sessionStore: sessionStore,
                    snapshotStore: FakeSnapshotStore(snapshot: cachedSnapshot),
                    hangarRepository: repository,
                    authService: PreviewAuthenticationService(),
                    recaptchaBroker: RecaptchaBroker()
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
                environment: AppEnvironment(
                    sessionStore: FakeSessionStore(
                        storedSnapshot: StoredSessionsSnapshot(activeSession: session, savedSessions: [session])
                    ),
                    snapshotStore: FakeSnapshotStore(snapshot: cachedSnapshot),
                    hangarRepository: FakeHangarRepository(error: LiveHangarRepositoryError.sessionExpired),
                    authService: PreviewAuthenticationService(),
                    recaptchaBroker: RecaptchaBroker()
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

    func invocationLog() -> [String] {
        invokedScopes
    }
}
