import Foundation
import Testing
@testable import Hanger_Express

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AccountOperationCoordinatorTests {
    let resources = TestResources()

    @Test func generationsRejectSameAccountAfterSwitchAwayAndBack() throws {
        let coordinator = AccountOperationCoordinator(defaults: resources.defaults)
        let a = operationSession("a")
        let old = try coordinator.begin(session: a, mutation: false)
        coordinator.invalidate()
        let fresh = try coordinator.begin(session: a, mutation: false)
        #expect(!coordinator.isCurrent(old, session: a))
        #expect(coordinator.isCurrent(fresh, session: a))
        coordinator.finish(old, session: a, succeeded: false)
        #expect(coordinator.isCurrent(fresh, session: a))
    }

    @Test func uncertainSubmissionSurvivesRelaunchAndNeedsFreshReadAndExplicitReview() throws {
        let a = operationSession("a")
        let first = AccountOperationCoordinator(defaults: resources.defaults)
        let owner = try first.begin(session: a, mutation: true)
        first.willSubmit(owner, session: a)
        first.finishedSubmission(owner, session: a)
        first.invalidate()
        let restored = AccountOperationCoordinator(defaults: resources.defaults)
        #expect(restored.requiresReview(a))
        #expect(!restored.canAcknowledgeReview(a))
        restored.acknowledgeReview(a)
        #expect(restored.requiresReview(a))
        #expect(throws: AccountOperationError.self) { try restored.begin(session: a, mutation: true) }
        restored.recordRecoveryRead(a, stamp: restored.recoveryReadStamp(a))
        #expect(restored.canAcknowledgeReview(a))
        #expect(restored.requiresReview(a)) // A refresh alone does not retry/resolve an action.
        restored.acknowledgeReview(a)
        #expect(!restored.requiresReview(a))
        _ = try restored.begin(session: a, mutation: true)
        let hashes = resources.defaults.stringArray(forKey: "operations.unconfirmedAccounts.v1") ?? []
        #expect(hashes.isEmpty)
    }

    @Test func pendingAccountDoesNotBlockAnotherAccountAndMarkerContainsOnlyAHash() throws {
        let c = AccountOperationCoordinator(defaults: resources.defaults)
        let a = operationSession("private-a")
        let b = operationSession("private-b")
        let owner = try c.begin(session: a, mutation: true)
        c.willSubmit(owner, session: a)
        c.invalidate()
        _ = try c.begin(session: b, mutation: true)
        #expect(c.requiresReview(a))
        #expect(!c.requiresReview(b))
        let hash = try #require(resources.defaults.stringArray(forKey: "operations.unconfirmedAccounts.v1")?.first)
        #expect(hash.count == 64)
        #expect(hash.allSatisfy { $0.isHexDigit })
        #expect(!hash.contains(a.email))
    }

    @Test func recoveryReadMustStartAfterTheSubmittedRequestSettles() throws {
        let c = AccountOperationCoordinator(defaults: resources.defaults)
        let a = operationSession("a")
        let owner = try c.begin(session: a, mutation: true)
        c.willSubmit(owner, session: a)
        let overlappingRead = c.recoveryReadStamp(a)
        #expect(overlappingRead == nil)
        c.finish(owner, session: a, succeeded: false)
        c.finishedSubmission(owner, session: a)
        c.recordRecoveryRead(a, stamp: overlappingRead)
        #expect(!c.canAcknowledgeReview(a))
        c.recordRecoveryRead(a, stamp: c.recoveryReadStamp(a))
        #expect(c.canAcknowledgeReview(a))
    }

    @Test func gateSpansReconciliationAndOldFinishCannotReleaseAnotherLease() throws {
        let c = AccountOperationCoordinator(defaults: resources.defaults)
        let a = operationSession("a")
        let old = try c.begin(session: a, mutation: true)
        c.willSubmit(old, session: a)
        c.finishedSubmission(old, session: a)
        c.handOffReconciliation(old)
        c.finish(old, session: a, succeeded: true)
        #expect(c.hasMutation)
        #expect(c.requiresReview(a))
        #expect(throws: AccountOperationError.self) { try c.begin(session: a, mutation: true) }
        c.completeReconciliation(old, session: a)
        c.finishReconciliation(old)
        #expect(!c.requiresReview(a))
        let fresh = try c.begin(session: a, mutation: true)
        c.finish(old, session: a, succeeded: true)
        #expect(c.hasMutation)
        #expect(c.isCurrent(fresh, session: a))
    }
}

