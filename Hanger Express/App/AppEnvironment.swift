import Foundation

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

    init(
        sessionStore: any SessionStore,
        snapshotStore: any SnapshotStore,
        imageCache: any RemoteImageCaching = URLCachedImageStore.shared,
        hangarRepository: any HangarRepository,
        sensitiveActionAuthorizer: any SensitiveActionAuthorizing,
        authService: any AuthenticationServicing,
        recaptchaBroker: RecaptchaBroker,
        authDiagnostics: AuthenticationDiagnosticsStore,
        refreshDiagnostics: RefreshDiagnosticsStore
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
    }

    static var preview: AppEnvironment {
        let diagnostics = AuthenticationDiagnosticsStore()
        let refreshDiagnostics = RefreshDiagnosticsStore()
        let broker = RecaptchaBroker(diagnostics: diagnostics)
        return AppEnvironment(
            sessionStore: PreviewSessionStore(),
            snapshotStore: PreviewSnapshotStore(),
            hangarRepository: PreviewHangarRepository(),
            sensitiveActionAuthorizer: PreviewSensitiveActionAuthorizer(),
            authService: PreviewAuthenticationService(diagnostics: diagnostics),
            recaptchaBroker: broker,
            authDiagnostics: diagnostics,
            refreshDiagnostics: refreshDiagnostics
        )
    }

    static var live: AppEnvironment {
        let diagnostics = AuthenticationDiagnosticsStore()
        let refreshDiagnostics = RefreshDiagnosticsStore()
        let broker = RecaptchaBroker(diagnostics: diagnostics)
        return AppEnvironment(
            sessionStore: KeychainSessionStore(),
            snapshotStore: FileSnapshotStore(),
            hangarRepository: LiveHangarRepository(diagnostics: refreshDiagnostics),
            sensitiveActionAuthorizer: DeviceOwnerSensitiveActionAuthorizer(),
            authService: RSIAuthService(recaptchaBroker: broker, diagnostics: diagnostics),
            recaptchaBroker: broker,
            authDiagnostics: diagnostics,
            refreshDiagnostics: refreshDiagnostics
        )
    }
}
