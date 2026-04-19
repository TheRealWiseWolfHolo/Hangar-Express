import SwiftUI

struct DashboardTabView: View {
    let appModel: AppModel
    let snapshot: HangarSnapshot

    var body: some View {
        TabView(selection: selection) {
            HangarDashboardView(appModel: appModel, snapshot: snapshot)
                .tabItem {
                    Label("Hangar", systemImage: "shippingbox")
                }
                .tag(AppModel.Tab.hangar)

            FleetView(appModel: appModel, snapshot: snapshot)
                .tabItem {
                    Label("Fleet", systemImage: "airplane")
                }
                .tag(AppModel.Tab.fleet)

            BuybackView(appModel: appModel, snapshot: snapshot)
                .tabItem {
                    Label("Buy Back", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                .tag(AppModel.Tab.buyback)

            AccountView(appModel: appModel, snapshot: snapshot)
                .tabItem {
                    Label("Account", systemImage: "person.crop.circle")
                }
                .tag(AppModel.Tab.account)
        }
        .safeAreaInset(edge: .top) {
            if let progress = appModel.refreshProgress {
                RefreshProgressCard(progress: progress, compact: true)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: appModel.refreshProgress)
        .alert(item: dashboardAlert) { alert in
            switch alert {
            case let .reauthentication(prompt):
                return Alert(
                    title: Text(prompt.title),
                    message: Text(prompt.message),
                    primaryButton: .default(Text("Sign In Again")) {
                        Task {
                            await appModel.beginReauthentication()
                        }
                    },
                    secondaryButton: .cancel(Text("Later")) {
                        appModel.dismissReauthenticationPrompt()
                    }
                )
            case let .refreshFailure(message):
                return Alert(
                    title: Text("Refresh Failed"),
                    message: Text(message),
                    dismissButton: .cancel(Text("OK")) {
                        appModel.dismissRefreshError()
                    }
                )
            }
        }
    }

    private var selection: Binding<AppModel.Tab> {
        Binding(
            get: { appModel.selectedTab },
            set: { appModel.selectedTab = $0 }
        )
    }

    private var dashboardAlert: Binding<DashboardAlert?> {
        Binding(
            get: {
                if let prompt = appModel.reauthenticationPrompt {
                    return .reauthentication(prompt)
                }

                if let message = appModel.lastRefreshErrorMessage {
                    return .refreshFailure(message)
                }

                return nil
            },
            set: { alert in
                guard alert == nil else {
                    return
                }

                if appModel.reauthenticationPrompt != nil {
                    appModel.dismissReauthenticationPrompt()
                } else {
                    appModel.dismissRefreshError()
                }
            }
        )
    }
}

private enum DashboardAlert: Identifiable {
    case reauthentication(AppModel.ReauthenticationPrompt)
    case refreshFailure(String)

    var id: String {
        switch self {
        case let .reauthentication(prompt):
            return "reauth:\(prompt.id.uuidString)"
        case let .refreshFailure(message):
            return "refresh:\(message)"
        }
    }
}
