import Foundation
@testable import Hanger_Express

@MainActor
extension Hanger_ExpressTests {
    func makeTestAppEnvironment(
        sessionStore: any SessionStore,
        snapshotStore: any SnapshotStore,
        hangarRepository: any HangarRepository,
        imageCache: (any RemoteImageCaching)? = nil,
        userDefaults: UserDefaults? = nil,
        responseCache: URLCache? = nil,
        shipDetailCatalogStore: HostedShipDetailCatalogStore? = nil,
        actionAuthorizer: (any SensitiveActionAuthorizing)? = nil,
        authenticationService: (any AuthenticationServicing)? = nil
    ) -> AppEnvironment {
        let userDefaults = userDefaults ?? resources.defaults
        let diagnostics = AuthenticationDiagnosticsStore()
        let refreshDiagnostics = RefreshDiagnosticsStore()
        let recaptchaBroker = RecaptchaBroker(diagnostics: diagnostics)

        return AppEnvironment(
            sessionStore: sessionStore,
            snapshotStore: snapshotStore,
            imageCache: imageCache ?? FakeRemoteImageCache(),
            hangarRepository: hangarRepository,
            sensitiveActionAuthorizer: actionAuthorizer ?? PreviewSensitiveActionAuthorizer(),
            authService: authenticationService ?? PreviewAuthenticationService(diagnostics: diagnostics),
            recaptchaBroker: recaptchaBroker,
            authIPRegionChecker: PreviewAuthenticationIPRegionChecker(),
            authDiagnostics: diagnostics,
            refreshDiagnostics: refreshDiagnostics,
            subscriptionStore: SubscriptionStore(userDefaults: userDefaults, storeKitEnabled: false),
            userDefaults: userDefaults,
            responseCache: responseCache ?? URLCache(memoryCapacity: 0, diskCapacity: 0),
            shipCatalogStore: HostedShipCatalogStore(),
            shipDetailCatalogStore: shipDetailCatalogStore ?? HostedShipDetailCatalogStore()
        )
    }
}

final class FakeAuthenticationWebSession: AuthenticationWebSessionProviding, @unchecked Sendable {
    let signInResponse: BrowserGraphQLResponse
    let twoFactorResponse: BrowserGraphQLResponse
    let cookies: [SessionCookie]
    let resetError: Error?

    init(
        signInResponse: BrowserGraphQLResponse,
        twoFactorResponse: BrowserGraphQLResponse = BrowserGraphQLResponse(statusCode: 200, body: #"{"data":{"account_multistep":null},"errors":[]}"#),
        cookies: [SessionCookie] = [],
        resetError: Error? = nil
    ) {
        self.signInResponse = signInResponse
        self.twoFactorResponse = twoFactorResponse
        self.cookies = cookies
        self.resetError = resetError
    }

    @MainActor
    func resetAuthenticationSession() async throws {
        if let resetError {
            throw resetError
        }
    }

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

@MainActor
final class FakeRemoteImageCache: RemoteImageCaching {
    private var clearCalls = 0

    func clear() async {
        clearCalls += 1
    }

    func clear(urls _: [URL]) async {}

    func clearCallCount() async -> Int {
        clearCalls
    }
}

@MainActor
final class FakeSessionStore: SessionStore {
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

@MainActor
final class FakeSnapshotStore: SnapshotStore {
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

struct RecordedCharacterRepairRequest: Equatable, Sendable {
    let reason: String
    let issueCouncilURL: String?
}

@MainActor
final class FakeHangarRepository: HangarRepository {
    var fetchOverride: (@MainActor (UserSession, @escaping RefreshProgressHandler) async throws -> HangarSnapshot)?
    var hangarOverride: (@MainActor (UserSession, HangarSnapshot) async throws -> HangarSnapshot)?
    var meltOverride: (@MainActor (UserSession, [Int]) async throws -> MeltPackagesResult)?

    private let fullSnapshot: HangarSnapshot?
    private let hangarSnapshot: HangarSnapshot?
    private let buybackSnapshot: HangarSnapshot?
    private let accountSnapshot: HangarSnapshot?
    private let fullError: Error?
    private let hangarError: Error?
    private let buybackError: Error?
    private let accountError: Error?
    private let characterRepairResult: CharacterRepairResult?
    private var invokedScopes: [String] = []
    private var recordedMeltRequests: [[Int]] = []
    private var recordedGiftRequests: [[Int]] = []
    private var recordedCharacterRepairRequests: [RecordedCharacterRepairRequest] = []

    init(
        snapshot: HangarSnapshot? = nil,
        hangarSnapshot: HangarSnapshot? = nil,
        buybackSnapshot: HangarSnapshot? = nil,
        accountSnapshot: HangarSnapshot? = nil,
        error: Error? = nil,
        hangarError: Error? = nil,
        buybackError: Error? = nil,
        accountError: Error? = nil,
        characterRepairResult: CharacterRepairResult? = nil
    ) {
        fullSnapshot = snapshot
        self.hangarSnapshot = hangarSnapshot
        self.buybackSnapshot = buybackSnapshot
        self.accountSnapshot = accountSnapshot
        fullError = error
        self.hangarError = hangarError
        self.buybackError = buybackError
        self.accountError = accountError
        self.characterRepairResult = characterRepairResult
    }

    func fetchSnapshot(
        for session: UserSession,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        invokedScopes.append("full")
        if let fetchOverride { return try await fetchOverride(session, progress) }

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
        if let hangarOverride { return try await hangarOverride(session, snapshot) }

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
        if let hangarOverride { return try await hangarOverride(session, snapshot) }

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
        progress: @escaping RefreshProgressHandler,
        batchHandler _: HangarLogBatchHandler?
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
        if let meltOverride { return try await meltOverride(session, pledgeIDs) }

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

    func requestCharacterRepair(
        for session: UserSession,
        reason: String,
        issueCouncilURL: String?
    ) async throws -> CharacterRepairResult {
        invokedScopes.append("characterRepair")
        recordedCharacterRepairRequests.append(
            RecordedCharacterRepairRequest(reason: reason, issueCouncilURL: issueCouncilURL)
        )

        return characterRepairResult ?? CharacterRepairResult(
            wasSuccessful: true,
            failureMessage: nil,
            cooldownRemainingSeconds: nil,
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

    func requestAuthorizedDevicesVerificationCode(
        for session: UserSession
    ) async throws -> [SessionCookie] {
        session.cookies
    }

    func verifyAuthorizedDevices(
        for session: UserSession,
        code _: String
    ) async throws -> [SessionCookie] {
        session.cookies
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

    func characterRepairRequests() -> [RecordedCharacterRepairRequest] {
        recordedCharacterRepairRequests
    }
}