extension Hanger_ExpressTests {
    @Test func lateRefreshCannotOverwriteSwitchedAccountOrPersistItsSnapshot() async throws {
        let f = operationFixture()
        defer { f.repository.fetchOverride = nil; f.repository.meltOverride = nil }
        let arrived = TestGate(), release = IgnoringCancellationGate()
        defer { Task { await release.open() } }
        f.repository.fetchOverride = { _, _ in
            await arrived.open(); await release.wait()
            return f.aSnapshot.updatingHangarLogs(hangarLogs: [], lastSyncedAt: Date(timeIntervalSince1970: 999))
        }
        let old = Task { await f.model.refresh() }
        try await arrived.wait()
        await f.model.switchAccount(to: f.b.id)
        await old.value // The old caller must stop waiting before its backend returns.
        #expect(f.model.session == f.b)
        await release.open()
        await f.model.waitForAccountOperationJobs(accountID: f.a.id)
        #expect(f.model.session == f.b)
        #expect(f.model.snapshot == f.bSnapshot)
        #expect(f.model.lastRefreshErrorMessage == nil)
        #expect(!f.snapshots.savedIDs.contains(f.a.id))
    }

    @Test func signOutDuringRefreshCannotResurrectSessionOrCachedContent() async throws {
        let f = operationFixture()
        defer { f.repository.fetchOverride = nil; f.repository.meltOverride = nil }
        let arrived = TestGate(), release = IgnoringCancellationGate()
        defer { Task { await release.open() } }
        f.repository.fetchOverride = { _, _ in
            await arrived.open(); await release.wait(); return f.aSnapshot
        }
        let old = Task { await f.model.refresh() }
        try await arrived.wait()
        await f.model.clearSession()
        await release.open(); await old.value
        await f.model.waitForAccountOperationJobs(accountID: f.a.id)
        #expect(f.model.session == nil)
        #expect(f.model.savedSessions.isEmpty)
        #expect(f.model.snapshot == nil)
        #expect(f.snapshots.savedIDs.isEmpty)
        #expect(f.model.lastRefreshErrorMessage == nil)
    }

    @Test func removingAccountDuringItsRefreshCannotRestoreIt() async throws {
        let f = operationFixture()
        defer { f.repository.fetchOverride = nil; f.repository.meltOverride = nil }
        let arrived = TestGate(), release = IgnoringCancellationGate()
        defer { Task { await release.open() } }
        f.repository.fetchOverride = { _, _ in
            await arrived.open(); await release.wait(); return f.aSnapshot
        }
        let old = Task { await f.model.refresh() }
        try await arrived.wait()
        await f.model.removeSavedAccount(id: f.a.id)
        await release.open(); await old.value
        await f.model.waitForAccountOperationJobs(accountID: f.a.id)
        #expect(f.model.session == f.b)
        #expect(f.model.savedSessions == [f.b])
        #expect(f.snapshots.values[f.a.id] == nil)
        #expect(!f.snapshots.savedIDs.contains(f.a.id))
    }

