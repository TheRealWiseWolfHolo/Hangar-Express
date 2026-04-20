import SwiftUI

struct ContentView: View {
    let appModel: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootView(appModel: appModel)
            .task {
                await appModel.bootstrap()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else {
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
