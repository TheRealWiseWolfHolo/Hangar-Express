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
        .sheet(item: versionRefreshPromptBinding) { prompt in
            VersionRefreshPromptSheet(
                prompt: prompt,
                onRefreshNow: {
                    appModel.dismissVersionRefreshPrompt()
                    Task {
                        await appModel.refresh(scope: .full)
                    }
                },
                onLater: {
                    appModel.dismissVersionRefreshPrompt()
                }
            )
            .presentationDetents([.height(240)])
            .presentationDragIndicator(.visible)
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

    private var versionRefreshPromptBinding: Binding<AppModel.VersionRefreshPrompt?> {
        Binding(
            get: { appModel.versionRefreshPrompt },
            set: { newValue in
                if newValue == nil {
                    appModel.dismissVersionRefreshPrompt()
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

private struct VersionRefreshPromptSheet: View {
    let prompt: AppModel.VersionRefreshPrompt
    let onRefreshNow: () -> Void
    let onLater: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(prompt.title)
                    .font(.title3.bold())

                Text(prompt.message)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Later", action: onLater)
                        .buttonStyle(.bordered)

                    Button("Refresh Now", action: onRefreshNow)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
