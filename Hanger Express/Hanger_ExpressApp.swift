import SwiftUI

@main
struct Hanger_ExpressApp: App {
    @State private var appModel: AppModel
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @AppStorage(AppAppearance.storageKey) private var appAppearanceRawValue = AppAppearance.system.rawValue

    init() {
        if Self.usesSyntheticHost {
            AppLocalizer.updateCurrentLanguage(rawValue: AppLanguage.english.rawValue)
        }
        _appModel = State(initialValue: AppModel(environment: Self.usesSyntheticHost ? .preview : .live))
    }

    private static var isUnitTestHost: Bool {
        #if DEBUG || HANGAR_BENCHMARKS
        ProcessInfo.processInfo.environment["HANGAR_UNIT_TEST_HOST"] == "1"
        #else
        false
        #endif
    }

    private static var usesSyntheticHost: Bool {
        #if DEBUG || HANGAR_BENCHMARKS
        isUnitTestHost || BenchmarkDashboardView.requestedSize != nil
        #else
        false
        #endif
    }

    private var appLanguage: AppLanguage {
        AppLanguage.resolved(from: appLanguageRawValue)
    }

    private var appAppearance: AppAppearance {
        AppAppearance.resolved(from: appAppearanceRawValue)
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG || HANGAR_BENCHMARKS
            if let count = BenchmarkDashboardView.requestedSize {
                BenchmarkDashboardView(count: count)
            } else {
                applicationContent
            }
            #else
            applicationContent
            #endif
        }
    }

    @ViewBuilder
    private var applicationContent: some View {
        if Self.isUnitTestHost {
            // Unit tests do not start login, StoreKit, or refresh tasks.
            Color.clear
        } else {
            ContentView(appModel: appModel)
                .environment(\.locale, appLanguage.locale)
                .preferredColorScheme(appAppearance.colorScheme)
                .onChange(of: appLanguageRawValue, initial: true) { _, newValue in
                    AppLocalizer.updateCurrentLanguage(rawValue: newValue)
                }
        }
    }
}
