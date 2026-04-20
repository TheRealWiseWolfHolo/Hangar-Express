import Foundation
import Observation

enum SyncPreferences {
    static let workerCountKey = "sync.workerCount"
    static let defaultWorkerCount = 4
    static let minWorkerCount = 1
    static let maxWorkerCount = 10
    static let automaticRefreshInterval: TimeInterval = 48 * 60 * 60
}

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

    struct VersionRefreshPrompt: Identifiable {
        let id = UUID()
        let previousVersion: String
        let currentVersion: String

        var title: String {
            "App Updated"
        }

        var message: String {
            "Hangar Express was updated from \(previousVersion) to \(currentVersion). Run a full refresh so your cached hangar, fleet, buy-back, and log data stay in sync with this build."
        }
    }

    struct StartupActivity: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let detail: String
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
    var hangarFleetImageReloadToken = UUID()
    var buybackImageReloadToken = UUID()
    var accountImageReloadToken = UUID()
    var authenticationFlowID = UUID()
    var reauthenticationPrompt: ReauthenticationPrompt?
    var versionRefreshPrompt: VersionRefreshPrompt?
    var startupActivity: StartupActivity?

    let authService: any AuthenticationServicing
    let recaptchaBroker: RecaptchaBroker
    let authDiagnostics: AuthenticationDiagnosticsStore

    private let sessionStore: any SessionStore
    private let snapshotStore: any SnapshotStore
    private let imageCache: any RemoteImageCaching
    private let hangarRepository: any HangarRepository
    private let userDefaults: UserDefaults
    private var hasBootstrapped = false
    private var pendingAuthenticationDraft: AuthenticationDraft?

    private static let lastLaunchedVersionDefaultsKey = "app.lastLaunchedVersion"

    init(environment: AppEnvironment) {
        sessionStore = environment.sessionStore
        snapshotStore = environment.snapshotStore
        imageCache = environment.imageCache
        hangarRepository = environment.hangarRepository
        authService = environment.authService
        recaptchaBroker = environment.recaptchaBroker
        authDiagnostics = environment.authDiagnostics
        userDefaults = .standard
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
        startupActivity = StartupActivity(
            title: "Starting Hangar Express",
            detail: "Restoring your saved RSI session and local cache."
        )
        authDiagnostics.record(
            stage: "app.bootstrap",
            summary: "Bootstrapping the app and restoring saved RSI sessions."
        )
        defer { startupActivity = nil }
        applyStoredSessions(await sessionStore.loadSnapshot(), resetContent: true)
        detectAppUpdateIfNeeded()
        await reconcileLaunchState()
    }

    func enablePreviewSession() async {
        let preview = UserSession.preview
        applyStoredSessions(await sessionStore.save(preview, makeActive: true), resetContent: true)
        await refresh(scope: .full)
    }

    func completeAuthentication(_ session: UserSession) async {
        reauthenticationPrompt = nil
        pendingAuthenticationDraft = nil
        authDiagnostics.record(
            stage: "auth.complete",
            summary: "Authentication completed. Starting a full refresh for the signed-in account.",
            detail: "displayName=\(session.displayName), cookieCount=\(session.cookies.count)"
        )
        applyStoredSessions(await sessionStore.save(session, makeActive: true), resetContent: true)
        await refresh(scope: .full)
    }

    func clearSession() async {
        await authService.cancelPendingAuthentication()
        authDiagnostics.record(
            stage: "auth.clear-session",
            summary: "Clearing the active RSI session and local snapshot state."
        )
        reauthenticationPrompt = nil
        pendingAuthenticationDraft = nil
        applyStoredSessions(await sessionStore.clear(), resetContent: true)
        await snapshotStore.clear()
        selectedTab = .hangar
    }

    func clearSavedKeychainContent() async {
        await authService.cancelPendingAuthentication()
        authDiagnostics.record(
            stage: "auth.clear-keychain",
            summary: "Removing all saved RSI accounts, cookies, and credentials from Keychain.",
            level: .warning
        )
        reauthenticationPrompt = nil
        pendingAuthenticationDraft = nil
        authenticationFlowID = UUID()
        applyStoredSessions(await sessionStore.clear(), resetContent: true)
        selectedTab = .hangar
    }

    func beginAddingAccount() async {
        await authService.cancelPendingAuthentication()
        authDiagnostics.record(
            stage: "auth.add-account",
            summary: "Opening a fresh sign-in flow for a new or replacement RSI account."
        )
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
        authDiagnostics.record(
            stage: "auth.switch-account",
            summary: "Switching to another saved RSI account."
        )
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
        authDiagnostics.record(
            stage: "auth.remove-saved-account",
            summary: "Removing a saved RSI account from local storage.",
            detail: "wasActive=\(wasActiveSession)",
            level: .warning
        )
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
            authDiagnostics.record(
                stage: "auth.saved-account",
                summary: "The selected saved account does not have reusable RSI cookies and needs a fresh sign-in.",
                detail: "displayName=\(savedSession.displayName)",
                level: .warning
            )
            await transitionToAuthentication(
                using: savedSession,
                notice: "This saved RSI account needs a fresh sign-in before live refresh can continue."
            )
            return
        }

        authDiagnostics.record(
            stage: "auth.saved-account",
            summary: "Opening a saved RSI account with stored cookies.",
            detail: "displayName=\(savedSession.displayName), cookieCount=\(savedSession.cookies.count)"
        )
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
            await invalidateImageCache(
                for: resolvedScope,
                previousSnapshot: existingSnapshot,
                refreshedSnapshot: snapshot
            )
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

    func dismissVersionRefreshPrompt() {
        versionRefreshPrompt = nil
    }

    func handleAppDidBecomeActive() async {
        guard hasBootstrapped else {
            await bootstrap()
            return
        }

        startupActivity = StartupActivity(
            title: "Waking Up",
            detail: "Checking your saved RSI session and cached hangar data."
        )
        defer { startupActivity = nil }
        await reconcileLaunchState()
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
        hangarFleetImageReloadToken = UUID()
        buybackImageReloadToken = UUID()
        accountImageReloadToken = UUID()
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
        authDiagnostics.record(
            stage: "auth.reauthenticate",
            summary: "The saved RSI session can no longer refresh live data and needs a fresh sign-in.",
            detail: "reason=\(liveError.localizedDescription)",
            level: .warning
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
        authDiagnostics.record(
            stage: "auth.transition",
            summary: "Returning to the login flow for the selected RSI account.",
            detail: "displayName=\(session.displayName), notice=\(notice)"
        )
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

    private func reconcileLaunchState() async {
        guard let session else {
            authDiagnostics.record(
                stage: "auth.launch-state",
                summary: "No active RSI session was found. Showing the login flow."
            )
            loadState = .idle
            return
        }

        guard session.authMode == .developerPreview || !session.cookies.isEmpty else {
            authDiagnostics.record(
                stage: "auth.launch-state",
                summary: "An active RSI account was found, but it no longer has saved cookies.",
                detail: "displayName=\(session.displayName)",
                level: .warning
            )
            await transitionToAuthentication(
                using: session,
                notice: "Your saved RSI session is no longer available. Sign in again to continue."
            )
            return
        }

        let restoredSnapshot = await restoreCachedSnapshot(for: session)

        if restoredSnapshot {
            authDiagnostics.record(
                stage: "auth.launch-state",
                summary: "Restored the cached snapshot for the active RSI account.",
                detail: "displayName=\(session.displayName), shouldAutoRefresh=\(shouldAutoRefreshAfterResume)"
            )
            guard shouldAutoRefreshAfterResume else {
                return
            }

            await refresh(scope: .full)
            return
        }

        authDiagnostics.record(
            stage: "auth.launch-state",
            summary: "No cached snapshot was available for the active RSI account. Starting a full refresh.",
            detail: "displayName=\(session.displayName)"
        )
        await refresh(scope: .full)
    }

    private var shouldAutoRefreshAfterResume: Bool {
        guard session != nil,
              !isRefreshing,
              versionRefreshPrompt == nil else {
            return false
        }

        guard let lastRefreshAt else {
            return true
        }

        return Date().timeIntervalSince(lastRefreshAt) >= SyncPreferences.automaticRefreshInterval
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

    private func detectAppUpdateIfNeeded() {
        guard let currentVersion = currentAppVersionIdentifier() else {
            return
        }

        let previousVersion = userDefaults.string(forKey: Self.lastLaunchedVersionDefaultsKey)
        userDefaults.set(currentVersion, forKey: Self.lastLaunchedVersionDefaultsKey)

        guard let previousVersion,
              previousVersion != currentVersion,
              session != nil else {
            return
        }

        versionRefreshPrompt = VersionRefreshPrompt(
            previousVersion: previousVersion,
            currentVersion: currentVersion
        )
    }

    private func currentAppVersionIdentifier() -> String? {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines), buildVersion?.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case let (.some(shortVersion), .some(buildVersion)) where !shortVersion.isEmpty && !buildVersion.isEmpty:
            return "\(shortVersion) (\(buildVersion))"
        case let (.some(shortVersion), _) where !shortVersion.isEmpty:
            return shortVersion
        case let (_, .some(buildVersion)) where !buildVersion.isEmpty:
            return buildVersion
        default:
            return nil
        }
    }

    private func invalidateImageCache(
        for scope: RefreshScope,
        previousSnapshot: HangarSnapshot?,
        refreshedSnapshot: HangarSnapshot
    ) async {
        let urlsToInvalidate = imageURLsToInvalidate(
            for: scope,
            previousSnapshot: previousSnapshot,
            refreshedSnapshot: refreshedSnapshot
        )

        guard !urlsToInvalidate.isEmpty || scope == .full else {
            return
        }

        if !urlsToInvalidate.isEmpty {
            await imageCache.clear(urls: Array(urlsToInvalidate))
        }

        switch scope {
        case .full:
            hangarFleetImageReloadToken = UUID()
            buybackImageReloadToken = UUID()
            accountImageReloadToken = UUID()
        case .hangar:
            hangarFleetImageReloadToken = UUID()
        case .buyback:
            buybackImageReloadToken = UUID()
        case .account:
            accountImageReloadToken = UUID()
        case .hangarLog:
            break
        }
    }

    private func imageURLsToInvalidate(
        for scope: RefreshScope,
        previousSnapshot: HangarSnapshot?,
        refreshedSnapshot: HangarSnapshot
    ) -> Set<URL> {
        let previousURLs: Set<URL>
        let refreshedURLs: Set<URL>

        switch scope {
        case .full:
            previousURLs = allImageURLs(in: previousSnapshot)
            refreshedURLs = allImageURLs(in: refreshedSnapshot)
        case .hangar:
            previousURLs = hangarAndFleetImageURLs(in: previousSnapshot)
            refreshedURLs = hangarAndFleetImageURLs(in: refreshedSnapshot)
        case .buyback:
            previousURLs = buybackImageURLs(in: previousSnapshot)
            refreshedURLs = buybackImageURLs(in: refreshedSnapshot)
        case .account:
            previousURLs = accountImageURLs(in: previousSnapshot)
            refreshedURLs = accountImageURLs(in: refreshedSnapshot)
        case .hangarLog:
            return []
        }

        return previousURLs.union(refreshedURLs)
    }

    private func allImageURLs(in snapshot: HangarSnapshot?) -> Set<URL> {
        hangarAndFleetImageURLs(in: snapshot)
            .union(buybackImageURLs(in: snapshot))
            .union(accountImageURLs(in: snapshot))
    }

    private func hangarAndFleetImageURLs(in snapshot: HangarSnapshot?) -> Set<URL> {
        guard let snapshot else {
            return []
        }

        var urls = Set<URL>()

        for package in snapshot.packages {
            if let thumbnailURL = package.thumbnailURL {
                urls.insert(thumbnailURL)
            }

            for item in package.contents {
                if let imageURL = item.imageURL {
                    urls.insert(imageURL)
                }
            }
        }

        for ship in snapshot.fleet {
            if let imageURL = ship.imageURL {
                urls.insert(imageURL)
            }
        }

        return urls
    }

    private func buybackImageURLs(in snapshot: HangarSnapshot?) -> Set<URL> {
        guard let snapshot else {
            return []
        }

        return Set(snapshot.buyback.compactMap(\.imageURL))
    }

    private func accountImageURLs(in snapshot: HangarSnapshot?) -> Set<URL> {
        guard let snapshot else {
            return []
        }

        var urls = Set<URL>()

        if let avatarURL = snapshot.avatarURL {
            urls.insert(avatarURL)
        }

        // Account surfaces can use fleet images as profile-card backgrounds and picker thumbnails.
        for ship in snapshot.fleet {
            if let imageURL = ship.imageURL {
                urls.insert(imageURL)
            }
        }

        return urls
    }
}
