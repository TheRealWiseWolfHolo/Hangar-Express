import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    struct AuthenticationDraft {
        let loginIdentifier: String
        let password: String
        let rememberMe: Bool
        let notice: String?
    }

    struct ReauthenticationPrompt: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    enum Tab: Hashable {
        case hangar
        case fleet
        case buyback
        case account
    }

    enum RefreshScope: Hashable {
        case full
        case hangar
        case buyback
        case hangarLog
        case account

        var errorSubject: String {
            switch self {
            case .full:
                return "the full account snapshot"
            case .hangar:
                return "the hangar and fleet data"
            case .buyback:
                return "the buy-back data"
            case .hangarLog:
                return "the hangar log"
            case .account:
                return "the account overview"
            }
        }
    }

    enum LoadState {
        case idle
        case loading
        case loaded(HangarSnapshot)
        case failed(String)
    }

    var selectedTab: Tab = .hangar
    var session: UserSession?
    var savedSessions: [UserSession] = []
    var loadState: LoadState = .idle
    var lastRefreshAt: Date?
    var refreshProgress: RefreshProgress?
    var lastRefreshErrorMessage: String?
    var activeRefreshScope: RefreshScope?
    var imageReloadToken = UUID()
    var authenticationFlowID = UUID()
    var reauthenticationPrompt: ReauthenticationPrompt?

    let authService: any AuthenticationServicing
    let recaptchaBroker: RecaptchaBroker

    private let sessionStore: any SessionStore
    private let snapshotStore: any SnapshotStore
    private let imageCache: any RemoteImageCaching
    private let hangarRepository: any HangarRepository
    private var hasBootstrapped = false
    private var pendingAuthenticationDraft: AuthenticationDraft?

    init(environment: AppEnvironment) {
        sessionStore = environment.sessionStore
        snapshotStore = environment.snapshotStore
        imageCache = environment.imageCache
        hangarRepository = environment.hangarRepository
        authService = environment.authService
        recaptchaBroker = environment.recaptchaBroker
    }

    var snapshot: HangarSnapshot? {
        guard case let .loaded(snapshot) = loadState else {
            return nil
        }

        return snapshot
    }

    var isRefreshing: Bool {
        activeRefreshScope != nil
    }

    func isRefreshing(_ scope: RefreshScope) -> Bool {
        guard let activeRefreshScope else {
            return false
        }

        if activeRefreshScope == .full {
            return true
        }

        return activeRefreshScope == scope
    }

    var quickLoginSessions: [UserSession] {
        savedSessions.filter { $0.authMode != .developerPreview }
    }

    func bootstrap() async {
        guard !hasBootstrapped else {
            return
        }

        hasBootstrapped = true
        applyStoredSessions(await sessionStore.loadSnapshot(), resetContent: true)

        if let session {
            let restoredSnapshot = await restoreCachedSnapshot(for: session)
            if !restoredSnapshot {
                await refresh(scope: .full)
            }
        }
    }

    func enablePreviewSession() async {
        let preview = UserSession.preview
        applyStoredSessions(await sessionStore.save(preview, makeActive: true), resetContent: true)
        await refresh(scope: .full)
    }

    func completeAuthentication(_ session: UserSession) async {
        reauthenticationPrompt = nil
        pendingAuthenticationDraft = nil
        applyStoredSessions(await sessionStore.save(session, makeActive: true), resetContent: true)
        await refresh(scope: .full)
    }

    func clearSession() async {
        await authService.cancelPendingAuthentication()
        reauthenticationPrompt = nil
        pendingAuthenticationDraft = nil
        applyStoredSessions(await sessionStore.clear(), resetContent: true)
        await snapshotStore.clear()
        selectedTab = .hangar
    }

    func beginAddingAccount() async {
        await authService.cancelPendingAuthentication()
        reauthenticationPrompt = nil
        pendingAuthenticationDraft = nil
        session = nil
        lastRefreshAt = nil
        loadState = .idle
        refreshProgress = nil
        lastRefreshErrorMessage = nil
        activeRefreshScope = nil
    }

    func switchAccount(to id: UserSession.ID) async {
        guard session?.id != id else {
            return
        }

        await authService.cancelPendingAuthentication()
        reauthenticationPrompt = nil
        pendingAuthenticationDraft = nil
        applyStoredSessions(await sessionStore.selectSession(id: id), resetContent: true)

        if let session {
            let restoredSnapshot = await restoreCachedSnapshot(for: session)
            if !restoredSnapshot {
                await refresh(scope: .full)
            }
        }
    }

    func removeSavedAccount(id: UserSession.ID) async {
        let wasActiveSession = session?.id == id
        let removedSession = savedSessions.first(where: { $0.id == id })
        await authService.cancelPendingAuthentication()
        if let removedSession {
            await snapshotStore.delete(for: removedSession)
        }
        if removedSession?.id == session?.id {
            reauthenticationPrompt = nil
        }
        applyStoredSessions(await sessionStore.deleteSession(id: id), resetContent: wasActiveSession)

        if wasActiveSession, let session {
            let restoredSnapshot = await restoreCachedSnapshot(for: session)
            if !restoredSnapshot {
                await refresh(scope: .full)
            }
        }
    }

    func openSavedAccount(id: UserSession.ID) async {
        guard let savedSession = savedSessions.first(where: { $0.id == id }) else {
            return
        }

        if savedSession.cookies.isEmpty {
            await transitionToAuthentication(
                using: savedSession,
                notice: "This saved RSI account needs a fresh sign-in before live refresh can continue."
            )
            return
        }

        await switchAccount(to: id)
    }

    func refresh(scope: RefreshScope = .full) async {
        guard let session else {
            loadState = .idle
            return
        }

        guard !isRefreshing else {
            return
        }

        let existingSnapshot = snapshot
        let resolvedScope = existingSnapshot == nil ? RefreshScope.full : scope

        if existingSnapshot == nil {
            loadState = .loading
        }
        lastRefreshErrorMessage = nil

        activeRefreshScope = resolvedScope
        refreshProgress = initialProgress(for: session, scope: resolvedScope)

        do {
            let snapshot = try await refreshedSnapshot(
                for: session,
                existingSnapshot: existingSnapshot,
                scope: resolvedScope
            ) { [weak self] progress in
                self?.refreshProgress = progress
            }
            await snapshotStore.save(snapshot, for: session)
            lastRefreshAt = snapshot.lastSyncedAt
            loadState = .loaded(snapshot)
            lastRefreshErrorMessage = nil
        } catch {
            if await handleReauthenticationIfNeeded(
                for: error,
                session: session,
                existingSnapshot: existingSnapshot
            ) {
                refreshProgress = nil
                activeRefreshScope = nil
                return
            }

            let message = "Unable to refresh \(resolvedScope.errorSubject). \(error.localizedDescription)"
            if let existingSnapshot {
                loadState = .loaded(existingSnapshot)
                lastRefreshErrorMessage = message
            } else {
                loadState = .failed(message)
            }
        }

        refreshProgress = nil
        activeRefreshScope = nil
    }

    func dismissRefreshError() {
        lastRefreshErrorMessage = nil
    }

    func dismissReauthenticationPrompt() {
        reauthenticationPrompt = nil
    }

    func beginReauthentication() async {
        guard let session else {
            reauthenticationPrompt = nil
            return
        }

        let notice = reauthenticationPrompt?.message ?? "Your saved RSI session is no longer valid. Sign in again to continue refreshing live data."
        await transitionToAuthentication(using: session, notice: notice)
    }

    func consumePendingAuthenticationDraft() -> AuthenticationDraft? {
        defer { pendingAuthenticationDraft = nil }
        return pendingAuthenticationDraft
    }

    func clearLocalCache() async {
        await snapshotStore.clear()
        await imageCache.clear()
        imageReloadToken = UUID()
        lastRefreshErrorMessage = nil

        guard session != nil else {
            loadState = .idle
            refreshProgress = nil
            activeRefreshScope = nil
            lastRefreshAt = nil
            return
        }

        await refresh(scope: .full)
    }

    private func handleReauthenticationIfNeeded(
        for error: Error,
        session: UserSession,
        existingSnapshot: HangarSnapshot?
    ) async -> Bool {
        guard let liveError = error as? LiveHangarRepositoryError,
              liveError.requiresReauthentication else {
            return false
        }

        let invalidatedSession = session.clearingCookies(
            notes: "The saved RSI session expired and needs a fresh sign-in."
        )
        applyStoredSessions(await sessionStore.save(invalidatedSession, makeActive: true), resetContent: false)
        lastRefreshErrorMessage = nil

        let notice = liveError == .sessionExpired
            ? "Your saved RSI session expired. Sign in again to continue refreshing live data."
            : "This saved RSI account no longer has a usable session. Sign in again to continue refreshing live data."

        if let existingSnapshot {
            loadState = .loaded(existingSnapshot)
            reauthenticationPrompt = ReauthenticationPrompt(
                title: "Sign In Again",
                message: notice
            )
        } else {
            await transitionToAuthentication(using: invalidatedSession, notice: notice)
        }

        return true
    }

    private func transitionToAuthentication(using session: UserSession, notice: String) async {
        await authService.cancelPendingAuthentication()
        reauthenticationPrompt = nil
        pendingAuthenticationDraft = AuthenticationDraft(
            loginIdentifier: session.credentials?.loginIdentifier ?? session.email,
            password: session.credentials?.password ?? "",
            rememberMe: true,
            notice: notice
        )
        authenticationFlowID = UUID()
        selectedTab = .hangar
        self.session = nil
        lastRefreshAt = nil
        loadState = .idle
        refreshProgress = nil
        lastRefreshErrorMessage = nil
        activeRefreshScope = nil
    }

    private func restoreCachedSnapshot(for session: UserSession) async -> Bool {
        guard let cachedSnapshot = await snapshotStore.load(for: session) else {
            return false
        }

        lastRefreshAt = cachedSnapshot.lastSyncedAt
        loadState = .loaded(cachedSnapshot)
        refreshProgress = nil
        lastRefreshErrorMessage = nil
        activeRefreshScope = nil
        reauthenticationPrompt = nil
        return true
    }

    private func refreshedSnapshot(
        for session: UserSession,
        existingSnapshot: HangarSnapshot?,
        scope: RefreshScope,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        switch scope {
        case .full:
            return try await hangarRepository.fetchSnapshot(for: session, progress: progress)
        case .hangar:
            guard let existingSnapshot else {
                return try await hangarRepository.fetchSnapshot(for: session, progress: progress)
            }

            return try await hangarRepository.refreshHangarData(
                for: session,
                from: existingSnapshot,
                progress: progress
            )
        case .buyback:
            guard let existingSnapshot else {
                return try await hangarRepository.fetchSnapshot(for: session, progress: progress)
            }

            return try await hangarRepository.refreshBuybackData(
                for: session,
                from: existingSnapshot,
                progress: progress
            )
        case .hangarLog:
            guard let existingSnapshot else {
                return try await hangarRepository.fetchSnapshot(for: session, progress: progress)
            }

            return try await hangarRepository.refreshHangarLogData(
                for: session,
                from: existingSnapshot,
                progress: progress
            )
        case .account:
            guard let existingSnapshot else {
                return try await hangarRepository.fetchSnapshot(for: session, progress: progress)
            }

            return try await hangarRepository.refreshAccountData(
                for: session,
                from: existingSnapshot,
                progress: progress
            )
        }
    }

    private func initialProgress(for session: UserSession, scope: RefreshScope) -> RefreshProgress {
        if session.authMode == .developerPreview {
            return RefreshProgress(
                stage: .preview,
                stepNumber: 1,
                stepCount: 1,
                detail: "Loading the local sample hangar snapshot.",
                completedUnitCount: 0,
                totalUnitCount: 1
            )
        }

        return RefreshProgress(
            stage: .preparingSession,
            stepNumber: 1,
            stepCount: stepCount(for: scope),
            detail: initialRefreshDetail(for: scope),
            completedUnitCount: 0,
            totalUnitCount: 1
        )
    }

    private func stepCount(for scope: RefreshScope) -> Int {
        switch scope {
        case .full:
            return 5
        case .hangar:
            return 3
        case .buyback, .hangarLog, .account:
            return 2
        }
    }

    private func initialRefreshDetail(for scope: RefreshScope) -> String {
        switch scope {
        case .full:
            return "Preparing your saved RSI cookies for a full refresh."
        case .hangar:
            return "Preparing your saved RSI cookies for a hangar refresh."
        case .buyback:
            return "Preparing your saved RSI cookies for a buy-back refresh."
        case .hangarLog:
            return "Preparing your saved RSI cookies for a hangar log refresh."
        case .account:
            return "Preparing your saved RSI cookies for an account refresh."
        }
    }

    private func applyStoredSessions(_ snapshot: StoredSessionsSnapshot, resetContent: Bool) {
        let previousSessionID = session?.id

        session = snapshot.activeSession
        savedSessions = snapshot.savedSessions

        guard resetContent || previousSessionID != snapshot.activeSession?.id else {
            return
        }

        lastRefreshAt = nil
        loadState = .idle
        refreshProgress = nil
        lastRefreshErrorMessage = nil
        activeRefreshScope = nil
    }
}
