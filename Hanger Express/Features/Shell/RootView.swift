import SwiftUI

struct RootView: View {
    let appModel: AppModel

    var body: some View {
        Group {
            if appModel.session == nil {
                PlanningLandingView(appModel: appModel)
            } else {
                switch appModel.loadState {
                case .idle, .loading:
                    NavigationStack {
                        VStack(spacing: 24) {
                            RefreshProgressCard(progress: appModel.refreshProgress ?? fallbackProgress)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                        .navigationTitle("Loading")
                    }
                case let .loaded(snapshot):
                    DashboardTabView(appModel: appModel, snapshot: snapshot)
                case let .failed(message):
                    NavigationStack {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Refresh failed")
                                .font(.title2.bold())
                            Text(message)
                                .foregroundStyle(.secondary)

                            Button("Try Again") {
                                Task {
                                    await appModel.refresh()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding()
                        .navigationTitle("Connection")
                    }
                }
            }
        }
        .task {
            await appModel.bootstrap()
        }
    }

    private var fallbackProgress: RefreshProgress {
        RefreshProgress(
            stage: .preparingSession,
            stepNumber: 1,
            stepCount: 4,
            detail: "Starting the hangar refresh.",
            completedUnitCount: 0,
            totalUnitCount: nil
        )
    }
}