    @Test func sameAccountAfterSwitchAwayAndBackStillRejectsOldRefresh() async throws {
        let f = operationFixture()
        defer { f.repository.fetchOverride = nil; f.repository.meltOverride = nil }
        let arrived = TestGate(), release = IgnoringCancellationGate()
        defer { Task { await release.open() } }
        f.repository.fetchOverride = { _, _ in
            await arrived.open(); await release.wait()
            return f.aSnapshot.updatingHangarLogs(hangarLogs: [], lastSyncedAt: Date(timeIntervalSince1970: 999))
        }
        let old = Task { await f.model.refresh() }
        try await arrived.wait()
        await f.model.switchAccount(to: f.b.id)
        f.model.savedSessions = [f.a, f.b] // Permit the first-account switch in the non-Pro fixture.
        await f.model.switchAccount(to: f.a.id)
        await release.open(); await old.value
        await f.model.waitForAccountOperationJobs(accountID: f.a.id)
        #expect(f.model.session == f.a)
        #expect(f.model.snapshot == f.aSnapshot)
        #expect(!f.snapshots.savedIDs.contains(f.a.id))
    }

    @Test func staleErrorAndProgressCannotClearNewAccountsRefresh() async throws {
        let f = operationFixture()
        defer { f.repository.fetchOverride = nil; f.repository.meltOverride = nil }
        let firstArrived = TestGate(), secondArrived = TestGate()
        let firstRelease = IgnoringCancellationGate(), secondRelease = IgnoringCancellationGate()
        defer { Task { await firstRelease.open(); await secondRelease.open() } }
        var lateProgress: RefreshProgressHandler?
        f.repository.fetchOverride = { session, progress in
            if session.id == f.a.id {
                lateProgress = progress
                await firstArrived.open(); await firstRelease.wait()
                throw LiveHangarRepositoryError.sessionExpired
            }
            await secondArrived.open(); await secondRelease.wait(); return f.bSnapshot
        }
        let first = Task { await f.model.refresh() }
        try await firstArrived.wait()
        await f.model.switchAccount(to: f.b.id)
        let second = Task { await f.model.refresh() }
        try await secondArrived.wait()
        lateProgress?(RefreshProgress(stage: .pledges, stepNumber: 1, stepCount: 2,
                                      detail: "obsolete", completedUnitCount: 1, totalUnitCount: 2))
        await firstRelease.open(); await first.value
        await f.model.waitForAccountOperationJobs(accountID: f.a.id)
        #expect(f.model.session == f.b)
        #expect(f.model.isRefreshing)
        #expect(f.model.refreshProgress?.detail != "obsolete")
        #expect(f.model.reauthenticationPrompt == nil)
        #expect(f.model.lastRefreshErrorMessage == nil)
        await secondRelease.open(); await second.value
        #expect(f.model.snapshot == f.bSnapshot)
    }

    @Test func explicitCancellationRejectsNoncooperativeResultAndClearsOwnPresentation() async throws {
        let f = operationFixture()
        defer { f.repository.fetchOverride = nil; f.repository.meltOverride = nil }
        let arrived = TestGate(), release = IgnoringCancellationGate()
        defer { Task { await release.open() } }
        f.repository.fetchOverride = { _, _ in
            await arrived.open(); await release.wait()
            return f.aSnapshot.updatingHangarLogs(hangarLogs: [], lastSyncedAt: Date(timeIntervalSince1970: 999))
        }
        let request = Task { await f.model.refresh() }
        try await arrived.wait()
        request.cancel()
        await request.value // Must return before the cancellation-ignoring dependency.
        #expect(!f.model.isRefreshing)
        await release.open()
        await f.model.waitForAccountOperationJobs(accountID: f.a.id)
        #expect(f.model.snapshot == f.aSnapshot)
        #expect(f.model.lastRefreshErrorMessage == nil)
        #expect(f.snapshots.savedIDs.isEmpty)
    }

    @Test func alreadyCancelledRefreshDoesNotSubmitARequest() async {
        let f = operationFixture()
        let request = Task { await f.model.refresh() }
        request.cancel()
        await request.value
        #expect(f.repository.invocationLog().isEmpty)
        #expect(!f.model.isRefreshing)
        #expect(f.model.snapshot == f.aSnapshot)
    }

