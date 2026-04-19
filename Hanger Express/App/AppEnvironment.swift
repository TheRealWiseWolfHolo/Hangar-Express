import Foundation

struct AppEnvironment {
    let sessionStore: any SessionStore
    let snapshotStore: any SnapshotStore
    let imageCache: any RemoteImageCaching
    let hangarRepository: any HangarRepository
    let authService: any AuthenticationServicing
    let recaptchaBroker: RecaptchaBroker

    init(
        sessionStore: any SessionStore,
        snapshotStore: any SnapshotStore,
        imageCache: any RemoteImageCaching = URLCachedImageStore.shared,
        hangarRepository: any HangarRepository,
        authService: any AuthenticationServicing,
        recaptchaBroker: RecaptchaBroker
    ) {
        self.sessionStore = sessionStore
        self.snapshotStore = snapshotStore
        self.imageCache = imageCache
        self.hangarRepository = hangarRepository
        self.authService = authService
        self.recaptchaBroker = recaptchaBroker
    }

    static var preview: AppEnvironment {
        let broker = RecaptchaBroker()
        return AppEnvironment(
            sessionStore: PreviewSessionStore(),
            snapshotStore: PreviewSnapshotStore(),
            hangarRepository: PreviewHangarRepository(),
            authService: PreviewAuthenticationService(),
            recaptchaBroker: broker
        )
    }

    static var live: AppEnvironment {
        let broker = RecaptchaBroker()
        return AppEnvironment(
            sessionStore: KeychainSessionStore(),
            snapshotStore: FileSnapshotStore(),
            hangarRepository: LiveHangarRepository(),
            authService: RSIAuthService(recaptchaBroker: broker),
            recaptchaBroker: broker
        )
    }
}
