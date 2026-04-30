import SwiftUI

@main
struct Hanger_ExpressApp: App {
    @State private var appModel: AppModel
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @AppStorage(AppAppearance.storageKey) private var appAppearanceRawValue = AppAppearance.system.rawValue

    init() {
        _appModel = State(initialValue: AppModel(environment: .live))
    }

    private var appLanguage: AppLanguage {
        AppLanguage.resolved(from: appLanguageRawValue)
    }

    private var appAppearance: AppAppearance {
        AppAppearance.resolved(from: appAppearanceRawValue)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appModel: appModel)
                .environment(\.locale, appLanguage.locale)
                .preferredColorScheme(appAppearance.colorScheme)
        }
    }
}