    @Test func oldCachedRestoreCannotApplyAfterSignOut() async throws {
        let f = operationFixture()
        defer { f.repository.fetchOverride = nil; f.repository.meltOverride = nil }
        let arrived = TestGate(), release = IgnoringCancellationGate()
        defer { Task { await release.open() } }
        f.snapshots.beforeLoad = { session in
            if session.id == f.b.id { await arrived.open(); await release.wait() }
        }
        let restore = Task { await f.model.switchAccount(to: f.b.id) }
        try await arrived.wait()
        await f.model.clearSession()
        await release.open(); await restore.value
        #expect(f.model.session == nil)
        #expect(f.model.snapshot == nil)
        #expect(f.repository.invocationLog().isEmpty)
    }

    @Test func mutationGateStartsBeforeAuthorizationAndSwitchPreventsSubmission() async throws {
        let arrived = TestGate(), release = IgnoringCancellationGate()
        defer { Task { await release.open() } }
        let f = operationFixture(authorizer: DelayedOperationAuthorizer(arrived: arrived, release: release))
        defer { f.repository.fetchOverride = nil; f.repository.meltOverride = nil }
        let group = try #require(f.aSnapshot.packages.groupedForInventoryDisplay.first)
        let mutation = Task { try await f.model.melt(packageGroup: group, quantity: 1) }
        try await arrived.wait()
        await #expect(throws: AccountOperationError.self) {
            try await f.model.requestCharacterRepair(reason: "test", issueCouncilURL: nil)
        }
        await f.model.refresh()
        #expect(f.repository.invocationLog().isEmpty)
        await f.model.switchAccount(to: f.b.id)
        await release.open()
        _ = try? await mutation.value
        #expect(f.repository.meltRequests().isEmpty)
        #expect(f.model.session == f.b)
        #expect(f.model.transientBanner == nil)
    }

    @Test func submittedMutationCancelledBySignOutRequiresReviewBeforeRetry() async throws {
        let f = operationFixture()
        defer { f.repository.fetchOverride = nil; f.repository.meltOverride = nil }
        let arrived = TestGate(), release = IgnoringCancellationGate()
        defer { Task { await release.open() } }
        f.repository.meltOverride = { _, ids in
            await arrived.open(); await release.wait()
            return MeltPackagesResult(requestedPledgeIDs: ids, completedPledgeIDs: ids, failedPledgeID: nil,
                                      failureMessage: nil, updatedCookies: f.a.cookies)
        }
        let group = try #require(f.aSnapshot.packages.groupedForInventoryDisplay.first)
        let mutation = Task { try await f.model.melt(packageGroup: group, quantity: 1) }
        try await arrived.wait()
        await f.model.clearSession()
        await release.open(); _ = try? await mutation.value
        await f.model.waitForAccountOperationJobs(accountID: f.a.id)
        #expect(f.model.session == nil)
        #expect(f.model.transientBanner == nil)
        #expect(f.snapshots.savedIDs.isEmpty)
        let pending = AccountOperationCoordinator(defaults: resources.defaults)
        #expect(pending.requiresReview(f.a))
        #expect(f.repository.meltRequests().count == 1)
        f.model.session = f.a; f.model.savedSessions = [f.a]; f.model.loadState = .loaded(f.aSnapshot)
        await #expect(throws: AccountOperationError.self) { try await f.model.melt(packageGroup: group, quantity: 1) }
        #expect(f.repository.meltRequests().count == 1)
        #expect(f.model.requiresMutationReview)
        f.model.acknowledgeMutationReview()
        #expect(f.model.requiresMutationReview)
        await f.model.refresh()
        #expect(f.model.canAcknowledgeMutationReview)
        #expect(f.model.requiresMutationReview)
        f.model.acknowledgeMutationReview()
        #expect(!f.model.requiresMutationReview)
    }

    @Test func browserCookiesRequireTheOriginalAccountAndGeneration() async throws {
        let f = operationFixture()
        defer { f.repository.fetchOverride = nil; f.repository.meltOverride = nil }
        let generation = f.model.accountContextGeneration
        await f.model.switchAccount(to: f.b.id)
        await f.model.persistBrowserCookies(f.a.cookies, for: f.a.id, generation: generation)
        #expect(f.model.session == f.b)
        let stored = await f.sessions.loadSnapshot()
        #expect(stored.activeSession == f.b)
        f.model.savedSessions = [f.a, f.b]
        await f.model.switchAccount(to: f.a.id)
        await f.model.persistBrowserCookies(f.b.cookies, for: f.a.id, generation: generation)
        #expect(f.model.session?.cookies == f.a.cookies)
    }

    @Test func gateRemainsHeldAfterMutationReturnsUntilReconciliationIsHandled() async throws {
        let f = operationFixture()
        defer { f.repository.fetchOverride = nil; f.repository.meltOverride = nil }
        let group = try #require(f.aSnapshot.packages.groupedForInventoryDisplay.first)
        try await f.model.melt(packageGroup: group, quantity: 1)
        #expect(!f.model.requiresMutationReview) // A normal reconciliation is not an uncertain-outcome prompt.
        await #expect(throws: AccountOperationError.self) {
            try await f.model.requestCharacterRepair(reason: "test", issueCouncilURL: nil)
        }
        #expect(f.repository.meltRequests().count == 1)
        await f.model.refresh() // Takes over reconciliation, not a duplicate mutation.
        #expect(f.model.requiresMutationReview)
        #expect(f.model.canAcknowledgeMutationReview)
        f.model.acknowledgeMutationReview()
        #expect(!f.model.requiresMutationReview)
    }

    @Test(arguments: [true, false])
    func delayedSignInCannotPublishToAnObsoleteAuthenticationFlow(authenticated: Bool) async throws {
        let arrived = TestGate(), release = IgnoringCancellationGate()
        defer { Task { await release.open() } }
        let service = OperationAuthenticationService()
        defer { service.signInResult = nil }
        let f = operationFixture(authentication: service)
        defer { f.repository.fetchOverride = nil; f.repository.meltOverride = nil }
        service.signInResult = {
            await arrived.open(); await release.wait()
            return authenticated ? .authenticated(f.a) : .requiresCaptcha(Data([1, 2, 3]))
        }
        let login = AuthenticationViewModel(appModel: f.model)
        login.loginIdentifier = "fixture"; login.password = "fixture"
        let pending = Task { await login.submitCredentials() }
        try await arrived.wait()
        await f.model.switchAccount(to: f.b.id)
        await release.open(); await pending.value
        #expect(f.model.session == f.b)
        #expect(login.step == .signIn)
        #expect(login.captchaImageData == nil)
        #expect(login.errorMessage == nil)
    }

    @Test func definitiveRejectedMutationDoesNotRequireUncertainOutcomeReview() async throws {
        let f = operationFixture()
        defer { f.repository.fetchOverride = nil; f.repository.meltOverride = nil }
        f.repository.meltOverride = { _, ids in
            MeltPackagesResult(requestedPledgeIDs: ids, completedPledgeIDs: [], failedPledgeID: ids.first,
                               failureMessage: "Rejected by fixture", updatedCookies: [])
        }
        let group = try #require(f.aSnapshot.packages.groupedForInventoryDisplay.first)
        await #expect(throws: HangarAccountActionError.self) { try await f.model.melt(packageGroup: group, quantity: 1) }
        #expect(!f.model.requiresMutationReview)
        #expect(f.repository.meltRequests().count == 1)
    }

    @Test func successfulRefreshStillPersistsItsCurrentAccountSnapshot() async {
        let f = operationFixture()
        let fresh = f.aSnapshot.updatingHangarLogs(hangarLogs: [], lastSyncedAt: Date(timeIntervalSince1970: 500))
        f.repository.fetchOverride = { _, _ in fresh }
        defer { f.repository.fetchOverride = nil }
        await f.model.refresh()
        await f.model.waitForAccountOperationJobs(accountID: f.a.id)
        #expect(f.model.snapshot == fresh)
        #expect(f.snapshots.values[f.a.id] == fresh)
        #expect(f.snapshots.savedIDs.contains(f.a.id))
    }

    @Test func delayedCachedRestoreCannotReplaceANewerRefreshForTheSameAccount() async throws {
        let f = operationFixture()
        let arrived = TestGate(), release = IgnoringCancellationGate()
        defer { Task { await release.open() }; f.repository.fetchOverride = nil }
        resources.defaults.set("never", forKey: SyncPreferences.inventoryAutoRefreshIntervalKey)
        let fresh = f.aSnapshot.updatingHangarLogs(hangarLogs: [], lastSyncedAt: Date(timeIntervalSince1970: 500))
        f.snapshots.beforeLoad = { _ in await arrived.open(); await release.wait() }
        f.repository.fetchOverride = { _, _ in fresh }
        let wake = Task { await f.model.handleAppDidBecomeActive() }
        try await arrived.wait()
        await f.model.refresh()
        await release.open(); await wake.value
        await f.model.waitForAccountOperationJobs(accountID: f.a.id)
        #expect(f.model.snapshot == fresh)
        #expect(f.repository.invocationLog() == ["full"])
    }

    @Test func completedReconciliationReleasesTheGateAndSubmitsTheConfirmedInventory() async throws {
        let f = operationFixture()
        let group = try #require(f.aSnapshot.packages.groupedForInventoryDisplay.first)
        let removed = try #require(group.packages.first?.id)
        let confirmed = f.aSnapshot.removingPackages(withIDs: [removed], lastSyncedAt: Date(timeIntervalSince1970: 500))
        f.repository.hangarOverride = { _, _ in confirmed }
        defer { f.repository.hangarOverride = nil }
        try await f.model.melt(packageGroup: group, quantity: 1)
        await f.model.waitForAccountOperationJobs(accountID: f.a.id)
        #expect(f.model.snapshot == confirmed)
        // #4 owns ordering of writes already accepted by SnapshotStore. Verify
        // this operation submitted the confirmed state, not a disk-ordering claim.
        #expect(f.snapshots.savedSnapshots.map(\.lastSyncedAt).contains(confirmed.lastSyncedAt))
        #expect(!f.model.requiresMutationReview)
        // Invalid input reaches validation only if the mutation gate is released;
        // it sends no checkout request and must not produce AccountOperationError.busy.
        await #expect(throws: HangarAccountActionError.self) { try await f.model.prepareWBCCUCheckout(items: []) }
    }

    @Test func authenticationTransitionCannotBypassAnAccountSwitchInProgress() async throws {
        let arrived = TestGate(), release = TestGate()
        defer { Task { await release.open() } }
        let service = OperationAuthenticationService()
        service.onCancel = { await arrived.open(); try? await release.wait() }
        defer { service.onCancel = nil }
        let f = operationFixture(authentication: service)
        let switching = Task { await f.model.switchAccount(to: f.b.id) }
        try await arrived.wait()
        await f.model.beginReauthentication()
        await release.open(); await switching.value
        #expect(f.model.session == f.b)
        #expect(await f.sessions.loadSnapshot().activeSession == f.b)
        #expect(f.model.consumePendingAuthenticationDraft() == nil)
    }

    @Test func oldAuthenticationFlowCannotReplaceTheCurrentAccount() async {
        let f = operationFixture()
        defer { f.repository.fetchOverride = nil; f.repository.meltOverride = nil }
        let flow = f.model.authenticationFlowID
        await f.model.switchAccount(to: f.b.id)
        await f.model.completeAuthentication(f.a, expectedFlowID: flow)
        #expect(f.model.session == f.b)
    }

    private func operationFixture(authorizer: (any SensitiveActionAuthorizing)? = nil,
                                  authentication: (any AuthenticationServicing)? = nil) -> OperationFixture {
        let a = operationSession("a"), b = operationSession("b")
        let aSnapshot = PreviewHangarRepository.sampleSnapshot.updatingHangarLogs(hangarLogs: [], lastSyncedAt: Date(timeIntervalSince1970: 10))
        let bSnapshot = PreviewHangarRepository.sampleSnapshot.updatingHangarLogs(hangarLogs: [], lastSyncedAt: Date(timeIntervalSince1970: 20))
        let sessions = FakeSessionStore(storedSnapshot: .init(activeSession: a, savedSessions: [b, a]))
        let snapshots = OperationSnapshotStore(values: [a.id: aSnapshot, b.id: bSnapshot])
        let repository = FakeHangarRepository(snapshot: aSnapshot)
        let model = AppModel(environment: makeTestAppEnvironment(sessionStore: sessions, snapshotStore: snapshots,
                                                                hangarRepository: repository, actionAuthorizer: authorizer, authenticationService: authentication))
        model.session = a; model.savedSessions = [b, a]; model.loadState = .loaded(aSnapshot)
        return OperationFixture(a: a, b: b, aSnapshot: aSnapshot, bSnapshot: bSnapshot,
                                model: model, sessions: sessions, snapshots: snapshots, repository: repository)
    }
}

