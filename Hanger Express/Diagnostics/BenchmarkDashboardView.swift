#if DEBUG || HANGAR_BENCHMARKS
import SwiftUI

/// An explicit launch environment selects this offline fixture screen. It is
/// absent from normal Release builds and never bootstraps the signed-in account.
struct BenchmarkDashboardView: View {
    static var requestedSize: Int? {
        guard let raw = ProcessInfo.processInfo.environment["HANGAR_BENCHMARK_UI_SIZE"],
              let count = Int(raw), BenchmarkInventory.sizes.contains(count) else { return nil }
        return count
    }

    @State private var appModel: AppModel
    private let snapshot: HangarSnapshot
    private let defaults: UserDefaults

    init(count: Int) {
        let workload = BenchmarkInventory.make(pledgeCount: count)
        snapshot = workload.snapshot
        defaults = UserDefaults(suiteName: "HangarExpress.OfflineBenchmark")!
        defaults.removePersistentDomain(forName: "HangarExpress.OfflineBenchmark")
        defaults.set("english", forKey: AppLanguage.storageKey)
        defaults.set("never", forKey: SyncPreferences.inventoryAutoRefreshIntervalKey)
        let preview = AppEnvironment.preview
        let environment = AppEnvironment(
            sessionStore: preview.sessionStore, snapshotStore: preview.snapshotStore,
            imageCache: preview.imageCache, hangarRepository: preview.hangarRepository,
            sensitiveActionAuthorizer: preview.sensitiveActionAuthorizer,
            authService: preview.authService, recaptchaBroker: preview.recaptchaBroker,
            authIPRegionChecker: preview.authIPRegionChecker,
            authDiagnostics: preview.authDiagnostics, refreshDiagnostics: preview.refreshDiagnostics,
            subscriptionStore: SubscriptionStore(userDefaults: defaults, storeKitEnabled: false),
            userDefaults: defaults,
            responseCache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            shipCatalogStore: HostedShipCatalogStore(), shipDetailCatalogStore: HostedShipDetailCatalogStore()
        )
        let model = AppModel(environment: environment)
        model.session = workload.session
        model.savedSessions = [workload.session]
        model.loadState = .loaded(workload.snapshot)
        _appModel = State(initialValue: model)
    }

    var body: some View {
        DashboardTabView(appModel: appModel, snapshot: snapshot)
            .keyboardDismissToolbar()
            .accessibilityIdentifier("OfflineBenchmark-\(snapshot.packages.count)")
            .defaultAppStorage(defaults)
            .environment(\.locale, Locale(identifier: "en"))
            .preferredColorScheme(.dark)
    }
}
#endif
