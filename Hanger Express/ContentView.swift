import SwiftUI

struct ContentView: View {
    let appModel: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootView(appModel: appModel)
            .keyboardDismissToolbar()
            .alert(AppLocalizer.string(appModel.sessionStorageErrorMessage != nil ? "Secure Storage" : "Local Storage"), isPresented: Binding(
                get: { (appModel.sessionStorageErrorMessage != nil || appModel.snapshotStorageErrorMessage != nil) },
                set: { if !$0 { appModel.sessionStorageErrorMessage = nil; appModel.snapshotStorageErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { appModel.sessionStorageErrorMessage = nil; appModel.snapshotStorageErrorMessage = nil }
            } message: {
                Text(appModel.sessionStorageErrorMessage ?? appModel.snapshotStorageErrorMessage ?? "")
            }
            .task {
                await appModel.bootstrap()
                #if DEBUG || HANGAR_BENCHMARKS
                await PerformanceLiveRefreshRunner.runIfRequested(appModel)
                #endif
            }
            .task {
                await appModel.prepareSubscriptions()
            }
            .onChange(of: appModel.isPro) { _, isPro in
                if isPro {
                    Task {
                        await appModel.reportPremiumTranslationOccurrencesIfNeeded()
                    }
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else {
                    appModel.handleAppDidLeaveActiveState()
                    Task {
                        await OnDeviceHangarItemTranslationService.shared.flushPersistedCache()
                    }
                    return
                }

                Task {
                    await appModel.handleAppDidBecomeActive()
                }
            }
    }
}

#Preview {
    ContentView(appModel: AppModel(environment: .preview))
}