@MainActor private struct OperationFixture {
    let a: UserSession, b: UserSession
    let aSnapshot: HangarSnapshot, bSnapshot: HangarSnapshot
    let model: AppModel
    let sessions: FakeSessionStore
    let snapshots: OperationSnapshotStore
    let repository: FakeHangarRepository
}

@MainActor private func operationSession(_ name: String) -> UserSession {
    let cookie = HTTPCookie(properties: [.name: "fixture", .value: name, .domain: "example.invalid", .path: "/"])!
    return UserSession(handle: name, displayName: name, email: "\(name)@example.invalid", authMode: .developerPreview,
                       notes: "operation fixture", credentials: .init(loginIdentifier: name, password: "fixture"),
                       cookies: [SessionCookie(cookie)], createdAt: Date(timeIntervalSince1970: 1))
}

@MainActor private final class OperationSnapshotStore: SnapshotStore {
    var values: [UUID: HangarSnapshot]
    var savedIDs: [UUID] = []
    var savedSnapshots: [HangarSnapshot] = []
    var beforeLoad: ((UserSession) async -> Void)?
    init(values: [UUID: HangarSnapshot]) { self.values = values }
    func load(for session: UserSession) async -> HangarSnapshot? {
        let captured = values[session.id]
        await beforeLoad?(session)
        return captured
    }
    func save(_ snapshot: HangarSnapshot, for session: UserSession) async { savedIDs.append(session.id); savedSnapshots.append(snapshot); values[session.id] = snapshot }
    func delete(for session: UserSession) async { values.removeValue(forKey: session.id) }
    func clear() async { values.removeAll() }
}

