import Foundation

@MainActor
struct AppEnvironment {
    let sessionStore: any SessionStore
    let snapshotStore: any SnapshotStore
    let imageCache: any RemoteImageCaching
    let hangarRepository: any HangarRepository
    let sensitiveActionAuthorizer: any SensitiveActionAuthorizing
    let authService: any AuthenticationServicing
    let recaptchaBroker: RecaptchaBroker
    let authDiagnostics: AuthenticationDiagnosticsStore
    let refreshDiagnostics: RefreshDiagnosticsStore
    let subscriptionStore: SubscriptionStore

    init(
        sessionStore: any SessionStore,
        snapshotStore: any SnapshotStore,
        imageCache: any RemoteImageCaching,
        hangarRepository: any HangarRepository,
        sensitiveActionAuthorizer: any SensitiveActionAuthorizing,
        authService: any AuthenticationServicing,
        recaptchaBroker: RecaptchaBroker,
        authDiagnostics: AuthenticationDiagnosticsStore,
        refreshDiagnostics: RefreshDiagnosticsStore,
        subscriptionStore: SubscriptionStore
    ) {
        self.sessionStore = sessionStore
        self.snapshotStore = snapshotStore
        self.imageCache = imageCache
        self.hangarRepository = hangarRepository
        self.sensitiveActionAuthorizer = sensitiveActionAuthorizer
        self.authService = authService
        self.recaptchaBroker = recaptchaBroker
        self.authDiagnostics = authDiagnostics
        self.refreshDiagnostics = refreshDiagnostics
        self.subscriptionStore = subscriptionStore
    }

    static var preview: AppEnvironment {
        let diagnostics = AuthenticationDiagnosticsStore()
        let refreshDiagnostics = RefreshDiagnosticsStore()
        let broker = RecaptchaBroker(diagnostics: diagnostics)
        return AppEnvironment(
            sessionStore: PreviewSessionStore(),
            snapshotStore: PreviewSnapshotStore(),
            imageCache: URLCachedImageStore.shared,
            hangarRepository: PreviewHangarRepository(),
            sensitiveActionAuthorizer: PreviewSensitiveActionAuthorizer(),
            authService: PreviewAuthenticationService(diagnostics: diagnostics),
            recaptchaBroker: broker,
            authDiagnostics: diagnostics,
            refreshDiagnostics: refreshDiagnostics,
            subscriptionStore: SubscriptionStore(storeKitEnabled: false)
        )
    }

    static var live: AppEnvironment {
        let diagnostics = AuthenticationDiagnosticsStore()
        let refreshDiagnostics = RefreshDiagnosticsStore()
        let broker = RecaptchaBroker(diagnostics: diagnostics)
        return AppEnvironment(
            sessionStore: KeychainSessionStore(),
            snapshotStore: FileSnapshotStore(),
            imageCache: URLCachedImageStore.shared,
            hangarRepository: LiveHangarRepository(diagnostics: refreshDiagnostics),
            sensitiveActionAuthorizer: DeviceOwnerSensitiveActionAuthorizer(),
            authService: RSIAuthService(recaptchaBroker: broker, diagnostics: diagnostics),
            recaptchaBroker: broker,
            authDiagnostics: diagnostics,
            refreshDiagnostics: refreshDiagnostics,
            subscriptionStore: SubscriptionStore()
        )
    }
}
