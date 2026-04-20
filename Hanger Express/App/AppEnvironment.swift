import Foundation

struct AppEnvironment {
    let sessionStore: any SessionStore
    let snapshotStore: any SnapshotStore
    let imageCache: any RemoteImageCaching
    let hangarRepository: any HangarRepository
    let authService: any AuthenticationServicing
    let recaptchaBroker: RecaptchaBroker
    let authDiagnostics: AuthenticationDiagnosticsStore

    init(
        sessionStore: any SessionStore,
        snapshotStore: any SnapshotStore,
        imageCache: any RemoteImageCaching = URLCachedImageStore.shared,
        hangarRepository: any HangarRepository,
        authService: any AuthenticationServicing,
        recaptchaBroker: RecaptchaBroker,
        authDiagnostics: AuthenticationDiagnosticsStore
    ) {
        self.sessionStore = sessionStore
        self.snapshotStore = snapshotStore
        self.imageCache = imageCache
        self.hangarRepository = hangarRepository
        self.authService = authService
        self.recaptchaBroker = recaptchaBroker
        self.authDiagnostics = authDiagnostics
    }

    static var preview: AppEnvironment {
        let diagnostics = AuthenticationDiagnosticsStore()
        let broker = RecaptchaBroker(diagnostics: diagnostics)
        return AppEnvironment(
            sessionStore: PreviewSessionStore(),
            snapshotStore: PreviewSnapshotStore(),
            hangarRepository: PreviewHangarRepository(),
            authService: PreviewAuthenticationService(diagnostics: diagnostics),
            recaptchaBroker: broker,
            authDiagnostics: diagnostics
        )
    }

    static var live: AppEnvironment {
        let diagnostics = AuthenticationDiagnosticsStore()
        let broker = RecaptchaBroker(diagnostics: diagnostics)
        return AppEnvironment(
            sessionStore: KeychainSessionStore(),
            snapshotStore: FileSnapshotStore(),
            hangarRepository: LiveHangarRepository(),
            authService: RSIAuthService(recaptchaBroker: broker, diagnostics: diagnostics),
            recaptchaBroker: broker,
            authDiagnostics: diagnostics
        )
    }
}