/// Deliberately ignores cancellation to prove generation fences, not just Task.cancel().
private actor IgnoringCancellationGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { opened = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}

private struct DelayedOperationAuthorizer: SensitiveActionAuthorizing {
    let arrived: TestGate
    let release: IgnoringCancellationGate
    @MainActor func authorize(reason: String) async throws { await arrived.open(); await release.wait() }
}

@MainActor private final class OperationAuthenticationService: AuthenticationServicing {
    var signInResult: (() async throws -> SignInOutcome)?
    var onCancel: (() async -> Void)?
    func signIn(loginIdentifier: String, password: String, rememberMe: Bool, forceBrowserLogin: Bool) async throws -> SignInOutcome {
        try await signInResult?() ?? .requiresTwoFactor
    }
    func submitCaptcha(_ code: String) async throws -> SignInOutcome { .requiresTwoFactor }
    func submitTwoFactor(code: String, deviceName: String, trustDuration: TrustedDeviceDuration) async throws -> UserSession { operationSession("auth") }
    func beginReadOnlySignIn() async throws -> SignInOutcome { .requiresTwoFactor }
    func rememberBrowserExportedCookies(_ cookies: [SessionCookie]) async {}
    func canCompleteBrowserAuthentication(cookies: [SessionCookie]) async -> Bool { false }
    func completeBrowserAuthentication(cookies: [SessionCookie], trustBrowserSession: Bool) async throws -> UserSession { operationSession("auth") }
    func cancelPendingAuthentication() async { await onCancel?() }
}
